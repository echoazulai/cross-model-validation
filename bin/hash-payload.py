#!/usr/bin/env python3
"""Add a deterministic payload inventory and hash to a package manifest."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(payload: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for root, directories, files in os.walk(payload, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        root_path = Path(root)
        for name in [*directories, *files]:
            path = root_path / name
            relative = path.relative_to(payload).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                target = os.readlink(path)
                entries.append({"path": relative, "type": "symlink", "target": target})
            elif stat.S_ISDIR(mode):
                entries.append({"path": relative, "type": "directory"})
            elif stat.S_ISREG(mode):
                entries.append(
                    {
                        "path": relative,
                        "type": "file",
                        "size": path.stat().st_size,
                        "sha256": digest_file(path),
                    }
                )
            else:
                raise ValueError(f"unsupported payload entry: {relative}")
    return entries


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: hash-payload.py MANIFEST PAYLOAD", file=sys.stderr)
        return 2
    manifest_path = Path(sys.argv[1])
    payload_path = Path(sys.argv[2])
    entries = inventory(payload_path)
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    manifest = json.loads(manifest_path.read_text())
    manifest["payload_files"] = entries
    manifest["payload_sha256"] = hashlib.sha256(canonical).hexdigest()
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
