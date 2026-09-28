import SwiftUI

/// Le jour affiché dans le surfomètre, en détail : ses moments (matin → soir) puis heure par heure.
struct PrevisionsJour: View {
    @EnvironmentObject var store: DataStore
    let jour: Date
    var changerJour: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            entete
            MomentsJour(jour: jour)
            detail
        }
        .padding(14)
        .background(Color.panneau, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) else { return }
            changerJour(v.translation.width < 0 ? 1 : -1)
        })
    }

    var entete: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { changerJour(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(Fmt.jourLong(jour).capitalized).font(.title3.weight(.bold))
                Spacer()
                Button { changerJour(1) } label: { Image(systemName: "chevron.right") }
            }
            .tint(Color.accent)
            if let r = store.meilleur(jour) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Color.accent)
                    Text("\(r.nom) \(r.creneau)").fontWeight(.semibold)
                    Text(String(format: "%.1f", r.score)).fontWeight(.bold).foregroundStyle(Color.note(r.score))
                }
                .font(.caption).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: heure par heure
    var detail: some View {
        DisclosureGroup {
            VStack(spacing: 6) {
                ForEach(store.instants(jour, de: 6, a: 22)) { p in
                    HStack(spacing: 8) {
                        Text(Fmt.heure(p.date)).font(.caption.monospacedDigit()).foregroundStyle(Color.sourdine).frame(width: 30, alignment: .leading)
                        Fleche(provenance: p.dir, taille: 12)
                        Text("\(Fmt.n(p.H)) m · \(Fmt.n(p.T, 0)) s").font(.caption.weight(.semibold).monospacedDigit())
                            .frame(width: 92, alignment: .leading)
                        PastilleVent(kmh: p.vent, provenance: p.ventDir, diametre: 20)
                        Text("\(Fmt.nd(p.vent)) nœuds").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.vent(p.qualiteVent))
                        Spacer()
                        Text("\(Fmt.n(p.niveau)) m").font(.caption2.monospacedDigit()).foregroundStyle(Color.maree)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Heure par heure").font(.subheadline.weight(.semibold))
        }
        .tint(Color.accent)
    }
}
