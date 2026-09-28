"""Effet du Gouf de Capbreton sur la houle : tracé de rayons (théorie linéaire) sur la
bathymétrie EMODnet, comparé à une bathymétrie de référence « sans canyon ».

Sortie : coefficient de réfraction Kr(s) le long de la côte (s = abscisse littorale) pour chaque
période T et direction de provenance au large theta. H_cote = Kr * H_large (à la profondeur de
référence h_stop, avant les effets locaux des bancs). Énergie ∝ Kr².
"""
from __future__ import annotations
import json
import numpy as np
import rasterio
from rasterio.warp import calculate_default_transform, reproject, Resampling
from scipy import ndimage
from pyproj import Transformer

from .config import RACINE, OUTPUT

G = 9.81
RES = 100.0            # maille de calcul (m)
CRS_UTM = "EPSG:32630"
BATHY = RACINE / "data" / "bathy_emodnet_wgs84.tif"

PERIODES = [8, 10, 12, 14, 16, 18, 20]
DIRECTIONS = [240, 250, 260, 270, 280, 290, 300, 310, 320]   # provenance, convention nautique


# ----------------------------------------------------------------------------- bathymétrie
def charger_bathy():
    """Profondeur (m, positive vers le bas) sur grille UTM 100 m. Terre -> NaN."""
    with rasterio.open(BATHY) as src:
        tr, w, h = calculate_default_transform(src.crs, CRS_UTM, src.width, src.height,
                                               *src.bounds, resolution=RES)
        z = np.full((h, w), np.nan, np.float32)
        reproject(src.read(1), z, src_transform=src.transform, src_crs=src.crs,
                  dst_transform=tr, dst_crs=CRS_UTM, resampling=Resampling.bilinear,
                  src_nodata=None, dst_nodata=np.nan)
    hors = np.isnan(z)                     # coins hors du raster source (pas de la terre)
    terre = ~hors & (z >= 0)
    prof = -z
    prof[terre] = np.nan
    # Lissage léger : les équations des rayons demandent un champ de célérité dérivable
    lisse = ndimage.gaussian_filter(np.nan_to_num(prof, nan=0), 1.0)
    poids = ndimage.gaussian_filter((~np.isnan(prof)).astype(float), 1.0)
    prof_l = np.where(poids > 0.3, lisse / np.maximum(poids, 1e-6), np.nan)
    prof_l[terre] = np.nan
    # Hors domaine : on prolonge la profondeur voisine (les rayons y passent en ligne quasi droite)
    if hors.any():
        idx = ndimage.distance_transform_edt(hors, return_distances=False, return_indices=True)
        prof_l = np.where(hors, prof_l[tuple(idx)], prof_l)
    return prof_l, tr, terre


def bathy_reference(prof: np.ndarray, tr, terre: np.ndarray, lat_min_ref=43.72):
    """Bathymétrie « sans Gouf » : profil cross-shore médian du plateau landais (mesuré au nord
    du canyon) réappliqué partout en fonction de la distance à la côte."""
    dist = ndimage.distance_transform_edt(~terre) * RES
    # Latitude de chaque ligne (approx. : northing -> lat)
    ys = tr.f + tr.e * (np.arange(prof.shape[0]) + 0.5)
    to_wgs = Transformer.from_crs(CRS_UTM, "EPSG:4326", always_xy=True)
    xc = tr.c + tr.a * prof.shape[1] / 2
    lats = np.array([to_wgs.transform(xc, y)[1] for y in ys])
    nord = (lats >= lat_min_ref)[:, None] & ~terre
    bins = np.arange(0, dist[~terre].max() + 500, 250)
    idx = np.digitize(dist, bins)
    profil = np.full(len(bins) + 1, np.nan)
    for i in range(1, len(bins) + 1):
        sel = nord & (idx == i)
        if sel.sum() > 20:
            profil[i] = np.median(prof[sel])
    # Interpolation des trous + monotonie douce
    ok = ~np.isnan(profil)
    profil = np.interp(np.arange(len(profil)), np.flatnonzero(ok), profil[ok])
    ref = profil[idx].astype(np.float32)
    ref[terre] = np.nan
    return ref, dist


