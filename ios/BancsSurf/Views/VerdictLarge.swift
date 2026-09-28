import SwiftUI

/// La réponse de l'onglet La Nord : le banc du large casse-t-il maintenant, et quand ça cassera.
struct VerdictLarge: View {
    @EnvironmentObject var store: DataStore
    let spotId: String
    let index: Int

    var body: some View {
        if let sp = store.scoring?.spots[spotId], let b = sp.banc_externe, let h = store.heure(spotId, index),
           let v = h.banc_externe, store.dates.indices.contains(index) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Le banc du large · \(Fmt.jourCourt(store.dates[index])) \(Fmt.heure(store.dates[index]))")
                    .font(.caption).foregroundStyle(Color.sourdine)
                HStack(spacing: 10) {
                    Image(systemName: icone(v)).font(.system(size: 30, weight: .bold)).foregroundStyle(couleur(v))
                    Text(titre(v)).font(.title2.weight(.heavy)).foregroundStyle(couleur(v))
                }
                Text(detail(v, h, b)).font(.footnote)
                prochains(sp)
                preuves(b)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panneau, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(couleur(v).opacity(0.6), lineWidth: 1.5))
        }
    }

    func titre(_ v: String) -> String {
        v == "oui" ? "ÇA CASSE AU LARGE" : v == "non" ? "ÇA NE CASSE PAS AU LARGE" : "LIMITE POUR LE LARGE"
    }
    func icone(_ v: String) -> String {
        v == "oui" ? "checkmark.circle.fill" : v == "non" ? "xmark.circle.fill" : "questionmark.circle.fill"
    }
    func couleur(_ v: String) -> Color { Color.note(v == "oui" ? 8 : v == "non" ? 2 : 5) }

    /// Taille et marée de l'heure, et ce qu'il manque pour que le large casse.
    func detail(_ v: String, _ h: Heure, _ b: BancExterne) -> String {
        let zh = store.scoring?.large.niveau_zh[index] ?? nil
        let base = "\(Fmt.n(h.H_b)) m au déferlement, marée \(Fmt.n(zh)) m"
        let banc = "le banc à plus de \(Int(b.d_min_m)) m du bord"
        switch v {
        case "oui":
            return "\(base) : \(banc) travaille."
        case "non":
            guard let m = b.margeOui, let Hb = h.H_b, let hb = h.h_b, hb > 0, let zh else { return "\(base) : seul le bord casse." }
            let marée = hb - m
            let taille = (m + zh) * Hb / hb                 // H_b = γ·h_b, γ = H_b / h_b
            let pistes = marée > 0 ? "une marée sous \(Fmt.n(marée)) m, ou " : ""
            return "\(base) : seul le bord casse. Il faudrait \(pistes)\(Fmt.n(taille)) m au déferlement à cette marée."
        default:
            return "\(base) : entre ce que le satellite a vu casser et ne pas casser. À vérifier sur place."
        }
    }

    /// Créneaux (7h–21h) où le large casse sur la prévision, heures contiguës regroupées.
    @ViewBuilder func prochains(_ sp: SpotScoring) -> some View {
        let cal = Calendar.current
        let maintenant = Date().addingTimeInterval(-3600)
        let creneaux: [(debut: Date, fin: Date, v: String)] = store.dates.indices.reduce(into: []) { acc, i in
            let d = store.dates[i]
            guard d >= maintenant, (7...21).contains(cal.component(.hour, from: d)),
                  let v = sp.heures[i].banc_externe, v != "non" else { return }
            if let der = acc.last, der.v == v, d.timeIntervalSince(der.fin) <= 3600 { acc[acc.count - 1].fin = d }
            else { acc.append((d, d, v)) }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Prochaines fois où le large casse").font(.subheadline.weight(.semibold))
            if creneaux.isEmpty {
                Text("Aucune sur les 7 jours de prévision.").font(.caption).foregroundStyle(Color.sourdine)
            }
            ForEach(Array(creneaux.prefix(6).enumerated()), id: \.offset) { _, c in
                HStack(spacing: 6) {
                    Circle().fill(couleur(c.v)).frame(width: 8, height: 8)
                    Text("\(Fmt.jourCourt(c.debut)) · \(Fmt.heure(c.debut))–\(Fmt.heure(c.fin.addingTimeInterval(3600)))")
                        .font(.caption.weight(.semibold))
                    Text(c.v == "oui" ? "casse au large" : "limite").font(.caption).foregroundStyle(Color.sourdine)
                }
            }
        }
    }

    /// Les scènes Sentinel-2 qui fondent le verdict, pour pouvoir le contester sur le terrain.
    func preuves(_ b: BancExterne) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(b.scenes.sorted { $0.date > $1.date }) { o in
                    HStack(spacing: 6) {
                        Image(systemName: o.casse ? "checkmark" : "xmark").font(.caption2.bold())
                            .foregroundStyle(Color.note(o.casse ? 8 : 2)).frame(width: 12)
                        Text(String(o.date.suffix(5)).replacingOccurrences(of: "-", with: "/")).font(.caption.monospacedDigit())
                        Text("houle \(Fmt.n(o.houle_m)) m · marée \(Fmt.n(o.hauteur_zh_m)) m · \(Fmt.n(o.H_b)) m au déf.")
                            .font(.caption).foregroundStyle(Color.sourdine)
                    }
                }
                Text("✓ = écume au-delà de \(Int(b.d_min_m)) m sur au moins 10 % de la côte du spot. Une vague casse quand la profondeur tombe sous sa hauteur ÷ 0,78 : plus la vague est grosse et la marée basse, plus elle casse loin. Les scènes où ça a cassé et celles où ça n'a pas cassé encadrent le seuil ; entre les deux, c'est « limite ».")
                    .font(.caption2).foregroundStyle(Color.sourdine).padding(.top, 2)
            }.padding(.top, 4)
        } label: {
            Text("Sur quoi repose le verdict (\(b.scenes.count) images satellite)").font(.caption.weight(.semibold))
        }
        .tint(Color.accent)
    }
}
