import SwiftUI
import MapKit

/// Carte rapprochée d'un spot : le banc de sable vu par Sentinel-2 (fréquence de déferlement ou
/// indice haut-fond, en surimpression du satellite) avec la houle animée qui arrive dessus,
/// réfractée et blanchissant sur le banc.
struct VueBancSpot: View {
    @EnvironmentObject var store: DataStore
    let spot: SpotInfo
    var houleDir: Double?, houlePeriode: Double?, houleHauteur: Double?
    var ventDir: Double?, ventKmh: Double?
    var hauteur: CGFloat = 420

    enum Calque: String, CaseIterable {
        case frequence = "Banc"
        case hautFond = "Haut-fond"
        case image = "Image S2"
        var fichier: String {
            switch self {
            case .frequence: return "frequence.png"
            case .hautFond:  return "haut_fond.png"
            case .image:     return "derniere_rgb.png"
            }
        }
    }
    @AppStorage("calqueSpot") private var calque: Calque = .frequence
    @State private var image: UIImage?
    @State private var coteNord: CGPoint?
    @State private var coteSud: CGPoint?
    @State private var metresParPoint: Double = 5
    @State private var montrerVent = true
    @State private var masqueMer: UIImage?
    @State private var rectEmprise: CGRect = .zero
    @State private var champ: ChampBanc?

    /// Emprise affichée : 3 fois la largeur maximale de déferlement (600–1200 m), rivage aux 3/4
    /// droits, pour voir la houle arriver du large et casser sur le banc.
    var region: MKCoordinateRegion {
        let largeurM = min(max((spot.largeur_max_m ?? 250) * 3, 600), 1200)
        let mParDegLon = 111_320 * cos(spot.lat * .pi / 180)
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon - 0.22 * largeurM / mParDegLon),
                                  span: MKCoordinateSpan(latitudeDelta: largeurM * 1.13 / 111_320, longitudeDelta: largeurM / mParDegLon))
    }
    var seuil: Double? { store.meta?.seuilHautFond(houle: houleHauteur) }
    var pasHautFond: Double { (store.meta?.haut_fond_houles_m?.count).map { $0 > 1 ? 1 / Double($0 - 1) : 0 } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                CarteSpotView(region: region,
                              overlay: image, bounds: store.meta?.bounds,
                              alpha: calque == .image ? 1.0 : 0.85,
                              spot: spot,
                              onGeometrie: { n, s, m in coteNord = n; coteSud = s; metresParPoint = m },
                              onRectEmprise: { rectEmprise = $0 })
                AnimationFlux(houleDir: houleDir, houlePeriode: houlePeriode, houleHauteur: houleHauteur,
                              ventDir: ventDir, ventKmh: ventKmh,
                              montrerHoule: true, montrerVent: montrerVent,
                              coteNord: coteNord, coteSud: coteSud,
                              metresParPoint: metresParPoint, flecheDirection: true,
                              largeurDeferlementM: spot.largeur_mediane_m ?? 130,
                              decouperCote: masqueMer == nil,
                              champ: champ, rectChamp: rectEmprise,
                              seuilHautFond: seuil, pasHautFond: pasHautFond,
                              nParticulesHoule: 120, lignesDeCrete: true)
                    .mask {
                        if let m = masqueMer, rectEmprise.width > 1 {
                            // Masque exact : la zone de surf calculée par le pipeline (trait de côte réel)
                            Image(uiImage: m).resizable().interpolation(.high)
                                .frame(width: rectEmprise.width, height: rectEmprise.height)
                                .position(x: rectEmprise.midX, y: rectEmprise.midY)
                        } else { Rectangle() }
                    }
            }
            .frame(height: hauteur)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button { montrerVent.toggle() } label: {
                    Image(systemName: "wind").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(montrerVent ? Color.accent.opacity(0.9) : Color.black.opacity(0.45), in: Circle())
                        .foregroundStyle(montrerVent ? Color.fond : .white)
                }.padding(6)
            }
            if let s = seuil, champ != nil {
                Label(ouCaCasse(s), systemImage: "water.waves").font(.footnote.weight(.semibold)).foregroundStyle(Color.accent)
            }
            Picker("", selection: $calque) { ForEach(Calque.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            Text(legende).font(.caption2).foregroundStyle(Color.sourdine)
        }
        .task(id: calque) { image = await store.image(calque.fichier) }
        .task { masqueMer = await store.image("masque_mer.png"); champ = await store.champBanc() }
    }

    /// La règle de déferlement en clair, pour la houle affichée.
    func ouCaCasse(_ s: Double) -> String {
        let h = "\(Fmt.n(houleHauteur)) m au large"
        if s >= 1 { return "\(h) : trop petit pour le banc, ça ne casse qu'au bord" }
        if s >= 0.6 { return "\(h) : ça casse sur les crêtes du banc, les chenaux passent" }
        if s >= 0.25 { return "\(h) : ça casse sur tout le banc, les chenaux profonds passent" }
        return "\(h) : ça casse partout, jusqu'au banc le plus au large"
    }

    var legende: String {
        switch calque {
        case .frequence:
            return "Orange = le banc vu par Sentinel-2 (où ça déferle le plus souvent). Chaque vague casse (gerbe blanche) là où le satellite a vu le banc casser par une houle de cette taille ; dans un chenal elle file jusqu'au bord."
        case .hautFond:  return "Jaune = crête de banc (casse même par petite houle), violet = chenal ou eau plus profonde (ne casse que par grosse houle)."
        case .image:     return "Dernière image Sentinel-2 claire : on distingue l'écume sur les bancs et les chenaux de vidange."
        }
    }
}