# ----------------------------------------------------------------------------- ondes
def nombre_onde(omega: float, h: np.ndarray) -> np.ndarray:
    """Résout omega² = g k tanh(k h) (Newton, vectorisé)."""
    h = np.maximum(h, 0.3)
    k = omega ** 2 / G / np.sqrt(np.tanh(omega ** 2 / G * h))       # approx. initiale
    for _ in range(8):
        th = np.tanh(k * h)
        f = G * k * th - omega ** 2
        df = G * th + G * k * h * (1 - th ** 2)
        k = k - f / df
    return k


def champ_celerite(prof: np.ndarray, T: float):
    omega = 2 * np.pi / T
    h = np.nan_to_num(prof, nan=0.3)
    k = nombre_onde(omega, h)
    c = omega / k
    cy, cx = np.gradient(c, RES)          # axes : (lignes = y décroissant, colonnes = x)
    cy = -cy                               # ligne croissante = y décroissant -> dérivée en y
    return c, cx, cy


# ----------------------------------------------------------------------------- rayons
def tracer_rayons(prof, c, cx, cy, tr, theta_naut: float, h_stop: float, ds=40.0,
                  espacement=50.0, demi_longueur=60_000.0, recul=45_000.0, traj_pas=0):
    """Lance un front de rayons parallèles depuis le large ; renvoie les points d'arrivée
    (x, y, direction locale) des rayons atteignant la profondeur h_stop."""
    H, W = prof.shape
    # direction de propagation (vecteur unitaire est/nord)
    ux, uy = -np.sin(np.radians(theta_naut)), -np.cos(np.radians(theta_naut))
    # centre du domaine côté côte, puis recul au large le long de -u
    xc = tr.c + tr.a * W * 0.85
    yc = tr.f + tr.e * H * 0.5
    x0c, y0c = xc - ux * recul, yc - uy * recul
    t = np.arange(-demi_longueur, demi_longueur + espacement, espacement)
    x = x0c + t * (-uy)
    y = y0c + t * ux
    theta = np.full(x.shape, np.arctan2(uy, ux))
    vivant = np.ones(x.shape, bool)
    arr_x, arr_y, arr_th, arr_id = [], [], [], []

    def interp(champ, xq, yq):
        col = (xq - tr.c) / tr.a - 0.5
        lig = (yq - tr.f) / tr.e - 0.5
        return ndimage.map_coordinates(champ, [lig, col], order=1, mode="nearest")

    def dedans(xq, yq):
        col = (xq - tr.c) / tr.a
        lig = (yq - tr.f) / tr.e
        return (col > 1) & (col < W - 2) & (lig > 1) & (lig < H - 2)

    # Rayons partant hors domaine : on les avance en ligne droite jusqu'à la frontière
    # (au-delà du domaine : plateau ~uniforme, réfraction négligée)
    xmin, xmax = tr.c + 2 * tr.a, tr.c + (W - 3) * tr.a
    ymax, ymin = tr.f + 2 * tr.e, tr.f + (H - 3) * tr.e
    with np.errstate(divide="ignore", invalid="ignore"):
        tx = np.where(ux != 0, np.maximum((xmin - x) / ux, (xmax - x) / ux), -np.inf)   # sortie en x
        tx_in = np.where(ux != 0, np.minimum((xmin - x) / ux, (xmax - x) / ux), -np.inf)
        ty_in = np.where(uy != 0, np.minimum((ymin - y) / uy, (ymax - y) / uy), -np.inf)
        ty = np.where(uy != 0, np.maximum((ymin - y) / uy, (ymax - y) / uy), np.inf)
    t_in = np.maximum(np.maximum(tx_in, ty_in), 0.0)
    t_out = np.minimum(tx, ty)
    ok = t_in < t_out
    x = x + ux * (t_in + ds)
    y = y + uy * (t_in + ds)
    ok &= dedans(x, y)
    ok &= ~np.isnan(interp(np.where(np.isnan(prof), np.nan, 1.0), x, y))
    x, y, theta, vivant = x[ok], y[ok], theta[ok], vivant[ok]
    ids = np.arange(len(x))

    def derivees(xq, yq, th):
        cq = interp(c, xq, yq)
        cxq = interp(cx, xq, yq)
        cyq = interp(cy, xq, yq)
        return np.cos(th), np.sin(th), (np.sin(th) * cxq - np.cos(th) * cyq) / np.maximum(cq, 0.1)

    traj = [] if traj_pas else None
    n_max = int(140_000 / ds)
    for it in range(n_max):
        if traj is not None and it % traj_pas == 0:
            traj.append(np.where(vivant, x, np.nan).copy()), traj.append(np.where(vivant, y, np.nan).copy())
        if not vivant.any():
            break
        iv = np.flatnonzero(vivant)
        xv, yv, tv = x[iv], y[iv], theta[iv]
        k1 = derivees(xv, yv, tv)
        k2 = derivees(xv + 0.5 * ds * k1[0], yv + 0.5 * ds * k1[1], tv + 0.5 * ds * k1[2])
        k3 = derivees(xv + 0.5 * ds * k2[0], yv + 0.5 * ds * k2[1], tv + 0.5 * ds * k2[2])
        k4 = derivees(xv + ds * k3[0], yv + ds * k3[1], tv + ds * k3[2])
        xv = xv + ds / 6 * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0])
        yv = yv + ds / 6 * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1])
        tv = tv + ds / 6 * (k1[2] + 2 * k2[2] + 2 * k3[2] + k4[2])
        x[iv], y[iv], theta[iv] = xv, yv, tv
        hors = ~dedans(xv, yv)
        hq = interp(np.nan_to_num(prof, nan=0.0), xv, yv)
        arrive = (hq <= h_stop) & (hq > 0.5) & ~hors
        echoue = (hq <= 0.5) & ~hors
        for j in np.flatnonzero(arrive):
            arr_x.append(xv[j]); arr_y.append(yv[j]); arr_th.append(tv[j]); arr_id.append(ids[iv[j]])
        vivant[iv[hors | arrive | echoue]] = False
    if traj is not None:
        tracer_rayons.traj = (np.array(traj[0::2]), np.array(traj[1::2]))
    return np.array(arr_x), np.array(arr_y), np.array(arr_th), np.array(arr_id), len(x)


