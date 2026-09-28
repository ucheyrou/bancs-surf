"""Détection du déferlement par scène et composite temporel (carte des bancs)."""
from __future__ import annotations
import datetime as dt
import numpy as np
from scipy import ndimage

from .scene import SCL_INVALIDE, RES


def produits_scene(s: dict, cfg: dict) -> dict:
    """Brillance visible, NDWI, masque nuage maison, validité et écume pour une scène.

    Discriminant clé : l'écume est blanche en visible mais absorbe dans le SWIR (bulles d'eau)
    -> SWIR/visible ~ 0.1-0.2 ; nuages et sable sec ont un ratio > 0.7."""
    d = cfg["detection"]
    b, g, r, nir = s["refl"]
    brillance = (b + g + r) / 3.0
    ndwi = (g - nir) / (g + nir + 1e-6)
    ratio_swir = s["swir"] / np.maximum(brillance, 1e-3)
    brillant = brillance > d["seuil_ecume"]
    nuage = brillant & (ratio_swir > d["ratio_swir_nuage"])
    # Bords de nuages : dilatation de quelques pixels
    nuage = ndimage.binary_dilation(nuage, iterations=d["dilatation_nuage_px"])
    valide = ~np.isin(s["scl"], SCL_INVALIDE) & (nir > 0) & ~nuage
    ecume = valide & brillant & (ratio_swir < d["ratio_swir_ecume"])
    return {"brillance": brillance, "ndwi": ndwi, "nir": nir, "valide": valide,
            "nuage": nuage, "ecume": ecume}


def masque_mer(produits: list[dict], cfg: dict) -> dict:
    """Masque statique de la zone de surf : tout pixel « parfois mouillé » (eau ou écume,
    NDWI > 0, dans >= `frac_mouille_min` des scènes valides), rattaché à l'océan (plus grande
    composante connexe) et à moins de `largeur_mer_m` du large. Le sable, même mouillé,
    a un NDWI négatif -> exclu ; la zone de swash/shorebreak est incluse."""
    d = cfg["detection"]
    n_eau = np.zeros(produits[0]["nir"].shape, dtype=np.int32)
    n_val = np.zeros_like(n_eau)
    for p in produits:
        n_val += p["valide"]
        n_eau += p["valide"] & (p["ndwi"] > 0)
    frac = n_eau / np.maximum(n_val, 1)
    eau = frac >= d["frac_mouille_min"]
    # Plus grande composante connexe = océan (élimine lac d'Hossegor, canal, étangs)
    lab, n = ndimage.label(eau)
    if n == 0:
        raise RuntimeError("Aucune zone d'eau détectée")
    tailles = ndimage.sum(eau, lab, index=range(1, n + 1))
    ocean = lab == (1 + int(np.argmax(tailles)))
    # Distance au trait de côte (en pixels), on garde la bande côtière
    dist = ndimage.distance_transform_edt(ocean) * RES
    # "surf" : bande côtière utilisée pour les statistiques. "ocean" : toute la mer, pour le
    # masque d'animation de l'app (qui doit couvrir aussi le large).
    return {"surf": ocean & (dist <= d["largeur_mer_m"]), "ocean": ocean}


def composite(scenes: list[dict], cfg: dict) -> dict:
    """Empile les scènes : fréquence de déferlement pondérée par la récence + timex."""
    d = cfg["detection"]
    c = cfg["composite"]
    produits = [produits_scene(s, cfg) for s in scenes]
    masques = masque_mer(produits, cfg)
    mer = masques["surf"]
    maintenant = dt.datetime.now(dt.timezone.utc)

    forme = mer.shape
    som_ecume = np.zeros(forme, np.float64)
    som_poids_ecume = np.zeros(forme, np.float64)
    som_brill = np.zeros(forme, np.float64)
    som_poids_brill = np.zeros(forme, np.float64)
    journal = []
    derniere_claire = None
    scenes_utilisees = []   # (frac_ecume, ecume_mask, scene) pour l'indice haut-fond et le viewer

    for s, p in zip(scenes, produits):
        t = dt.datetime.fromisoformat(s["meta"]["datetime"])
        age = (maintenant - t).total_seconds() / 86400
        poids = 0.5 ** (age / c["demi_vie_jours"])
        nuages_local = 1 - p["valide"][mer].mean()
        ecume = p["ecume"] & mer
        frac_ecume = ecume[mer & p["valide"]].mean() if (mer & p["valide"]).any() else 0.0
        garde = nuages_local <= d["nuages_local_max"]
        # Une scène sans houle (pas d'écume) n'apprend rien sur les bancs : on l'ignore
        avec_houle = frac_ecume >= d.get("ecume_min_fraction", 0.005)
        cond = s["meta"].get("conditions") or {}
        journal.append({
            "id": s["meta"]["id"], "datetime": s["meta"]["datetime"], "conditions": cond,
            "platform": s["meta"]["platform"], "nuages_tuile": s["meta"]["nuages_tuile"],
            "nuages_local": round(float(nuages_local), 3), "frac_ecume": round(float(frac_ecume), 4),
            "poids": round(float(poids), 3), "utilisee": bool(garde and avec_houle),
            "age_jours": round(age, 1),
        })
        if not garde:
            continue
        derniere_claire = s
        v = p["valide"] & mer
        som_brill[v] += poids * p["brillance"][v]
        som_poids_brill[v] += poids
        if avec_houle:
            som_ecume[v] += poids * ecume[v]
            som_poids_ecume[v] += poids
            # Taille de houle réelle si connue, sinon la fraction d'écume comme proxy
            taille = cond.get("houle_m") if cond.get("houle_m") is not None else float(frac_ecume) * 20
            scenes_utilisees.append((float(taille), ecume, s))

    frequence = np.where(som_poids_ecume > 0, som_ecume / np.maximum(som_poids_ecume, 1e-9), np.nan)
    timex = np.where(som_poids_brill > 0, som_brill / np.maximum(som_poids_brill, 1e-9), np.nan)
    # Lissage léger (bruit pixel) : 3x3
    freq_l = ndimage.uniform_filter(np.nan_to_num(frequence), 3)
    freq_l[~mer] = np.nan

    # Indice haut-fond : les scènes sont classées par taille de houle (Open-Meteo au passage,
    # sinon fraction d'écume). Un pixel qui casse déjà sur la scène la plus calme est une crête (1) ;
    # un pixel qui ne casse que sur la scène la plus agitée est profond (indice ~0).
    haut_fond = np.full(forme, np.nan, np.float32)
    if len(scenes_utilisees) >= 2:
        ordre = sorted(scenes_utilisees, key=lambda t: t[0])           # calme -> agité
        n = len(ordre)
        for rang, (_, ecume, _) in enumerate(reversed(ordre)):          # agité -> calme
            haut_fond[ecume] = rang / (n - 1)                           # écrase avec la valeur la + calme
        haut_fond = ndimage.median_filter(np.nan_to_num(haut_fond, nan=0), 3)
        haut_fond[~mer] = np.nan
        haut_fond[mer & (haut_fond == 0) & ~(som_ecume > 0)] = np.nan   # jamais cassé -> NaN

    return {
        "mer": mer, "ocean": masques["ocean"], "frequence": freq_l, "timex": timex, "haut_fond": haut_fond,
        "derniere": derniere_claire, "journal": journal,
        "scenes_utilisees": [(f, e, sc["meta"]) for f, e, sc in scenes_utilisees],
        "scenes_claires": [sc for sc in scenes if any(j["id"] == sc["meta"]["id"] and j["nuages_local"] <= d["nuages_local_max"] for j in journal)],
        "geo": scenes[0]["geo"],
    }


