import SwiftUI
import Charts

/// Onglet dédié à La Nord : le banc du large, l'effet du Gouf, et ce que ça donne sur 7 jours.
struct LaNordView: View {
    @EnvironmentObject var store: DataStore
    private let spotId = "la_nord"

    var spot: SpotInfo? { store.spotsParId[spotId] }
    var gouf: GoufSpot? { store.gouf?.spots[spotId] }
    /// Index de l'heure courante (ou la plus proche) dans la prévision.
    /// Crochet de capture : SIMCTL_CHILD_DANS_H=72 regarde dans 72 h.
    var indexMaintenant: Int {
        let now = Date().addingTimeInterval(3600 * (Double(ProcessInfo.processInfo.environment["DANS_H"] ?? "") ?? 0))
        guard !store.dates.isEmpty else { return 0 }
        return store.dates.enumerated().min { abs($0.element.timeIntervalSince(now)) < abs($1.element.timeIntervalSince(now)) }?.offset ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VerdictLarge(spotId: spotId, index: indexMaintenant)
                    enTete
                    sectionLarge
                    sectionProfil
                    sectionGouf
                    sectionKr
                    sectionSemaine
                    sectionSatellite
                    Text("Le Kr et le profil d'approche viennent d'un tracé de rayons sur la bathymétrie EMODnet (réel vs côte sans canyon). Les bancs viennent de Sentinel-2. Précision de position des lobes : ±500 m.")
                        .font(.caption2).foregroundStyle(Color.sourdine)
                }
                .padding()
            }
            .background(Color.fond)
            .navigationTitle("La Nord")
        }
    }

    // MARK: en-tête : conditions du moment
    @ViewBuilder var enTete: some View {
        if let h = store.heure(spotId, indexMaintenant), let L = store.scoring?.large, store.dates.indices.contains(indexMaintenant) {
            let i = indexMaintenant
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.1f", h.score)).font(.system(size: 40, weight: .bold)).foregroundStyle(Color.note(h.score))
                    Text("/10").foregroundStyle(Color.sourdine)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("\(Fmt.n(h.H_b)) m au déferlement").font(.headline)
                        Text("large \(Fmt.n(L.H[i])) m · \(Fmt.n(L.T[i], 0)) s · \(Fmt.rose(L.dir[i]))").font(.caption).foregroundStyle(Color.sourdine)
                    }
                }
                HStack(spacing: 14) {
                    pastille("Kr Gouf", Fmt.n(h.Kr, 2), h.Kr ?? 1 >= 1 ? Color.note(8) : Color.note(5))
                    pastille("tube", "\(h.tube ?? 0)", Color.accent)
                    pastille("puissance", Fmt.n(h.puissance), Color.accent)
                    pastille("vent", h.vent ?? "?", Color.sourdine)
                }
                if let e = h.explication, e != "conditions dans la fenêtre du spot" {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.note(4))
                }
            }
            .padding().background(Color.panneau, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    func pastille(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(spacing: 1) { Text(v).font(.subheadline.bold()).foregroundStyle(c); Text(t).font(.caption2).foregroundStyle(Color.sourdine) }
    }

    // MARK: la vague du large
    @ViewBuilder var sectionLarge: some View {
        VStack(alignment: .leading, spacing: 6) {
            titre("La vague du large")
            Text("La Nord casse sur un banc externe calé sur le rebord du Gouf de Capbreton. Contrairement aux beach breaks voisins, le fond remonte brutalement juste devant : la houle traverse le plateau sans se dissiper, puis lève d'un coup.")
                .font(.footnote).foregroundStyle(Color.sourdine)
            if let s = spot {
                HStack(spacing: 18) {
                    mesure("déferlement observé", s.largeur_max_m.map { "jusqu'à \(Int($0)) m du bord" } ?? "—")
                    mesure("zone de surf médiane", s.largeur_mediane_m.map { "\(Int($0)) m" } ?? "—")
                }
            }
        }
    }
    func mesure(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(v).font(.subheadline.weight(.semibold)); Text(t).font(.caption2).foregroundStyle(Color.sourdine) }
    }

    // MARK: profil cross-shore (barre interne vs barre externe)
    @ViewBuilder var sectionProfil: some View {
        if let p = spot?.profil, !p.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                titre("Où ça casse, du bord vers le large")
                Chart {
                    ForEach(p) { pt in
                        AreaMark(x: .value("distance", pt.d), y: .value("fréquence", pt.freq))
                            .foregroundStyle(.linearGradient(colors: [Color.banc.opacity(0.85), Color.banc.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        if let hf = pt.hf {
                            LineMark(x: .value("distance", pt.d), y: .value("haut-fond", hf), series: .value("s", "hf"))
                                .foregroundStyle(Color.hautFond).interpolationMethod(.monotone)
                        }
                    }
                }
                .chartXScale(domain: 0...500)
                .chartXAxis { AxisMarks(values: [0, 100, 200, 300, 400, 500]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Int.self) { Text("\(d) m") } } } }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 150).padding(8).background(Color.panneau, in: RoundedRectangle(cornerRadius: 10))
                Text("Orange : fréquence de déferlement (Sentinel-2, 8 scènes). Vert : indice haut-fond (1 = casse même par petite houle). Le pic près du bord est le shorebreak ; la traîne au-delà de 200 m est le banc externe, qui ne travaille que les jours de houle.")
                    .font(.caption2).foregroundStyle(Color.sourdine)
            }
        }
    }

    // MARK: profil d'approche (pourquoi plus grosse et plus puissante)
    @ViewBuilder var sectionGouf: some View {
        if let g = gouf, let autres = store.gouf?.spots {
            VStack(alignment: .leading, spacing: 6) {
                titre("Pourquoi elle est plus grosse et plus puissante")
                let comparaison: [(String, Double)] = [("La Nord", g.approche.pente_20_10 ?? 0)]
                    + ["graviere", "estagnots", "la_piste", "casernes"].compactMap { id in
                        guard let s = autres[id], let p = s.approche.pente_20_10 else { return nil }
                        return (store.spotsParId[id]?.nom ?? id, p)
                    }
                Chart(comparaison, id: \.0) { e in
                    BarMark(x: .value("pente", e.1 * 100), y: .value("spot", e.0))
                        .foregroundStyle(e.0 == "La Nord" ? Color.accent : Color.sourdine.opacity(0.6))
                        .annotation(position: .trailing) { Text(String(format: "%.1f %%", e.1 * 100)).font(.caption2).foregroundStyle(Color.sourdine) }
                }
                .chartXAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(d, specifier: "%.0f") %") } } } }
                .frame(height: 140).padding(8).background(Color.panneau, in: RoundedRectangle(cornerRadius: 10))
                Text("Pente du fond entre 20 m et 10 m de profondeur.").font(.caption2).foregroundStyle(Color.sourdine)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("isobathe").font(.caption).foregroundStyle(Color.sourdine); Text("La Nord").font(.caption.bold()); Text("beach breaks voisins").font(.caption).foregroundStyle(Color.sourdine) }
                    ligneIso(g, 20, "1 700 – 2 400 m")
                    ligneIso(g, 50, "5 – 8 km")
                }
                Text("La 20 m est à un demi-kilomètre du bord au lieu de deux : pas de dissipation sur le plateau (elle arrive intacte quand les autres spots sont déjà de la mousse), puis un shoaling brutal façon reef qui fait plonger la lèvre d'un bloc.")
                    .font(.footnote).foregroundStyle(Color.sourdine)
            }
        }
    }
    @ViewBuilder func ligneIso(_ g: GoufSpot, _ m: Int, _ autres: String) -> some View {
        GridRow {
            Text("\(m) m").font(.caption)
            Text(g.approche.iso(m).map { "\(Int($0)) m" } ?? "—").font(.caption.weight(.semibold)).foregroundStyle(Color.accent)
            Text(autres).font(.caption).foregroundStyle(Color.sourdine)
        }
    }

    // MARK: matrice Kr
    @ViewBuilder var sectionKr: some View {
        if let g = gouf {
            let Ts = g.periodes, Ds = g.directions
            VStack(alignment: .leading, spacing: 6) {
                titre("Effet du Gouf selon la houle")
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        Text("").frame(width: 34)
                        ForEach(Ds, id: \.self) { d in Text("\(d)").font(.system(size: 8)).foregroundStyle(Color.sourdine).frame(maxWidth: .infinity) }
                    }
                    ForEach(Ts.reversed(), id: \.self) { T in
                        HStack(spacing: 2) {
                            Text("\(T) s").font(.system(size: 9)).foregroundStyle(Color.sourdine).frame(width: 34, alignment: .leading)
                            ForEach(Ds, id: \.self) { d in
                                let k = g.kr(T, d) ?? 1
                                RoundedRectangle(cornerRadius: 3).fill(couleurKr(k)).frame(height: 22).frame(maxWidth: .infinity)
                                    .overlay(Text(String(format: "%.2f", k)).font(.system(size: 8, weight: .medium)).foregroundStyle(k > 1.15 || k < 0.5 ? .white : .black.opacity(0.75)))
                            }
                        }
                    }
                }
                .padding(8).background(Color.panneau, in: RoundedRectangle(cornerRadius: 10))
                Text("Kr = hauteur avec le Gouf ÷ hauteur sans le canyon, pour une provenance au large (colonnes) et une période (lignes). > 1 : le canyon concentre. < 1 : zone d'ombre. La Nord gagne par houle longue de NW (300–320°) et se retrouve en bordure d'ombre par W/SW long — c'est alors le sud (Santocha) qui prend.")
                    .font(.caption2).foregroundStyle(Color.sourdine)
            }
        }
    }
    func couleurKr(_ k: Double) -> Color {
        if k >= 1.0 { let t = min((k - 1.0) / 0.5, 1); return Color(red: 1, green: 0.85 - 0.5 * t, blue: 0.35 - 0.3 * t) }
        let t = min((1.0 - k) / 0.6, 1)
        return Color(red: 0.35 + 0.3 * (1 - t), green: 0.55 + 0.25 * (1 - t), blue: 0.85)
    }

    // MARK: 7 jours
    @ViewBuilder var sectionSemaine: some View {
        if let sp = store.scoring?.spots[spotId], !store.dates.isEmpty {
            let pts = store.dates.indices.filter { (7...21).contains(Calendar.current.component(.hour, from: store.dates[$0])) }
            VStack(alignment: .leading, spacing: 6) {
                titre("La Nord sur 7 jours")
                Chart {
                    ForEach(pts, id: \.self) { i in
                        if let hb = sp.heures[i].H_b {
                            BarMark(x: .value("h", store.dates[i]), y: .value("taille", hb), width: 2)
                                .foregroundStyle(Color.note(sp.heures[i].score))
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(d, specifier: "%.0f") m") } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.abbreviated).day()) } }
                .frame(height: 130).padding(8).background(Color.panneau, in: RoundedRectangle(cornerRadius: 10))
                .environment(\.locale, Locale(identifier: "fr_FR"))
                Text("Hauteur au déferlement, colorée par la note (vert = bon). La Nord ne démarre vraiment qu'à partir de 1,5 m au déferlement : les jours plats, tout est rouge.")
                    .font(.caption2).foregroundStyle(Color.sourdine)
                if let meilleur = store.scoring?.resume.compactMap({ j in j.classement.first(where: { $0.spot == spotId }).map { (j.jour, $0) } }).max(by: { $0.1.score < $1.1.score }) {
                    Label("Meilleur moment de la semaine : \(meilleur.0), \(meilleur.1.creneau) — \(String(format: "%.1f", meilleur.1.score))/10, \(Fmt.n(meilleur.1.H_b)) m", systemImage: "star.fill")
                        .font(.footnote).foregroundStyle(Color.accent)
                }
            }
        }
    }

    @ViewBuilder var sectionSatellite: some View {
        if let s = spot {
            VStack(alignment: .leading, spacing: 6) {
                titre("Le banc vu du satellite")
                ImageDistante(chemin: s.image).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    func titre(_ t: String) -> some View { Text(t).font(.headline) }
}
