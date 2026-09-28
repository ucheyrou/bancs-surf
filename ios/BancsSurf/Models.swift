import Foundation
import UIKit

// Miroir des JSON produits par le pipeline Python (output/*.json).

struct Scoring: Codable {
    let time: [String]
    let spots: [String: SpotScoring]
    let large: Large
    let resume: [ResumeJour]
}
struct SpotScoring: Codable {
    let nom: String
    let type: String
    let heures: [Heure]
    /// Calage du « casse au large » sur les scènes Sentinel-2 (La Nord seulement).
    let banc_externe: BancExterne?
}
/// Une vague casse quand la profondeur tombe à h_b ; sur le banc du large ça casse si la marge
/// h_b − marée dépasse la profondeur du banc. Bornes tirées des scènes où il a / n'a pas cassé.
struct BancExterne: Codable {
    let d_min_m: Double
    let oui_m: Double?
    let non_m: Double?
    let scenes: [ObsBancExterne]
    /// Marge à atteindre pour un « oui » franc.
    var margeOui: Double? { [oui_m, non_m].compactMap { $0 }.max() }
}
struct ObsBancExterne: Codable, Identifiable {
    var id: String { date }
    let date: String
    let houle_m: Double?
    let hauteur_zh_m: Double?
    let H_b: Double?
    let marge_m: Double?
    let frac_lignes: Double?
    let casse: Bool
}
struct Heure: Codable {
    let score: Double
    let H_b: Double?
    let Kr: Double?
    let puissance: Double?
    let tube: Int?
    let xi: Double?
    let type: String?
    let vent: String?
    let banc: String?
    let explication: String?
    /// Profondeur de déferlement (m) = H_b / γ.
    let h_b: Double?
    /// « oui » / « non » / « limite » : le banc du large casse-t-il ? (spots avec banc externe)
    let banc_externe: String?
}
struct Large: Codable {
    let H: [Double?]
    let T: [Double?]
    let dir: [Double?]
    let vent: [Double?]
    let vent_dir: [Double?]
    let niveau_zh: [Double?]
}
struct ResumeJour: Codable, Identifiable {
    var id: String { date }
    let date: String
    let jour: String
    let large: LargeJour
    let classement: [Classement]
}
struct LargeJour: Codable { let H: Double?; let T: Double?; let dir: Double? }
struct Classement: Codable, Identifiable {
    var id: String { spot }
    let spot: String
    let nom: String
    let score: Double
    let creneau: String
    let H_b: Double?
    let tube: Int?
    let puissance: Double?
    let type: String?
    let vent: String?
    let explication: String?
}

struct Previsions: Codable {
    let genere_utc: String
    let msl_sur_zero_hydro_m: Double
    let horaires: Horaires
    let marees: [Maree]
}
struct Horaires: Codable {
    let time: [String]
    let swell_wave_height: [Double?]
    let swell_wave_period: [Double?]
    let swell_wave_peak_period: [Double?]?
    let swell_wave_direction: [Double?]
    let wind_speed_10m: [Double?]
    let wind_direction_10m: [Double?]
    let wind_gusts_10m: [Double?]
    let sea_level_height_msl: [Double?]
}
/// Une heure de prévision globale (point « large » Open-Meteo), marée ramenée au zéro hydro.
struct Instant: Identifiable {
    let id: Int
    let date: Date
    let H: Double?, T: Double?, dir: Double?
    let vent: Double?, ventDir: Double?, rafale: Double?
    let niveau: Double?
    var qualiteVent: QualiteVent { QualiteVent.de(vent, ventDir) }
}
struct Maree: Codable, Identifiable {
    var id: String { heure_utc }
    let heure_utc: String
    let type: String
    let hauteur_zh_m: Double
    let coef: Int?
}

struct SpotInfo: Codable, Identifiable {
    let id: String
    let nom: String
    let lat: Double
    let lon: Double
    let image: String
    let largeur_mediane_m: Double?
    let largeur_max_m: Double?
    let variabilite_m: Double?
    let profil: [ProfilPoint]?
}
/// Profil cross-shore : fréquence de déferlement et indice haut-fond selon la distance au bord.
struct ProfilPoint: Codable, Identifiable {
    var id: Int { d }
    let d: Int
    let freq: Double
    let hf: Double?
}

