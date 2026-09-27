#!/usr/bin/env bash
# One-time, idempotent: pull the pinned FA2 prebuilt and extract its /artifacts payload
# into artifacts/<artifact_id>/, verifying every file's sha256 against the manifest.
# Runs on any host with docker + network to ghcr.io. Refuses on any drift.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="ghcr.io/antonprokopyev/fa2-fp8kv-sm86@sha256:da040941fa048fd5fdfce520503341c0beda4ce41436a1c1fecaf3f8a99777c7"

echo "[stage] pulling $IMG"
docker pull "$IMG"

# The pinned artifact id, read straight from the image's manifest (no hard-coding).
ID="$(docker run --rm --entrypoint /usr/bin/python3 "$IMG" \
      -c 'import json;print(json.load(open("/artifacts/manifest.json"))["artifact_id"])')"
echo "[stage] artifact_id=$ID"

DEST="$HERE/artifacts/$ID"
rm -rf "$DEST"; mkdir -p "$DEST"
SCRATCH="$(docker create --name fa2-stage-tmp "$IMG")"
docker cp "fa2-stage-tmp:/artifacts/." "$DEST/"
docker rm -f fa2-stage-tmp >/dev/null

echo "[stage] verifying sha256 against the manifest"
python3 - "$DEST" <<'PY'
import hashlib, json, sys
from pathlib import Path
dest = Path(sys.argv[1])
manifest = json.loads((dest / "manifest.json").read_text(encoding="utf-8"))
bad = 0
for name, want in manifest["files"].items():
    p = dest / name
    if not p.is_file():
        print(f"  MISSING {name}"); bad += 1; continue
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    ok = got == want
    print(f"  {'OK ' if ok else 'BAD '} {name}")
    bad += (not ok)
if bad:
    sys.exit(f"{bad} file(s) failed verification")
print("[stage] all files verified")
PY
echo "[stage] done -> $DEST"
