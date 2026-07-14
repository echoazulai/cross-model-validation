#!/usr/bin/env python3
"""Strict validation for bridge review-request manifests."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path, PurePosixPath

ALLOWED = {
    "id", "kind", "target", "base", "criteria", "created_by", "tier",
    "merge_on_pass", "branch", "reviewed_sha", "base_sha", "untracked_at_drop",
    "untracked_files", "checks", "check_deps", "payload_files", "payload_sha256",
}
SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$")


def bad(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 3:
        return bad("usage: validate-manifest.py MANIFEST EXPECTED_AUTHOR")
    try:
        obj = json.loads(Path(sys.argv[1]).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        return bad(f"invalid manifest JSON: {exc}")
    if not isinstance(obj, dict) or set(obj) - ALLOWED:
        return bad("manifest has unknown fields or is not an object")
    required = {"id", "kind", "criteria", "created_by", "tier", "merge_on_pass", "checks"}
    if not required <= set(obj):
        return bad("manifest missing required fields")
    if obj["created_by"] != sys.argv[2] or obj["kind"] not in {"artifact", "repo-diff"}:
        return bad("manifest direction or kind is invalid")
    if obj["tier"] not in {"light", "standard", "full"} or not isinstance(obj["merge_on_pass"], bool):
        return bad("manifest tier or merge flag is invalid")
    if not isinstance(obj["id"], str) or not PACKAGE_ID.fullmatch(obj["id"]):
        return bad("manifest id is invalid")
    if not isinstance(obj["criteria"], str) or not obj["criteria"].strip():
        return bad("manifest criteria must be a non-empty string")
    checks = obj["checks"]
    if not isinstance(checks, list):
        return bad("checks must be an array")
    for check in checks:
        if not isinstance(check, dict) or set(check) != {"command", "timeout_seconds"}:
            return bad("declared check shape is invalid")
        if not isinstance(check["command"], str) or not check["command"]:
            return bad("declared check command is invalid")
        if not isinstance(check["timeout_seconds"], int) or not 1 <= check["timeout_seconds"] <= 3600:
            return bad("declared check timeout is invalid")
    check_deps = obj.get("check_deps", [])
    if not isinstance(check_deps, list):
        return bad("check_deps must be an array")
    for dep in check_deps:
        # Read-only host paths the sandbox exposes at their real location (e.g. a
        # test venv). Absolute only, no traversal, never the filesystem root.
        if not isinstance(dep, str) or not dep.startswith("/") or dep == "/" or ".." in PurePosixPath(dep).parts:
            return bad("check_deps entries must be absolute paths without '..'")
    if obj["kind"] == "artifact":
        if not SHA256.fullmatch(obj.get("payload_sha256", "")) or not isinstance(obj.get("payload_files"), list):
            return bad("artifact payload identity is missing")
        for entry in obj["payload_files"]:
            if not isinstance(entry, dict) or entry.get("type") not in {"file", "directory", "symlink"}:
                return bad("artifact payload inventory entry is invalid")
            kind = entry["type"]
            expected = {"path", "type"} | ({"size", "sha256"} if kind == "file" else {"target"} if kind == "symlink" else set())
            if set(entry) != expected or not isinstance(entry.get("path"), str) or not entry["path"]:
                return bad("artifact payload inventory shape is invalid")
            if kind == "file" and (not isinstance(entry["size"], int) or entry["size"] < 0 or not SHA256.fullmatch(entry["sha256"])):
                return bad("artifact file identity is invalid")
            if kind == "symlink" and not isinstance(entry["target"], str):
                return bad("artifact symlink target is invalid")
        if obj["merge_on_pass"]:
            return bad("artifact cannot request merge-on-pass")
    else:
        for field in ("target", "base", "branch", "reviewed_sha", "base_sha"):
            if not isinstance(obj.get(field), str) or not obj[field]:
                return bad(f"repo-diff field missing: {field}")
        if not SHA1.fullmatch(obj["reviewed_sha"]) or not SHA1.fullmatch(obj["base_sha"]):
            return bad("repo-diff SHA is malformed")
        if obj["tier"] == "full" and obj["merge_on_pass"]:
            return bad("Full-tier merge-on-pass is forbidden")
        if not isinstance(obj.get("untracked_files"), list):
            return bad("untracked_files must be recorded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
