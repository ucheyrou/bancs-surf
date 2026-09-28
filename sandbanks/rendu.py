"""Sorties : GeoTIFF (UTM), PNG géoréférencés WGS84 pour la carte web, crops par spot, viewer HTML."""
from __future__ import annotations
import json
import math
from pathlib import Path
import numpy as np
import rasterio
from rasterio.transform import Affine, rowcol
from rasterio.warp import calculate_default_transform, reproject, Resampling
from pyproj import Transformer
from PIL import Image, ImageDraw
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import colormaps

from .config import OUTPUT


def _affine(geo) -> Affine:
    return Affine(*geo["transform"])


def ecrire_geotiff(chemin: Path, arr: np.ndarray, geo: dict, nodata=np.nan):
    arr = np.atleast_3d(arr).transpose(2, 0, 1) if arr.ndim == 2 else arr
    with rasterio.open(chemin, "w", driver="GTiff", height=arr.shape[1], width=arr.shape[2],
                       count=arr.shape[0], dtype="float32", crs=geo["crs"], transform=_affine(geo),
                       nodata=nodata, compress="deflate") as dst:
        dst.write(arr.astype("float32"))


def vers_wgs84(arr: np.ndarray, geo: dict, nodata=np.nan, categoriel=False):
    """Reprojette un tableau (H,W) ou (C,H,W) UTM -> EPSG:4326 ; renvoie (tableau, bounds)."""
    src_crs = geo["crs"]
    src_tr = _affine(geo)
    h, w = geo["shape"]
    dst_tr, dw, dh = calculate_default_transform(src_crs, "EPSG:4326", w, h, *geo["bounds"])
    arr3 = arr[None] if arr.ndim == 2 else arr
    out = np.full((arr3.shape[0], dh, dw), nodata, dtype="float32")
    for i in range(arr3.shape[0]):
        reproject(arr3[i].astype("float32"), out[i], src_transform=src_tr, src_crs=src_crs,
                  dst_transform=dst_tr, dst_crs="EPSG:4326",
                  resampling=Resampling.nearest if categoriel else Resampling.bilinear,
                  src_nodata=nodata, dst_nodata=nodata)
    b = rasterio.transform.array_bounds(dh, dw, dst_tr)   # (w, s, e, n)
    bounds = [[b[1], b[0]], [b[3], b[2]]]                  # Leaflet : [[sud, ouest],[nord, est]]
    return (out[0] if arr.ndim == 2 else out), bounds


def png_frequence(freq: np.ndarray, chemin: Path, vmax=1.0, cmap="inferno"):
    """Colormap sur un indice 0..1, transparent hors zone / valeurs faibles."""
    cm = colormaps[cmap]
    v = np.clip(np.nan_to_num(freq, nan=0) / vmax, 0, 1)
    rgba = (cm(v) * 255).astype("uint8")
    alpha = np.where(np.isnan(freq), 0, np.clip(v * 2.0, 0, 1) * 230).astype("uint8")
    rgba[..., 3] = alpha
    Image.fromarray(rgba, "RGBA").save(chemin)


def png_masque_mer(mer: np.ndarray, chemin: Path):
    """Masque de la zone de surf : blanc opaque sur la mer, transparent sur la terre.
    Sert à l'app iOS pour limiter l'animation de houle à l'eau, au trait de côte réel."""
    m = np.nan_to_num(mer, nan=0) > 0.5
    rgba = np.zeros(m.shape + (4,), "uint8")
    rgba[m] = (255, 255, 255, 255)
    Image.fromarray(rgba, "RGBA").save(chemin)


def png_champ_banc(freq: np.ndarray, hf: np.ndarray, ocean: np.ndarray, chemin: Path):
    """Données brutes du banc pour l'animation iOS (où chaque vague casse), pas une image à afficher.
    R = fréquence de déferlement ×255 ; G = 0 si le pixel n'a jamais cassé, sinon 1 + haut-fond ×254 ;
    B = 255 sur l'océan. Alpha opaque : iOS prémultiplie l'alpha, ce qui écraserait les canaux."""
    r = np.clip(np.nan_to_num(freq, nan=0), 0, 1) * 255
    g = np.where(np.isnan(hf), 0, 1 + np.clip(np.nan_to_num(hf, nan=0), 0, 1) * 254)
    b = np.where(np.nan_to_num(ocean, nan=0) > 0.5, 255, 0)
    rgba = np.dstack([r, g, b, np.full(r.shape, 255)]).round().astype("uint8")
    Image.fromarray(rgba, "RGBA").save(chemin)


def png_ecume(ecume: np.ndarray, chemin: Path):
    """Masque d'écume d'une scène : blanc semi-transparent."""
    rgba = np.zeros(ecume.shape + (4,), "uint8")
    e = np.nan_to_num(ecume, nan=0) > 0.5
    rgba[e] = (255, 255, 255, 200)
    Image.fromarray(rgba, "RGBA").save(chemin)


def png_timex(timex: np.ndarray, chemin: Path, vmin=0.03, vmax=0.20):
    v = np.clip((np.nan_to_num(timex, nan=0) - vmin) / (vmax - vmin), 0, 1)
    rgba = np.zeros(v.shape + (4,), "uint8")
    rgba[..., :3] = (v * 255).astype("uint8")[..., None]
    rgba[..., 3] = np.where(np.isnan(timex), 0, 255).astype("uint8")
    Image.fromarray(rgba, "RGBA").save(chemin)


def rgb_etire(refl: np.ndarray, gain=0.25) -> np.ndarray:
    b, g, r = refl[0], refl[1], refl[2]
    rgb = np.dstack([r, g, b]) / gain
    return np.clip(rgb, 0, 1)


def png_rgb(refl: np.ndarray, chemin: Path):
    rgb = rgb_etire(refl)
    nod = (refl[3] <= 0)
    rgba = np.dstack([(rgb * 255).astype("uint8"), np.where(nod, 0, 255).astype("uint8")])
    Image.fromarray(rgba, "RGBA").save(chemin)


