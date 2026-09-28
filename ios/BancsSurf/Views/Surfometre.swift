import SwiftUI

/// Les jours côte à côte, comme le surfomètre de YaduSurf : pour chacun, des étoiles, un dessin de la
/// journée (houle en aplat, vent en cases colorées, note du meilleur spot en bande) et trois phrases.
/// On compare les jours d'un coup d'œil ; les chiffres heure par heure sont dans le détail du jour.
struct Surfometre: View {
    @EnvironmentObject var store: DataStore
    var ouvrirJour: (Date) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(store.joursPrevus, id: \.self) { j in
                    Button { ouvrirJour(j) } label: { ColonneJour(jour: j, echelle_m: echelle_m) }
                        .buttonStyle(.plain)
                        // 2,7 colonnes visibles : on voit qu'il y a une suite, qui invite à glisser
                        .containerRelativeFrame(.horizontal) { w, _ in w / 2.7 }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }

    /// Même échelle de hauteur pour tous les jours (le max de la semaine, arrondi au demi-mètre) :
    /// un gros jour se voit gros à côté d'un petit.
    var echelle_m: Double {
        let h = store.instants.compactMap(\.H).max() ?? 1
        return max(1.5, (h / 0.5).rounded(.up) * 0.5)
    }
}

/// Un jour du surfomètre.
struct ColonneJour: View {
    @EnvironmentObject var store: DataStore
    let jour: Date
    let echelle_m: Double

    /// Fenêtre dessinée ; le vent est échantillonné aux heures où l'on regarde d'habitude.
    static let debut = 7, fin = 21
    static let heuresVent = [9, 12, 15, 18]

    var body: some View {
        let pts = store.instants(jour, de: Self.debut, a: Self.fin)
        let surfables = store.instants(jour, de: Self.debut, a: 20)
        let best = store.meilleur(jour)
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 3) {
                Text(titre).font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                Etoiles(note: best?.score)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)

            rangeeVent(pts)
            dessin(pts)
            bandeNote
            heures

