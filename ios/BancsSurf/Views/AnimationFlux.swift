import SwiftUI

/// Couche animée au-dessus d'une carte : trains de houle et filets de vent.
///
/// Tout est dessiné en espace écran (les cartes ne tournent pas, nord en haut), donc les
/// directions affichées correspondent aux directions réelles.
/// Conventions : `houleDir` et `ventDir` sont des **provenances** (nautique, 0 = N) ; la
/// propagation se fait vers provenance + 180°.
///
/// La houle est réfractée : en approchant du trait de côte les crêtes ralentissent et pivotent
/// pour devenir parallèles au rivage, puis blanchissent en déferlant — c'est ce qui rend la
/// direction réellement lisible sur la carte d'un spot.
struct AnimationFlux: View {
    var houleDir: Double?
    var houlePeriode: Double?
    var houleHauteur: Double?
    var ventDir: Double?
    var ventKmh: Double?
    var montrerHoule: Bool
    var montrerVent: Bool
    /// Deux points du trait de côte à l'écran (l'animation est coupée côté terre).
    var coteNord: CGPoint?
    var coteSud: CGPoint?
    /// Échelle de la carte : sert à exprimer la zone de réfraction et le déferlement en mètres.
    var metresParPoint: Double = 75
    /// Grande flèche + cartouche de direction (utile sur la vue d'un spot).
    var flecheDirection = false
    /// Largeur de la zone où la crête blanchit (m). Par défaut 130 m ; sur une vue de spot on y
    /// met la largeur de déferlement mesurée par satellite, donc l'écume colle au banc réel.
    var largeurDeferlementM: Double = 130
    /// Découpe par demi-plan (approximation droite du rivage). À désactiver quand un masque
    /// bitmap exact de la mer est appliqué par-dessus.
    var decouperCote = true
    /// Banc réel (Sentinel-2) et son emprise à l'écran : quand il est fourni, chaque vague casse
    /// sur le premier pixel dont l'indice haut-fond atteint `seuilHautFond` (houle du jour), et
    /// file jusqu'au bord sinon (chenal → shorebreak).
    var champ: ChampBanc? = nil
    var rectChamp: CGRect = .zero
    var seuilHautFond: Double? = nil
    /// Résolution de l'indice haut-fond, 1/(n − 1) pour n scènes : sert de dispersion au seuil.
    var pasHautFond: Double = 0
    var nParticulesHoule = 95
    /// Houle en lignes de crête plutôt qu'en comètes (vue d'un spot) : on voit quelle partie de la
    /// vague touche le banc en premier.
    var lignesDeCrete = false

