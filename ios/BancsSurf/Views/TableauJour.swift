import SwiftUI

/// Le tableau des prévisions qu'on fait défiler horizontalement : les jours se suivent, toutes les
/// 3 h de 6h à 21h. Légende fixe à gauche ; une ligne par donnée — houle en barres (échelle de la
/// semaine), période, direction, vent en nœuds dans une case colorée, rafales, marée, note du
/// meilleur spot. Lignes fines, pas d'effets : on lit d'un coup d'œil.
struct FrisePrevisions: View {
    @EnvironmentObject var store: DataStore
    var ouvrirJour: (Date) -> Void
    @State private var jourVisible: Date?

    static let heures = [6, 9, 12, 15, 18, 21]
    /// Lignes : titre, unité, hauteur (pt). L'ordre est celui de l'affichage.
    enum Ligne: CaseIterable {
        case jour, heure, houle, periode, direction, sep1, vent, rafales, sep2, maree, note, marees
        var titre: String {
            switch self {
            case .houle: return "Houle"; case .periode: return "Période"; case .direction: return "Direction"
            case .vent: return "Vent"; case .rafales: return "Rafales"; case .maree: return "Marée"; case .note: return "Note"
            default: return ""
            }
        }
        var unite: String? {
            switch self { case .houle, .maree: return "m"; case .periode: return "s"; case .vent: return "nœuds"; default: return nil }
        }
        var hauteur: CGFloat {
            switch self {
            case .jour: return 30; case .heure: return 20; case .houle: return 72; case .periode: return 22
            case .direction: return 26; case .sep1, .sep2: return 7; case .vent: return 34; case .rafales: return 22
            case .maree: return 24; case .note: return 28; case .marees: return 22
            }
        }
    }
    private let colLegende: CGFloat = 62

    var body: some View {
        GeometryReader { g in
            // 6,6 colonnes visibles : on aperçoit le début du jour suivant, qui invite à glisser
            let col = (g.size.width - colLegende) / (CGFloat(Self.heures.count) + 0.6)
            HStack(spacing: 0) {
                legende
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(store.joursPrevus, id: \.self) { j in
                            BlocJour(jour: j, col: col, ouvrir: { ouvrirJour(j) }).id(j)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $jourVisible)
            }
        }
        .frame(height: Ligne.allCases.map(\.hauteur).reduce(0, +))
    }

    var legende: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Ligne.allCases, id: \.self) { l in
                VStack(alignment: .leading, spacing: 0) {
                    Text(l.titre).font(.caption.weight(.semibold))
                    if let u = l.unite { Text(u).font(.system(size: 9)).foregroundStyle(Color.sourdine) }
                }
                .frame(height: l.hauteur, alignment: .leading)
            }
        }
        .frame(width: colLegende, alignment: .leading)
    }
}

/// Un jour de la frise : ses 6 colonnes, séparé du précédent par un trait.
struct BlocJour: View {
    @EnvironmentObject var store: DataStore
    let jour: Date
    let col: CGFloat
    var ouvrir: () -> Void
    typealias Ligne = FrisePrevisions.Ligne