def scenes_wgs84(comp: dict, dossier: Path) -> list[dict]:
    """PNG WGS84 par scène claire : image RGB + masque d'écume (pour le curseur temporel du viewer)."""
    dossier.mkdir(parents=True, exist_ok=True)
    geo = comp["geo"]
    ecume_par_id = {m["id"]: e for _, e, m in comp["scenes_utilisees"]}
    liste = []
    for sc in comp["scenes_claires"]:
        sid = sc["meta"]["id"]
        rgb_w, _ = vers_wgs84(sc["refl"], geo, nodata=0)
        png_rgb(rgb_w, dossier / f"{sid}_rgb.png")
        entree = {"id": sid, "date": sc["meta"]["datetime"][:10], "rgb": f"scenes/{sid}_rgb.png", "ecume": None}
        if sid in ecume_par_id:
            e_w, _ = vers_wgs84(ecume_par_id[sid].astype("float32"), geo, nodata=-1, categoriel=True)
            png_ecume(e_w, dossier / f"{sid}_ecume.png")
            entree["ecume"] = f"scenes/{sid}_ecume.png"
        liste.append(entree)
    return liste


def crops_spots(comp: dict, cfg: dict, dossier: Path) -> list[dict]:
    """Une vignette par spot : dernière image RGB + fréquence de déferlement en surimpression."""
    dossier.mkdir(parents=True, exist_ok=True)
    geo = comp["geo"]
    tr = _affine(geo)
    to_utm = Transformer.from_crs("EPSG:4326", geo["crs"], always_xy=True)
    demi = int(cfg["rendu"]["demi_cote_spot_m"] / 10)
    from .analyse import metriques_spot, obs_banc_externe
    rgb = rgb_etire(comp["derniere"]["refl"])
    freq = comp["frequence"]
    hf = comp["haut_fond"]
    n_util = sum(j["utilisee"] for j in comp["journal"])
    date_der = comp["derniere"]["meta"]["datetime"][:10]
    infos = []
    for sp in cfg["spots"]:
        x, y = to_utm.transform(sp.lon, sp.lat)
        r, c = rowcol(tr, x, y)
        r0, r1 = max(r - demi, 0), min(r + demi, rgb.shape[0])
        c0, c1 = max(c - demi, 0), min(c + demi, rgb.shape[1])
        fig, axes = plt.subplots(1, 3, figsize=(15, 5.6), dpi=100)
        fond = rgb[r0:r1, c0:c1]
        f = freq[r0:r1, c0:c1]
        h = hf[r0:r1, c0:c1]
        for ax in axes:
            ax.imshow(fond)
            ax.plot(c - c0, r - r0, marker="v", color="cyan", ms=12, mec="k")
            ax.plot([5, 25], [f.shape[0] - 8] * 2, color="w", lw=3)
            ax.text(15, f.shape[0] - 12, "200 m", color="w", ha="center", fontsize=8)
            ax.axis("off")
        axes[0].set_title(f"Dernière image claire — {date_der}", fontsize=10)
        im1 = axes[1].imshow(np.ma.masked_where(np.isnan(f) | (f < 0.05), f), cmap="inferno", vmin=0, vmax=1, alpha=0.85)
        axes[1].set_title(f"Fréquence de déferlement ({n_util} scènes)", fontsize=10)
        fig.colorbar(im1, ax=axes[1], fraction=0.04, pad=0.02)
        im2 = axes[2].imshow(np.ma.masked_where(np.isnan(h), h), cmap="viridis", vmin=0, vmax=1, alpha=0.85)
        axes[2].set_title("Indice haut-fond (jaune = crête de banc, violet = chenal)", fontsize=10)
        fig.colorbar(im2, ax=axes[2], fraction=0.04, pad=0.02)
        fig.suptitle(sp.nom, fontsize=13)
        fig.tight_layout()
        p = dossier / f"{sp.id}.png"
        fig.savefig(p)
        plt.close(fig)
        met = metriques_spot(comp, r0, r1, c0, c1)
        if sp.banc_externe_m:
            met["banc_externe"] = {"d_min_m": sp.banc_externe_m, "scenes": obs_banc_externe(
                comp, r0, r1, c0, c1, sp.banc_externe_m, cfg["detection"]["banc_externe_lignes_min"])}
        infos.append({"id": sp.id, "nom": sp.nom, "lat": sp.lat, "lon": sp.lon,
                      "image": f"spots/{sp.id}.png", **met})
    return infos


def _scoring_leger(scoring: dict | None) -> dict | None:
    """Version allégée du scoring pour l'embarquer dans la page (heures à venir, champs utiles)."""
    if not scoring:
        return None
    import datetime as dt
    t0 = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=1)
    keep = [i for i, t in enumerate(scoring["time"]) if dt.datetime.fromisoformat(t).replace(tzinfo=dt.timezone.utc) >= t0]
    champs = ("score", "H_b", "tube", "puissance", "type", "vent", "explication", "Kr", "banc_externe")
    return {"time": [scoring["time"][i] for i in keep],
            "large": {k: [v[i] for i in keep] for k, v in scoring["large"].items()},
            "spots": {sid: {"nom": sp["nom"], "type": sp["type"],
                            "heures": [{c: sp["heures"][i].get(c) for c in champs} for i in keep]}
                      for sid, sp in scoring["spots"].items()},
            "resume": scoring["resume"]}