// MARK: - Gouf de Capbreton
struct GoufFichier: Codable { let description: String; let spots: [String: GoufSpot] }
struct GoufSpot: Codable {
    let approche: Approche
    let Kr_effectif: [String: Double]
    /// Kr pour une période et une provenance données (clés "T14_D300")
    func kr(_ T: Int, _ dir: Int) -> Double? { Kr_effectif["T\(T)_D\(dir)"] }
    var periodes: [Int] { Set(Kr_effectif.keys.compactMap { Int($0.split(separator: "_")[0].dropFirst()) }).sorted() }
    var directions: [Int] { Set(Kr_effectif.keys.compactMap { Int($0.split(separator: "_")[1].dropFirst()) }).sorted() }
}
struct Approche: Codable {
    let isobathe_m: [String: Double?]
    let pente_20_10: Double?
    func iso(_ m: Int) -> Double? { isobathe_m["\(m)"] ?? nil }
}

struct SceneSat: Codable, Identifiable {
    let id: String
    let datetime: String
    let platform: String?
    let nuages_local: Double
    let frac_ecume: Double
    let utilisee: Bool
    let conditions: Conditions?
}
struct Conditions: Codable {
    let houle_m: Double?
    let periode_s: Double?
    let direction: Double?
    let vent_kmh: Double?
    let vent_dir: Double?
    let hauteur_zh_m: Double?
    let maree_tendance: String?
    let coef_estime: Int?
}

struct Meta: Codable {
    let genere_utc: String
    let bounds: [[Double]]      // [[sud, ouest], [nord, est]]
    let images: [SceneImage]
    /// Tailles de houle (m, calme → agité) des scènes qui fondent l'indice haut-fond.
    let haut_fond_houles_m: [Double]?

    /// Indice haut-fond minimal d'un pixel qui casse pour une houle `H` (définition de l'indice,
    /// analyse.composite) : casse si indice ≥ 1 − rang(H)/(n − 1), rang interpolé entre scènes.
    func seuilHautFond(houle H: Double?) -> Double? {
        guard let t = haut_fond_houles_m, t.count >= 2, let H else { return nil }
        let n = Double(t.count - 1)
        if H <= t[0] { return 1 }
        guard let k = t.indices.dropFirst().first(where: { H <= t[$0] }) else { return 0 }
        let frac = t[k] > t[k - 1] ? (H - t[k - 1]) / (t[k] - t[k - 1]) : 1
        return 1 - (Double(k - 1) + frac) / n
    }
}

/// Champ du banc lu dans `champ_banc.png` (même emprise WGS84 que les overlays) : fréquence de
/// déferlement, indice haut-fond et masque océan, échantillonnables en coordonnées normalisées.
struct ChampBanc {
    let largeur: Int, hauteur: Int
    let octets: [UInt8]                   // RGBA
    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let l = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: l * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: l, height: h, bitsPerComponent: 8,
                                      bytesPerRow: l * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: l, height: h))
            return true
        }
        guard ok else { return nil }
        largeur = l; hauteur = h; octets = buf
    }
    /// (x, y) dans [0, 1] depuis le coin nord-ouest. nil hors emprise.
    func pixel(_ x: Double, _ y: Double) -> (freq: Double, hautFond: Double?, ocean: Bool)? {
        guard x >= 0, y >= 0, x < 1, y < 1 else { return nil }
        let i = (Int(y * Double(hauteur)) * largeur + Int(x * Double(largeur))) * 4
        let g = octets[i + 1]
        return (Double(octets[i]) / 255, g == 0 ? nil : Double(g - 1) / 254, octets[i + 2] > 127)
    }
}

struct SceneImage: Codable, Identifiable {
    let id: String
    let date: String
    let rgb: String
    let ecume: String?
}

// MARK: - Webcams ViewSurf

/// Une webcam de la zone. `direct` : photo du direct, rafraîchie par ViewSurf toutes les ~30 s.
/// `lecteurDirect` : page ViewSurf qui joue le direct. Sinon, pour les vues de la caméra orientable
/// de Seignosse : dernier clip horaire (`clipDossier` = dossier des clips, retrouvé dans la page
/// ViewSurf ; `fluxClip` = identifiant du flux sur le lecteur intégrable ViewSurf).
struct Webcam: Identifiable {
    let id: String
    let nom: String
    let spots: [String]
    let page: URL
    var direct: URL? = nil
    var lecteurDirect: URL? = nil
    var clipDossier: String? = nil
    var fluxClip: String? = nil
    /// Page ViewSurf qui liste les clips, si ce n'est pas `page`.
    var pageClips: URL? = nil

    /// Lecteur plein écran : la page du direct, sinon le clip d'horodatage `clip`.
    func lecteur(clip: Int?) -> URL {
        if let l = lecteurDirect { return l }
        guard let f = fluxClip else { return page }
        var s = "https://platforms5.joada.net/embeded/embeded.html?uuid=\(f)&type=vod&liveicon=0&vsheader=0&tz=Europe/Paris"
        if let clip { s += "&tsp=\(clip)" }
        return URL(string: s)!
    }