    /// Repère de la côte : point d'origine, tangente (vers le sud), normale dirigée vers le large.
    struct Cote { let o: CGPoint; let t: CGPoint; let n: CGPoint }
    /// Nombre de pas pour traverser la vue, et longueur des traînées (en pas).
    var etapesMax: Int { 130 }
    private var longueurTrace: Int { 14 }
    private var longueurTraceVent: Int { 10 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(montrerHoule || montrerVent))) { tl in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, taille in
                let t = tl.date.timeIntervalSinceReferenceDate
                let cote = repereCote()
                var ctx = ctx
                if decouperCote, let p = zoneMer(taille, cote) { ctx.clip(to: p) }
                if montrerVent, let d = ventDir { dessinerVent(ctx, taille, t, provenance: d) }
                if montrerHoule, let d = houleDir {
                    if lignesDeCrete { dessinerCretes(ctx, taille, t, provenance: d, cote: cote) }
                    else { dessinerHoule(ctx, taille, t, provenance: d, cote: cote) }
                }
            }
        }
        .overlay(alignment: .topLeading) { if flecheDirection, let d = houleDir { cartoucheDirection(d) } }
        .allowsHitTesting(false)
    }

    // MARK: repères

    func vecteur(_ provenanceDeg: Double) -> CGPoint {
        let r = (provenanceDeg + 180) * .pi / 180
        return CGPoint(x: sin(r), y: -cos(r))
    }
    func repereCote() -> Cote? {
        guard let a = coteNord, let b = coteSud else { return nil }
        var dx = b.x - a.x, dy = b.y - a.y
        let n = sqrt(dx * dx + dy * dy)
        guard n > 1 else { return nil }
        dx /= n; dy /= n
        var nx = dy, ny = -dx                    // normale ; on la veut vers l'ouest (le large)
        if nx > 0 { nx = -nx; ny = -ny }
        return Cote(o: a, t: CGPoint(x: dx, y: dy), n: CGPoint(x: nx, y: ny))
    }
    /// Distance signée au trait de côte, en points d'écran (> 0 : au large).
    func distanceCote(_ p: CGPoint, _ c: Cote) -> Double {
        (p.x - c.o.x) * c.n.x + (p.y - c.o.y) * c.n.y
    }
    func etendue(_ taille: CGSize, _ u: CGPoint, _ v: CGPoint) -> (uMin: Double, uMax: Double, vMin: Double, vMax: Double) {
        let coins = [CGPoint(x: 0, y: 0), CGPoint(x: taille.width, y: 0), CGPoint(x: 0, y: taille.height), CGPoint(x: taille.width, y: taille.height)]
        let pu = coins.map { $0.x * u.x + $0.y * u.y }
        let pv = coins.map { $0.x * v.x + $0.y * v.y }
        return (pu.min()!, pu.max()!, pv.min()!, pv.max()!)
    }
    func point(_ a: Double, _ b: Double, _ u: CGPoint, _ v: CGPoint) -> CGPoint {
        CGPoint(x: a * u.x + b * v.x, y: a * u.y + b * v.y)
    }
    private func zoneMer(_ taille: CGSize, _ c: Cote?) -> Path? {
        guard let c else { return nil }
        let marge = min(150.0 / max(metresParPoint, 0.1), 25.0)   // ~150 m de plage, borné à 25 pt
        let L = (taille.width + taille.height) * 2
        let a2 = CGPoint(x: c.o.x - c.n.x * marge - c.t.x * L, y: c.o.y - c.n.y * marge - c.t.y * L)
        let b2 = CGPoint(x: c.o.x - c.n.x * marge + c.t.x * L, y: c.o.y - c.n.y * marge + c.t.y * L)
        var p = Path()
        p.move(to: a2); p.addLine(to: b2)
        p.addLine(to: CGPoint(x: b2.x + c.n.x * L, y: b2.y + c.n.y * L))
        p.addLine(to: CGPoint(x: a2.x + c.n.x * L, y: a2.y + c.n.y * L))
        p.closeSubpath()
        return p
    }

    // MARK: houle — particules suivant les rayons de houle

    /// Célérité relative : la vague ralentit en eau peu profonde (c ~ racine de la profondeur).
    func celerite(_ d: Double, zone: Double) -> Double {
        guard d < zone else { return 1 }
        let x = max(d, 0) / zone
        return 0.3 + 0.7 * sqrt(x)
    }

    /// Direction de propagation locale : pivote vers la normale à la côte en eau peu profonde.
    func directionLocale(_ u: CGPoint, _ d: Double, _ zone: Double, _ cote: Cote?) -> CGPoint {
        guard let c = cote, d < zone else { return u }
        let f = pow(1 - max(0, d) / zone, 1.5) * 0.85
        let cible = CGPoint(x: -c.n.x, y: -c.n.y)
        var x = u.x * (1 - f) + cible.x * f
        var y = u.y * (1 - f) + cible.y * f
        let n = max(sqrt(x * x + y * y), 0.001)
        return CGPoint(x: x / n, y: y / n)
    }

    /// Ce que la vague rencontre en `p` : le bord (fin de course) ou un banc où elle casse.
    enum Rencontre { case rien, banc, bord }
    func rencontre(_ p: CGPoint, seuil: Double) -> Rencontre {
        guard let c = champ, rectChamp.width > 1,
              let px = c.pixel((p.x - rectChamp.minX) / rectChamp.width, (p.y - rectChamp.minY) / rectChamp.height)
        else { return .rien }
        if !px.ocean { return .bord }
        if let hf = px.hautFond, hf >= seuil { return .banc }
        return .rien
    }

    private func dessinerHoule(_ ctx: GraphicsContext, _ taille: CGSize, _ t: TimeInterval, provenance: Double, cote: Cote?) {
        let u = vecteur(provenance)
        let v = CGPoint(x: -u.y, y: u.x)
        let e = etendue(taille, u, v)
        let T = houlePeriode ?? 10
        let H = houleHauteur ?? 1

        let zoneRefraction = 900.0 / metresParPoint
        let zoneDeferlement = max(largeurDeferlementM, 40) / metresParPoint
        let spanU = max(e.uMax - e.uMin, 1) + 40
        let spanV = max(e.vMax - e.vMin, 1)
        let surBanc = champ != nil && seuilHautFond != nil && rectChamp.width > 1

        let n = nParticulesHoule
        let pas = spanU / Double(etapesMax)                 // longueur d'un pas d'intégration
        let vitesse = 26 + T * 5.5                          // points/seconde (période = énergie)
        let duree = spanU / vitesse                          // temps de traversée
        let rayon = max(1.6, min(4.2, 1.5 + H * 1.1))        // grosseur du point de tête
        let couleurHoule = Color.houle
        let etapesMousse = 45.0                              // durée de vie de la mousse (pas)

        for i in 0..<n {
            let h1 = Double((i &* 2654435761) % 1009) / 1009
            let h2 = Double((i &* 40503) % 997) / 997
            let h3 = Double((i &* 2246822519) % 1013) / 1013
            let h4 = Double((i &* 1597334677) % 1019) / 1019
            let age = ((t / (duree * (0.9 + h3 * 0.2))) + h1).truncatingRemainder(dividingBy: 1)
            let etapes = Int(age * Double(etapesMax))
            guard etapes > 1 else { continue }
            let seuil = (seuilHautFond ?? 1) + (h4 - 0.5) * pasHautFond

            // Départ au large, réparti sur l'axe perpendiculaire
            var p = point(e.uMin - 20, e.vMin + (Double(i) + 0.5 + (h2 - 0.5) * 0.9) / Double(n) * spanV, u, v)
            var trace: [CGPoint] = []
            var dCourant = Double.infinity
            var casse = false
            var pointCasse = CGPoint.zero, dirCasse = u
            var depuisCasse = 0, depuisBord = -1
            for _ in 0...etapes {
                dCourant = cote.map { distanceCote(p, $0) } ?? .infinity
                let dir = directionLocale(u, dCourant, zoneRefraction, cote)
                if surBanc {
                    if depuisBord >= 0 { depuisBord += 1; trace.append(p); if trace.count > longueurTrace { trace.removeFirst() }; continue }
                    switch rencontre(p, seuil: seuil) {
                    case .bord:
                        depuisBord = 0
                        if !casse { casse = true; pointCasse = p; dirCasse = dir }   // chenal : casse au bord
                    case .banc where !casse:
                        casse = true; pointCasse = p; dirCasse = dir
                    default: break
                    }
                    if casse { depuisCasse += 1 }
                } else if dCourant < zoneDeferlement { casse = true }
                trace.append(p)
                if trace.count > longueurTrace { trace.removeFirst() }
                // la mousse (bore) avance moins vite que la vague qui l'a produite
                let l = pas * celerite(dCourant, zone: zoneRefraction) * (casse && surBanc ? 0.7 : 1)
                p = CGPoint(x: p.x + dir.x * l, y: p.y + dir.y * l)
            }
            guard trace.count > 1 else { continue }

            // Fondu : apparition au large, disparition dans la mousse puis au bord
            let entree = min(1, age * 8)
            let sortie: Double
            if surBanc {
                let mousse = casse ? max(0, 1 - Double(depuisCasse) / etapesMousse) : 1
                let bord = depuisBord >= 0 ? max(0, 1 - Double(depuisBord) / 5) : 1
                sortie = mousse * bord
            } else {
                sortie = casse ? max(0, 1 - (zoneDeferlement - max(dCourant, 0)) / max(zoneDeferlement, 1)) : 1
            }
            let opacite = 0.9 * entree * max(sortie, 0.05)
            guard opacite > 0.03 else { continue }
            if surBanc && casse && depuisCasse < 14 {
                dessinerGerbe(ctx, en: pointCasse, dir: dirCasse, avance: Double(depuisCasse) / 14, rayon: rayon, opacite: entree)
            }
            if casse && surBanc {
                // tête de mousse : halo blanc diffus sous la comète
                let tt = trace[trace.count - 1], r = rayon * 2.6
                ctx.fill(Path(ellipseIn: CGRect(x: tt.x - r, y: tt.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.white.opacity(opacite * 0.28)))
            }
            let couleur = casse ? Color.white : couleurHoule
            dessinerComete(ctx, trace: trace, rayon: casse ? rayon * 1.25 : rayon, couleur: couleur, opacite: opacite)
        }
    }

    /// Gerbe au point de déferlement : quelques gouttes qui s'écartent le long de la crête et vers
    /// l'arrière, puis s'éteignent — ce qui marque l'endroit exact où la vague touche le banc.
    func dessinerGerbe(_ ctx: GraphicsContext, en p: CGPoint, dir: CGPoint, avance: Double, rayon: Double, opacite: Double) {
        let crete = CGPoint(x: -dir.y, y: dir.x)
        let portee = rayon * (3 + 7 * avance)
        let a = opacite * (1 - avance)
        guard a > 0.03 else { return }
        let gouttes: [(Double, Double)] = [(-1, -0.2), (1, -0.2), (-0.55, -0.7), (0.55, -0.7), (0, -1), (-1.3, 0.25), (1.3, 0.25)]
        for (k, (c, d)) in gouttes.enumerated() {
            let x = p.x + (crete.x * c + dir.x * d) * portee
            let y = p.y + (crete.y * c + dir.y * d) * portee
            let r = max(0.6, rayon * (0.75 - 0.08 * Double(k % 3)) * (1 - 0.6 * avance))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r - 0.8, y: y - r - 0.8, width: 2 * (r + 0.8), height: 2 * (r + 0.8))),
                     with: .color(.black.opacity(a * 0.3)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(a)))
        }
    }

    /// Un point de tête et sa traînée continue : la ligne s'affine et s'efface vers l'arrière.
    private func dessinerComete(_ ctx: GraphicsContext, trace: [CGPoint], rayon: Double, couleur: Color, opacite: Double) {
        let n = trace.count
        guard n > 1 else { return }
        // Traînée : chaque segment s'affine et s'efface vers la queue ; l'ombre suit le même
        // effilement (une ombre d'épaisseur constante redessinerait une barre).
        for k in 1..<n {
            let f = Double(k) / Double(n - 1)                 // 0 = queue, 1 = tête
            let l = rayon * 1.5 * (0.08 + 0.92 * f * f * f)
            let a = opacite * (0.03 + 0.97 * f * f * f)
            guard a > 0.03, l > 0.3 else { continue }
            var seg = Path()
            seg.move(to: trace[k - 1]); seg.addLine(to: trace[k])
            if f > 0.6 {
                ctx.stroke(seg, with: .color(.black.opacity(a * 0.4)),
                           style: StrokeStyle(lineWidth: l + 1.6, lineCap: .round))
            }
            ctx.stroke(seg, with: .color(couleur.opacity(min(1, a))),
                       style: StrokeStyle(lineWidth: l, lineCap: .round))
        }
        // Tête : un point net, avec un léger halo sombre
        let t = trace[n - 1]
        let r = rayon
        ctx.fill(Path(ellipseIn: CGRect(x: t.x - r - 0.9, y: t.y - r - 0.9, width: (r + 0.9) * 2, height: (r + 0.9) * 2)),
                 with: .color(.black.opacity(opacite * 0.4)))
        ctx.fill(Path(ellipseIn: CGRect(x: t.x - r, y: t.y - r, width: r * 2, height: r * 2)),
                 with: .color(couleur.opacity(min(1, opacite))))
    }

    // MARK: vent — petites flèches, d'autant plus grosses que le vent est fort

    private func dessinerVent(_ ctx: GraphicsContext, _ taille: CGSize, _ t: TimeInterval, provenance: Double) {
        let kmh = ventKmh ?? 0
        guard kmh >= 1 else { return }
        let u = vecteur(provenance)
        let v = CGPoint(x: -u.y, y: u.x)
        let e = etendue(taille, u, v)
        let couleur = Color.vent(QualiteVent.de(kmh, provenance))
        let spanU = max(e.uMax - e.uMin, 1) + 60
        let spanV = max(e.vMax - e.vMin, 1)
        // Taille et épaisseur de la flèche : proportionnelles à la force du vent
        let force = min(kmh, 50.0)
        let longueur = 7 + force * 0.42                       // ~7 pt à 1 km/h, ~28 pt à 50 km/h
        let epaisseur = 1.1 + force * 0.048
        let vitesse = 26 + kmh * 5.0
        let n = 58

        for i in 0..<n {
            let h1 = Double((i &* 1103515245) % 1009) / 1009
            let h2 = Double((i &* 22695477) % 997) / 997
            let h3 = Double((i &* 134775813) % 1013) / 1013
            let avance = (t * vitesse * (0.88 + h3 * 0.24) + h1 * spanU).truncatingRemainder(dividingBy: spanU)
            let a = e.uMin - 30 + avance
            let b = e.vMin + (Double(i) + 0.5 + (h2 - 0.5) * 0.9) / Double(n) * spanV
            let centre = point(a, b, u, v)
            let prog = (a - (e.uMin - 30)) / spanU
            let opacite = 0.85 * sin(max(0, min(1, prog)) * .pi)
            guard opacite > 0.03 else { continue }
            dessinerFleche(ctx, centre: centre, u: u, longueur: longueur, epaisseur: epaisseur,
                           couleur: couleur, opacite: opacite)
        }
    }

    /// Une flèche : hampe + deux barbes, centrée sur `centre` et pointant vers `u`.
    private func dessinerFleche(_ ctx: GraphicsContext, centre: CGPoint, u: CGPoint, longueur: Double,
                                epaisseur: Double, couleur: Color, opacite: Double) {
        let v = CGPoint(x: -u.y, y: u.x)
        let pointe = CGPoint(x: centre.x + u.x * longueur / 2, y: centre.y + u.y * longueur / 2)
        let queue = CGPoint(x: centre.x - u.x * longueur / 2, y: centre.y - u.y * longueur / 2)
        let barbe = longueur * 0.38
        let g = CGPoint(x: pointe.x - u.x * barbe + v.x * barbe * 0.62, y: pointe.y - u.y * barbe + v.y * barbe * 0.62)
        let d = CGPoint(x: pointe.x - u.x * barbe - v.x * barbe * 0.62, y: pointe.y - u.y * barbe - v.y * barbe * 0.62)
        var p = Path()
        p.move(to: queue); p.addLine(to: pointe)
        p.move(to: g); p.addLine(to: pointe); p.addLine(to: d)
        let style = StrokeStyle(lineWidth: epaisseur, lineCap: .round, lineJoin: .round)
        ctx.stroke(p, with: .color(.black.opacity(min(1, opacite) * 0.45)),
                   style: StrokeStyle(lineWidth: epaisseur + 1.6, lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .color(couleur.opacity(min(1, opacite))), style: style)
    }

    // MARK: cartouche de direction

    @ViewBuilder private func cartoucheDirection(_ d: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .rotationEffect(.degrees(d + 180))          // provenance -> flèche vers où ça va
                .foregroundStyle(Color.houle)
            VStack(alignment: .leading, spacing: 0) {
                Text("houle \(Fmt.rose(d))").font(.caption2.bold())
                Text("\(Int(d))° · \(Fmt.n(houlePeriode, 0)) s").font(.system(size: 9)).foregroundStyle(Color.sourdine)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}

/// Période de la houle, en grand et translucide : l'info qui dit si la houle est « propre ».
/// À poser sur un conteneur qui respecte la safe area (sinon elle passe sous la Dynamic Island).
struct AffichagePeriode: View {
    let periode: Double?
    let hauteur: Double?
    var body: some View {
        if let T = periode {
            VStack(spacing: -8) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(T.rounded()))").font(.system(size: 54, weight: .heavy, design: .rounded))
                    Text("s").font(.system(size: 25, weight: .semibold, design: .rounded))
                }
                Text("période").font(.system(size: 10, weight: .semibold)).textCase(.uppercase).kerning(1.6)
            }
            .foregroundStyle(.white.opacity(0.40))
            .shadow(color: .black.opacity(0.6), radius: 5)
            .allowsHitTesting(false)
        }
    }
}
