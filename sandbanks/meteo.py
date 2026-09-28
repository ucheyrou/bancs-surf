"""Conditions de mer et de vent — passé (conditions au passage satellite) et prévisions.

Sources, toutes gratuites et sans clé :
- Open-Meteo Marine (houle, mer du vent, niveau de la mer avec marée) — point au large du Gouf.
- Open-Meteo Forecast (vent 10 m, modèle Météo-France sur la France) — point côtier.
- SHOM, portail gratuit maree.shom.fr (pleines/basses mers, coefficients, 7 jours) — pour le
  coefficient officiel et pour calibrer le niveau Open-Meteo sur le zéro hydrographique.
"""
from __future__ import annotations
import datetime as dt
import json
import re
import time
import requests

from .config import RACINE, CACHE

POINT_LARGE = (43.66, -1.60)      # houle « au large », avant le Gouf (grille Marine ~ 43.625/-1.625)
POINT_COTE = (43.67, -1.44)       # vent à la côte (Hossegor)
PORT_SHOM = "CAPBRETON"
CACHE_METEO = CACHE.parent / "meteo"
# Calibrations tirées des prédictions SHOM Capbreton (sept. 2026) :
MSL_SUR_ZERO_HYDRO = 2.40          # niveau moyen (référence Open-Meteo) au-dessus du zéro hydrographique, m
COEF_A, COEF_B = 28.4, -13.0       # coefficient de marée ≈ A × marnage(m) + B  (vérifié à ±1 sur 4 jours)
CORR_MARNAGE_HORAIRE = 1.03        # l'échantillonnage horaire rabote les extrêmes d'environ 3 %

VARS_MARINE = ["wave_height", "wave_period", "wave_direction",
               "swell_wave_height", "swell_wave_period", "swell_wave_peak_period", "swell_wave_direction",
               "wind_wave_height", "wind_wave_period", "wind_wave_direction",
               "sea_level_height_msl"]
VARS_VENT = ["wind_speed_10m", "wind_direction_10m", "wind_gusts_10m"]


def _get(url, params, timeout=30, attentes_s=(5, 20)):
    """GET JSON, retenté après une panne passagère (délai dépassé, 429, 5xx) : Open-Meteo
    Marine ne répond parfois pas en 30 s depuis GitHub Actions (28/09/2026)."""
    for attente in (*attentes_s, None):
        try:
            r = requests.get(url, params=params, timeout=timeout)
            if r.status_code != 429 and r.status_code < 500:
                r.raise_for_status()
                return r.json()
            r.raise_for_status()
        except (requests.ConnectionError, requests.Timeout, requests.HTTPError):
            if attente is None:
                raise
            time.sleep(attente)


def horaires(debut: dt.date, fin: dt.date) -> dict:
    """Séries horaires marine + vent entre deux dates (passé ou futur, UTC)."""
    p = {"latitude": POINT_LARGE[0], "longitude": POINT_LARGE[1], "hourly": ",".join(VARS_MARINE),
         "start_date": debut.isoformat(), "end_date": fin.isoformat(), "timezone": "UTC"}
    mar = _get("https://marine-api.open-meteo.com/v1/marine", p)["hourly"]
    p = {"latitude": POINT_COTE[0], "longitude": POINT_COTE[1], "hourly": ",".join(VARS_VENT),
         "start_date": debut.isoformat(), "end_date": fin.isoformat(), "timezone": "UTC",
         "wind_speed_unit": "kmh"}
    vent = _get("https://api.open-meteo.com/v1/forecast", p)["hourly"]
    assert mar["time"] == vent["time"]
    out = {"time": mar["time"]}
    out.update({k: mar[k] for k in VARS_MARINE})
    out.update({k: vent[k] for k in VARS_VENT})
    return out


