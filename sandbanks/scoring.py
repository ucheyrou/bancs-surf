"""Moteur de notation : prévision au large -> pour chaque spot et chaque heure, taille au
déferlement, puissance, indice tube et note /10, avec explication.

Chaîne physique : H_large --Kr (Gouf, réfraction)--> H à l'isobathe 10 m --Ks (shoaling)--> H_b au
déferlement (critère H_b = γ h_b). Puissance ∝ H_b² T. Type de déferlement : Iribarren
ξ0 = tanβ / sqrt(H0/L0) avec la pente du banc. Puis fenêtres locales : taille du spot, marée,
vent (offshore = E à 101°), direction, état du banc vu par satellite.
"""
from __future__ import annotations
import datetime as dt
import json
import math
import numpy as np

from .config import OUTPUT
from . import gouf

G = 9.81


# ----------------------------------------------------------------------------- physique
def _cg(T: float, h: float) -> float:
    """Vitesse de groupe (théorie linéaire) à la profondeur h."""
    omega = 2 * math.pi / T
    k = omega ** 2 / G
    for _ in range(30):
        th = math.tanh(k * h)
        f = G * k * th - omega ** 2
        k -= f / (G * th + G * k * h * (1 - th ** 2))
    n = 0.5 * (1 + 2 * k * h / math.sinh(2 * k * h))
    return n * omega / k


def hauteur_deferlement(H0: float, T: float, gamma=0.78) -> tuple[float, float]:
    """H_b et h_b : shoaling linéaire depuis le large jusqu'au point où H = γ h."""
    if H0 <= 0.05 or T <= 2:
        return 0.0, 0.0
    cg0 = G * T / (4 * math.pi)
    h = max(H0 / gamma, 0.3)
    for _ in range(40):
        Hb = H0 * math.sqrt(cg0 / _cg(T, h))
        h_new = Hb / gamma
        if abs(h_new - h) < 0.005:
            break
        h = 0.5 * (h + h_new)
    return Hb, h


def iribarren(H0: float, T: float, pente: float) -> float:
    L0 = 1.56 * T * T
    return pente / math.sqrt(max(H0, 0.05) / L0)


def type_deferlement(xi: float) -> str:
    if xi < 0.4:
        return "mou"
    if xi < 2.0:
        return "creux"
    return "gonflant"


# ----------------------------------------------------------------------------- fenêtres
def trapeze(x, a, b, c, d) -> float:
    """1 entre b et c, 0 sous a et au-dessus de d, linéaire entre."""
    if x <= a or x >= d:
        return 0.0
    if x < b:
        return (x - a) / (b - a)
    if x <= c:
        return 1.0
    return (d - x) / (d - c)


def angle_diff(a, b) -> float:
    return abs((a - b + 180) % 360 - 180)


def facteur_vent(v_kmh: float, v_dir: float, cfg: dict) -> tuple[float, str]:
    """Qualité du vent pour la côte landaise (face à 281°). Renvoie (facteur, libellé)."""
    c = cfg["vent"]
    if v_kmh is None or v_kmh < 6:
        return 0.95, "glassy"
    d = angle_diff(v_dir, c["offshore_deg"])           # 0 = plein offshore (E), 180 = plein onshore (W)
    if d <= 45:                                          # NE-E-SE : offshore
        if v_kmh <= c["ideal_kmh"][1]:
            return 1.0, "offshore"
        if v_kmh <= c["fort_offshore_kmh"]:
            return 0.85, "offshore soutenu"
        return 0.6, "offshore fort (spray)"
    if d <= 80:                                          # NNE / SSE : side-offshore
        return (0.9 if v_kmh <= 20 else 0.7), "side-off"
    if d <= 110:                                         # N / S : side-shore
        return (0.75 if v_kmh <= 15 else 0.5 if v_kmh <= 25 else 0.3), "side-shore"
    # onshore (NW, W, SW)
    if v_kmh <= 10:
        return 0.6, "onshore faible"
    if v_kmh <= c["onshore_tue_kmh"]:
        return 0.3, "onshore"
    return 0.1, "onshore fort"


