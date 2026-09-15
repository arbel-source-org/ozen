#!/usr/bin/env python3
"""Turns a WhisperKit model folder into release assets and back.

  manifest.py pack <model-folder> <assets-dir>
      Copies every file of the folder into <assets-dir> under a flat name
      (path separators become "__") and writes manifest.json beside them:
      path, asset, size and SHA-256 per file. Upload the directory's files
      as the assets of one GitHub release.

  manifest.py unpack <assets-dir> <model-folder>
      The reverse, for checking a release on a Mac: rebuilds the folder
      from manifest.json and the assets, verifying every checksum.

The app does the unpacking itself (see ReleaseModelDownloader); this is
the publisher's side and the CI check's.
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pack(folder: Path, assets: Path) -> None:
    assets.mkdir(parents=True, exist_ok=True)
    files = []
    for path in sorted(p for p in folder.rglob("*") if p.is_file()):
        relative = path.relative_to(folder).as_posix()
        if relative == "manifest.json" or path.name.startswith("."):
            continue
        asset = relative.replace("/", "__")
        shutil.copyfile(path, assets / asset)
        files.append({"path": relative, "asset": asset, "size": path.stat().st_size, "sha256": sha256(path)})
    (assets / "manifest.json").write_text(json.dumps({"files": files}, indent=1) + "\n")
    total = sum(f["size"] for f in files)
    print(f"{len(files)} files, {total / 1e6:.1f} MB -> {assets}")


def unpack(assets: Path, folder: Path) -> None:
    manifest = json.loads((assets / "manifest.json").read_text())
    for entry in manifest["files"]:
        target = folder / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(assets / entry["asset"], target)
        if target.stat().st_size != entry["size"] or sha256(target) != entry["sha256"]:
            raise SystemExit(f"{entry['path']}: does not match the manifest")
    print(f"{len(manifest['files'])} files verified -> {folder}")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("pack", "unpack"):
        raise SystemExit(__doc__)
    if sys.argv[1] == "pack":
        pack(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        unpack(Path(sys.argv[2]), Path(sys.argv[3]))
