"""Lecture fenêtrée d'une scène (4 bandes 10 m + SCL) sur la zone, avec cache local."""
from __future__ import annotations
import json
import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.windows import from_bounds, Window
from rasterio.warp import transform_bounds
from rasterio.transform import from_origin

from .config import CACHE

BANDES = {"blue": "B02", "green": "B03", "red": "B04", "nir": "B08"}
RES = 10.0

# Classes SCL (Scene Classification) considérées invalides. On NE rejette PAS les classes
# nuage (8, 9) ni neige (11) : ESA y classe très souvent l'écume de déferlement. Le masque
# nuage est refait maison à partir du ratio SWIR/visible (voir analyse.py).
SCL_INVALIDE = (0, 1, 3, 10)   # nodata, saturé, ombre, cirrus


def grille_aoi(cfg: dict, src_crs, src_transform) -> tuple[Window, dict]:
    """Fenêtre pixel alignée sur la grille 10 m native, identique pour toutes les scènes."""
    bb = transform_bounds("EPSG:4326", src_crs, *cfg["aoi"]["bbox"])
    # Snap des bornes sur la grille 10 m pour que toutes les scènes s'empilent exactement
    x0 = np.floor(bb[0] / RES) * RES
    x1 = np.ceil(bb[2] / RES) * RES
    y0 = np.floor(bb[1] / RES) * RES
    y1 = np.ceil(bb[3] / RES) * RES
    win = from_bounds(x0, y0, x1, y1, transform=src_transform).round_offsets().round_lengths()
    transform = from_origin(x0, y1, RES, RES)
    geo = {"crs": str(src_crs), "transform": list(transform)[:6],
           "bounds": [x0, y0, x1, y1], "shape": [int(win.height), int(win.width)]}
    return win, geo


def _chemin(item) -> "Path":
    return CACHE / f"{item.id}.npz"


def est_en_cache(item) -> bool:
    return _chemin(item).exists()


def charger_scene(item, cfg: dict) -> dict:
    """Retourne dict {refl: (4,H,W) float32, scl: (H,W) uint8, geo, meta}. Télécharge si besoin."""
    p = _chemin(item)
    if p.exists():
        with np.load(p, allow_pickle=False) as d:
            d = {k: d[k] for k in d.files}      # tout en mémoire avant d'éventuellement réécrire
        meta = json.loads(str(d["meta"]))
        if "swir" not in d:                      # cache ancien sans SWIR : on complète
            d["swir"] = _lire_20m(item.assets["swir16"].href, cfg, d["refl"].shape[1:]).astype("float32") * 1e-4
            np.savez_compressed(p, **d)
        return {"refl": d["refl"], "swir": d["swir"], "scl": d["scl"], "geo": meta["geo"], "meta": meta}

    refl = []
    geo = None
    for cle in ("blue", "green", "red", "nir"):
        href = item.assets[cle].href
        with rasterio.open(href) as src:
            win, geo = grille_aoi(cfg, src.crs, src.transform)
            arr = src.read(1, window=win, boundless=True, fill_value=0).astype("float32")
            # Earth Search : offset BOA déjà appliqué -> réflectance = DN * 1e-4
            arr *= 1e-4
            refl.append(arr)
    refl = np.stack(refl)

    forme = refl.shape[1:]
    scl = _lire_20m(item.assets["scl"].href, cfg, forme).astype("uint8")
    swir = _lire_20m(item.assets["swir16"].href, cfg, forme).astype("float32") * 1e-4

    pr = item.properties
    meta = {
        "id": item.id,
        "datetime": item.datetime.isoformat(),
        "platform": pr.get("platform"),
        "nuages_tuile": pr.get("eo:cloud_cover"),
        "geo": geo,
        # Champs à remplir plus tard (étape prévisions) : marée et houle au moment du passage
        "maree_m": None,
        "houle_m": None,
    }
    CACHE.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(p, refl=refl, swir=swir, scl=scl, meta=json.dumps(meta))
    return {"refl": refl, "swir": swir, "scl": scl, "geo": geo, "meta": meta}


def _lire_20m(href: str, cfg: dict, forme_10m) -> np.ndarray:
    """Lit une bande 20 m (SCL, B11) sur la zone, rééchantillonnée au plus proche sur la grille 10 m."""
    with rasterio.open(href) as src:
        win, _ = grille_aoi(cfg, src.crs, src.transform)
        return src.read(1, window=win, boundless=True, fill_value=0,
                        out_shape=tuple(forme_10m), resampling=Resampling.nearest)