/// Carte figée centrée sur un spot, avec une image géoréférencée en surimpression.
struct CarteSpotView: UIViewRepresentable {
    let region: MKCoordinateRegion
    var overlay: UIImage?
    var bounds: [[Double]]?
    var alpha: CGFloat
    var spot: SpotInfo
    var onGeometrie: (CGPoint, CGPoint, Double) -> Void
    /// Rectangle écran occupé par l'emprise des images (pour poser le masque de mer au pixel près).
    var onRectEmprise: ((CGRect) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.mapType = .satellite
        mv.pointOfInterestFilter = .excludingAll
        mv.isRotateEnabled = false; mv.isPitchEnabled = false
        mv.isScrollEnabled = false; mv.isZoomEnabled = false       // évite les conflits de gestes dans une fiche
        mv.showsCompass = false
        mv.setRegion(region, animated: false)
        return mv
    }
    func updateUIView(_ mv: MKMapView, context: Context) {
        let co = context.coordinator
        co.alpha = alpha
        if co.imageAffichee !== overlay {
            mv.removeOverlays(mv.overlays)
            if let img = overlay, let b = bounds { mv.addOverlay(ImageOverlay(image: img, bounds: b, cle: "spot")) }
            co.imageAffichee = overlay
        }
        if mv.annotations.isEmpty {
            let a = MKPointAnnotation(); a.coordinate = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon); a.title = spot.nom
            mv.addAnnotation(a)
        }
        co.onGeometrie = onGeometrie
        co.bounds = bounds
        co.onRectEmprise = onRectEmprise
        co.publier(mv)
    }
    func makeCoordinator() -> Coord { Coord() }

    final class Coord: NSObject, MKMapViewDelegate {
        var alpha: CGFloat = 0.85
        var imageAffichee: UIImage?
        var onGeometrie: ((CGPoint, CGPoint, Double) -> Void)?
        var bounds: [[Double]]?
        var onRectEmprise: ((CGRect) -> Void)?
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = ImageOverlayRenderer(overlay: overlay); r.alpha = alpha; return r
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let v = MKAnnotationView(annotation: annotation, reuseIdentifier: "pt")
            let taille: CGFloat = 12
            v.frame = CGRect(x: 0, y: 0, width: taille, height: taille)
            let rond = UIView(frame: v.bounds)
            rond.backgroundColor = UIColor.cyan.withAlphaComponent(0.9)
            rond.layer.cornerRadius = taille / 2
            rond.layer.borderColor = UIColor.white.cgColor; rond.layer.borderWidth = 2
            v.addSubview(rond); v.canShowCallout = false
            return v
        }
        /// Trait de côte local : le spot est sur le rivage, la côte landaise porte à ~11,5° du nord.
        func publier(_ mv: MKMapView) {
            guard let cb = onGeometrie, let a = mv.annotations.first else { return }
            let cap = 11.5 * Double.pi / 180
            let d = 0.012
            let nord = CLLocationCoordinate2D(latitude: a.coordinate.latitude + d * cos(cap),
                                              longitude: a.coordinate.longitude + d * sin(cap) / cos(a.coordinate.latitude * .pi / 180))
            let sud = CLLocationCoordinate2D(latitude: a.coordinate.latitude - d * cos(cap),
                                             longitude: a.coordinate.longitude - d * sin(cap) / cos(a.coordinate.latitude * .pi / 180))
            let pn = mv.convert(nord, toPointTo: mv), ps = mv.convert(sud, toPointTo: mv)
            let metres = mv.region.span.longitudeDelta * 111_320 * cos(mv.region.center.latitude * .pi / 180) / max(Double(mv.frame.width), 1)
            var rect: CGRect? = nil
            if let b = bounds, b.count == 2 {
                let so = mv.convert(CLLocationCoordinate2D(latitude: b[0][0], longitude: b[0][1]), toPointTo: mv)
                let ne = mv.convert(CLLocationCoordinate2D(latitude: b[1][0], longitude: b[1][1]), toPointTo: mv)
                rect = CGRect(x: min(so.x, ne.x), y: min(so.y, ne.y), width: abs(ne.x - so.x), height: abs(ne.y - so.y))
            }
            let r = rect
            DispatchQueue.main.async { cb(pn, ps, metres); if let r, let cb2 = self.onRectEmprise { cb2(r) } }
        }
    }
}
