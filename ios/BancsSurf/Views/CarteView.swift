import SwiftUI
import UIKit

enum ModeCarte: String, CaseIterable { case notes = "Notes des spots", bancs = "Bancs (satellite)" }

struct CarteView: View {
    @EnvironmentObject var store: DataStore
    @State private var mode: ModeCarte = .notes
    @State private var jour: Date = Calendar.current.startOfDay(for: Date())
    @State private var heure: Double = 10
    @State private var spotSelectionne: String?
    // mode bancs
    @State private var indexScene: Double = 0
    @State private var voirImage = true
    @State private var voirEcume = true
    @State private var voirFreq = false
    @State private var voirHautFond = false
    @State private var imagesChargees: [String: UIImage] = [:]
    @State private var jourInitialise = false
    @AppStorage("animHoule") private var animHoule = true
    @AppStorage("animVent") private var animVent = true
    @State private var coteNord: CGPoint?
    @State private var coteSud: CGPoint?
    @State private var metresParPoint: Double = 75
    @State private var detente: PresentationDetent = .large

    var indexHeure: Int? { store.indexHeure(jour: jour, heure: Int(heure)) }
    var scores: [String: Double] {
        guard mode == .notes, let i = indexHeure, let sc = store.scoring else { return [:] }
        return sc.spots.compactMapValues { $0.heures.indices.contains(i) ? $0.heures[i].score : nil }
    }
    var sceneCourante: SceneImage? {
        guard let imgs = store.meta?.images, !imgs.isEmpty else { return nil }
        return imgs[min(Int(indexScene), imgs.count - 1)]
    }
    var overlays: [(cle: String, image: UIImage, alpha: CGFloat)] {
        guard mode == .bancs else { return [] }
        var out: [(String, UIImage, CGFloat)] = []
        if voirImage, let s = sceneCourante, let im = imagesChargees[s.rgb] { out.append((s.rgb, im, 1)) }
        if voirEcume, let s = sceneCourante, let e = s.ecume, let im = imagesChargees[e] { out.append((e, im, 0.8)) }
        if voirFreq, let im = imagesChargees["frequence.png"] { out.append(("frequence.png", im, 0.9)) }
        if voirHautFond, let im = imagesChargees["haut_fond.png"] { out.append(("haut_fond.png", im, 0.9)) }
        return out.map { (cle: $0.0, image: $0.1, alpha: $0.2) }
    }

    /// Conditions utilisées par l'animation : l'heure choisie, ou la scène affichée en mode bancs.
    var flux: (hDir: Double?, hT: Double?, hH: Double?, vDir: Double?, vKmh: Double?) {
        if mode == .bancs, let s = sceneCourante, let c = store.scenes.first(where: { $0.id == s.id })?.conditions {
            return (c.direction, c.periode_s, c.houle_m, c.vent_dir, c.vent_kmh)
        }
        guard let i = indexHeure, let L = store.scoring?.large else { return (nil, nil, nil, nil, nil) }
        return (L.dir[i], L.T[i], L.H[i], L.vent_dir[i], L.vent[i])
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CarteMapView(spots: store.spots, scores: scores, afficherNotes: mode == .notes, overlays: overlays,
                         bounds: store.meta?.bounds, onSelect: { spotSelectionne = $0 },
                         onCote: { n, s, m in coteNord = n; coteSud = s; metresParPoint = m })
                .ignoresSafeArea(edges: .top)
                .overlay {
                    AnimationFlux(houleDir: flux.hDir, houlePeriode: flux.hT, houleHauteur: flux.hH,
                                  ventDir: flux.vDir, ventKmh: flux.vKmh,
                                  montrerHoule: animHoule, montrerVent: animVent,
                                  coteNord: coteNord, coteSud: coteSud, metresParPoint: metresParPoint)
                        .ignoresSafeArea(edges: .top)
                }
                .overlay(alignment: .topTrailing) { boutonsAnimation.padding(.trailing, 10).padding(.top, 6) }
            // Posé sur le ZStack (et non sur la carte, qui ignore la safe area) pour rester
            // sous la Dynamic Island et non derrière.
            if animHoule {
                AffichagePeriode(periode: flux.hT, hauteur: flux.hH)
                    .padding(.top, 6)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            panneau
        }
        .sheet(item: $spotSelectionne) { id in
            SpotDetailView(spotId: id, indexHeure: indexHeure ?? 0)
                .presentationDetents([.large, .medium], selection: $detente).presentationDragIndicator(.visible)
        }
        .onChange(of: store.scoring?.time.count) { _ in initialiserJour() }
        .onAppear { initialiserJour() }
        .task(id: "\(mode.rawValue)-\(Int(indexScene))-\(voirFreq)-\(voirHautFond)") { await chargerImages() }
    }

