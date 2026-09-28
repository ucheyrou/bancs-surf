import SwiftUI

/// Houle en lignes de crête sur la vue d'un spot : une crête = une rangée de rayons partis ensemble
/// du large, intégrés du même nombre de pas. La ligne se courbe (réfraction) et blanchit tronçon par
/// tronçon là où chaque rayon rencontre le banc : on voit où la vague touche en premier.
extension AnimationFlux {
    /// État d'un rayon après n pas.
    struct PointRayon { var p: CGPoint; var casse: Bool; var depuisCasse: Int; var mort: Bool; var impact: CGPoint?; var dir: CGPoint }

    /// Trajectoire complète d'un rayon (un état par pas), mêmes règles que les comètes.
    func trajectoire(depart: CGPoint, u: CGPoint, pas: Double, seuil: Double, cote: Cote?, zoneRefraction: Double) -> [PointRayon] {
        var etats: [PointRayon] = []
        etats.reserveCapacity(etapesMax + 1)
        var p = depart, casse = false, depuisCasse = 0, depuisBord = -1
        var impact: CGPoint? = nil
        for _ in 0...etapesMax {
            let d = cote.map { distanceCote(p, $0) } ?? .infinity
            let dir = directionLocale(u, d, zoneRefraction, cote)
            if depuisBord >= 0 {
                depuisBord += 1; depuisCasse += 1
                etats.append(PointRayon(p: p, casse: true, depuisCasse: depuisCasse, mort: depuisBord > 4, impact: impact, dir: dir))
                continue
            }
            switch rencontre(p, seuil: seuil) {
            case .bord:
                depuisBord = 0
                if !casse { casse = true; impact = p }          // chenal : casse au bord
            case .banc where !casse:
                casse = true; impact = p
            default: break
            }
            if casse { depuisCasse += 1 }
            etats.append(PointRayon(p: p, casse: casse, depuisCasse: depuisCasse, mort: false, impact: impact, dir: dir))
            // la mousse (bore) avance moins vite que la vague qui l'a produite
            let l = pas * celerite(d, zone: zoneRefraction) * (casse ? 0.7 : 1)
            p = CGPoint(x: p.x + dir.x * l, y: p.y + dir.y * l)
        }
        return etats
    }