    var body: some View {
        let hMax = max(store.instants.compactMap(\.H).max() ?? 1, 0.5)
        VStack(spacing: 0) {
            Button(action: ouvrir) {
                HStack(spacing: 6) {
                    Text(Fmt.jour(jour).uppercased()).font(.caption.weight(.heavy)).kerning(0.4)
                    Etoiles(note: store.meilleur(jour)?.score)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.sourdine)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.panneau)
            }
            .frame(height: Ligne.jour.hauteur)
            rangee(.heure) { h, _ in
                Text("\(h)h").font(.caption.weight(.semibold)).foregroundStyle(maintenant(h) ? Color.accent : Color.sourdine)
            }
            rangee(.houle) { _, p in barreHoule(p?.H, hMax) }
            rangee(.periode) { _, p in Text(p?.T.map { "\(Int($0.rounded()))" } ?? "–").font(.subheadline.monospacedDigit()) }
            rangee(.direction) { _, p in Fleche(provenance: p?.dir, taille: 14) }
            separateur
            rangee(.vent) { _, p in caseVent(p) }
            rangee(.rafales) { _, p in Text(Fmt.nd(p?.rafale)).font(.caption.monospacedDigit()).foregroundStyle(Color.sourdine) }
            separateur
            rangee(.maree) { h, p in
                Text("\(Fmt.n(p?.niveau))\(tendance(h, p))").font(.caption.monospacedDigit()).foregroundStyle(Color.maree)
            }
            rangee(.note) { h, _ in caseNote(store.meilleureNote(jour, h)) }
            Text(store.marees(jour).map { "\($0.type) \(Fmt.heureMinute(Fmt.date($0.heure_utc)))\($0.type == "PM" ? $0.coef.map { " (\($0))" } ?? "" : "")" }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(Color.maree).lineLimit(1).minimumScaleFactor(0.7)
                .frame(height: Ligne.marees.hauteur)
        }
        .frame(width: col * CGFloat(FrisePrevisions.heures.count))
        .overlay(alignment: .leading) { Rectangle().fill(Color.sourdine.opacity(0.35)).frame(width: 1) }
    }

    func rangee<C: View>(_ l: Ligne, @ViewBuilder _ cellule: @escaping (Int, Instant?) -> C) -> some View {
        let cal = Calendar.current
        let pts = Dictionary(store.instants(jour, de: 6, a: 21).map { (cal.component(.hour, from: $0.date), $0) },
                             uniquingKeysWith: { a, _ in a })
        return HStack(spacing: 0) {
            ForEach(FrisePrevisions.heures, id: \.self) { h in
                cellule(h, pts[h])
                    .frame(width: col, height: l.hauteur)
                    .background(maintenant(h) ? Color.panneauClair.opacity(0.7) : Color.clear)
            }
        }
    }
    var separateur: some View {
        Rectangle().fill(Color.sourdine.opacity(0.15)).frame(height: 1).frame(height: Ligne.sep1.hauteur)
    }
    func maintenant(_ h: Int) -> Bool {
        Calendar.current.isDateInToday(jour) && abs(Calendar.current.component(.hour, from: Date()) - h) <= 1
    }

    // MARK: cellules
    func barreHoule(_ H: Double?, _ hMax: Double) -> some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            Text(Fmt.n(H)).font(.subheadline.weight(.bold).monospacedDigit())
            Rectangle().fill(Color.houle.opacity(0.85)).frame(width: 22, height: max(3, 44 * (H ?? 0) / hMax))
        }
    }
    func caseVent(_ p: Instant?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.up").font(.system(size: 10, weight: .heavy))
                .rotationEffect(.degrees((p?.ventDir ?? 0) + 180))
            Text(Fmt.nd(p?.vent)).font(.subheadline.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(Color.fond)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((p.map { Color.vent($0.qualiteVent) } ?? Color.clear).opacity(0.9))
        .padding(.vertical, 2).padding(.horizontal, 1)
    }
    func caseNote(_ n: Double?) -> some View {
        Text(n.map { String(format: "%.0f", $0) } ?? "")
            .font(.caption.weight(.heavy).monospacedDigit()).foregroundStyle(Color.fond)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background((n.map { Color.note($0) } ?? Color.clear).opacity(0.9))
            .padding(.vertical, 4).padding(.horizontal, 1)
    }
    /// ↗ si la mer monte d'ici l'heure suivante, ↘ sinon.
    func tendance(_ h: Int, _ p: Instant?) -> String {
        guard let n = p?.niveau, let s = store.instants(jour, de: h + 1, a: h + 1).first?.niveau else { return "" }
        return s > n ? "↗" : "↘"
    }
}

/// 0 à 3 étoiles, proportionnelles à la note /10 du meilleur spot (demi-étoiles).
struct Etoiles: View {
    let note: Double?
    var body: some View {
        let e = ((note ?? 0) / 10 * 3 * 2).rounded() / 2
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { k in
                let v = e - Double(k)
                Image(systemName: v >= 1 ? "star.fill" : v >= 0.5 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(v > 0 ? Color.accent : Color.sourdine.opacity(0.4))
            }
        }
    }
}
