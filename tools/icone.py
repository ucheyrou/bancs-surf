"""Régénère l'icône de l'app iOS (1024 px) depuis le même dessin que l'icône du viewer web."""
from pathlib import Path
import sys

RACINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RACINE))
from sandbanks.rendu import dessin_icone  # noqa: E402

cible = RACINE / "ios/BancsSurf/Assets.xcassets/AppIcon.appiconset/icon.png"
dessin_icone(1024).save(cible)
print(cible.relative_to(RACINE))
