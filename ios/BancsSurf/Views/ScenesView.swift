import SwiftUI

struct ScenesView: View {
    @EnvironmentObject var store: DataStore
    var body: some View {
        NavigationStack {
            List(store.scenes.sorted { $0.datetime > $1.datetime }) { sc in
                NavigationLink {
                    ScrollView { VStack(alignment: .leading, spacing: 8) {
                        Text(String(sc.datetime.prefix(10))).font(.title2.bold())
                        if let c = sc.conditions, let h = c.houle_m {
                            Text("Houle \(Fmt.n(h)) m · \(Fmt.n(c.periode_s, 0)) s · \(Fmt.rose(c.direction)) — vent \(Fmt.nd(c.vent_kmh)) nœuds \(Fmt.rose(c.vent_dir)) — marée \(Fmt.n(c.hauteur_zh_m)) m \(c.maree_tendance ?? "") · coef \(c.coef_estime ?? 0)").font(.footnote).foregroundStyle(Color.accent)
                        }
                        Text("Nuages \(Int(sc.nuages_local * 100)) % · écume \(String(format: "%.1f", sc.frac_ecume * 100)) % · \(sc.utilisee ? "utilisée dans le composite" : "ignorée")").font(.caption).foregroundStyle(Color.sourdine)
                        if let img = store.meta?.images.first(where: { $0.id == sc.id }) {
                            ImageDistante(chemin: img.rgb).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Image Sentinel-2 (13h10 locales). Ouvrir l'onglet Carte → Bancs (satellite) pour la superposer à la carte avec l'écume détectée.").font(.caption2).foregroundStyle(Color.sourdine)
                        }
                    }.padding() }.background(Color.fond).navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(sc.datetime.prefix(10))).font(.subheadline.weight(.semibold))
                            if let c = sc.conditions, let h = c.houle_m { Text("\(Fmt.n(h)) m · \(Fmt.n(c.periode_s, 0)) s · \(Fmt.rose(c.direction)) · marée \(Fmt.n(c.hauteur_zh_m)) m c\(c.coef_estime ?? 0)").font(.caption).foregroundStyle(Color.sourdine) }
                        }
                        Spacer()
                        Text((sc.platform ?? "").replacingOccurrences(of: "sentinel-", with: "S").uppercased()).font(.caption2).foregroundStyle(Color.sourdine)
                        Text("\(Int(sc.nuages_local * 100)) %").font(.caption).foregroundStyle(sc.utilisee ? Color.note(8) : Color.sourdine)
                    }
                }
            }
            .overlay { if store.scenes.isEmpty { ProgressView(store.enCours ? "Chargement…" : store.statut) } }
            .scrollContentBackground(.hidden).background(Color.fond).navigationTitle("Scènes Sentinel-2")
        }
    }
}