def viewer_html(chemin: Path, bounds, infos_spots, journal, scenes_liste, cfg, previsions=None, scoring=None):
    donnees = json.dumps({"bounds": bounds, "spots": infos_spots, "scenes": journal,
                          "images": scenes_liste, "previsions": previsions,
                          "scoring": _scoring_leger(scoring)}, ensure_ascii=False)
    html = """<!doctype html><html lang="fr"><head><meta charset="utf-8">
<title>Bancs de sable — Landes</title>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=1">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Bancs">
<meta name="theme-color" content="#0b1020">
<link rel="apple-touch-icon" href="icon-180.png">
<link rel="manifest" href="manifest.json">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<style>
 html,body{margin:0;height:100%;font-family:system-ui,sans-serif;background:#0b1020;color:#e8ecf4;overflow-x:hidden;max-width:100vw}
 #map{position:absolute;inset:0 380px 0 0;background:#06101c}
 #side{position:absolute;top:0;right:0;bottom:0;width:380px;overflow:auto;padding:14px;box-sizing:border-box;background:#11182b;border-left:1px solid #26304a}
 h1{font-size:16px;margin:0 0 8px} h2{font-size:13px;margin:16px 0 6px;color:#9fb0d0}
 table{width:100%;border-collapse:collapse;font-size:11.5px} td,th{padding:3px 4px;text-align:left;border-bottom:1px solid #26304a;white-space:nowrap}
 th{color:#9fb0d0;font-weight:500} td.n{text-align:right;font-variant-numeric:tabular-nums}
 .ok{color:#7ee787} .ko{color:#8b93a7} .dim{color:#9fb0d0}
 .spot{cursor:pointer} .spot:hover{background:#1b2440}
 #timeline{position:absolute;left:12px;bottom:12px;right:392px;background:#11182bdd;border:1px solid #26304a;border-radius:8px;padding:8px 12px;font-size:12px;z-index:1000}
 #timeline input{width:100%} #timeline .row{display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap} #timeline .row span{display:flex;gap:4px;flex-wrap:wrap}
 #tcond{color:#ffd47a;font-size:12px;margin-top:2px}
 #modes{display:flex;gap:6px;margin-bottom:6px} #modes button{background:#0b1020;border:1px solid #26304a;color:#9fb0d0;border-radius:14px;padding:3px 10px;font-size:12px} #modes button.on{background:#ffd47a;color:#0b1020;border-color:#ffd47a;font-weight:600}
 #jourschips{display:flex;gap:4px;overflow-x:auto;margin:4px 0} #jourschips button{flex:0 0 auto;background:#0b1020;border:1px solid #26304a;color:#c9d1d9;border-radius:6px;padding:3px 8px;font-size:11px} #jourschips button.on{border-color:#ffd47a;color:#ffd47a}
 #heureLbl{font-weight:600;min-width:42px;display:inline-block}
 .note-ic{display:flex;align-items:center;justify-content:center;width:30px;height:30px;border-radius:50%;border:2px solid #fff;color:#0b1020;font:700 12px system-ui;box-shadow:0 1px 4px #0008}
 .note-ic.lo{background:#e5534b;color:#fff} .note-ic.mid{background:#ffd47a} .note-ic.hi{background:#7ee787}
 .leaflet-popup-content-wrapper,.leaflet-popup-tip{background:#11182b;color:#e8ecf4;box-shadow:0 2px 12px #000a}
 .leaflet-popup-content{margin:10px 12px;font-size:12px;line-height:1.35;min-width:220px} .leaflet-popup-content b.t{font-size:14px} .leaflet-popup-content .big{font-size:22px;font-weight:700} .leaflet-popup-content .l{color:#9fb0d0}
 .leaflet-popup-content .bar{height:6px;border-radius:3px;background:#26304a;margin:3px 0 6px} .leaflet-popup-content .bar i{display:block;height:100%;border-radius:3px;background:#ffd47a}
 .leaflet-popup-content img{width:100%;border-radius:4px;margin-top:6px}
 #crop img{width:100%;margin-top:8px;border-radius:6px;cursor:zoom-in}
 label.chk{display:inline-flex;align-items:center;gap:4px;margin-right:6px;white-space:nowrap}
 canvas{width:100%;display:block;background:#0b1020;border-radius:6px;margin-bottom:6px}
 .jour{background:#0b1020;border:1px solid #26304a;border-radius:6px;padding:6px 8px;margin-bottom:6px;font-size:11.5px}
 .jour b{color:#ffd47a} .jour .l{color:#9fb0d0} .jour .top{display:grid;grid-template-columns:auto 1fr;gap:2px 8px;margin-top:3px}
 .jour .sc{font-weight:600;color:#7ee787} .jour .sc.mid{color:#ffd47a} .jour .sc.low{color:#e5534b}
 select{background:#0b1020;color:#e8ecf4;border:1px solid #26304a;border-radius:4px;padding:2px 4px;font-size:11px;margin-bottom:4px}
 #tabs{display:none}
 @media (max-width:800px){
   :root{--tabh:calc(56px + env(safe-area-inset-bottom))}
   #map{inset:0 0 var(--tabh) 0}
   #side{left:0;width:100%;top:0;bottom:var(--tabh);display:none;padding:12px 12px calc(12px + env(safe-area-inset-bottom))}
   body.tab-side #side{display:block} body.tab-side #map,body.tab-side #timeline{visibility:hidden}
   #side section{display:none} #side section.on{display:block} #side h1,#side .intro{display:none}
   #timeline{right:8px;left:8px;bottom:calc(var(--tabh) + 8px);padding:6px 10px;font-size:11px}
   #timeline .row{gap:4px} label.chk{font-size:11px}
   #tabs{display:flex;position:fixed;left:0;bottom:0;width:100vw;box-sizing:border-box;height:var(--tabh);padding-bottom:env(safe-area-inset-bottom);background:#11182b;border-top:1px solid #26304a;z-index:1200}
   #side{overflow-x:hidden} #side table{display:block;overflow-x:auto;max-width:100%} .jour{overflow:hidden} .jour .top span{overflow-wrap:anywhere;white-space:normal}
   .leaflet-popup-content{max-width:calc(100vw - 90px)!important;min-width:0}
   #tabs button{flex:1 1 0;min-width:0;background:none;border:0;color:#9fb0d0;font-size:10.5px;padding:6px 0 0;display:flex;flex-direction:column;align-items:center;gap:2px}
   #tabs button span{font-size:18px} #tabs button.on{color:#ffd47a}
   .leaflet-top.leaflet-left{top:env(safe-area-inset-top)}
 }
</style></head><body>
<div id="map"></div>
<div id="timeline">
 <div id="modes"><button data-mode="notes" class="on">Notes des spots</button><button data-mode="sat">Bancs (satellite)</button></div>
 <div id="pane-notes">
  <div id="jourschips"></div>
  <div class="row"><span><span id="heureLbl">—</span> <span class="dim" id="largeLbl"></span></span><span class="dim" id="bestLbl"></span></div>
  <input type="range" id="hslider" min="7" max="21" value="9" step="1">
 </div>
 <div id="pane-sat" style="display:none">
 <div class="row"><b id="tdate">—</b>
  <span><label class="chk"><input type="checkbox" id="showRgb" checked> image S2</label>
        <label class="chk"><input type="checkbox" id="showEcume" checked> écume détectée</label>
        <label class="chk"><input type="checkbox" id="showFreq"> fréquence</label>
        <label class="chk"><input type="checkbox" id="showHf"> haut-fond</label></span></div>
 <div id="tcond"></div>
 <input type="range" id="slider" min="0" max="0" value="0" step="1">
 </div>
</div>
<div id="side">
 <h1>Bancs de sable — Seignosse → Capbreton</h1>
 <div class="intro" style="font-size:12px;color:#9fb0d0">Sentinel-2 · fenêtre __FEN__ j · demi-vie __DV__ j.<br>
 <b>Fréquence</b> : chaud = déferle souvent. <b>Haut-fond</b> : jaune = casse même par petite houle (crête de banc), violet = ne casse que par grosse houle (chenal).</div>
 <section id="s-ouller" class="on">
 <h2>Où aller ? <span class="dim">— note /10 par spot et par heure</span></h2>
 <div id="jours"></div>
 <div class="row2"><select id="hmVar"><option value="score">note /10</option><option value="tube">indice tube</option><option value="H_b">taille au déferlement (m)</option><option value="puissance">puissance</option></select></div>
 <canvas id="cHeat" height="230"></canvas>
 <div id="hmInfo" class="dim" style="font-size:11px;min-height:34px">Survoler / cliquer une case.</div>
 </section><section id="s-prev">
 <h2>Prévisions 7 jours <span class="dim" id="pgen"></span></h2>
 <canvas id="cHoule" height="120"></canvas>
 <canvas id="cVent" height="90"></canvas>
 <canvas id="cMaree" height="110"></canvas>
 <div class="dim" style="font-size:11px">Houle au large du Gouf (avant réfraction), vent à Hossegor, marée / zéro hydro Capbreton avec coefficient estimé. Heures locales.</div>
 </section><section id="s-spots">
 <h2>Spots — largeur de la zone de déferlement</h2>
 <table id="spots"><tr><th>spot</th><th class="n">médiane</th><th class="n">max</th><th class="n">σ</th></tr></table>
 <div id="crop"></div>
 </section><section id="s-scenes">
 <h2>Scènes Sentinel-2</h2>
 <div class="dim" style="font-size:11px;margin-bottom:6px">Sentinel-2 · fenêtre __FEN__ j · demi-vie __DV__ j. <b>Fréquence</b> : chaud = déferle souvent. <b>Haut-fond</b> : jaune = crête de banc, violet = chenal.</div>
 <table id="scenes"><tr><th>date</th><th>sat</th><th class="n">nuage</th><th>houle</th><th>marée</th><th></th></tr></table>
 </section>
</div>
<nav id="tabs">
 <button data-tab="carte" class="on"><span>🗺</span>Carte</button>
 <button data-tab="s-ouller"><span>🏄</span>Où aller</button>
 <button data-tab="s-prev"><span>🌊</span>Prévisions</button>
 <button data-tab="s-spots"><span>📍</span>Spots</button>
 <button data-tab="s-scenes"><span>🛰</span>Scènes</button>
</nav>
<script>
const D = __DATA__;
const map = L.map('map', {zoomControl:true});
const sat = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',{maxZoom:19,attribution:'Esri'}).addTo(map);
const osm = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'OSM'});
L.control.layers({'Esri imagerie':sat,'OSM':osm},{},{collapsed:true}).addTo(map);
const freq = L.imageOverlay('frequence.png', D.bounds, {opacity:0.9});
const hf = L.imageOverlay('haut_fond.png', D.bounds, {opacity:0.9});
let rgbLayer = null, ecumeLayer = null;
map.fitBounds(D.bounds);
const condById = {}; D.scenes.forEach(s=>condById[s.id]=s.conditions||null);
const rose = d => ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'][Math.round(d/22.5)%16];
const fmtCond = c => c ? `houle ${c.houle_m.toFixed(1)} m · ${Math.round(c.periode_s)} s · ${rose(c.direction)} (${Math.round(c.direction)}°) — vent ${Math.round(c.vent_kmh)} km/h ${rose(c.vent_dir)} — marée ${c.hauteur_zh_m.toFixed(1)} m ${c.maree_tendance} · coef ${c.coef_estime}` : '';

function showScene(i){
  const s = D.images[i]; document.getElementById('tdate').textContent = s.date + (s.ecume?'':' (pas de houle : écume non calculée)');
  document.getElementById('tcond').textContent = fmtCond(condById[s.id]);
  if(rgbLayer) map.removeLayer(rgbLayer); if(ecumeLayer) map.removeLayer(ecumeLayer);
  if(document.getElementById('showRgb').checked){ rgbLayer = L.imageOverlay(s.rgb, D.bounds).addTo(map); }
  if(s.ecume && document.getElementById('showEcume').checked){ ecumeLayer = L.imageOverlay(s.ecume, D.bounds, {opacity:0.8}).addTo(map); }
  if(document.getElementById('showFreq').checked){ freq.addTo(map); } else map.removeLayer(freq);
  if(document.getElementById('showHf').checked){ hf.addTo(map); } else map.removeLayer(hf);
}
const sl = document.getElementById('slider'); sl.max = D.images.length-1; sl.value = sl.max;
sl.oninput = ()=>showScene(+sl.value);
['showRgb','showEcume','showFreq','showHf'].forEach(id=>document.getElementById(id).onchange=()=>showScene(+sl.value));
showScene(+sl.value);

// ---- Mode Notes : marqueurs colorés par note à l'heure choisie
const S = D.scoring;
const noteMarkers = {}; let hIndex = 0;
const spotInfo = {}; D.spots.forEach(s=>spotInfo[s.id]=s);
const Tloc = S ? S.time.map(t=>new Date(t+'Z')) : [];
const jours = S ? [...new Set(Tloc.map(d=>d.toDateString()))] : [];
let jourSel = jours[0];
function idxPour(jourStr, heure){ let best=-1; Tloc.forEach((d,i)=>{ if(d.toDateString()===jourStr && d.getHours()===heure) best=i; }); return best; }
function classe(n){ return n>=7?'hi':n>=4?'mid':'lo'; }
function popupHtml(sid, i){
  const sp=S.spots[sid], h=sp.heures[i], LG=S.large, d=Tloc[i], s=spotInfo[sid];
  const jourRes=(S.resume||[]).find(r=>new Date(r.date+'T12:00').toDateString()===d.toDateString());
  const cl=jourRes?jourRes.classement.find(c=>c.spot===sid):null;
  const ex=h.explication==='conditions dans la fenêtre du spot'?'✓ dans la fenêtre du spot':'⚠ '+h.explication;
  return `<b class="t">${sp.nom}</b> <span class="l">· ${sp.type}</span><br>
   <span class="l">${d.toLocaleDateString('fr-FR',{weekday:'long',day:'numeric'})} ${d.getHours()}h</span><br>
   <span class="big">${h.score.toFixed(1)}</span><span class="l">/10</span> &nbsp; <span class="l">${ex}</span>
   <div class="bar"><i style="width:${h.score*10}%"></i></div>
   <b>${h.H_b.toFixed(1)} m</b> au déferlement <span class="l">(large ${LG.H[i]} m · ${LG.T[i]?Math.round(LG.T[i]):'?'} s · ${LG.dir[i]?rose(LG.dir[i]):'?'} · Kr Gouf ${h.Kr})</span><br>
   ${h.type} · <b>tube ${h.tube}</b>/100 · puissance <b>${h.puissance.toFixed(1)}</b><br>
   vent ${LG.vent[i]!=null?Math.round(LG.vent[i])+' km/h '+rose(LG.vent_dir[i]):'?'} → <b>${h.vent}</b> · marée ${LG.niveau_zh[i]} m<br>
   ${h.banc_externe?`<b>banc du large : ${h.banc_externe==='oui'?'ça casse au large':h.banc_externe==='non'?'ne casse pas':'limite'}</b><br>`:''}
   ${cl?`<span class="l">meilleur créneau du jour : <b>${cl.creneau}</b> (${cl.score.toFixed(1)})</span><br>`:''}
   <span class="l">banc satellite : ${s&&s.largeur_mediane_m!=null?`zone de surf ${s.largeur_mediane_m} m, σ ${s.variabilite_m} m`:'n/d'}</span>
   <a href="${s.image}" target="_blank"><img src="${s.image}"></a>`;
}
function majNotes(){
  if(!S) return;
  const heure=+document.getElementById('hslider').value; let i=idxPour(jourSel,heure); if(i<0){ i=Math.max(0,Tloc.findIndex(d=>d.toDateString()===jourSel)); }
  hIndex=i; const d=Tloc[i];
  document.getElementById('heureLbl').textContent=`${d.toLocaleDateString('fr-FR',{weekday:'short'})} ${d.getHours()}h`;
  const LG=S.large; document.getElementById('largeLbl').textContent=`large ${LG.H[i]} m · ${LG.T[i]?Math.round(LG.T[i]):'?'} s · ${LG.dir[i]?rose(LG.dir[i]):'?'} · vent ${LG.vent[i]!=null?Math.round(LG.vent[i]):'?'} km/h ${LG.vent_dir[i]!=null?rose(LG.vent_dir[i]):''} · marée ${LG.niveau_zh[i]} m`;
  const jourRes=(S.resume||[]).find(r=>new Date(r.date+'T12:00').toDateString()===jourSel);
  document.getElementById('bestLbl').textContent = jourRes&&jourRes.classement[0] ? `★ ${jourRes.classement[0].nom} ${jourRes.classement[0].creneau}` : '';
  const z=map.getZoom(); const px = z>=14?32: z>=13?26: z>=12?18: 12; const txt = z>=13;
  D.spots.forEach(s=>{ const h=S.spots[s.id]?.heures[i]; if(!h) return; const m=noteMarkers[s.id];
    m.setIcon(L.divIcon({className:'', html:`<div class="note-ic ${classe(h.score)}" style="width:${px}px;height:${px}px;font-size:${Math.round(px*0.4)}px">${txt?(h.score>=9.95?'10':h.score.toFixed(1)):''}</div>`, iconSize:[px,px], iconAnchor:[px/2,px/2], popupAnchor:[0,-px/2]}));
    if(m.isPopupOpen()) m.setPopupContent(popupHtml(s.id,i)); });
}
if(S){
  const chips=document.getElementById('jourschips');
  jours.forEach((j,k)=>{ const b=document.createElement('button'); const d=new Date(j); b.textContent=d.toLocaleDateString('fr-FR',{weekday:'short',day:'numeric'}); if(k===0) b.classList.add('on');
    b.onclick=()=>{ jourSel=j; chips.querySelectorAll('button').forEach(x=>x.classList.remove('on')); b.classList.add('on'); majNotes(); }; chips.appendChild(b); });
  // heure par défaut : prochaine heure de jour
  const now=new Date(); const h0=Math.min(21,Math.max(7, now.getHours()+1)); document.getElementById('hslider').value=h0;
  if(now.getHours()>=21 && jours[1]){ jourSel=jours[1]; chips.children[1].click(); document.getElementById('hslider').value=9; }
  document.getElementById('hslider').oninput=majNotes;
}
const tb = document.getElementById('spots');
D.spots.forEach(s=>{
  const m = L.marker([s.lat,s.lon],{icon:L.divIcon({className:'',html:'<div class="note-ic mid">·</div>',iconSize:[30,30],iconAnchor:[15,15]})}).addTo(map).bindTooltip(s.nom,{direction:'right',offset:[16,0]});
  noteMarkers[s.id]=m;
  if(S){ m.bindPopup(()=>popupHtml(s.id,hIndex),{maxWidth:Math.min(320, window.innerWidth-70), autoPanPaddingTopLeft:[10,10]}); }
  const tr = document.createElement('tr'); tr.className='spot';
  const f = v => v==null ? '—' : v+' m';
  tr.innerHTML = `<td>${s.nom}</td><td class="n">${f(s.largeur_mediane_m)}</td><td class="n">${f(s.largeur_max_m)}</td><td class="n">${f(s.variabilite_m)}</td>`;
  const show = ()=>{ map.setView([s.lat,s.lon],16); document.getElementById('crop').innerHTML=`<a href="${s.image}" target="_blank"><img src="${s.image}"></a>`; };
  tr.onclick = ()=>{ show(); document.getElementById('crop').scrollIntoView({behavior:'smooth'}); };
  m.on('click', ()=>{ document.getElementById('crop').innerHTML=`<a href="${s.image}" target="_blank"><img src="${s.image}"></a>`; }); tb.appendChild(tr);
});
map.on('zoomend', majNotes);
// vue initiale : les spots (Hossegor au centre), puis ?spot=<id> ouvre une fiche
map.fitBounds(L.latLngBounds(D.spots.map(s=>[s.lat,s.lon])).pad(0.15));
majNotes();
const qs=new URLSearchParams(location.search);
if(qs.get('spot') && noteMarkers[qs.get('spot')]){ const m=noteMarkers[qs.get('spot')]; map.setView(m.getLatLng(), 14); setTimeout(()=>m.openPopup(), 300); }
if(qs.get('tab')){ const b=document.querySelector(`#tabs button[data-tab="${qs.get('tab')}"]`); if(b) setTimeout(()=>b.click(), 400); }
// ---- Modes de la carte
function setMode(mode){
  document.querySelectorAll('#modes button').forEach(b=>b.classList.toggle('on', b.dataset.mode===mode));
  document.getElementById('pane-notes').style.display = mode==='notes'?'':'none';
  document.getElementById('pane-sat').style.display = mode==='sat'?'':'none';
  if(mode==='notes'){ [rgbLayer,ecumeLayer,freq,hf].forEach(l=>l&&map.removeLayer(l)); rgbLayer=ecumeLayer=null; }
  else showScene(+sl.value);
}
document.querySelectorAll('#modes button').forEach(b=>b.onclick=()=>setMode(b.dataset.mode));
setMode('notes');
const ts = document.getElementById('scenes');
D.scenes.slice().reverse().forEach(sc=>{
  const c = sc.conditions||null; const tr=document.createElement('tr');
  tr.innerHTML=`<td>${sc.datetime.slice(0,10)}</td><td>${(sc.platform||'').replace('sentinel-','S').toUpperCase()}</td><td class="n">${(sc.nuages_local*100).toFixed(0)} %</td>`+
   `<td>${c?`${c.houle_m.toFixed(1)} m ${Math.round(c.periode_s)} s ${rose(c.direction)}`:'—'}</td><td>${c?`${c.hauteur_zh_m.toFixed(1)} m ${c.maree_tendance==='montante'?'↑':c.maree_tendance==='descendante'?'↓':'='} c${c.coef_estime}`:'—'}</td>`+
   `<td class="${sc.utilisee?'ok':'ko'}">${sc.utilisee?'utilisée':'ignorée'}</td>`;
  ts.appendChild(tr);
});

// ---- Onglets (mobile)
const redraws = [];
document.querySelectorAll('#tabs button').forEach(b=>b.onclick=()=>{
  document.querySelectorAll('#tabs button').forEach(x=>x.classList.remove('on')); b.classList.add('on');
  const t=b.dataset.tab; document.body.classList.toggle('tab-side', t!=='carte');
  document.querySelectorAll('#side section').forEach(sec=>sec.classList.toggle('on', sec.id===t));
  if(t==='carte') map.invalidateSize(); else requestAnimationFrame(()=>redraws.forEach(f=>f()));
});
// Clic sur un spot depuis un onglet -> revenir à la carte
function goCarte(){ const b=document.querySelector('#tabs button[data-tab=carte]'); if(getComputedStyle(document.getElementById('tabs')).display!=='none') b.click(); }

// ---- Scoring : cartes journalières + heatmap
(function(){
  const S = D.scoring; if(!S) return;
  const cls = v => v>=7?'sc':v>=4?'sc mid':'sc low';
  const J = document.getElementById('jours');
  S.resume.forEach(j=>{
    const div=document.createElement('div'); div.className='jour';
    const L=j.large; let html=`<b>${j.jour}</b> <span class="l">large ${L.H??'?'} m · ${L.T?Math.round(L.T):'?'} s · ${L.dir?rose(L.dir):'?'}</span><div class="top">`;
    j.classement.slice(0,3).forEach(c=>{ const ex=c.explication==='conditions dans la fenêtre du spot'?'':` — <i>${c.explication}</i>`; html+=`<span class="${cls(c.score)}">${c.score.toFixed(1)}</span><span>${c.nom} <span class="l">${c.creneau} · ${c.H_b.toFixed(1)} m · tube ${c.tube} · puiss. ${c.puissance.toFixed(1)} · ${c.vent}${ex}</span></span>`; });
    div.innerHTML=html+'</div>'; J.appendChild(div);
  });
  const ids = Object.keys(S.spots), n = S.time.length, T = S.time.map(t=>new Date(t+'Z'));
  const c = document.getElementById('cHeat'); let W=350, Hh=+c.getAttribute('height'), g, x0=92, rowH, colW;
  function size(){ W=c.clientWidth||W; c.width=W*2; c.height=Hh*2; g=c.getContext('2d'); g.setTransform(1,0,0,1,0,0); g.scale(2,2); rowH=(Hh-16)/ids.length; colW=(W-x0-2)/n; }
  size();
  const scale = {score:[0,10], tube:[0,100], H_b:[0,4], puissance:[0,3]};
  function couleur(v,vmin,vmax){ const t=Math.max(0,Math.min(1,(v-vmin)/(vmax-vmin))); // sombre -> orange -> jaune clair
    const r=Math.round(20+235*Math.min(1,t*1.4)), gg=Math.round(20+200*Math.max(0,t-0.25)/0.75), b=Math.round(40+60*(1-t)*(t<0.3?1:0)+ (t>0.85?150*(t-0.85)/0.15:0)); return `rgb(${r},${gg},${b})`; }
  function draw(){
    const v = document.getElementById('hmVar').value, [vmin,vmax]=scale[v];
    g.clearRect(0,0,W,Hh); g.font='10px system-ui';
    ids.forEach((id,r)=>{ g.fillStyle='#c9d1d9'; g.fillText(S.spots[id].nom.replace(/ \(.*\)/,'').slice(0,16), 2, 14+r*rowH+rowH*0.7);
      S.spots[id].heures.forEach((h,i)=>{ const val=h[v]??0; g.fillStyle=couleur(val,vmin,vmax); const d=T[i]; const nuit=d.getHours()<7||d.getHours()>20; if(nuit) g.fillStyle='#141a2c'; g.fillRect(x0+i*colW,14+r*rowH,colW+0.5,rowH-1); }); });
    g.fillStyle='#9fb0d0'; T.forEach((d,i)=>{ if(d.getHours()===0){ g.fillStyle='#26304a'; g.fillRect(x0+i*colW,12,1,Hh-12); g.fillStyle='#9fb0d0'; g.fillText(d.toLocaleDateString('fr-FR',{weekday:'short',day:'numeric'}),x0+i*colW+2,10);} });
  }
  draw(); document.getElementById('hmVar').onchange=draw; redraws.push(()=>{ if(c.clientWidth){ size(); draw(); } });
  c.onmousemove = c.onclick = ev=>{ const rect=c.getBoundingClientRect(); const mx=ev.clientX-rect.left, my=ev.clientY-rect.top; const i=Math.floor((mx-x0)/colW), r=Math.floor((my-14)/rowH); if(i<0||i>=n||r<0||r>=ids.length) return;
    const h=S.spots[ids[r]].heures[i], d=T[i], L=S.large;
    document.getElementById('hmInfo').innerHTML=`<b>${S.spots[ids[r]].nom}</b> — ${d.toLocaleDateString('fr-FR',{weekday:'short'})} ${d.getHours()}h : <b>${h.score}/10</b> · ${h.H_b} m au déferlement (large ${L.H[i]} m/${L.T[i]?Math.round(L.T[i]):'?'} s/${L.dir[i]?rose(L.dir[i]):'?'}, Kr ${h.Kr}) · ${h.type} · tube ${h.tube} · puissance ${h.puissance} · vent ${h.vent} · marée ${L.niveau_zh[i]} m<br><span class="dim">${h.explication}</span>`; };
})();

// ---- Prévisions : petits graphes canvas
function drawPrev(){
  const P = D.previsions; if(!P){ document.getElementById('pgen').textContent='(indisponibles)'; return; }
  if(!document.getElementById('cHoule').clientWidth) return;
  const H = P.horaires, T = H.time.map(t=>new Date(t+'Z')), n = T.length, now = Date.now();
  document.getElementById('pgen').textContent = '· généré '+new Date(P.genere_utc).toLocaleString('fr-FR',{weekday:'short',hour:'2-digit',minute:'2-digit'});
  const dayLbl = d => d.toLocaleDateString('fr-FR',{weekday:'short',day:'numeric'});
  function setup(id){ const c=document.getElementById(id); const W=c.clientWidth||350; c.width=W*2; c.height=c.getAttribute('height')*2; const g=c.getContext('2d'); g.setTransform(1,0,0,1,0,0); g.scale(2,2); return [g,W,+c.getAttribute('height')]; }
  const x = (i,W) => 34 + (W-40)*i/(n-1);
  function axes(g,W,Hh,titre){
    g.fillStyle='#9fb0d0'; g.font='10px system-ui'; g.fillText(titre,4,10);
    let last=-1; for(let i=0;i<n;i++){ const d=T[i]; if(d.getHours()===0){ g.strokeStyle='#26304a'; g.beginPath(); g.moveTo(x(i,W),14); g.lineTo(x(i,W),Hh-12); g.stroke(); g.fillText(dayLbl(d),x(i,W)+2,Hh-2);} }
    const i0 = T.findIndex(d=>d.getTime()>now); if(i0>0){ g.strokeStyle='#ffd47a'; g.beginPath(); g.moveTo(x(i0,W),14); g.lineTo(x(i0,W),Hh-12); g.stroke(); }
  }
  // Houle
  { const [g,W,Hh]=setup('cHoule'); axes(g,W,Hh,'Houle au large : hauteur (m) · période (s) · direction');
    const hs=H.swell_wave_height, per=H.swell_wave_period, dir=H.swell_wave_direction; const hmax=Math.max(1.5,...hs.filter(v=>v!=null))*1.15;
    const y = v => Hh-14-(Hh-32)*v/hmax;
    g.fillStyle='#4a90d9aa'; for(let i=0;i<n;i++){ if(hs[i]==null) continue; g.fillRect(x(i,W)-1.2,y(hs[i]),2.4,Hh-14-y(hs[i])); }
    g.strokeStyle='#e67e22'; g.lineWidth=1.5; g.beginPath(); const pmax=20; for(let i=0;i<n;i++){ if(per[i]==null) continue; const yy=Hh-14-(Hh-32)*per[i]/pmax; i?g.lineTo(x(i,W),yy):g.moveTo(x(i,W),yy);} g.stroke();
    g.fillStyle='#e8ecf4'; g.font='10px system-ui'; for(let i=0;i<n;i+=12){ if(dir[i]==null) continue; g.save(); g.translate(x(i,W),20); g.rotate((dir[i]+180)*Math.PI/180); g.fillText('➤',-5,4); g.restore(); }
    g.fillStyle='#4a90d9'; g.fillText(hmax.toFixed(1)+' m',2,26); g.fillStyle='#e67e22'; g.fillText('20 s',W-24,26);
  }
  // Vent
  { const [g,W,Hh]=setup('cVent'); axes(g,W,Hh,'Vent à la côte (km/h) — vert = offshore (E/NE), rouge = onshore (W)');
    const v=H.wind_speed_10m, d=H.wind_direction_10m, r=H.wind_gusts_10m; const vmax=Math.max(30,...v.filter(a=>a!=null))*1.1; const y=a=>Hh-14-(Hh-32)*a/vmax;
    for(let i=0;i<n;i++){ if(v[i]==null) continue; const off = Math.cos((d[i]-70)*Math.PI/180); // 70° = offshore idéal (ENE)
      g.fillStyle = off>0.3?'#7ee787cc':off<-0.3?'#e5534bcc':'#c9d1d9aa'; g.fillRect(x(i,W)-1.2,y(v[i]),2.4,Hh-14-y(v[i])); }
    g.strokeStyle='#c9d1d955'; g.beginPath(); for(let i=0;i<n;i++){ if(r[i]==null) continue; i?g.lineTo(x(i,W),y(r[i])):g.moveTo(x(i,W),y(r[i])); } g.stroke();
    g.fillStyle='#9fb0d0'; g.fillText(Math.round(vmax)+' km/h',2,26);
  }
  // Marée
  { const [g,W,Hh]=setup('cMaree'); axes(g,W,Hh,'Marée / zéro hydro (m) — PM/BM et coefficient');
    const z=H.sea_level_height_msl.map(a=>a==null?null:a+P.msl_sur_zero_hydro_m); const zmax=5, y=a=>Hh-14-(Hh-32)*a/zmax;
    g.strokeStyle='#4a90d9'; g.lineWidth=1.5; g.beginPath(); for(let i=0;i<n;i++){ if(z[i]==null) continue; i?g.lineTo(x(i,W),y(z[i])):g.moveTo(x(i,W),y(z[i])); } g.stroke();
    g.fillStyle='#e8ecf4'; g.font='9px system-ui'; let pm=0;
    (P.marees||[]).forEach(e=>{ const t=new Date(e.heure_utc).getTime(); const i=(t-T[0].getTime())/(T[n-1].getTime()-T[0].getTime())*(n-1); if(i<0||i>n-1) return;
      const xx=x(i,W), yy=y(e.hauteur_zh_m); g.fillStyle=e.type==='PM'?'#ffd47a':'#9fb0d0'; g.beginPath(); g.arc(xx,yy,2,0,7); g.fill();
      if(e.type==='PM'){ pm++; const dy = (pm%2)?-5:-15; g.fillStyle='#ffd47a'; g.fillText(`${new Date(e.heure_utc).toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'})}`, xx-12, yy+dy); g.fillStyle='#e8ecf4'; g.fillText(`c${e.coef??'?'}`, xx-6, yy+dy+9>yy-1?yy+dy-9:yy+dy+9); } });
    g.fillStyle='#9fb0d0'; g.fillText('5 m',2,26); g.fillText('0',2,Hh-14);
  }
}
drawPrev(); redraws.push(drawPrev);
</script></body></html>"""
    _pwa_fichiers(chemin.parent)
    html = html.replace("__DATA__", donnees).replace("__FEN__", str(cfg["composite"]["fenetre_jours"])).replace("__DV__", str(cfg["composite"]["demi_vie_jours"]))
    chemin.write_text(html, encoding="utf-8")