    func dessinerCretes(_ ctx: GraphicsContext, _ taille: CGSize, _ t: TimeInterval, provenance: Double, cote: Cote?) {
        let u = vecteur(provenance)
        let v = CGPoint(x: -u.y, y: u.x)
        let e = etendue(taille, u, v)
        let T = houlePeriode ?? 10
        let H = houleHauteur ?? 1
        let zoneRefraction = 900.0 / metresParPoint
        let spanU = max(e.uMax - e.uMin, 1) + 40
        let spanV = max(e.vMax - e.vMin, 1)
        let pas = spanU / Double(etapesMax)
        // Célérité au large c = gT/2π ≈ 1,56·T m/s (houle linéaire, eau profonde), jouée ×4 ;
        // les crêtes sont espacées d'une longueur d'onde λ = 1,56·T² m.
        let acceleration = 4.0
        let vitesse = 1.56 * T / metresParPoint * acceleration   // points/seconde
        let duree = spanU / vitesse
        let lambda = 1.56 * T * T / metresParPoint                // points
        let nCretes = min(max(Int((spanU / lambda).rounded()), 2), 14)
        let nRayons = 80
        let ecart = spanV / Double(nRayons)
        let epaisseur = max(1.4, min(3.6, 1.2 + H * 0.9))
        let etapesMousse = 28.0
        let bleu = Color.houle

        // Tous les rayons une fois par image ; chaque crête lit l'état au même pas.
        // Seuil commun à toute la crête (pas de dispersion par rayon : elle dentèle la ligne).
        let seuil = seuilHautFond ?? 1
        let rayons: [[PointRayon]] = (0..<nRayons).map { j in
            let depart = point(e.uMin - 20, e.vMin + (Double(j) + 0.5) * ecart, u, v)
            return trajectoire(depart: depart, u: u, pas: pas, seuil: seuil, cote: cote, zoneRefraction: zoneRefraction)
        }

        for k in 0..<nCretes {
            let age = (t / duree + Double(k) / Double(nCretes)).truncatingRemainder(dividingBy: 1)
            let n = Int(age * Double(etapesMax))
            guard n > 0 else { continue }
            let entree = min(1, age * 10)
            let etats = rayons.map { $0[min(n, $0.count - 1)] }

            // Lissage [1 2 1] le long de la crête (entre voisins proches) : la ligne reste souple
            let lim2 = (ecart * 3) * (ecart * 3)
            func proches(_ a: PointRayon, _ b: PointRayon) -> Bool {
                let dx = b.p.x - a.p.x, dy = b.p.y - a.p.y
                return !a.mort && !b.mort && dx * dx + dy * dy < lim2
            }
            let lisses: [CGPoint] = etats.indices.map { j in
                guard j > 0, j < etats.count - 1, proches(etats[j - 1], etats[j]), proches(etats[j], etats[j + 1]) else { return etats[j].p }
                let a = etats[j - 1].p, b = etats[j].p, c = etats[j + 1].p
                return CGPoint(x: (a.x + 2 * b.x + c.x) / 4, y: (a.y + 2 * b.y + c.y) / 4)
            }

            // Tronçons regroupés par état (bleu / mousse par tranche d'âge) : un seul tracé par
            // groupe, sinon chaque ombre recouvre le tronçon voisin et la ligne paraît pointillée.
            var bleu_ = Path()
            var mousse: [Int: Path] = [:]
            let tranche = 3.0
            for j in 1..<etats.count {
                let a = etats[j - 1], b = etats[j]
                guard proches(a, b) else { continue }
                if a.casse || b.casse {
                    let g = Int(Double(max(a.depuisCasse, b.depuisCasse)) / tranche)
                    mousse[g, default: Path()].move(to: lisses[j - 1]); mousse[g]!.addLine(to: lisses[j])
                } else {
                    bleu_.move(to: lisses[j - 1]); bleu_.addLine(to: lisses[j])
                }
            }
            let opBleu = entree * 0.9
            ctx.stroke(bleu_, with: .color(.black.opacity(opBleu * 0.45)), style: StrokeStyle(lineWidth: epaisseur + 1.6, lineCap: .round, lineJoin: .round))
            ctx.stroke(bleu_, with: .color(bleu.opacity(opBleu)), style: StrokeStyle(lineWidth: epaisseur, lineCap: .round, lineJoin: .round))
            let groupes = mousse.keys.sorted(by: >)            // la mousse vieille d'abord, l'impact par-dessus
            func style(_ g: Int) -> (op: Double, l: Double) {
                let dc = (Double(g) + 0.5) * tranche
                let flash = max(0, 1 - dc / 8)                  // l'instant où la vague touche : plus large
                return (entree * max(0, 1 - dc / etapesMousse), epaisseur * (1.6 + 1.6 * flash))
            }
            for g in groupes {
                let (op, l) = style(g); guard op > 0.03, let p = mousse[g] else { continue }
                ctx.stroke(p, with: .color(.white.opacity(op * 0.25)), style: StrokeStyle(lineWidth: l * 2.6, lineCap: .round, lineJoin: .round))
                ctx.stroke(p, with: .color(.black.opacity(op * 0.35)), style: StrokeStyle(lineWidth: l + 1.6, lineCap: .round, lineJoin: .round))
            }
            for g in groupes {
                let (op, l) = style(g); guard op > 0.03, let p = mousse[g] else { continue }
                ctx.stroke(p, with: .color(.white.opacity(op)), style: StrokeStyle(lineWidth: l, lineCap: .round, lineJoin: .round))
            }
            // Gerbes aux points d'impact tout juste touchés (un rayon sur trois, pour rester lisible)
            for (j, s) in etats.enumerated() where j % 3 == 0 && s.casse && s.depuisCasse < 14 {
                if let i = s.impact {
                    dessinerGerbe(ctx, en: i, dir: s.dir, avance: Double(s.depuisCasse) / 14, rayon: epaisseur * 0.9, opacite: entree)
                }
            }
        }
    }
}
