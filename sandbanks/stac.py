"""Recherche des scènes Sentinel-2 L2A sur Earth Search (miroir AWS, sans compte)."""
from __future__ import annotations
import datetime as dt
from pystac_client import Client


def chercher_scenes(cfg: dict, jours: int) -> list:
    cat = Client.open(cfg["stac"]["url"])
    fin = dt.datetime.now(dt.timezone.utc)
    debut = fin - dt.timedelta(days=jours)
    rech = cat.search(
        collections=[cfg["stac"]["collection"]],
        bbox=cfg["aoi"]["bbox"],
        datetime=f"{debut:%Y-%m-%dT%H:%M:%SZ}/{fin:%Y-%m-%dT%H:%M:%SZ}",
        query={
            "eo:cloud_cover": {"lt": cfg["stac"]["nuages_tuile_max"]},
            "grid:code": {"eq": cfg["aoi"]["tuile"]},
        },
        max_items=200,
    )
    items = list(rech.items())
    items.sort(key=lambda i: i.datetime)
    return items
