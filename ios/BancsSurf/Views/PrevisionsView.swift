import SwiftUI

/// Prévisions de toute la zone, esprit YaduSurf : une ligne « maintenant », puis le surfomètre (un jour
/// par colonne, qu'on fait glisser). Toucher un jour ouvre son détail.
struct PrevisionsView: View {
    @EnvironmentObject var store: DataStore
    @State private var detail: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.instants.isEmpty {
                        Text(store.statut.isEmpty ? "Chargement…" : store.statut).foregroundStyle(Color.sourdine).padding()
                    } else {
                        maintenant
                        Surfometre(ouvrirJour: { detail = $0 })
                        Text("Glisse pour voir la semaine · touche un jour pour le détail heure par heure")
                            .font(.caption2).foregroundStyle(Color.sourdine).padding(.horizontal).padding(.top, 4)
                        Text("Houle au large (avant le Gouf) : Open-Meteo Marine. Vent en nœuds : Météo-France via Open-Meteo. Marée au zéro hydro de Capbreton.")
                            .font(.caption2).foregroundStyle(Color.sourdine).padding()
                    }
                }
            }
            .background(Color.fond)
            .navigationTitle("Prévisions")
            .environment(\.locale, Locale(identifier: "fr_FR"))
            .sheet(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                if let j = detail {
                    ScrollView { PrevisionsJour(jour: j, changerJour: { changer(j, $0) }).padding() }
                        .background(Color.fond)
                        .presentationDetents([.large]).presentationDragIndicator(.visible)
                }
            }
        }
    }

    func changer(_ j: Date, _ pas: Int) {
        guard let i = store.joursPrevus.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: j) }),
              store.joursPrevus.indices.contains(i + pas) else { return }
        detail = store.joursPrevus[i + pas]
    }

    // MARK: maintenant — une ligne, la réponse tout de suite
    @ViewBuilder var maintenant: some View {
        let now = Date()
        if let p = store.instants.min(by: { abs($0.date.timeIntervalSince(now)) < abs($1.date.timeIntervalSince(now)) }) {
            let q = p.qualiteVent
            VStack(alignment: .leading, spacing: 6) {
                Text("MAINTENANT · \(Fmt.heure(p.date))").font(.caption2.weight(.bold)).kerning(1).foregroundStyle(Color.sourdine)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Fleche(provenance: p.dir, taille: 16).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(" \(Fmt.n(p.H)) m").font(.title2.weight(.bold).monospacedDigit())
                    Text("  \(Fmt.n(p.T, 0)) s · \(Fmt.rose(p.dir))").font(.subheadline).foregroundStyle(Color.sourdine)
                    Spacer()
                    Fleche(provenance: p.ventDir, couleur: Color.vent(q), taille: 16).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(" \(Fmt.nd(p.vent))").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(Color.vent(q))
                    Text(" nœuds").font(.subheadline).foregroundStyle(Color.sourdine)
                }
                Text("Vent \(Fmt.rose(p.ventDir)) \(q.libelle) · marée \(Fmt.n(p.niveau)) m\(prochaineMaree(now).map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(Color.sourdine)
            }
            .padding(.horizontal).padding(.vertical, 12)
        }
    }
    func prochaineMaree(_ d: Date) -> String? {
        guard let m = (store.previsions?.marees ?? []).first(where: { Fmt.date($0.heure_utc) > d }) else { return nil }
        return "\(m.type) \(Fmt.heureMinute(Fmt.date(m.heure_utc)))\(m.coef.map { " (coef \($0))" } ?? "")"
    }
}
