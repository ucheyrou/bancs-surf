import SwiftUI

/// Design system : toutes les couleurs de l'app. Une nouvelle couleur devient un token ici.
extension Color {
    static func note(_ s: Double) -> Color { s >= 7 ? Color(red: 0.49, green: 0.91, blue: 0.53) : s >= 4 ? Color(red: 1, green: 0.83, blue: 0.48) : Color(red: 0.90, green: 0.33, blue: 0.29) }
    static let fond = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let panneau = Color(red: 0.067, green: 0.094, blue: 0.17)
    /// Panneau surélevé (cellule choisie, carte dans une carte).
    static let panneauClair = Color(red: 0.11, green: 0.15, blue: 0.25)
    static let accent = Color(red: 1, green: 0.83, blue: 0.48)
    static let sourdine = Color(red: 0.62, green: 0.69, blue: 0.82)

    /// Houle : cyan (particules, flèches, graphes) et son dégradé de fond de graphe.
    static let houle = Color(red: 0.55, green: 0.88, blue: 1)
    static let houleProfond = Color(red: 0.16, green: 0.42, blue: 0.75)
    static let maree = Color(red: 0.29, green: 0.56, blue: 0.85)
    /// Bancs Sentinel-2 : orange = fréquence de déferlement, vert = indice haut-fond.
    static let banc = Color(red: 1, green: 0.55, blue: 0.2)
    static let hautFond = Color(red: 0.55, green: 0.9, blue: 0.6)

    /// Vent selon sa qualité pour la côte (vert offshore → rouge onshore).
    static func vent(_ q: QualiteVent) -> Color {
        switch q {
        case .offshore: return Color(red: 0.49, green: 0.95, blue: 0.55)
        case .sideOff:  return Color(red: 0.72, green: 0.92, blue: 0.6)
        case .side:     return Color(red: 0.85, green: 0.86, blue: 0.9)
        case .onshore:  return Color(red: 1.0, green: 0.45, blue: 0.38)
        case .glassy:   return Color(red: 0.8, green: 0.85, blue: 0.95)
        }
    }
}

extension QualiteVent {
    var libelle: String {
        switch self {
        case .offshore: return "offshore"; case .sideOff: return "side-off"
        case .side: return "side-shore"; case .onshore: return "onshore"; case .glassy: return "glassy"
        }
    }
}

/// Flèche de direction : `provenance` en degrés (convention météo), la flèche pointe où ça va.
struct Fleche: View {
    let provenance: Double?
    var couleur: Color = .houle
    var taille: CGFloat = 16
    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: taille, weight: .heavy))
            .rotationEffect(.degrees((provenance ?? 0) + 180))
            .foregroundStyle(couleur)
            .opacity(provenance == nil ? 0.2 : 1)
    }
}

/// Pastille de vent façon surfomètre : rond coloré par la qualité, flèche et vitesse.
struct PastilleVent: View {
    let kmh: Double?
    let provenance: Double?
    var diametre: CGFloat = 30
    var body: some View {
        let c = Color.vent(QualiteVent.de(kmh, provenance))
        ZStack {
            Circle().fill(c.opacity(0.22))
            Circle().stroke(c, lineWidth: 1.5)
            Image(systemName: "arrow.up").font(.system(size: diametre * 0.45, weight: .heavy))
                .rotationEffect(.degrees((provenance ?? 0) + 180)).foregroundStyle(c)
        }
        .frame(width: diametre, height: diametre)
    }
}
