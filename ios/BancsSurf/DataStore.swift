import Foundation
import SwiftUI
import UIKit

/// Charge les données : serveur (hébergement GitHub Pages, ou le Mac) → cache disque → copie embarquée dans le bundle.
@MainActor
final class DataStore: ObservableObject {
    /// Recalculées chaque heure par .github/workflows/donnees.yml.
    static let urlHebergee = "https://ucheyrou.github.io/bancs-surf"
    /// Vide = hébergement ; sinon l'adresse d'un Mac qui exécute ./serve.sh.
    @AppStorage("baseURL") var baseURL: String = ""
    @Published var scoring: Scoring? { didSet { dates = scoring?.time.map(Fmt.date) ?? [] } }
    @Published var previsions: Previsions? { didSet { instants = Self.calculerInstants(previsions) } }
    @Published var spots: [SpotInfo] = []
    @Published var scenes: [SceneSat] = []
    @Published var meta: Meta?
    @Published var gouf: GoufFichier?
    @Published var statut: String = ""
    @Published var enCours = false
    @Published var source: String = ""

    /// Dates des heures notées, et prévisions heure par heure : calculées une fois au chargement
    /// (les vues les interrogent des centaines de fois par affichage).
    private(set) var dates: [Date] = []
    private(set) var instants: [Instant] = []
    var spotsParId: [String: SpotInfo] { Dictionary(uniqueKeysWithValues: spots.map { ($0.id, $0) }) }

    private var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("donnees")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func url(_ chemin: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? Self.urlHebergee : baseURL
        return URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/" + chemin)
    }

