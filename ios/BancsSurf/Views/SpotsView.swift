import SwiftUI

struct SpotsView: View {
    @EnvironmentObject var store: DataStore
    var body: some View {
        NavigationStack {
            List(store.spots) { s in
                NavigationLink {
                    ScrollView { VStack(alignment: .leading, spacing: 10) {
                        Text(s.nom).font(.title2.bold())
                        if let l = s.largeur_mediane_m { Text("Zone de déferlement : médiane \(Int(l)) m · max \(Int(s.largeur_max_m ?? 0)) m · variabilité σ \(Int(s.variabilite_m ?? 0)) m").font(.footnote).foregroundStyle(Color.sourdine) }
                        Text("σ élevé = bancs rythmiques (pics et chenaux) ; σ faible = barre linéaire (tendance close-out par gros).").font(.caption2).foregroundStyle(Color.sourdine)
                        ImageDistante(chemin: s.image).clipShape(RoundedRectangle(cornerRadius: 8))
                        if let sc = store.scoring?.spots[s.id] { Text("Type : \(sc.type)").font(.footnote).foregroundStyle(Color.sourdine) }
                    }.padding() }.background(Color.fond).navigationTitle(s.nom).navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.nom).font(.subheadline.weight(.semibold))
                            if let sc = store.scoring?.spots[s.id] { Text(sc.type).font(.caption).foregroundStyle(Color.sourdine) }
                        }
                        Spacer()
                        if let l = s.largeur_mediane_m { Text("\(Int(l)) m · σ \(Int(s.variabilite_m ?? 0))").font(.caption).foregroundStyle(Color.sourdine) }
                    }
                }
            }
            .overlay { if store.spots.isEmpty { ProgressView(store.enCours ? "Chargement…" : store.statut) } }
            .scrollContentBackground(.hidden).background(Color.fond).navigationTitle("Spots")
        }
    }
}
