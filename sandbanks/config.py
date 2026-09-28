from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path
import yaml

RACINE = Path(__file__).resolve().parent.parent
CACHE = RACINE / "cache" / "scenes"
OUTPUT = RACINE / "output"


@dataclass
class Spot:
    id: str
    nom: str
    lat: float
    lon: float
    taille: list = field(default_factory=lambda: [0.6, 1.2, 2.5, 3.0])
    maree: list = field(default_factory=lambda: [0.2, 0.8])
    pente_banc: float = 0.05
    protection: float = 1.0
    type: str = "beachbreak"
    banc_externe_m: float | None = None   # distance au bord où commence le banc du large (La Nord)


def charger(chemin: Path | None = None) -> dict:
    chemin = chemin or RACINE / "config" / "zone.yaml"
    with open(chemin, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    cfg["spots"] = [Spot(**s) for s in cfg["spots"]]
    return cfg
