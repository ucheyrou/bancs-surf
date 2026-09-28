import SwiftUI
import UIKit

/// Panneau de la carte en mode notes : le jour, les conditions de l'heure en gros (houle, vent,
/// marée), et une frise 7h–21h qu'on balaie du doigt — chaque heure montre sa houle et son vent,
/// donc on voit la journée évoluer en choisissant l'heure.
struct PanneauHeureCarte: View {
    @EnvironmentObject var store: DataStore
    @Binding var jour: Date
    @Binding var heure: Double
    private let heures = Array(7...21)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            jours
            conditions
            frise
            if let r = store.meilleur(jour) {
                Label("\(r.nom) \(r.creneau) · \(String(format: "%.1f", r.score))", systemImage: "star.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.accent)
            }
        }
    }

    var jours: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.joursPrevus, id: \.self) { j in
                    let choisi = Calendar.current.isDate(j, inSameDayAs: jour)
                    Button { jour = j } label: {
                        HStack(spacing: 5) {
                            Text(Fmt.jourCourt(j))
                            if let s = store.meilleur(j)?.score { Circle().fill(Color.note(s)).frame(width: 6, height: 6) }
                        }
                        .font(.caption.weight(choisi ? .bold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(choisi ? Color.accent.opacity(0.18) : Color.fond, in: Capsule())
                        .overlay(Capsule().stroke(choisi ? Color.accent : Color.sourdine.opacity(0.25)))
                        .foregroundStyle(choisi ? Color.accent : .primary)
                    }
                }
            }
        }
    }

    /// Houle, vent et marée de l'heure choisie, en gros et avec leurs flèches.
    @ViewBuilder var conditions: some View {
        let cal = Calendar.current
        if let p = store.instants(jour, de: Int(heure), a: Int(heure)).first {
            let suivante = store.instants.first { $0.date > p.date }
            let q = p.qualiteVent
            HStack(spacing: 0) {
                Text("\(Int(heure))h").font(.title3.weight(.heavy)).frame(width: 44, alignment: .leading)
                HStack(spacing: 6) {
                    Fleche(provenance: p.dir, taille: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Fmt.n(p.H)) m").font(.headline.monospacedDigit())
                        Text("\(Fmt.n(p.T, 0)) s · \(Fmt.rose(p.dir))").font(.caption2).foregroundStyle(Color.sourdine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    PastilleVent(kmh: p.vent, provenance: p.ventDir, diametre: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Fmt.nd(p.vent)) nœuds").font(.headline.monospacedDigit())
                        Text(q.libelle).font(.caption2.weight(.semibold)).foregroundStyle(Color.vent(q))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    let monte = (suivante?.niveau ?? 0) > (p.niveau ?? 0)
                    Text("\(Fmt.n(p.niveau)) m \(monte ? "↗" : "↘")").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.maree)
                    Text("marée").font(.caption2).foregroundStyle(Color.sourdine)
                }
            }
            .id(cal.component(.hour, from: p.date))
        } else {
            Text("Pas de prévision pour cette heure").font(.caption).foregroundStyle(Color.sourdine)
        }
    }

    /// Frise des heures : barre = houle (échelle de la semaine), point = vent coloré.
    var frise: some View {
        let hMax = max(store.instants.compactMap(\.H).max() ?? 1, 0.5)
        let points = Dictionary(store.instants(jour, de: 7, a: 21).map { (Calendar.current.component(.hour, from: $0.date), $0) },
                                uniquingKeysWith: { a, _ in a })
        return GeometryReader { g in
            let w = g.size.width / CGFloat(heures.count)
            HStack(spacing: 0) {
                ForEach(heures, id: \.self) { h in
                    let p = points[h]
                    let choisi = Int(heure) == h
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Color.sourdine.opacity(0.10)).frame(width: 8, height: 30)
                            Capsule().fill(LinearGradient(colors: [Color.houle, Color.houleProfond], startPoint: .top, endPoint: .bottom))
                                .frame(width: 8, height: max(4, 30 * (p?.H ?? 0) / hMax))
                        }
                        Circle().fill(p.map { Color.vent($0.qualiteVent) } ?? Color.clear).frame(width: 7, height: 7)
                        Text("\(h)").font(.system(size: 10, weight: choisi ? .heavy : .regular).monospacedDigit())
                            .foregroundStyle(choisi ? Color.accent : Color.sourdine)
                    }
                    .frame(width: w, height: 56)
                    .background(choisi ? Color.panneauClair : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(choisi ? Color.accent.opacity(0.8) : Color.clear, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let i = min(max(Int(v.location.x / w), 0), heures.count - 1)
                if Int(heure) != heures[i] {
                    heure = Double(heures[i])
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            })
        }
        .frame(height: 56)
    }
}