def conditions_a(t: dt.datetime, series: dict | None = None) -> dict:
    """Conditions à l'instant t (UTC), interpolées à l'heure la plus proche + tendance de marée."""
    t = t.astimezone(dt.timezone.utc)
    if series is None:
        series = horaires(t.date(), t.date())
    times = [dt.datetime.fromisoformat(x).replace(tzinfo=dt.timezone.utc) for x in series["time"]]
    i = min(range(len(times)), key=lambda k: abs((times[k] - t).total_seconds()))
    g = lambda k, j=i: series[k][j]
    niv = g("sea_level_height_msl")
    niv_av = series["sea_level_height_msl"][max(i - 1, 0)]
    niv_ap = series["sea_level_height_msl"][min(i + 1, len(times) - 1)]
    pente = (niv_ap - niv_av) / 2  # m/h
    tendance = "montante" if pente > 0.05 else "descendante" if pente < -0.05 else "étale"
    # marnage du jour -> coefficient estimé
    jour = t.date().isoformat()
    niv_jour = [v for x, v in zip(series["time"], series["sea_level_height_msl"]) if x.startswith(jour) and v is not None]
    marnage = (max(niv_jour) - min(niv_jour)) * CORR_MARNAGE_HORAIRE if niv_jour else None
    coef = int(min(max(round(COEF_A * marnage + COEF_B), 20), 120)) if marnage else None
    # position dans le cycle : 0 = basse mer, 1 = pleine mer (sur le marnage du jour)
    pos = (niv - min(niv_jour)) / marnage if marnage else None
    return {
        "heure_utc": times[i].isoformat(),
        "houle_m": g("swell_wave_height"), "periode_s": g("swell_wave_period"),
        "periode_pic_s": g("swell_wave_peak_period"), "direction": g("swell_wave_direction"),
        "hs_total_m": g("wave_height"), "mer_vent_m": g("wind_wave_height"),
        "vent_kmh": g("wind_speed_10m"), "vent_dir": g("wind_direction_10m"), "rafales_kmh": g("wind_gusts_10m"),
        "niveau_msl_m": niv, "hauteur_zh_m": round(niv + MSL_SUR_ZERO_HYDRO, 2), "maree_tendance": tendance, "maree_position": round(pos, 2) if pos is not None else None,
        "marnage_jour_m": round(marnage, 2) if marnage else None, "coef_estime": coef,
    }


# ----------------------------------------------------------------------------- SHOM
def _cle_shom() -> str | None:
    try:
        html = requests.get(f"https://maree.shom.fr/harbor/{PORT_SHOM}", timeout=20,
                            headers={"User-Agent": "Mozilla/5.0"}).text
    except requests.RequestException:
        return None
    for k in re.findall(r"services\.data\.shom\.fr/([A-Za-z0-9]+)", html):
        r = requests.get(f"https://services.data.shom.fr/{k}/hdm/spm/hlt",
                         params={"harborName": PORT_SHOM, "duration": 1, "date": dt.date.today().isoformat(),
                                 "utc": "standard", "correlation": 1},
                         headers={"User-Agent": "Mozilla/5.0", "Referer": "https://maree.shom.fr/"}, timeout=20)
        if r.ok and r.text.startswith("{"):
            return k
    return None


def marees_shom(jours: int = 7) -> list[dict] | None:
    """Pleines/basses mers SHOM (heure UTC, hauteur / zéro hydro, coefficient) pour les prochains jours."""
    k = _cle_shom()
    if not k:
        return None
    r = requests.get(f"https://services.data.shom.fr/{k}/hdm/spm/hlt",
                     params={"harborName": PORT_SHOM, "duration": jours, "date": dt.date.today().isoformat(),
                             "utc": "standard", "correlation": 1},
                     headers={"User-Agent": "Mozilla/5.0", "Referer": "https://maree.shom.fr/"}, timeout=20)
    r.raise_for_status()
    out = []
    for jour, evts in r.json().items():
        for typ, heure, haut, coef in evts:
            if heure == "---":
                continue
            out.append({"heure_utc": f"{jour}T{heure}:00+00:00", "type": "PM" if typ == "tide.high" else "BM",
                        "hauteur_m": float(haut), "coef": int(coef) if coef.isdigit() else None})
    return out


def calibrer_zero_hydro(series: dict, shom: list[dict]) -> float | None:
    """Décalage à ajouter au niveau Open-Meteo (MSL) pour obtenir la hauteur / zéro hydrographique.
    = moyenne des extrêmes SHOM − moyenne des extrêmes Open-Meteo sur la même période."""
    if not shom:
        return None
    hs = [e["hauteur_m"] for e in shom]
    t0, t1 = shom[0]["heure_utc"][:10], shom[-1]["heure_utc"][:10]
    om = [v for x, v in zip(series["time"], series["sea_level_height_msl"]) if t0 <= x[:10] <= t1 and v is not None]
    if not om:
        return None
    # extrêmes Open-Meteo : maxima/minima locaux
    ext = [om[i] for i in range(1, len(om) - 1) if (om[i] >= om[i-1] and om[i] >= om[i+1]) or (om[i] <= om[i-1] and om[i] <= om[i+1])]
    return round(sum(hs) / len(hs) - sum(ext) / max(len(ext), 1), 2)