def facteur_periode(T: float) -> float:
    return max(0.15, trapeze(T, 4, 10, 17, 22))


def facteur_direction(d: float, cfg: dict) -> float:
    ideal, ok = cfg["houle"]["direction_ideale"], cfg["houle"]["direction_ok"]
    return max(0.35, trapeze(d, ok[0] - 20, ideal[0], ideal[1], ok[1] + 20))


def facteur_maree(pos: float, tendance: str, spot) -> float:
    lo, hi = spot.maree
    marge = 0.2
    f = trapeze(pos, lo - marge, lo, hi, hi + marge)
    return max(0.15, f)


def facteur_banc(m: dict | None) -> tuple[float, str]:
    """État du banc d'après le satellite : σ alongshore (rythmicité) et largeur de la zone de surf."""
    if not m or m.get("largeur_mediane_m") is None:
        return 1.0, "banc : pas de donnée"
    sig, larg = m["variabilite_m"], m["largeur_mediane_m"]
    f = 1.0
    txt = []
    if sig >= 45:
        f *= 1.08; txt.append("bancs rythmiques (pics)")
    elif sig < 25:
        f *= 0.9; txt.append("barre linéaire (close-out par gros)")
    if larg < 50:
        f *= 0.85; txt.append("peu de banc")
    elif larg > 250:
        f *= 0.95; txt.append("zone de surf large (dissipative)")
    return f, ", ".join(txt) or "banc standard"


# ----------------------------------------------------------------------------- notation
def noter_heure(spot, H0, T, dirh, v_kmh, v_dir, pos_maree, tendance, metriques_banc, K, cfg) -> dict:
    sc = cfg["scoring"]
    if H0 is None or T is None:
        return {"score": 0, "H_b": 0, "explication": "pas de donnée"}
    kr = max(gouf.kr_spot(K, spot.id, T, dirh), sc["kr_plancher"]) if K else 1.0
    H10 = H0 * kr * spot.protection
    Hb, hb = hauteur_deferlement(H10, T, sc["gamma_deferlement"])
    pente = spot.pente_banc
    xi = iribarren(H10, T, pente)
    puissance = (Hb ** 2 * T) / (2.0 ** 2 * 12.0)              # 1.0 = 2 m / 12 s

    a, b, c, d = spot.taille
    f_taille = trapeze(Hb, a, b, c, d)
    f_vent, lib_vent = facteur_vent(v_kmh, v_dir, cfg)
    f_per = facteur_periode(T)
    f_dir = facteur_direction(dirh, cfg)
    f_mar = facteur_maree(pos_maree, tendance, spot)
    f_banc, lib_banc = facteur_banc(metriques_banc)

    score = 10 * f_taille * f_vent * f_mar * (0.4 + 0.6 * f_per) * (0.5 + 0.5 * f_dir) * f_banc
    score = round(min(score, 10), 1)

    # Indice tube 0-100 : plus ξ est haut dans la zone plongeante, plus la lèvre se projette
    # (ξ 0,45 = limite glissant/plongeant -> 0,3 ; ξ >= 0,9 -> 1). Puis période, offshore, marée, taille.
    f_xi = trapeze(xi, 0.3, 0.9, 2.2, 3.2)
    f_tube_taille = trapeze(Hb, 0.7, 1.2, c, d + 0.5)
    tube = 100 * f_xi * (0.2 + 0.8 * f_per) * f_vent * (0.5 + 0.5 * f_mar) * f_tube_taille
    tube = round(min(tube, 100))

    # Explication : le facteur limitant
    limites = []
    if f_taille < 0.5:
        limites.append("trop petit" if Hb < b else "trop gros / ferme")
    if f_vent < 0.6:
        limites.append(f"vent {lib_vent}")
    if f_mar < 0.5:
        limites.append("mauvaise marée")
    if f_per < 0.6:
        limites.append("période courte")
    if f_dir < 0.7:
        limites.append("direction de houle défavorable")
    expl = " · ".join(limites) if limites else "conditions dans la fenêtre du spot"
    return {"score": score, "H_b": round(Hb, 2), "h_b": round(hb, 1), "Kr": round(kr, 2), "H10": round(H10, 2),
            "puissance": round(puissance, 2), "tube": tube, "xi": round(xi, 2), "type": type_deferlement(xi),
            "f": {"taille": round(f_taille, 2), "vent": round(f_vent, 2), "maree": round(f_mar, 2),
                  "periode": round(f_per, 2), "direction": round(f_dir, 2), "banc": round(f_banc, 2)},
            "vent": lib_vent, "banc": lib_banc, "explication": expl}