            VStack(alignment: .leading, spacing: 5) {
                Text(Phrases.verdict(best)).font(.subheadline.weight(.bold))
                    .foregroundStyle(best.map { Color.note($0.score) } ?? Color.sourdine)
                if let l = Phrases.limite(best) {
                    Text(l).font(.caption.weight(.semibold)).foregroundStyle(best.map { Color.note($0.score) } ?? Color.sourdine)
                }
                if let b = best {
                    Text("\(b.nom) \(b.creneau.replacingOccurrences(of: "(^|–)0", with: "$1", options: .regularExpression))")
                        .font(.caption.weight(.semibold))
                }
                Text(Phrases.houle(surfables)).font(.caption).foregroundStyle(Color.houle)
                Text(Phrases.vent(surfables)).font(.caption).foregroundStyle(Color.sourdine)
                Text(maree).font(.caption2).foregroundStyle(Color.maree)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) { Rectangle().fill(Color.sourdine.opacity(0.3)).frame(width: 1) }
    }

    var titre: String {
        let cal = Calendar.current, num = cal.component(.day, from: jour)
        if cal.isDateInToday(jour) { return "Aujourd'hui \(num)" }
        if cal.isDateInTomorrow(jour) { return "Demain \(num)" }
        return Fmt.jour(jour).capitalized
    }
    var maree: String {
        store.marees(jour).filter { (6...22).contains(Calendar.current.component(.hour, from: Fmt.date($0.heure_utc))) }.map { "\($0.type) \(Fmt.heureMinute(Fmt.date($0.heure_utc)))\($0.type == "PM" ? $0.coef.map { " (\($0))" } ?? "" : "")" }
            .joined(separator: " · ")
    }

    /// Position horizontale (0…1) d'une heure dans la fenêtre.
    func x(_ d: Date) -> CGFloat {
        let cal = Calendar.current
        let h = Double(cal.component(.hour, from: d)) + Double(cal.component(.minute, from: d)) / 60
        return CGFloat((h - Double(Self.debut)) / Double(Self.fin - Self.debut))
    }

    // MARK: vent — une case colorée par qualité, flèche et nœuds, alignée sur son heure
    func rangeeVent(_ pts: [Instant]) -> some View {
        let cal = Calendar.current
        return GeometryReader { g in
            let pas = g.size.width * 3 / CGFloat(Self.fin - Self.debut)
            ForEach(Self.heuresVent, id: \.self) { h in
                let p = pts.first { cal.component(.hour, from: $0.date) == h }
                VStack(spacing: 0) {
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .heavy))
                        .rotationEffect(.degrees((p?.ventDir ?? 0) + 180))
                    Text(Fmt.nd(p?.vent)).font(.caption.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(Color.fond)
                .frame(width: pas - 2, height: 30)
                .background(p.map { Color.vent($0.qualiteVent) } ?? Color.panneau)
                .position(x: g.size.width * CGFloat(h - Self.debut) / CGFloat(Self.fin - Self.debut), y: 15)
            }
        }
        .frame(height: 30)
    }

    // MARK: houle — aplat sur l'échelle de la semaine, plus sombre quand la période est longue
    func dessin(_ pts: [Instant]) -> some View {
        let ts = pts.compactMap(\.T).sorted()
        let t = ts.isEmpty ? nil : ts[ts.count / 2]
        // 8 s → cyan clair, 16 s → bleu profond (même convention que YaduSurf : sombre = long)
        let profondeur = min(max(((t ?? 10) - 8) / 8, 0), 1)
        let dir = pts.isEmpty ? nil : pts[pts.count / 2].dir
        return GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let points = pts.compactMap { p in p.H.map { CGPoint(x: x(p.date) * w, y: h - h * CGFloat($0 / echelle_m)) } }
            ZStack(alignment: .bottomLeading) {
                Color.panneau
                // Un trait tous les 50 cm, légendé au mètre
                ForEach(Array(stride(from: 0.5, to: echelle_m, by: 0.5)), id: \.self) { m in
                    let y = h - h * CGFloat(m / echelle_m)
                    Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Color.sourdine.opacity(m.truncatingRemainder(dividingBy: 1) == 0 ? 0.3 : 0.12), lineWidth: 1)
                    if m.truncatingRemainder(dividingBy: 1) == 0 {
                        Text("\(Int(m)) m").font(.system(size: 8)).foregroundStyle(Color.sourdine)
                            .position(x: 12, y: y - 6)
                    }
                }
                if points.count > 1 {
                    let aplat = Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: h))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: h)); p.closeSubpath()
                    }
                    aplat.fill(Color.houleProfond)
                    aplat.fill(Color.houle.opacity(0.85 * (1 - profondeur)))
                    Path { p in p.addLines(points) }.stroke(Color.houle, lineWidth: 2)
                }
                if Calendar.current.isDateInToday(jour), (0...1).contains(x(Date())) {
                    Rectangle().fill(Color.accent).frame(width: 1.5).offset(x: x(Date()) * w)
                }
                // Période et direction dans une bulle, en bas à gauche
                HStack(spacing: 2) {
                    Fleche(provenance: dir, couleur: .white, taille: 9)
                    Text(t.map { "\(Fmt.n($0, 0)) s" } ?? "?").font(.caption2.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.fond.opacity(0.55), in: Capsule())
                .padding(5)
            }
        }
        .frame(height: 190)
        .clipped()
    }

    // MARK: note du meilleur spot, heure par heure
    var bandeNote: some View {
        HStack(spacing: 0) {
            ForEach(Self.debut..<Self.fin, id: \.self) { h in
                Rectangle().fill(store.meilleureNote(jour, h).map { Color.note($0) } ?? Color.clear)
            }
        }
        .frame(height: 6)
    }

    var heures: some View {
        GeometryReader { g in
            ForEach(Self.heuresVent, id: \.self) { h in
                Text("\(h)h").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.sourdine)
                    .position(x: g.size.width * CGFloat(h - Self.debut) / CGFloat(Self.fin - Self.debut), y: 8)
            }
        }
        .frame(height: 16)
    }
}

/// 0 à 3 étoiles (demi-étoiles), calculées comme le verdict : `Phrases.etoiles`.
struct Etoiles: View {
    let note: Double?
    var body: some View {
        let e = Phrases.etoiles(note)
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { k in
                let v = e - Double(k)
                Image(systemName: v >= 1 ? "star.fill" : v >= 0.5 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(v > 0 ? Color.accent : Color.sourdine.opacity(0.4))
            }
        }
    }
}