# ----------------------------------------------------------------------------- produits
def extremes_maree(series: dict) -> list[dict]:
    """Pleines/basses mers à partir de la série horaire (interpolation parabolique des extrêmes)."""
    t, v = series["time"], series["sea_level_height_msl"]
    out = []
    for i in range(1, len(v) - 1):
        if None in (v[i-1], v[i], v[i+1]):
            continue
        if (v[i] > v[i-1] and v[i] >= v[i+1]) or (v[i] < v[i-1] and v[i] <= v[i+1]):
            # sommet de la parabole passant par les 3 points
            d = v[i-1] - 2 * v[i] + v[i+1]
            dx = 0.5 * (v[i-1] - v[i+1]) / d if d else 0.0
            vmax = v[i] - 0.25 * (v[i-1] - v[i+1]) * dx
            h = dt.datetime.fromisoformat(t[i]).replace(tzinfo=dt.timezone.utc) + dt.timedelta(hours=dx)
            out.append({"heure_utc": h.isoformat(timespec="minutes"), "type": "PM" if v[i] > v[i-1] else "BM",
                        "hauteur_zh_m": round(vmax + MSL_SUR_ZERO_HYDRO, 2)})
    # coefficient par jour = f(marnage PM - BM voisines)
    for i, e in enumerate(out):
        voisins = [abs(e["hauteur_zh_m"] - o["hauteur_zh_m"]) for o in out[max(i-1, 0):i+2] if o["type"] != e["type"]]
        if voisins:
            e["coef"] = int(min(max(round(COEF_A * max(voisins) + COEF_B), 20), 120))
    return out


def previsions(jours: int = 7, shom: bool = False) -> dict:
    """Prévisions horaires de la zone (houle au large, vent côte, marée) + pleines/basses mers."""
    auj = dt.datetime.now(dt.timezone.utc).date()
    series = horaires(auj - dt.timedelta(days=1), auj + dt.timedelta(days=jours))
    marees = extremes_maree(series)
    sh = marees_shom(jours) if shom else None
    return {"genere_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="minutes"),
            "point_houle": POINT_LARGE, "point_vent": POINT_COTE, "msl_sur_zero_hydro_m": MSL_SUR_ZERO_HYDRO,
            "horaires": series, "marees": marees, "marees_shom": sh}


def enrichir_scenes(verbose=True) -> int:
    """Complète les métadonnées de chaque scène en cache avec les conditions au passage."""
    import numpy as np
    n = 0
    fichiers = sorted(CACHE.glob("*.npz"))
    if not fichiers:
        return 0
    # Une seule requête couvrant toutes les dates
    dates = []
    for f in fichiers:
        with np.load(f, allow_pickle=False) as d:
            dates.append(dt.datetime.fromisoformat(json.loads(str(d["meta"]))["datetime"]))
    series = horaires(min(dates).date(), max(dates).date())
    for f, t in zip(fichiers, dates):
        with np.load(f, allow_pickle=False) as d:
            d = {k: d[k] for k in d.files}
        meta = json.loads(str(d["meta"]))
        if meta.get("conditions") and "hauteur_zh_m" in meta["conditions"]:
            continue
        meta["conditions"] = conditions_a(t, series)
        meta["houle_m"] = meta["conditions"]["houle_m"]
        meta["maree_m"] = meta["conditions"]["niveau_msl_m"]
        d["meta"] = json.dumps(meta)
        np.savez_compressed(f, **d)
        n += 1
        if verbose:
            c = meta["conditions"]
            print(f"  {meta['datetime'][:10]}  houle {c['houle_m']} m / {c['periode_s']} s / {c['direction']}°  "
                  f"vent {c['vent_kmh']} km/h {c['vent_dir']}°  marée {c['niveau_msl_m']:+.2f} m {c['maree_tendance']} "
                  f"(coef ~{c['coef_estime']})")
    return n
