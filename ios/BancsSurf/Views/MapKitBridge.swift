import SwiftUI
import MapKit

// MARK: - Overlay image géoréférencée (PNG WGS84 du pipeline : fréquence, haut-fond, scènes)
final class ImageOverlay: NSObject, MKOverlay {
    let image: UIImage
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    let cle: String
    init(image: UIImage, bounds: [[Double]], cle: String) {
        self.image = image; self.cle = cle
        let so = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[0][0], longitude: bounds[0][1]))
        let ne = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[1][0], longitude: bounds[1][1]))
        boundingMapRect = MKMapRect(x: min(so.x, ne.x), y: min(so.y, ne.y), width: abs(ne.x - so.x), height: abs(ne.y - so.y))
        coordinate = CLLocationCoordinate2D(latitude: (bounds[0][0] + bounds[1][0]) / 2, longitude: (bounds[0][1] + bounds[1][1]) / 2)
    }
}
final class ImageOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let ov = overlay as? ImageOverlay, let cg = ov.image.cgImage else { return }
        let r = rect(for: ov.boundingMapRect)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.maxY + r.minY); ctx.scaleBy(x: 1, y: -1)
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high        // pixels Sentinel-2 de 10 m lissés au zoom d'un spot
        ctx.draw(cg, in: r)
        ctx.restoreGState()
    }
}

// MARK: - Annotation de spot avec note
final class SpotAnnotation: NSObject, MKAnnotation {
    let spot: SpotInfo
    var score: Double?
    var afficherNote = true
    init(_ s: SpotInfo) { spot = s; super.init() }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon) }
    var title: String? { spot.nom }
}
final class NoteAnnotationView: MKAnnotationView {
    private let label = UILabel()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        label.textAlignment = .center; label.font = .systemFont(ofSize: 12, weight: .bold)
        label.layer.borderColor = UIColor.white.cgColor; label.layer.borderWidth = 2; label.clipsToBounds = true
        label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 0.5; label.layer.shadowRadius = 3
        addSubview(label); canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError() }
    func configurer(zoom: Double) {
        guard let a = annotation as? SpotAnnotation else { return }
        let taille: CGFloat = zoom >= 14 ? 34 : zoom >= 13 ? 28 : zoom >= 12 ? 20 : 13
        frame = CGRect(x: 0, y: 0, width: taille, height: taille); label.frame = bounds; label.layer.cornerRadius = taille / 2
        label.font = .systemFont(ofSize: taille * 0.4, weight: .bold)
        if let s = a.score, a.afficherNote {
            label.backgroundColor = UIColor(Color.note(s)); label.textColor = s >= 4 && s < 7 ? UIColor(Color.fond) : (s >= 7 ? UIColor(Color.fond) : .white)
            label.text = zoom >= 13 ? (s >= 9.95 ? "10" : String(format: "%.1f", s)) : ""
        } else {
            label.backgroundColor = UIColor.cyan.withAlphaComponent(0.6); label.text = ""
        }
        centerOffset = .zero
    }
}

// MARK: - MKMapView pour SwiftUI
struct CarteMapView: UIViewRepresentable {
    var spots: [SpotInfo]
    var scores: [String: Double]          // spot id -> note à l'heure choisie
    var afficherNotes: Bool
    var overlays: [(cle: String, image: UIImage, alpha: CGFloat)]
    var bounds: [[Double]]?
    var onSelect: (String) -> Void
    /// Position à l'écran de deux points de la côte (spot le plus au nord / au sud) :
    /// sert à limiter l'animation houle/vent à la mer.
    var onCote: ((CGPoint, CGPoint, Double) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.mapType = .satellite
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = false; mv.isPitchEnabled = false
        mv.isRotateEnabled = false   // nord en haut : indispensable pour l'animation houle/vent en espace écran
        mv.register(NoteAnnotationView.self, forAnnotationViewWithReuseIdentifier: "note")
        if !spots.isEmpty {
            let lats = spots.map(\.lat), lons = spots.map(\.lon)
            let c = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2 - 0.01)
            mv.setRegion(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: (lats.max()! - lats.min()!) * 1.4, longitudeDelta: 0.12)), animated: false)
        }
        return mv
    }
    func updateUIView(_ mv: MKMapView, context: Context) {
        let co = context.coordinator
        // annotations : créer une fois
        if co.annotations.count != spots.count {
            mv.removeAnnotations(mv.annotations)
            co.annotations = spots.map(SpotAnnotation.init)
            mv.addAnnotations(co.annotations)
            if !spots.isEmpty {   // première arrivée des données : cadrer sur les spots
                let lats = spots.map(\.lat), lons = spots.map(\.lon)
                let c = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2 - 0.01)
                mv.setRegion(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: (lats.max()! - lats.min()!) * 1.5, longitudeDelta: 0.12)), animated: false)
            }
        }
        let zoom = log2(360 * Double(mv.frame.width) / (mv.region.span.longitudeDelta * 256))
        for a in co.annotations {
            a.score = scores[a.spot.id]; a.afficherNote = afficherNotes
            (mv.view(for: a) as? NoteAnnotationView)?.configurer(zoom: zoom)
        }
        // overlays : remplacer si la liste de clés a changé
        let cles = overlays.map(\.cle)
        if cles != co.clesOverlays, let b = bounds {
            mv.removeOverlays(mv.overlays)
            for o in overlays { mv.addOverlay(ImageOverlay(image: o.image, bounds: b, cle: o.cle)) }
            co.clesOverlays = cles; co.alphas = Dictionary(uniqueKeysWithValues: overlays.map { ($0.cle, $0.alpha) })
        }
        co.onSelect = onSelect
        co.onCote = onCote
        co.publierCote(mv)
    }
    func makeCoordinator() -> Coord { Coord() }

    final class Coord: NSObject, MKMapViewDelegate {
        var annotations: [SpotAnnotation] = []
        var clesOverlays: [String] = []
        var alphas: [String: CGFloat] = [:]
        var onSelect: (String) -> Void = { _ in }
        var onCote: ((CGPoint, CGPoint, Double) -> Void)?
        func publierCote(_ mv: MKMapView) {
            guard let f = annotations.max(by: { $0.spot.lat < $1.spot.lat }),
                  let d = annotations.min(by: { $0.spot.lat < $1.spot.lat }), let cb = onCote else { return }
            let a = mv.convert(f.coordinate, toPointTo: mv)
            let b = mv.convert(d.coordinate, toPointTo: mv)
            let metres = mv.region.span.longitudeDelta * 111_320 * cos(mv.region.center.latitude * .pi / 180) / max(Double(mv.frame.width), 1)
            DispatchQueue.main.async { cb(a, b, metres) }
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is SpotAnnotation else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "note", for: annotation) as! NoteAnnotationView
            let zoom = log2(360 * Double(mapView.frame.width) / (mapView.region.span.longitudeDelta * 256))
            v.configurer(zoom: zoom)
            return v
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = ImageOverlayRenderer(overlay: overlay)
            if let o = overlay as? ImageOverlay { r.alpha = alphas[o.cle] ?? 1 }
            return r
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let a = view.annotation as? SpotAnnotation { onSelect(a.spot.id) }
            mapView.deselectAnnotation(view.annotation, animated: false)
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let zoom = log2(360 * Double(mapView.frame.width) / (mapView.region.span.longitudeDelta * 256))
            for a in annotations { (mapView.view(for: a) as? NoteAnnotationView)?.configurer(zoom: zoom) }
            publierCote(mapView)
        }
    }
}