    /// Relevées sur viewsurf.com le 23/09/2026, du nord au sud.
    static let toutes: [Webcam] = [
        Webcam(id: "penon", nom: "Le Penon", spots: ["penon"],
               page: URL(string: "https://viewsurf.com/univers/plage/vue/19430-france-aquitaine-seignosse-le-penon")!,
               direct: URL(string: "https://filmssite.viewsurf.com/seignosse02_live/media.jpg")!,
               clipDossier: "seignosse01/penon", fluxClip: "e3ad6dcf-e77f-4d63-3937-3430-6d61-63-abc1-9f015f578d28d",
               pageClips: URL(string: "https://viewsurf.com/univers/surf/vue/14378-france-aquitaine-seignosse-le-penon")!),
        Webcam(id: "estagnots", nom: "Les Estagnots", spots: ["estagnots"],
               page: URL(string: "https://viewsurf.com/univers/surf/vue/14374-france-aquitaine-seignosse-les-estagnots")!,
               clipDossier: "seignosse01/estagnots", fluxClip: "d3bf4ca8-a04b-4e7e-3937-3430-6d61-63-a8af-31478978ffe2d"),
        Webcam(id: "hossegor", nom: "La Sud · La Nord", spots: ["la_sud", "la_nord"],
               page: URL(string: "https://pv.viewsurf.com/2646/Hossegor")!,
               direct: URL(string: "https://filmspv.viewsurf.com/hossegor01_live.stream/media.jpg")!,
               lecteurDirect: URL(string: "https://pv.viewsurf.com/2646/Hossegor")!),
        Webcam(id: "prevent", nom: "Le Prévent", spots: ["prevent"],
               page: URL(string: "https://pv.viewsurf.com/2648/Capbreton-Plage-du-Prevent")!,
               direct: URL(string: "https://filmspv.viewsurf.com/capbreton01_live/media.jpg")!,
               lecteurDirect: URL(string: "https://pv.viewsurf.com/2648/Capbreton-Plage-du-Prevent")!),
        Webcam(id: "santocha", nom: "Le Santocha · La Piste", spots: ["santocha", "la_piste"],
               page: URL(string: "https://pv.viewsurf.com/2534/Capbreton-Santocha")!,
               direct: URL(string: "https://filmspv.viewsurf.com/capbreton02_live/media.jpg")!,
               lecteurDirect: URL(string: "https://pv.viewsurf.com/2534/Capbreton-Santocha")!),
    ]
}
/// Ce qu'on affiche d'une webcam : l'image, son heure, et l'horodatage du dernier clip s'il y en a.
struct VueWebcam {
    let image: UIImage
    let date: Date?
    var clip: Int? = nil
    var horsLigne = false
}

// MARK: - Utilitaires

enum Fmt {
    static let utcMinute: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    /// Accepte "2026-09-22T07:00", "2026-09-22T09:28+00:00", "2026-09-19T11:09:21.024000+00:00"
    static func date(_ s: String) -> Date {
        if let d = utcMinute.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        if let d = isoFrac.date(from: s) { return d }
        let tronque = String(s.prefix(16))
        return utcMinute.date(from: tronque) ?? Date()
    }
    static func heure(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "H'h'"; return f.string(from: d) }
    /// « 14h32 » (marées, à la minute)
    static func heureMinute(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "H'h'mm"; return f.string(from: d) }
    static func jourCourt(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEE d"; return f.string(from: d) }
    /// « vendredi 25 »
    static func jour(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d"; return f.string(from: d) }
    static func jourLong(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d MMMM"; return f.string(from: d) }
    static func rose(_ deg: Double?) -> String {
        guard let d = deg else { return "?" }
        let r = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
        return r[Int((d / 22.5).rounded()) % 16]
    }
    /// Vent en nœuds : Open-Meteo donne des km/h (1 nœud = 1,852 km/h). Nombre seul, arrondi.
    static func nd(_ kmh: Double?) -> String { guard let v = kmh else { return "?" }; return "\(Int((v / 1.852).rounded()))" }
    static func n(_ v: Double?, _ dec: Int = 1) -> String { guard let v else { return "?" }; return String(format: "%.\(dec)f", v) }
}

/// Qualité du vent pour une côte face à 281° (offshore = E/ENE ~101°), miroir de scoring.py
enum QualiteVent {
    case glassy, offshore, sideOff, side, onshore
    static func de(_ kmh: Double?, _ dir: Double?) -> QualiteVent {
        guard let v = kmh, let d = dir else { return .glassy }
        if v < 6 { return .glassy }
        let diff = abs(((d - 101) + 180).truncatingRemainder(dividingBy: 360) - 180)
        if diff <= 45 { return .offshore }
        if diff <= 80 { return .sideOff }
        if diff <= 110 { return .side }
        return .onshore
    }
}