def obs_banc_externe(comp: dict, r0: int, r1: int, c0: int, c1: int, d_min_m: float, lignes_min: float) -> list[dict]:
    """Pour chaque scène du composite : le banc du large a-t-il cassé ? (part des lignes de la
    vignette avec de l'écume au-delà de d_min_m du bord). Sert à caler le verdict « casse au large »."""
    mer = comp["mer"][r0:r1, c0:c1]
    lignes = [i for i in range(mer.shape[0]) if mer[i].any()]
    if not lignes:
        return []
    cols = np.arange(mer.shape[1])
    au_large = np.zeros(mer.shape, bool)
    for i in lignes:
        au_large[i] = mer[i] & ((np.flatnonzero(mer[i]).max() - cols) * RES >= d_min_m)
    obs = []
    for taille, ecume, meta in comp["scenes_utilisees"]:
        e = ecume[r0:r1, c0:c1] & au_large
        frac = float(np.mean([e[i].any() for i in lignes]))
        c = meta.get("conditions") or {}
        obs.append({"date": meta["datetime"][:10], "houle_m": c.get("houle_m", round(taille, 2)),
                    "periode_s": c.get("periode_s"), "direction": c.get("direction"),
                    "hauteur_zh_m": c.get("hauteur_zh_m"), "frac_lignes": round(frac, 2),
                    "casse": frac >= lignes_min})
    return obs


def metriques_spot(comp: dict, r0: int, r1: int, c0: int, c1: int, seuil=0.3, pas_profil=20.0) -> dict:
    """Largeur de la zone de déferlement (bord -> limite externe où freq >= seuil), ligne par
    ligne dans la boîte du spot, et profil cross-shore moyen (fréquence et indice haut-fond en
    fonction de la distance au bord). La côte est à l'est : bord = colonne max du masque mer."""
    mer = comp["mer"][r0:r1, c0:c1]
    freq = np.nan_to_num(comp["frequence"][r0:r1, c0:c1], nan=0)
    hf = comp["haut_fond"][r0:r1, c0:c1]
    largeurs = []
    d_list, f_list, h_list = [], [], []
    for i in range(mer.shape[0]):
        cols_mer = np.flatnonzero(mer[i])
        cols_def = np.flatnonzero(freq[i] >= seuil)
        if cols_mer.size == 0:
            continue
        bord = cols_mer.max()
        largeurs.append((bord - cols_def.min()) * RES if cols_def.size else 0.0)
        d_list.append((bord - cols_mer) * RES)
        f_list.append(freq[i][cols_mer])
        h_list.append(hf[i][cols_mer])
    if not largeurs:
        return {"largeur_mediane_m": None, "largeur_max_m": None, "variabilite_m": None, "profil": []}
    l = np.array(largeurs)
    # Profil : moyenne par tranche de distance au bord
    d = np.concatenate(d_list); f = np.concatenate(f_list); h = np.concatenate(h_list)
    bords = np.arange(0, 1000 + pas_profil, pas_profil)
    idx = np.digitize(d, bords) - 1
    profil = []
    for k in range(len(bords) - 1):
        m = idx == k
        if m.sum() < 3:
            continue
        hv = h[m][~np.isnan(h[m])]
        # L'indice haut-fond n'a de sens que là où assez de pixels ont déferlé au moins une fois ;
        # au-delà, quelques pixels isolés donneraient une courbe en dents de scie.
        assez = hv.size >= max(10, 0.15 * m.sum())
        profil.append({"d": int(bords[k] + pas_profil / 2),
                       "freq": round(float(np.nanmean(f[m])), 3),
                       "hf": round(float(np.mean(hv)), 3) if assez else None})
    return {"largeur_mediane_m": round(float(np.median(l))), "largeur_max_m": round(float(l.max())),
            "variabilite_m": round(float(l.std())), "profil": profil}