def _pwa_fichiers(dossier: Path):
    """manifest.json + icône (vague qui tube) pour l'installation sur l'écran d'accueil iOS."""
    (dossier / "manifest.json").write_text(json.dumps({
        "name": "Bancs de sable — Landes", "short_name": "Bancs", "start_url": "./index.html",
        "display": "standalone", "background_color": "#0b1020", "theme_color": "#0b1020",
        "icons": [{"src": "icon-180.png", "sizes": "180x180", "type": "image/png"},
                  {"src": "icon-512.png", "sizes": "512x512", "type": "image/png"}]}, ensure_ascii=False))
    for taille in (180, 512):
        dessin_icone(taille).save(dossier / f"icon-{taille}.png")


def _bezier(p0, p1, p2, p3, n: int = 80) -> list[tuple[float, float]]:
    t = np.linspace(0, 1, n)[:, None]
    p = ((1 - t) ** 3 * np.array(p0) + 3 * (1 - t) ** 2 * t * np.array(p1)
         + 3 * (1 - t) * t ** 2 * np.array(p2) + t ** 3 * np.array(p3))
    return [tuple(q) for q in p]


def dessin_icone(taille: int) -> Image.Image:
    """Vague qui tube, de profil : la lèvre s'enroule en spirale et retombe sur le plat, le tube reste ouvert."""
    ss = 4                                   # suréchantillonnage pour lisser les bords
    T = taille * ss
    u = T / 1024                             # dessin exprimé sur une grille 1024
    im = Image.new("RGB", (T, T), "#0b1020")
    d = ImageDraw.Draw(im)

    cx, cy = 470 * u, 575 * u                # centre du tube
    r90 = 360 * u                            # rayon à la crête (φ = 90°)
    b = math.log(1 / 0.22) / 360             # spirale log : rayon × 0,22 par tour

    def spirale(phi_deg, fac=1.0):
        phi_deg = np.asarray(phi_deg, dtype=float)
        r = r90 * np.exp(-b * (phi_deg - 90)) * fac
        phi = np.radians(phi_deg)
        return [tuple(q) for q in np.column_stack([cx + 1.15 * r * np.cos(phi), cy - r * np.sin(phi)])]

    niveau = 745 * u                         # plan d'eau devant la vague
    phi_l = np.linspace(90, 280, 220)        # lèvre : de la crête jusqu'à l'impact
    ep = np.interp(phi_l, [90, 200, 280], [0.40, 0.36, 0.26])
    ext = spirale(phi_l)
    inte = spirale(phi_l, 1 - ep)
    crete = ext[0]

    # masse d'eau : dos de la vague → crête → lèvre → plat devant → fond
    dos = _bezier((T, 690 * u), (850 * u, 640 * u), (680 * u, 200 * u), crete)
    ix, iy = ext[-1]                         # point d'impact de la lèvre
    masse = dos + ext + [(ix, niveau), (0, niveau), (0, T), (T, T)]
    d.polygon(masse, fill="#1f6fb2")
    # mousse sur le plat devant la vague
    d.polygon(_bezier((ix, niveau - 12 * u), (ix - 150 * u, niveau - 4 * u), (ix - 300 * u, niveau), (0, niveau))
              + _bezier((0, niveau + 16 * u), (ix - 300 * u, niveau + 16 * u), (ix - 100 * u, niveau + 14 * u), (ix, niveau + 4 * u)),
              fill="#8ec9f5")

    # tube : sous la lèvre, fermé par la face creuse de la vague
    creux = inte[:int(len(inte) * 0.9)]      # s'arrête avant la pointe pour un fond de tube lisse
    x0, y0 = creux[0]
    x1, y1 = creux[-1]
    face = _bezier(creux[-1], (x1 + 190 * u, y1 + 12 * u), (x0 + 200 * u, y0), creux[0])
    d.polygon(creux + face, fill="#0d2748")

    # lèvre plus claire, qui naît en biseau sur la crête
    ep_c = np.interp(phi_l, [90, 210, 262, 280], [0.0, 0.26, 0.24, 0.0])
    d.polygon(ext + spirale(phi_l[::-1], 1 - ep_c[::-1]), fill="#3c95d9")

    # écume : liseré sur la crête
    phi_e = np.linspace(95, 280, 200)
    ep_e = np.interp(phi_e, [95, 140, 230, 280], [0.0, 0.06, 0.05, 0.0])
    d.polygon(spirale(phi_e) + spirale(phi_e[::-1], 1 - ep_e[::-1]), fill="#ffffff")

    # sable
    d.rectangle([0, 900 * u, T, T], fill="#e8c77a")
    return im.resize((taille, taille), Image.LANCZOS)