def seuils_banc_externe(spot, obs: list[dict], K, cfg: dict) -> dict | None:
    """Cale le verdict « le banc du large casse » sur les scènes Sentinel-2. Une vague casse quand
    la profondeur tombe à h_b = H_b/γ ; sur un banc à profondeur fixe sous le zéro hydro, ça casse
    si la marge h_b − marée dépasse cette profondeur. Chaque scène borne donc la marge : les
    scènes où ça a cassé la bornent par le haut (« oui »), les autres par le bas (« non »)."""
    lignes = []
    for o in obs:
        if o.get("houle_m") is None or o.get("periode_s") is None or o.get("hauteur_zh_m") is None:
            continue
        r = noter_heure(spot, o["houle_m"], o["periode_s"], o.get("direction") or 300, None, None, 0.5,
                        "montante", None, K, cfg)
        lignes.append({**o, "H_b": r["H_b"], "marge_m": round(r["h_b"] - o["hauteur_zh_m"], 2)})
    oui = [l["marge_m"] for l in lignes if l["casse"]]
    non = [l["marge_m"] for l in lignes if not l["casse"]]
    if not lignes:
        return None
    return {"d_min_m": spot.banc_externe_m, "oui_m": min(oui) if oui else None,
            "non_m": max(non) if non else None, "scenes": lignes}


def verdict_banc_externe(h_b: float | None, zh: float | None, s: dict) -> str | None:
    """« oui » / « non » / « limite » (entre les bornes observées, ou bornes qui se chevauchent)."""
    if h_b is None or zh is None:
        return None
    m = h_b - zh
    bornes = [b for b in (s["oui_m"], s["non_m"]) if b is not None]
    haut, bas = max(bornes), min(bornes)
    if s["oui_m"] is not None and m >= haut:
        return "oui"
    if s["non_m"] is not None and m <= bas:
        return "non"
    return "limite"


def position_maree(niveaux: list, i: int, fen=13) -> float | None:
    """Position dans le cycle (0 = BM, 1 = PM) : niveau relatif au min/max sur ±13 h."""
    seg = [v for v in niveaux[max(i - fen, 0):i + fen + 1] if v is not None]
    if not seg or niveaux[i] is None:
        return None
    lo, hi = min(seg), max(seg)
    return (niveaux[i] - lo) / (hi - lo) if hi > lo else 0.5


