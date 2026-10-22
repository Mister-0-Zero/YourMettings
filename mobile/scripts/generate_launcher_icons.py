"""Package the unchanged icon master for Android/iOS. Requires Pillow."""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
source = Image.open(ROOT / "assets/branding/yourmettings-icon-master.png")
assert source.width == source.height, "Launcher master must be square"
if "A" in source.getbands():
    assert source.getchannel("A").getextrema() == (255, 255), "Master must be opaque"


def save(path: Path, size: int):
    path.parent.mkdir(parents=True, exist_ok=True)
    source.resize((size, size), Image.Resampling.LANCZOS).convert("RGB").save(path, optimize=True)


res = ROOT / "android/app/src/main/res"
for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    save(res / f"mipmap-{density}/ic_launcher.png", size)
save(res / "drawable-nodpi/yourmettings_mark.png", 1024)
icons = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
for entry in json.loads((icons / "Contents.json").read_text())["images"]:
    size = round(float(entry["size"].split("x")[0]) * float(entry["scale"].rstrip("x")))
    save(icons / entry["filename"], size)
print("Packaged Android adaptive/legacy and iOS launcher resources from the master.")
