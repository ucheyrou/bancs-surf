import SwiftUI

struct SpotDetailView: View {
    @EnvironmentObject var store: DataStore
    let spotId: String
    let indexHeure: Int
    /// Heure choisie dans la fiche (bandeau heure par heure) ; nil = l'heure d'ouverture.
    @State private var choix: Int?
    var i: Int { choix ?? indexHeure }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let sp = store.scoring?.spots[spotId], let h = store.heure(spotId, i), let L = store.scoring?.large {
                    let d = store.dates[i]
                    entete(sp, h, d)
                    // La réponse d'abord : la houle de cette heure qui arrive et casse sur le banc
                    if let info = store.spotsParId[spotId] {
                        VueBancSpot(spot: info,
                                    houleDir: L.dir[i], houlePeriode: L.T[i], houleHauteur: L.H[i],
                                    ventDir: L.vent_dir[i], ventKmh: L.vent[i])
                    }
                    HeuresDuJour(spotId: spotId, jour: d, selection: Binding(get: { i }, set: { choix = $0 }))
                    if let r = store.scoring?.resume.first(where: { Calendar.current.isDate(Fmt.date($0.date + "T12:00"), inSameDayAs: d) })?.classement.first(where: { $0.spot == spotId }) {
                        Button { allerAuCreneau(r.creneau, d) } label: {
                            Label("Meilleur créneau du jour : \(r.creneau) (\(String(format: "%.1f", r.score))) — voir", systemImage: "clock")
                                .font(.footnote).foregroundStyle(Color.accent)
                        }
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { ligne("Taille", "\(Fmt.n(h.H_b)) m au déferlement", "large \(Fmt.n(L.H[i])) m · \(Fmt.n(L.T[i], 0)) s · \(Fmt.rose(L.dir[i])) · Kr Gouf \(Fmt.n(h.Kr, 2))") }
                        GridRow { ligne("Vague", h.type ?? "?", "tube \(h.tube ?? 0)/100 · puissance \(Fmt.n(h.puissance))") }
                        GridRow { ligne("Vent", "\(Fmt.nd(L.vent[i])) nœuds \(Fmt.rose(L.vent_dir[i]))", h.vent ?? "") }
                        GridRow { ligne("Marée", "\(Fmt.n(L.niveau_zh[i], 2)) m / zéro hydro", "") }
                        if let s = store.spotsParId[spotId], let l = s.largeur_mediane_m {
                            GridRow { ligne("Banc (satellite)", "zone de surf \(Int(l)) m", "σ \(Int(s.variabilite_m ?? 0)) m · \(h.banc ?? "")") }
                        }
                    }
                    if let s = store.spotsParId[spotId] {
                        DisclosureGroup("Planche satellite détaillée") {
                            ImageDistante(chemin: s.image).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                        }.font(.headline).padding(.top, 4)
                    }
                } else {
                    Text("Pas de notation pour ce spot / cette heure.").foregroundStyle(Color.sourdine)
                }
            }.padding()
        }
        .background(Color.fond)
        .onChange(of: indexHeure) { _ in choix = nil }
    }

    /// Nom, heure, note et facteur limitant : la réponse en une ligne.
    func entete(_ sp: SpotScoring, _ h: Heure, _ d: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sp.nom).font(.title2.bold())
                    Text("\(Fmt.jourLong(d)) · \(Fmt.heure(d))").foregroundStyle(Color.sourdine)
                    Text(sp.type).font(.caption).foregroundStyle(Color.sourdine)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", h.score)).font(.system(size: 40, weight: .bold)).foregroundStyle(Color.note(h.score))
                    Text("/10").font(.caption).foregroundStyle(Color.sourdine)
                }
            }
            let ex = h.explication ?? ""
            Text(ex == "conditions dans la fenêtre du spot" ? "✓ dans la fenêtre du spot" : "⚠ \(ex)")
                .font(.footnote).foregroundStyle(Color.sourdine)
        }
    }

    /// Saute au début du meilleur créneau ("20h–21h" → 20h).
    func allerAuCreneau(_ creneau: String, _ jour: Date) {
        let h = Int(creneau.split(separator: "h").first ?? "") ?? 9
        if let j = store.indexHeure(jour: jour, heure: h) { choix = j }
    }

    func ligne(_ t: String, _ v: String, _ d: String) -> some View {
        Group {
            Text(t).font(.caption).foregroundStyle(Color.sourdine)
            VStack(alignment: .leading, spacing: 1) { Text(v).font(.subheadline.weight(.semibold)); if !d.isEmpty { Text(d).font(.caption).foregroundStyle(Color.sourdine) } }
        }
    }
}

/// Bandeau des notes heure par heure (7h–21h) pour le jour affiché ; touchable si `selection`
/// est fourni (la fiche rejoue alors la houle de l'heure choisie).
struct HeuresDuJour: View {
    @EnvironmentObject var store: DataStore
    let spotId: String
    let jour: Date
    var selection: Binding<Int>? = nil
    var body: some View {
        let cal = Calendar.current
        let idx = store.dates.indices.filter { cal.isDate(store.dates[$0], inSameDayAs: jour) && (7...21).contains(cal.component(.hour, from: store.dates[$0])) }
        VStack(alignment: .leading, spacing: 4) {
            Text(selection == nil ? "Heure par heure" : "Heure par heure · touche une heure").font(.headline)
            HStack(spacing: 2) {
                ForEach(idx, id: \.self) { i in
                    let s = store.heure(spotId, i)?.score ?? 0
                    let choisi = selection?.wrappedValue == i
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.note(s).opacity(0.25 + 0.75 * s / 10)).frame(height: 30)
                            .overlay(Text(s >= 9.95 ? "10" : String(format: "%.0f", s)).font(.system(size: 10, weight: .bold)))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: choisi ? 2 : 0))
                        Text("\(cal.component(.hour, from: store.dates[i]))").font(.system(size: 9, weight: choisi ? .bold : .regular))
                            .foregroundStyle(choisi ? Color.white : Color.sourdine)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection?.wrappedValue = i }
                }
            }
        }
    }
}

/// Image servie par le Mac / hébergement, avec repli cache + bundle
struct ImageDistante: View {
    @EnvironmentObject var store: DataStore
    let chemin: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ZStack { Color.panneau; ProgressView() }.frame(height: 120) }
        }
        .task(id: chemin) { image = await store.image(chemin) }
    }
}