# ----------------------------------------------------------------------------- abscisse littorale
def axe_cote(prof, tr, h_stop, lat_min=43.55, lat_max=43.85):
    """Axe de la côte : droite ajustée sur l'isobathe h_stop entre lat_min et lat_max.
    Renvoie (origine, vecteur unitaire le long de la côte, orienté vers le nord)."""
    H, W = prof.shape
    ys = tr.f + tr.e * (np.arange(H) + 0.5)
    xs = tr.c + tr.a * (np.arange(W) + 0.5)
    to_wgs = Transformer.from_crs(CRS_UTM, "EPSG:4326", always_xy=True)
    pts = []
    for i, y in enumerate(ys):
        lat = to_wgs.transform(xs[W // 2], y)[1]
        if not (lat_min <= lat <= lat_max):
            continue
        ligne = np.nan_to_num(prof[i], nan=0)
        j = np.flatnonzero(ligne >= h_stop)
        if j.size:
            pts.append((xs[j.max()], y))       # point le plus à l'est encore >= h_stop
    pts = np.array(pts)
    orig = pts.mean(0)
    u = np.linalg.svd(pts - orig)[2][0]
    if u[1] < 0:
        u = -u
    return orig, u


def abscisse(orig, u, x, y):
    return (x - orig[0]) * u[0] + (y - orig[1]) * u[1]


# ----------------------------------------------------------------------------- pipeline
def calculer(cfg: dict, h_stop=10.0, sigma_m=300.0, verbose=True) -> dict:
    prof, tr, terre = charger_bathy()
    ref, _ = bathy_reference(prof, tr, terre)
    orig, u = axe_cote(prof, tr, h_stop)
    to_utm = Transformer.from_crs("EPSG:4326", CRS_UTM, always_xy=True)
    spots_s = {}
    for sp in cfg["spots"]:
        x, y = to_utm.transform(sp.lon, sp.lat)
        spots_s[sp.id] = abscisse(orig, u, x, y)

    s_grid = np.arange(-16_000, 16_000, 100.0)
    res = {"s": s_grid, "spots_s": spots_s, "Kr": {}, "dir_arrivee": {}, "rayons": {}}
    sig = sigma_m / 100.0
    for T in PERIODES:
        c, cx, cy = champ_celerite(prof, T)
        cr, crx, cry = champ_celerite(ref, T)
        for th in DIRECTIONS:
            cas_fig = (T, th) in [(14, 290), (10, 280), (18, 300)]
            ax_, ay_, ath, aid, n0 = tracer_rayons(prof, c, cx, cy, tr, th, h_stop, traj_pas=10 if cas_fig else 0)
            if cas_fig:
                res["rayons"][(T, th)] = tracer_rayons.traj
            rx_, ry_, rth, rid, n1 = tracer_rayons(ref, cr, crx, cry, tr, th, h_stop)
            sa = abscisse(orig, u, ax_, ay_)
            sr = abscisse(orig, u, rx_, ry_)
            da = ndimage.gaussian_filter1d(np.histogram(sa, bins=np.append(s_grid, s_grid[-1] + 100))[0].astype(float), sig)
            dr = ndimage.gaussian_filter1d(np.histogram(sr, bins=np.append(s_grid, s_grid[-1] + 100))[0].astype(float), sig)
            Kr = np.sqrt(da / np.maximum(dr, 1e-9))
            Kr[dr < 0.05] = np.nan
            Kr = np.clip(Kr, 0.1, 3.0)
            # direction moyenne d'arrivée par bin (nautique)
            idx = np.clip(((sa - s_grid[0]) / 100).astype(int), 0, len(s_grid) - 1)
            dir_arr = np.full(len(s_grid), np.nan)
            for i in np.unique(idx):
                m = idx == i
                ang = np.arctan2(np.sin(ath[m]).mean(), np.cos(ath[m]).mean())
                dir_arr[i] = (np.degrees(np.arctan2(-np.cos(ang), -np.sin(ang))) + 360) % 360
            res["Kr"][(T, th)] = Kr
            res["dir_arrivee"][(T, th)] = dir_arr
            if verbose:
                kn = Kr[np.argmin(abs(s_grid - spots_s["la_nord"]))]
                print(f"  T={T:2d}s  dir={th:3d}°  rayons arrivés {len(sa):4d}/{n0}  Kr La Nord = {kn:.2f}")
    res["prof"], res["tr"], res["ref"], res["orig"], res["u"] = prof, tr, ref, orig, u
    return res


# ----------------------------------------------------------------------------- rendu
def rendre(res: dict, cfg: dict, dossier=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    dossier = dossier or (OUTPUT / "gouf")
    dossier.mkdir(parents=True, exist_ok=True)
    prof, tr, s_grid, spots_s = res["prof"], res["tr"], res["s"], res["spots_s"]
    noms = {sp.id: sp.nom for sp in cfg["spots"]}
    H, W = prof.shape
    ext = [tr.c, tr.c + tr.a * W, tr.f + tr.e * H, tr.f]
    to_utm = Transformer.from_crs("EPSG:4326", CRS_UTM, always_xy=True)

    # 1) Rayons sur la bathymétrie
    for (T, th), (tx, ty) in res["rayons"].items():
        fig, ax = plt.subplots(figsize=(10, 9), dpi=100)
        ax.imshow(-prof, extent=ext, cmap="Blues_r", vmin=-800, vmax=0)
        ax.contour(np.linspace(ext[0], ext[1], W), np.linspace(ext[3], ext[2], H), prof,
                   levels=[10, 20, 30, 50, 100, 200, 300, 500], colors="w", linewidths=0.4)
        for j in range(0, tx.shape[1], 4):
            ax.plot(tx[:, j], ty[:, j], color="orange", lw=0.5, alpha=0.8)
        for sp in cfg["spots"]:
            x, y = to_utm.transform(sp.lon, sp.lat)
            ax.plot(x, y, "r.", ms=5)
            if sp.id in ("la_nord", "graviere", "la_sud", "estagnots", "la_piste", "soustons", "casernes"):
                ax.text(x + 400, y, sp.nom, color="w", fontsize=8, va="center")
        xn, yn = to_utm.transform(cfg["spots"][8].lon, cfg["spots"][8].lat) if False else (None, None)
        ax.set_xlim(ext[1] - 22_000, ext[1] - 2_000)
        ax.set_ylim(*[to_utm.transform(-1.45, 43.58)[1], to_utm.transform(-1.42, 43.80)[1]])
        ax.set_title(f"Rayons de houle — T = {T} s, provenance {th}° — arrêt à l'isobathe 10 m", fontsize=11)
        ax.set_aspect("equal"); ax.set_xticks([]); ax.set_yticks([])
        fig.savefig(dossier / f"rayons_T{T}_{th}.png", bbox_inches="tight")
        plt.close(fig)

    # 2) Kr le long de la côte, plusieurs périodes, direction 290 (WNW = houle classique)
    fig, ax = plt.subplots(figsize=(12, 5), dpi=100)
    for T, col in zip([8, 12, 16, 20], ["#999", "#4a90d9", "#e67e22", "#c0392b"]):
        ax.plot(s_grid / 1000, res["Kr"][(T, 290)], color=col, lw=1.8, label=f"T = {T} s")
    ax.axhline(1, color="k", lw=0.6, ls="--")
    for sid, sv in spots_s.items():
        ax.axvline(sv / 1000, color="#ccc", lw=0.5)
        ax.text(sv / 1000, 2.55, noms[sid], rotation=90, fontsize=7, va="top", ha="center")
    ax.set_xlim(spots_s["savane"] / 1000 - 1.5, spots_s["vieux_boucau"] / 1000 + 1.5)
    ax.set_ylim(0, 2.6)
    ax.set_xlabel("abscisse littorale (km, sud → nord)"); ax.set_ylabel("Kr = H côte / H sans Gouf")
    ax.set_title("Amplification de la houle par le Gouf de Capbreton — provenance 290° (WNW)")
    ax.legend(loc="upper left")
    fig.savefig(dossier / "Kr_le_long_de_la_cote_290.png", bbox_inches="tight")
    plt.close(fig)

    # 3) La Nord : Kr(T, dir) et position du maximum de focalisation par rapport au spot
    sn = spots_s["la_nord"]
    i_n = np.argmin(abs(s_grid - sn))
    fen = (s_grid > sn - 2500) & (s_grid < sn + 2500)
    Kn = np.zeros((len(PERIODES), len(DIRECTIONS)))
    Kmax = np.zeros_like(Kn); off = np.zeros_like(Kn)
    for i, T in enumerate(PERIODES):
        for j, th in enumerate(DIRECTIONS):
            k = res["Kr"][(T, th)]
            Kn[i, j] = np.nanmean(k[i_n - 3:i_n + 4])          # ±300 m autour du spot
            kk = np.where(fen, np.nan_to_num(k, nan=0), 0)
            m = np.argmax(kk); Kmax[i, j] = kk[m]; off[i, j] = (s_grid[m] - sn)
    fig, axes = plt.subplots(1, 3, figsize=(16, 4.6), dpi=100)
    for ax, mat, titre, cmap, fmt in [
        (axes[0], Kn, "Kr à La Nord (±300 m)", "YlOrRd", "{:.2f}"),
        (axes[1], Kmax, "Kr max dans ±2,5 km", "YlOrRd", "{:.2f}"),
        (axes[2], off / 1000, "position du max (km, + = nord de La Nord)", "coolwarm", "{:+.1f}")]:
        im = ax.imshow(mat, aspect="auto", cmap=cmap, origin="lower",
                       vmin=(0.5 if "Kr" in titre else -2.5), vmax=(2.5 if "Kr" in titre else 2.5))
        ax.set_xticks(range(len(DIRECTIONS))); ax.set_xticklabels([f"{d}°" for d in DIRECTIONS])
        ax.set_yticks(range(len(PERIODES))); ax.set_yticklabels([f"{t} s" for t in PERIODES])
        ax.set_xlabel("provenance de la houle au large"); ax.set_title(titre, fontsize=10)
        for i in range(mat.shape[0]):
            for j in range(mat.shape[1]):
                ax.text(j, i, fmt.format(mat[i, j]), ha="center", va="center", fontsize=7)
        fig.colorbar(im, ax=ax, fraction=0.04)
    fig.suptitle("La Nord — effet du Gouf selon période et direction", fontsize=12)
    fig.tight_layout()
    fig.savefig(dossier / "la_nord_Kr.png", bbox_inches="tight")
    plt.close(fig)

    # 4) Tables JSON par spot + npz complet pour le moteur de scoring
    table = {}
    for sid, sv in spots_s.items():
        i = np.argmin(abs(s_grid - sv))
        table[sid] = {f"T{T}_D{th}": round(float(np.nanmean(res["Kr"][(T, th)][i - 3:i + 4])), 3)
                      for T in PERIODES for th in DIRECTIONS}
    (dossier / "amplification_spots.json").write_text(json.dumps(
        {"description": "Kr = H(isobathe 10 m) / H(même houle sans le Gouf). Énergie ∝ Kr². Moyenne ±300 m.",
         "periodes_s": PERIODES, "directions_provenance_deg": DIRECTIONS, "spots": table},
        indent=1, ensure_ascii=False))
    np.savez_compressed(RACINE / "data" / "gouf_Kr.npz", s=s_grid,
                        Kr=np.array([[res["Kr"][(T, th)] for th in DIRECTIONS] for T in PERIODES]),
                        dir_arrivee=np.array([[res["dir_arrivee"][(T, th)] for th in DIRECTIONS] for T in PERIODES]),
                        periodes=PERIODES, directions=DIRECTIONS,
                        spots_id=list(spots_s.keys()), spots_s=list(spots_s.values()))
    return table, Kn, Kmax, off


# ----------------------------------------------------------------------------- Kr effectif
def charger_Kr():
    d = np.load(RACINE / "data" / "gouf_Kr.npz", allow_pickle=True)
    return {"s": d["s"], "Kr": d["Kr"], "P": list(d["periodes"]), "D": list(d["directions"]),
            "spots": dict(zip(d["spots_id"], d["spots_s"]))}


def kr_effectif(K: dict, T: float, theta: float, sigma_dir=12.0, sigma_T=2.0) -> np.ndarray:
    """Kr le long de la côte pour une houle réelle : moyenne énergétique sur un étalement
    directionnel gaussien (sigma_dir) et en période (sigma_T). Interpole entre les cas calculés."""
    num = np.zeros_like(K["s"], dtype=float)
    den = 0.0
    for i, Tq in enumerate(K["P"]):
        wT = np.exp(-0.5 * ((Tq - T) / sigma_T) ** 2)
        if wT < 0.05:
            continue
        for j, Dq in enumerate(K["D"]):
            w = wT * np.exp(-0.5 * ((Dq - theta) / sigma_dir) ** 2)
            if w < 1e-3:
                continue
            num += w * np.nan_to_num(K["Kr"][i, j], nan=1.0) ** 2
            den += w
    return np.sqrt(num / max(den, 1e-9))


def kr_spot(K: dict, spot_id: str, T: float, theta: float, **kw) -> float:
    """Kr effectif moyen sur ±300 m autour du spot — c'est la valeur pour le moteur de scoring."""
    i = int(np.argmin(abs(K["s"] - K["spots"][spot_id])))
    return float(np.mean(kr_effectif(K, T, theta, **kw)[i - 3:i + 4]))


def metriques_approche(cfg: dict) -> dict:
    """Profil d'approche par spot : distance au bord des isobathes et pente 20 m -> 10 m.
    Une pente forte = shoaling brutal = déferlement plongeant (puissant), et peu de
    dissipation sur le plateau : c'est l'effet principal du Gouf à La Nord."""
    prof, tr, terre = charger_bathy()
    dist = ndimage.distance_transform_edt(~terre) * RES
    to_utm = Transformer.from_crs("EPSG:4326", CRS_UTM, always_xy=True)
    out = {}
    for sp in cfg["spots"]:
        x, y = to_utm.transform(sp.lon, sp.lat)
        r0 = int((y - tr.f) / tr.e)
        rows = slice(max(r0 - 4, 0), r0 + 5)
        iso = {}
        for h in (10, 20, 30, 50):
            dd = dist[rows][prof[rows] >= h]
            iso[h] = float(dd.min()) if dd.size else None
        pente = (10.0 / (iso[20] - iso[10])) if iso[10] and iso[20] and iso[20] > iso[10] else None
        out[sp.id] = {"isobathe_m": iso, "pente_20_10": round(pente, 4) if pente else None}
    return out


def rendre_effectif(cfg: dict, dossier=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    dossier = dossier or (OUTPUT / "gouf")
    dossier.mkdir(parents=True, exist_ok=True)
    K = charger_Kr()
    noms = {sp.id: sp.nom for sp in cfg["spots"]}
    # le npz peut contenir des spots retirés depuis de zone.yaml : on ne rend que ceux de la config
    abs_spots = {sid: sv for sid, sv in K["spots"].items() if sid in noms}
    s = K["s"]

    # Kr effectif le long de la côte, deux directions typiques
    fig, axes = plt.subplots(2, 1, figsize=(12, 8), dpi=100, sharex=True)
    for ax, th in zip(axes, (280, 305)):
        for T, col in zip([8, 12, 16, 20], ["#999", "#4a90d9", "#e67e22", "#c0392b"]):
            ax.plot(s / 1000, kr_effectif(K, T, th), color=col, lw=1.8, label=f"T = {T} s")
        ax.axhline(1, color="k", lw=0.6, ls="--")
        for sid, sv in abs_spots.items():
            ax.axvline(sv / 1000, color="#ccc", lw=0.5)
            ax.text(sv / 1000, 1.95, noms[sid], rotation=90, fontsize=7, va="top", ha="center")
        ax.set_xlim(min(abs_spots.values()) / 1000 - 1.5, max(abs_spots.values()) / 1000 + 1.5)
        ax.set_ylim(0, 2.0); ax.set_ylabel("Kr effectif")
        ax.set_title(f"Provenance {th}° — spectre réaliste (±12° de direction, ±2 s de période)", fontsize=10)
        ax.legend(loc="lower right", fontsize=8)
    axes[1].set_xlabel("abscisse littorale (km, sud → nord)")
    fig.suptitle("Effet du Gouf : Kr = H(isobathe 10 m) / H(même houle sans canyon)")
    fig.tight_layout()
    fig.savefig(dossier / "Kr_effectif_le_long_de_la_cote.png", bbox_inches="tight"); plt.close(fig)

    # La Nord + voisins : Kr effectif (T, dir)
    Ts = [8, 10, 12, 14, 16, 18, 20]; Ds = [250, 260, 270, 280, 290, 300, 310, 320]
    fig, axes = plt.subplots(1, 4, figsize=(19, 4.4), dpi=100)
    for ax, sid in zip(axes, ["la_nord", "graviere", "la_sud", "santocha"]):
        mat = np.array([[kr_spot(K, sid, T, th) for th in Ds] for T in Ts])
        im = ax.imshow(mat, aspect="auto", cmap="RdYlBu_r", origin="lower", vmin=0.3, vmax=1.7)
        ax.set_xticks(range(len(Ds))); ax.set_xticklabels([f"{d}°" for d in Ds], fontsize=8)
        ax.set_yticks(range(len(Ts))); ax.set_yticklabels([f"{t} s" for t in Ts], fontsize=8)
        for i in range(len(Ts)):
            for j in range(len(Ds)):
                ax.text(j, i, f"{mat[i, j]:.2f}", ha="center", va="center", fontsize=7)
        ax.set_title(noms[sid], fontsize=10); ax.set_xlabel("provenance au large")
    fig.colorbar(im, ax=axes, fraction=0.015, label="Kr effectif")
    fig.suptitle("Kr effectif par spot — La Nord en bordure d'ombre pour les longues houles W, focalisation par NW", fontsize=11)
    fig.savefig(dossier / "Kr_effectif_spots.png", bbox_inches="tight"); plt.close(fig)

    # JSON pour le moteur de scoring
    appro = metriques_approche(cfg)
    table = {sid: {"approche": appro[sid],
                   "Kr_effectif": {f"T{T}_D{th}": round(kr_spot(K, sid, T, th), 3) for T in Ts for th in Ds}}
             for sid in abs_spots}
    (dossier / "gouf_spots.json").write_text(json.dumps(
        {"description": "Kr_effectif = H(isobathe 10 m)/H(sans canyon), spectre ±12°/±2 s, moyenne ±300 m. "
                        "approche.isobathe_m = distance au bord des isobathes ; pente_20_10 = pente entre 20 et 10 m.",
         "spots": table}, indent=1, ensure_ascii=False))
    return table
