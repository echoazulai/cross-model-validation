#!/usr/bin/env python3
"""Validate an internal verdict-notification envelope before displaying it."""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        obj = json.loads(Path(sys.argv[1]).read_text())
    except (OSError, json.JSONDecodeError):
        return 1
    if not isinstance(obj, dict) or set(obj) != {"source_id", "source_manifest", "verdict"}:
        return 1
    verdict = obj["verdict"]
    if not isinstance(obj["source_id"], str) or not obj["source_id"]:
        return 1
    if not isinstance(obj["source_manifest"], dict) or not isinstance(verdict, dict):
        return 1
    if verdict.get("verdict") not in {"pass", "needs-changes", "fail"}:
        return 1
    return 0 if isinstance(verdict.get("summary"), str) else 1


if __name__ == "__main__":
    raise SystemExit(main())
