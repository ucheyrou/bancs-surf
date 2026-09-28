"""Usage : python -m sandbanks update [--jours N]   |   python -m sandbanks scenes"""
from __future__ import annotations
import argparse, json, sys, time
from pathlib import Path
import numpy as np

from . import config, stac, scene, analyse, rendu


def cmd_scenes(cfg, args):
    items = stac.chercher_scenes(cfg, args.jours)
    print(f"{len(items)} scènes sur {args.jours} jours :")
    for it in items:
        print(f"  {it.datetime:%Y-%m-%d %H:%M}Z  {it.properties.get('platform'):<11} "
              f"nuages tuile {it.properties['eo:cloud_cover']:5.1f}%  "
              f"{'cache' if scene.est_en_cache(it) else '   à télécharger'}")


def cmd_update(cfg, args):
    jours = args.jours or cfg["composite"]["fenetre_jours"]
    items = stac.chercher_scenes(cfg, jours)
    print(f"{len(items)} scènes candidates sur {jours} jours")
    scenes = []
    for it in items:
        t = time.time()
        deja = scene.est_en_cache(it)
        s = scene.charger_scene(it, cfg)
        scenes.append(s)
        print(f"  {it.datetime:%Y-%m-%d}  {'cache' if deja else f'téléchargée en {time.time()-t:4.0f}s'}")
    if not scenes:
        sys.exit("Aucune scène")

    from . import meteo
    try:
        n = meteo.enrichir_scenes(verbose=False)
        if n:
            print(f"Conditions (houle/vent/marée) ajoutées à {n} scène(s)")
        # recharger les métadonnées enrichies
        scenes = [scene.charger_scene(it, cfg) for it in items]
    except Exception as e:  # réseau : on continue sans
        print(f"(conditions au passage indisponibles : {e})")

    comp = analyse.composite(scenes, cfg)
    n_util = sum(j["utilisee"] for j in comp["journal"])
    print(f"\nComposite : {n_util} scènes utilisées / {len(scenes)}")
    for j in comp["journal"]:
        c = j.get("conditions") or {}
        cond = (f"houle {c['houle_m']:.1f} m/{c['periode_s']:.0f} s/{c['direction']:.0f}°  vent {c['vent_kmh']:.0f} km/h "
                f"marée {c['hauteur_zh_m']:.1f} m {c['maree_tendance']} coef {c['coef_estime']}") if c else ""
        print(f"  {j['datetime'][:10]}  nuages {j['nuages_local']*100:3.0f}%  écume {j['frac_ecume']*100:4.1f}%  "
              f"{'utilisée' if j['utilisee'] else 'ignorée ':<9} {cond}")

    out = config.OUTPUT
    out.mkdir(exist_ok=True)
    geo = comp["geo"]
    rendu.ecrire_geotiff(out / "frequence_deferlement.tif", comp["frequence"], geo)
    rendu.ecrire_geotiff(out / "timex.tif", comp["timex"], geo)
    rendu.ecrire_geotiff(out / "masque_mer.tif", comp["mer"].astype("float32"), geo, nodata=None)

    freq_w, bounds = rendu.vers_wgs84(comp["frequence"], geo)
    timex_w, _ = rendu.vers_wgs84(comp["timex"], geo)
    rgb_w, _ = rendu.vers_wgs84(comp["derniere"]["refl"], geo, nodata=0)
    hf_w, _ = rendu.vers_wgs84(comp["haut_fond"], geo)
    rendu.ecrire_geotiff(out / "haut_fond.tif", comp["haut_fond"], geo)
    rendu.png_frequence(freq_w, out / "frequence.png")
    rendu.png_frequence(hf_w, out / "haut_fond.png", cmap="viridis")
    mer_w, _ = rendu.vers_wgs84(comp["ocean"].astype("float32"), geo, nodata=0, categoriel=True)
    rendu.png_masque_mer(mer_w, out / "masque_mer.png")
    rendu.png_champ_banc(freq_w, hf_w, mer_w, out / "champ_banc.png")
    rendu.png_timex(timex_w, out / "timex.png")
    rendu.png_rgb(rgb_w, out / "derniere_rgb.png")
    print("Rendu des scènes pour le viewer…")
    scenes_liste = rendu.scenes_wgs84(comp, out / "scenes")

    prev = None
    try:
        prev = meteo.previsions()
        (out / "previsions.json").write_text(json.dumps(prev, ensure_ascii=False))
        print(f"Prévisions 7 j enregistrées ({len(prev['horaires']['time'])} h, {len(prev['marees'])} PM/BM)")
    except Exception as e:
        print(f"(prévisions indisponibles : {e})")

    infos = rendu.crops_spots(comp, cfg, out / "spots")
    scoring_res = None
    if prev:
        from . import scoring
        scoring_res = scoring.noter_previsions(prev, cfg, {i["id"]: i for i in infos})
        (out / "scoring.json").write_text(json.dumps(scoring_res, ensure_ascii=False))
        print("\nOù aller ? (3 meilleurs spots par jour)" + scoring.texte_resume(scoring_res, 3))
    rendu.viewer_html(out / "index.html", bounds, infos, comp["journal"], scenes_liste, cfg, prev, scoring_res)
    (out / "scenes.json").write_text(json.dumps(comp["journal"], indent=1, ensure_ascii=False))
    import datetime as _dt
    (out / "meta.json").write_text(json.dumps({
        "genere_utc": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="minutes"),
        "bounds": bounds,  # [[sud, ouest], [nord, est]] WGS84 des PNG frequence/haut_fond/scenes
        "images": scenes_liste, "spots": [s.id for s in cfg["spots"]],
        # tailles de houle (m, calme -> agité) des scènes qui fondent l'indice haut-fond :
        # un pixel casse pour une houle H si son indice >= 1 - rang(H) / (n - 1)
        "haut_fond_houles_m": sorted(round(t, 2) for t, _, _ in comp["scenes_utilisees"])},
        ensure_ascii=False))
    (out / "spots.json").write_text(json.dumps(infos, indent=1, ensure_ascii=False))

    print("\nLargeur de la zone de déferlement devant chaque spot (médiane / max / variabilité) :")
    for i in infos:
        print(f"  {i['nom']:<30} {i['largeur_mediane_m']:>5} m  {i['largeur_max_m']:>5} m  σ {i['variabilite_m']:>4} m")
    print(f"\nCarte : {out/'index.html'}")