    func initialiserJour() {
        guard !jourInitialise, !store.dates.isEmpty else { return }
        jourInitialise = true
        let maintenant = Date(); let h = Calendar.current.component(.hour, from: maintenant)
        if h >= 21, store.jours.count > 1 { jour = store.jours[1]; heure = 9 } else { jour = store.jours.first ?? jour; heure = Double(min(max(h + 1, 7), 21)) }
        if let n = store.meta?.images.count { indexScene = Double(max(n - 1, 0)) }
    }
    func chargerImages() async {
        guard mode == .bancs else { return }
        var cles: [String] = []
        if let s = sceneCourante { cles.append(s.rgb); if let e = s.ecume { cles.append(e) } }
        if voirFreq { cles.append("frequence.png") }
        if voirHautFond { cles.append("haut_fond.png") }
        for c in cles where imagesChargees[c] == nil {
            if let im = await store.image(c) { imagesChargees[c] = im }
        }
    }

    /// Deux boutons flottants pour activer/couper chaque animation.
    @ViewBuilder var boutonsAnimation: some View {
        VStack(spacing: 6) {
            Button { animHoule.toggle() } label: {
                Image(systemName: "water.waves").font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(animHoule ? Color.houle.opacity(0.85) : Color.black.opacity(0.45), in: Circle())
                    .foregroundStyle(animHoule ? Color.fond : .white)
            }
            Button { animVent.toggle() } label: {
                Image(systemName: "wind").font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(animVent ? Color.accent.opacity(0.9) : Color.black.opacity(0.45), in: Circle())
                    .foregroundStyle(animVent ? Color.fond : .white)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    @ViewBuilder var panneau: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) { ForEach(ModeCarte.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if mode == .notes { panneauNotes } else { panneauBancs }
        }
        .padding(12)
        .background(Color.panneau.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    var panneauNotes: some View { PanneauHeureCarte(jour: $jour, heure: $heure) }

    @ViewBuilder var panneauBancs: some View {
        if let s = sceneCourante {
            HStack {
                Text(s.date).bold()
                if let sc = store.scenes.first(where: { $0.id == s.id }), let c = sc.conditions, let h = c.houle_m {
                    Text("houle \(Fmt.n(h)) m · \(Fmt.n(c.periode_s, 0)) s · \(Fmt.rose(c.direction)) · marée \(Fmt.n(c.hauteur_zh_m)) m \(c.maree_tendance ?? "") · coef \(c.coef_estime ?? 0)")
                        .font(.caption).foregroundStyle(Color.accent).lineLimit(2)
                }
            }.font(.subheadline)
            if let n = store.meta?.images.count, n > 1 { Slider(value: $indexScene, in: 0...Double(n - 1), step: 1) }
            HStack(spacing: 10) {
                Toggle("image", isOn: $voirImage); Toggle("écume", isOn: $voirEcume); Toggle("fréquence", isOn: $voirFreq); Toggle("haut-fond", isOn: $voirHautFond)
            }.toggleStyle(.button).font(.caption2).buttonStyle(.bordered).controlSize(.mini)
        } else {
            Text("Scènes satellite indisponibles (serveur non joignable et rien en cache).").font(.caption).foregroundStyle(Color.sourdine)
        }
    }
}

extension String: Identifiable { public var id: String { self } }