def noter_previsions(prev: dict, cfg: dict, metriques: dict | None = None) -> dict:
    """Note tous les spots sur toutes les heures de prévision. metriques = spots.json (satellite)."""
    H = prev["horaires"]
    times = H["time"]
    n = len(times)
    try:
        K = gouf.charger_Kr()
    except FileNotFoundError:
        K = None
    metriques = metriques or {}
    niv = H["sea_level_height_msl"]
    pic = H.get("swell_wave_peak_period") or [None] * n
    T_h = [pic[i] if pic[i] else H["swell_wave_period"][i] for i in range(n)]   # période de pic, sinon moyenne
    resultats = {"time": times, "spots": {}, "large": {
        "H": H["swell_wave_height"], "T": T_h,
        "dir": H["swell_wave_direction"], "vent": H["wind_speed_10m"], "vent_dir": H["wind_direction_10m"],
        "niveau_zh": [None if v is None else round(v + prev.get("msl_sur_zero_hydro_m", 2.4), 2) for v in niv]}}
    for spot in cfg["spots"]:
        lignes = []
        for i in range(n):
            T = T_h[i]
            pos = position_maree(niv, i)
            tend = "montante" if i + 1 < n and niv[i + 1] is not None and niv[i] is not None and niv[i + 1] > niv[i] else "descendante"
            lignes.append(noter_heure(spot, H["swell_wave_height"][i], T, H["swell_wave_direction"][i],
                                      H["wind_speed_10m"][i], H["wind_direction_10m"][i], pos if pos is not None else 0.5,
                                      tend, metriques.get(spot.id), K, cfg))
        entree = {"nom": spot.nom, "type": spot.type, "heures": lignes}
        obs = (metriques.get(spot.id) or {}).get("banc_externe")
        s = seuils_banc_externe(spot, obs["scenes"], K, cfg) if spot.banc_externe_m and obs else None
        if s:
            entree["banc_externe"] = s
            for i, l in enumerate(lignes):
                l["banc_externe"] = verdict_banc_externe(l.get("h_b"), resultats["large"]["niveau_zh"][i], s)
        resultats["spots"][spot.id] = entree
    resultats["resume"] = resume_journalier(resultats, cfg)
    return resultats


def resume_journalier(res: dict, cfg: dict, tz_offset_h=2) -> list[dict]:
    """Par jour (heure locale) : meilleurs spots et créneau, entre 7 h et 21 h."""
    times = [dt.datetime.fromisoformat(t).replace(tzinfo=dt.timezone.utc) + dt.timedelta(hours=tz_offset_h) for t in res["time"]]
    auj = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=tz_offset_h)).date()
    jours = sorted({t.date() for t in times if t.date() >= auj})
    JOURS = ["lun", "mar", "mer", "jeu", "ven", "sam", "dim"]
    out = []
    for j in jours:
        idx = [i for i, t in enumerate(times) if t.date() == j and 7 <= t.hour <= 21]
        if len(idx) < 4:
            continue
        classement = []
        for sid, sp in res["spots"].items():
            sc = [sp["heures"][i]["score"] for i in idx]
            k = int(np.argmax(sc))
            best = idx[k]
            # créneau : heures contiguës à >= 80 % du max
            seuil = max(sc) * 0.8
            deb = k
            while deb > 0 and sc[deb - 1] >= seuil:
                deb -= 1
            fin = k
            while fin < len(sc) - 1 and sc[fin + 1] >= seuil:
                fin += 1
            h = sp["heures"][best]
            classement.append({"spot": sid, "nom": sp["nom"], "score": max(sc),
                               "creneau": f"{times[idx[deb]].hour:02d}h–{times[idx[fin]].hour + 1:02d}h",
                               "H_b": h["H_b"], "tube": h["tube"], "puissance": h["puissance"], "type": h["type"],
                               "vent": h["vent"], "explication": h["explication"]})
        classement.sort(key=lambda x: -x["score"])
        i0 = idx[len(idx) // 2]
        L = res["large"]
        out.append({"date": j.isoformat(), "jour": f"{JOURS[j.weekday()]} {j:%d/%m}",
                    "large": {"H": L["H"][i0], "T": L["T"][i0], "dir": L["dir"][i0]},
                    "classement": classement})
    return out


def texte_resume(res: dict, n_spots=4) -> str:
    lignes = []
    for j in res["resume"]:
        L = j["large"]
        lignes.append(f"\n{j['jour']}  — large : {L['H']} m / {L['T']} s / {L['dir']}°")
        for c in j["classement"][:n_spots]:
            lignes.append(f"   {c['score']:4.1f}/10  {c['nom']:<28} {c['creneau']}  {c['H_b']:.1f} m  "
                          f"tube {c['tube']:3d}  puiss. {c['puissance']:.1f}  {c['type']:<18} vent {c['vent']:<16} — {c['explication']}")
    return "\n".join(lignes)
