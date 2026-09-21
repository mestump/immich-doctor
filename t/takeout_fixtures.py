#!/usr/bin/env python3
"""Build fake Google Takeout archives in two shapes, plus one junk zip."""
import zipfile, json, os, shutil, sys

DL = sys.argv[1] if len(sys.argv) > 1 else "/tmp/igtest/dl"
shutil.rmtree(DL, ignore_errors=True)
os.makedirs(DL, exist_ok=True)

def photo_bytes(seed):
    # minimal JPEG-ish payload; immich-go only needs bytes + a readable sidecar
    return b"\xff\xd8\xff\xe0" + bytes(str(seed), "ascii") + b"x" * 5000

def sidecar(title, ts):
    return json.dumps({
        "title": title,
        "photoTakenTime": {"timestamp": str(ts)},
        "geoData": {"latitude": 0, "longitude": 0},
        "keywordsList": [],
        "description": "",
    }).encode()

def make_takeout_part(path, year, photos, album=None, prefix="P"):
    with zipfile.ZipFile(path, "w") as z:
        for i, ts in enumerate(photos):
            name = f"{prefix}{i:03d}.jpg"
            z.writestr(f"Photos/{year}/{name}", photo_bytes(ts))
            z.writestr(f"Photos/{year}/{name}.json", sidecar(name, ts))
        if album:
            aname, aphotos = album
            for i, ts in enumerate(aphotos):
                name = f"A{i:03d}.jpg"
                z.writestr(f"Photos/{year}/{aname}/{name}", photo_bytes(ts))
                z.writestr(f"Photos/{year}/{aname}/{name}.json", sidecar(name, ts))
            z.writestr(f"Photos/{year}/{aname}/{album[0]}-album.json",
                       json.dumps({"title": aname, "accessTime": {"timestamp": "0"}}).encode())

TS = "20240115T101530Z"
# takeout A: loose two-part
make_takeout_part(f"{DL}/takeout-{TS}-1 of 2.zip", "2020", [1580000000, 1580100000, 1580200000])
make_takeout_part(f"{DL}/takeout-{TS}-2 of 2.zip", "2021", [1610000000, 1610100000],
                  album=("Roadtrip", [1610200000]))

# takeout B: Chrome-merged wrapper holding one part
inner = f"{DL}/.inner-{TS}.zip"
make_takeout_part(inner, "2022", [1650000000, 1650100000])
with zipfile.ZipFile(f"{DL}/Takeout-February-2024.zip", "w") as z:
    z.write(inner, "Takeout-February-2024/takeout-20240220T080000Z-1 of 1.zip")
os.remove(inner)

# junk zip: no takeout markers, big enough to be scanned
with zipfile.ZipFile(f"{DL}/some-addon-v1.2.zip", "w") as z:
    for i in range(200):
        z.writestr(f"plugin/file{i:04d}.dat", b"data" * 40000)   # ~3.2MB
print("fixtures written to", DL)