    /// Données brutes d'un fichier : réseau si demandé, sinon cache, sinon bundle.
    private func donnees(_ nom: String, reseau: Bool) async -> (Data, String)? {
        if reseau, let u = url(nom) {
            var req = URLRequest(url: u); req.timeoutInterval = 8; req.cachePolicy = .reloadIgnoringLocalCacheData
            if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 {
                try? d.write(to: cacheDir.appendingPathComponent(nom))
                return (d, "serveur")
            }
        }
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent(nom)) { return (d, "cache") }
        if let u = Bundle.main.url(forResource: nom, withExtension: nil, subdirectory: "Data"), let d = try? Data(contentsOf: u) { return (d, "embarqué") }
        return nil
    }

    func charger(reseau: Bool = true) async {
        enCours = true; defer { enCours = false }
        let dec = JSONDecoder()
        var sources: [String] = []
        func lire<T: Decodable>(_ nom: String, _ t: T.Type) async -> T? {
            guard let (d, src) = await donnees(nom, reseau: reseau) else { statut = "\(nom) introuvable"; return nil }
            sources.append(src)
            do { return try dec.decode(t, from: d) } catch { statut = "\(nom) : \(error.localizedDescription)"; print(error); return nil }
        }
        // petits fichiers d'abord (la carte et les listes s'affichent tout de suite), scoring en dernier
        if let sp: [SpotInfo] = await lire("spots.json", [SpotInfo].self) { spots = sp }
        if let m: Meta = await lire("meta.json", Meta.self) { meta = m }
        if let g: GoufFichier = await lire("gouf_spots.json", GoufFichier.self) { gouf = g }
        if let sc: [SceneSat] = await lire("scenes.json", [SceneSat].self) { scenes = sc }
        if let p: Previsions = await lire("previsions.json", Previsions.self) { previsions = p }
        if let s: Scoring = await lire("scoring.json", Scoring.self) { scoring = s }
        source = sources.contains("serveur") ? "serveur" : sources.contains("cache") ? "cache" : "embarqué"
        if let g = meta?.genere_utc {
            let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEE d MMM HH:mm"
            statut = "données du \(f.string(from: Fmt.date(g))) (\(source))"
        }
    }

    // MARK: images (overlays, planches) avec cache mémoire + disque + bundle
    private var imagesMem: [String: UIImage] = [:]
    func image(_ chemin: String) async -> UIImage? {
        if let i = imagesMem[chemin] { return i }
        let local = cacheDir.appendingPathComponent(chemin.replacingOccurrences(of: "/", with: "_"))
        if let u = url(chemin) {
            var req = URLRequest(url: u); req.timeoutInterval = 15
            if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: d) {
                try? d.write(to: local); imagesMem[chemin] = img; return img
            }
        }
        if let d = try? Data(contentsOf: local), let img = UIImage(data: d) { imagesMem[chemin] = img; return img }
        let parties = chemin.split(separator: "/").map(String.init)
        let sousDossier = (["Data"] + parties.dropLast()).joined(separator: "/")
        if let u = Bundle.main.url(forResource: parties.last ?? chemin, withExtension: nil, subdirectory: sousDossier), let d = try? Data(contentsOf: u), let img = UIImage(data: d) {
            imagesMem[chemin] = img; return img
        }
        return nil
    }

    /// Champ du banc (`champ_banc.png`) décodé une fois : sert à faire casser la houle animée
    /// là où Sentinel-2 voit le banc casser. nil si le pipeline est trop ancien pour le produire.
    private var champ: ChampBanc?
    func champBanc() async -> ChampBanc? {
        if let champ { return champ }
        guard let img = await image("champ_banc.png") else { return nil }
        champ = ChampBanc(img)
        return champ
    }

    // MARK: prévisions globales (houle au large, vent, marée) heure par heure
    private static func calculerInstants(_ p: Previsions?) -> [Instant] {
        guard let h = p?.horaires else { return [] }
        let msl = p?.msl_sur_zero_hydro_m ?? 2.4
        return h.time.indices.map { i in
            Instant(id: i, date: Fmt.date(h.time[i]), H: h.swell_wave_height[i],
                    T: h.swell_wave_peak_period?[i] ?? h.swell_wave_period[i], dir: h.swell_wave_direction[i],
                    vent: h.wind_speed_10m[i], ventDir: h.wind_direction_10m[i], rafale: h.wind_gusts_10m[i],
                    niveau: h.sea_level_height_msl[i].map { $0 + msl })
        }
    }
    /// Jours avec une vraie journée de prévision de houle (≥ 8 h entre 7h et 21h).
    var joursPrevus: [Date] { jours.filter { instants($0, de: 7, a: 21).compactMap(\.H).count >= 8 } }
    /// Heures du jour (heure locale) entre `de` et `a` inclus.
    func instants(_ jour: Date, de: Int = 0, a: Int = 23) -> [Instant] {
        let cal = Calendar.current
        return instants.filter { cal.isDate($0.date, inSameDayAs: jour) && (de...a).contains(cal.component(.hour, from: $0.date)) }
    }
    /// Meilleur spot du jour (classement du pipeline).
    func meilleur(_ jour: Date) -> Classement? {
        scoring?.resume.first { Calendar.current.isDate(Fmt.date($0.date + "T12:00"), inSameDayAs: jour) }?.classement.first
    }
    /// Meilleur spot sur des heures d'un jour (note max, tous spots) : pour les moments de la journée.
    func meilleur(_ jour: Date, heures: ClosedRange<Int>) -> (nom: String, score: Double, heure: Int)? {
        guard let sc = scoring else { return nil }
        var best: (String, Double, Int)?
        for h in heures {
            guard let i = indexHeure(jour: jour, heure: h) else { continue }
            for sp in sc.spots.values where sp.heures.indices.contains(i) {
                let s = sp.heures[i].score
                if s > (best?.1 ?? -1) { best = (sp.nom, s, h) }
            }
        }
        return best.map { (nom: $0.0, score: $0.1, heure: $0.2) }
    }
    /// Note du meilleur spot à une heure donnée.
    func meilleureNote(_ jour: Date, _ h: Int) -> Double? {
        guard let i = indexHeure(jour: jour, heure: h) else { return nil }
        return scoring?.spots.values.compactMap { $0.heures.indices.contains(i) ? $0.heures[i].score : nil }.max()
    }
    /// Pleines et basses mers du jour, heure locale.
    func marees(_ jour: Date) -> [Maree] {
        (previsions?.marees ?? []).filter { Calendar.current.isDate(Fmt.date($0.heure_utc), inSameDayAs: jour) }
    }

    // MARK: webcams (réseau, avec la dernière image gardée sur disque pour le hors-ligne)
    func vueWebcam(_ w: Webcam) async -> VueWebcam? {
        let disque = cacheDir.appendingPathComponent("webcam_\(w.id).jpg")
        if let v = await Self.telechargerWebcam(w) {
            Task.detached { if let d = v.image.jpegData(compressionQuality: 0.8) { try? d.write(to: disque) } }
            return v
        }
        guard let d = try? Data(contentsOf: disque), let img = UIImage(data: d) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: disque.path)[.modificationDate]) as? Date
        return VueWebcam(image: img, date: date, horsLigne: true)
    }
    /// Session sans cache : une photo de direct change toutes les ~30 s, et un 304 n'a pas de corps.
    nonisolated private static let sessionWebcam: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()
    /// Hors du fil principal : photo du direct et/ou dernier clip, décodés réduits à 1280 px.
    nonisolated private static func telechargerWebcam(_ w: Webcam) async -> VueWebcam? {
        let clip = await dernierClip(w)
        if let u = w.direct {
            guard let (d, r) = try? await sessionWebcam.data(from: u), let http = r as? HTTPURLResponse,
                  http.statusCode == 200, let img = reduite(d) else { return nil }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return VueWebcam(image: img, date: http.value(forHTTPHeaderField: "Last-Modified").flatMap(f.date(from:)), clip: clip)
        }
        guard let ts = clip, let dossier = w.clipDossier,
              let (di, ri) = try? await sessionWebcam.data(from: URL(string: "https://filmssite.viewsurf.com/\(dossier)/media_\(ts).jpg")!),
              (ri as? HTTPURLResponse)?.statusCode == 200, let img = reduite(di) else { return nil }
        return VueWebcam(image: img, date: Date(timeIntervalSince1970: TimeInterval(ts)), clip: ts)
    }
    /// Horodatage du dernier clip d'une vue : la page ViewSurf liste `<dossier>/media_<horodatage>_tn.jpg`.
    nonisolated private static func dernierClip(_ w: Webcam) async -> Int? {
        guard let dossier = w.clipDossier, let (d, _) = try? await sessionWebcam.data(from: w.pageClips ?? w.page),
              let html = String(data: d, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: dossier) + "/media_([0-9]+)_tn\\.jpg")
        else { return nil }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html))
            .compactMap { Range($0.range(at: 1), in: html).flatMap { Int(html[$0]) } }.max()
    }
    nonisolated private static func reduite(_ d: Data) -> UIImage? {
        guard let img = UIImage(data: d) else { return nil }
        let l: CGFloat = 1280
        guard img.size.width > l else { return img.preparingForDisplay() ?? img }
        return img.preparingThumbnail(of: CGSize(width: l, height: img.size.height * l / img.size.width)) ?? img
    }
    /// Note d'un spot à l'heure la plus proche de maintenant.
    func noteMaintenant(_ spot: String) -> Double? {
        let now = Date(), d = dates
        guard let i = d.indices.min(by: { abs(d[$0].timeIntervalSince(now)) < abs(d[$1].timeIntervalSince(now)) }) else { return nil }
        return heure(spot, i)?.score
    }

    // MARK: aides scoring
    func indexHeure(jour: Date, heure: Int) -> Int? {
        let cal = Calendar.current
        return dates.firstIndex { cal.isDate($0, inSameDayAs: jour) && cal.component(.hour, from: $0) == heure }
    }
    /// Jours disponibles à partir d'aujourd'hui (la prévision commence la veille pour le calcul de marée)
    var jours: [Date] {
        var vus: [Date] = []
        let cal = Calendar.current
        let auj = cal.startOfDay(for: Date())
        for d in dates where d >= auj { if !vus.contains(where: { cal.isDate($0, inSameDayAs: d) }) { vus.append(cal.startOfDay(for: d)) } }
        return vus
    }
    func heure(_ spot: String, _ i: Int) -> Heure? {
        guard let h = scoring?.spots[spot]?.heures, i >= 0, i < h.count else { return nil }
        return h[i]
    }
}