def cmd_gouf(cfg, args):
    from . import gouf
    if not args.rendu_seul:
        print("Tracé de rayons sur la bathymétrie EMODnet (réel vs référence sans canyon), ~4 min…")
        res = gouf.calculer(cfg, verbose=args.verbose)
        gouf.rendre(res, cfg)
    table = gouf.rendre_effectif(cfg)
    print("Kr effectif par spot (houle 280° / 305°, T = 10 / 14 / 18 s) et pente d'approche 20→10 m :")
    for sid, t in table.items():
        k = t["Kr_effectif"]; a = t["approche"]
        print(f"  {sid:<14} 280°: {k['T10_D280']:4.2f} {k['T14_D280']:4.2f} {k['T18_D280']:4.2f}   "
              f"305°: {k['T10_D300']:4.2f} {k['T14_D300']:4.2f} {k['T18_D300']:4.2f}   "
              f"iso10 {a['isobathe_m']['10'] if '10' in a['isobathe_m'] else a['isobathe_m'][10]:5.0f} m  pente {a['pente_20_10'] or 0:.3f}")
    print(f"\nFigures et tables : {config.OUTPUT / 'gouf'}")


def cmd_score(cfg, args):
    """Re-note à partir des prévisions déjà téléchargées (rapide, sans satellite)."""
    from . import meteo, scoring
    out = config.OUTPUT
    prev = meteo.previsions()
    (out / "previsions.json").write_text(json.dumps(prev, ensure_ascii=False))
    met = {}
    if (out / "spots.json").exists():
        met = {i["id"]: i for i in json.loads((out / "spots.json").read_text())}
    res = scoring.noter_previsions(prev, cfg, met)
    (out / "scoring.json").write_text(json.dumps(res, ensure_ascii=False))
    print(scoring.texte_resume(res, args.n))


def main():
    ap = argparse.ArgumentParser(prog="sandbanks")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p1 = sub.add_parser("scenes", help="lister les scènes disponibles")
    p1.add_argument("--jours", type=int, default=60)
    p2 = sub.add_parser("update", help="télécharger, analyser, générer la carte")
    p2.add_argument("--jours", type=int, default=None)
    p4 = sub.add_parser("score", help="prévisions + notation par spot (sans satellite)")
    p4.add_argument("-n", type=int, default=4, help="spots affichés par jour")
    p3 = sub.add_parser("gouf", help="effet du Gouf : tracé de rayons, amplification par spot")
    p3.add_argument("--verbose", action="store_true")
    p3.add_argument("--rendu-seul", action="store_true", help="réutiliser data/gouf_Kr.npz")
    args = ap.parse_args()
    cfg = config.charger()
    {"scenes": cmd_scenes, "update": cmd_update, "gouf": cmd_gouf, "score": cmd_score}[args.cmd](cfg, args)


if __name__ == "__main__":
    main()
