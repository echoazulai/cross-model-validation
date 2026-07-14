#!/usr/bin/env python3
"""Verify an artefact payload still matches its recorded inventory and package hash."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify-payload.py MANIFEST PAYLOAD", file=sys.stderr)
        return 2
    manifest_path, payload = map(Path, sys.argv[1:3])
    helper = Path(__file__).with_name("hash-payload.py")
    spec = importlib.util.spec_from_file_location("hash_payload", helper)
    if spec is None or spec.loader is None:
        return 2
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = json.loads(manifest_path.read_text())
    entries = module.inventory(payload)
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    import hashlib

    actual_hash = hashlib.sha256(canonical).hexdigest()
    if entries != manifest.get("payload_files") or actual_hash != manifest.get("payload_sha256"):
        print("payload identity mismatch", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
