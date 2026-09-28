import SwiftUI

/// Un jour découpé en moments (matin, midi, après-midi, soir) : pour chacun la houle, le vent et
/// son évolution, la marée, le meilleur spot, puis le détail heure par heure.
struct MomentsJour: View {
    @EnvironmentObject var store: DataStore
    let jour: Date

    struct Moment { let nom: String; let heures: ClosedRange<Int> }
    /// Heures incluses ; « 7h–10h » = 7, 8 et 9h. Coucher du soleil ≈ 20h fin septembre.
    static let moments = [Moment(nom: "Matin", heures: 7...9), Moment(nom: "Midi", heures: 10...13),
                          Moment(nom: "Après-midi", heures: 14...17), Moment(nom: "Soir", heures: 18...20)]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Self.moments, id: \.nom) { m in
                let pts = store.instants(jour, de: m.heures.lowerBound, a: m.heures.upperBound)
                if !pts.isEmpty { carte(m, pts) }
            }
        }
    }

    func carte(_ m: Moment, _ pts: [Instant]) -> some View {
        let best = store.meilleur(jour, heures: m.heures)
        let couleur = best.map { Color.note($0.score) } ?? Color.sourdine
        return VStack(alignment: .leading, spacing: 8) {
            // Titre + meilleur spot du moment
            HStack(alignment: .firstTextBaseline) {
                Text(m.nom).font(.headline)
                Text("\(m.heures.lowerBound)h–\(m.heures.upperBound + 1)h").font(.caption).foregroundStyle(Color.sourdine)
                Spacer()
                if let b = best {
                    Text("\(b.nom) \(String(format: "%.1f", b.score))").font(.caption.weight(.bold)).foregroundStyle(couleur)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            ligneHoule(pts)
            ligneVent(pts)
            ligneMaree(m, pts)
            heureParHeure(pts)
        }
        .padding(12)
        .background(Color.panneauClair.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(couleur).frame(width: 4)
        }
    }

    // MARK: lignes de synthèse

    func ligneHoule(_ pts: [Instant]) -> some View {
        let a = pts.first, z = pts.last
        return HStack(spacing: 8) {
            Fleche(provenance: z?.dir, taille: 15).frame(width: 22)
            Text(plage(a?.H, z?.H, "m")).font(.subheadline.weight(.bold).monospacedDigit())
            Text("\(Fmt.n(z?.T, 0)) s · \(Fmt.rose(z?.dir))").font(.caption).foregroundStyle(Color.sourdine)
            Spacer()
            Text(tendance(a?.H, z?.H, seuil: 0.15, monte: "monte", baisse: "baisse")).font(.caption2).foregroundStyle(Color.houle)
        }
    }

    func ligneVent(_ pts: [Instant]) -> some View {
        let a = pts.first, z = pts.last
        let vMin = pts.compactMap(\.vent).min(), vMax = pts.compactMap(\.vent).max(), raf = pts.compactMap(\.rafale).max()
        let qa = a?.qualiteVent, qz = z?.qualiteVent
        return HStack(spacing: 8) {
            PastilleVent(kmh: z?.vent, provenance: z?.ventDir, diametre: 22).frame(width: 22)
            Text("\(Fmt.nd(vMin))–\(Fmt.nd(vMax)) nœuds").font(.subheadline.weight(.bold).monospacedDigit())
            Text("\(Fmt.rose(z?.ventDir)) · \(qz?.libelle ?? "")").font(.caption.weight(.semibold))
                .foregroundStyle(qz.map { Color.vent($0) } ?? Color.sourdine)
            Spacer()
            Text(evolutionVent(qa, qz, a?.vent, z?.vent, raf)).font(.caption2).foregroundStyle(Color.sourdine)
        }
    }

    func ligneMaree(_ m: Moment, _ pts: [Instant]) -> some View {
        let a = pts.first?.niveau, z = pts.last?.niveau
        let evts = store.marees(jour).filter { m.heures.contains(Calendar.current.component(.hour, from: Fmt.date($0.heure_utc))) }
        return HStack(spacing: 8) {
            Image(systemName: "water.waves").font(.system(size: 13)).foregroundStyle(Color.maree).frame(width: 22)
            Text("\(Fmt.n(a)) → \(Fmt.n(z)) m").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.maree)
            // Une PM ou une BM dans le créneau : « haute » / « basse » plutôt qu'une tendance trompeuse
            Text(evts.first.map { $0.type == "PM" ? "marée haute" : "marée basse" } ?? ((z ?? 0) >= (a ?? 0) ? "montante" : "descendante"))
                .font(.caption).foregroundStyle(Color.sourdine)
            Spacer()
            ForEach(evts) { e in
                Text("\(e.type) \(Fmt.heureMinute(Fmt.date(e.heure_utc)))\(e.type == "PM" ? e.coef.map { " · \($0)" } ?? "" : "")")
                    .font(.caption2.weight(.bold)).foregroundStyle(Color.maree)
            }
        }
    }

    // MARK: heure par heure dans le moment
    func heureParHeure(_ pts: [Instant]) -> some View {
        HStack(spacing: 4) {
            ForEach(pts) { p in
                let h = Calendar.current.component(.hour, from: p.date)
                let note = store.meilleureNote(jour, h)
                VStack(spacing: 3) {
                    Text("\(h)h").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.sourdine)
                    Text(Fmt.n(p.H)).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Color.houle)
                    PastilleVent(kmh: p.vent, provenance: p.ventDir, diametre: 18)
                    Text(Fmt.nd(p.vent)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.vent(p.qualiteVent))
                    RoundedRectangle(cornerRadius: 2).fill(note.map { Color.note($0) } ?? Color.clear).frame(height: 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Color.fond.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: textes

    func plage(_ a: Double?, _ z: Double?, _ u: String) -> String {
        guard let a, let z else { return "\(Fmt.n(a ?? z)) \(u)" }
        return abs(a - z) < 0.05 ? "\(Fmt.n(z)) \(u)" : "\(Fmt.n(a)) → \(Fmt.n(z)) \(u)"
    }
    func tendance(_ a: Double?, _ z: Double?, seuil: Double, monte: String, baisse: String) -> String {
        guard let a, let z else { return "" }
        return z - a > seuil ? monte : a - z > seuil ? baisse : "stable"
    }
    /// Ce qui compte pour le surfeur : le vent qui tourne, puis celui qui se lève ou tombe.
    func evolutionVent(_ qa: QualiteVent?, _ qz: QualiteVent?, _ va: Double?, _ vz: Double?, _ raf: Double?) -> String {
        if let qa, let qz, qa != qz, qa != .glassy, qz != .glassy { return "passe \(qz.libelle)" }
        if let va, let vz {
            if vz - va >= 6 { return "se lève" }
            if va - vz >= 6 { return "tombe" }
        }
        return raf.map { "rafales \(Fmt.nd($0))" } ?? ""
    }
}
