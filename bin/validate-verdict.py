#!/usr/bin/env python3
"""Strictly validate a judge verdict and bind repo verdicts to the package identity."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SHA1 = re.compile(r"^[0-9a-f]{40}$")
VERDICT_KEYS = {"verdict", "summary", "findings", "checked", "executions", "reviewed_identity"}
FINDING_KEYS = {"severity", "location", "detail"}
EXECUTION_KEYS = {"command", "exit_code", "evidence"}


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 3:
        return fail("usage: validate-verdict.py VERDICT MANIFEST")
    try:
        verdict = json.loads(Path(sys.argv[1]).read_text())
        manifest = json.loads(Path(sys.argv[2]).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        return fail(f"invalid JSON: {exc}")
    if not isinstance(verdict, dict) or set(verdict) - VERDICT_KEYS:
        return fail("verdict has unknown fields or is not an object")
    if set(verdict) != VERDICT_KEYS:
        return fail("verdict is missing required fields")
    if verdict["verdict"] not in {"pass", "needs-changes", "fail"}:
        return fail("invalid verdict value")
    if not isinstance(verdict["summary"], str) or not isinstance(verdict["checked"], str):
        return fail("summary and checked must be strings")
    if not isinstance(verdict["findings"], list):
        return fail("findings must be an array")
    for finding in verdict["findings"]:
        if not isinstance(finding, dict) or set(finding) != FINDING_KEYS:
            return fail("finding shape is invalid")
        if finding["severity"] not in {"high", "medium", "low"}:
            return fail("finding severity is invalid")
        if not all(isinstance(finding[key], str) for key in ("location", "detail")):
            return fail("finding text fields must be strings")
    executions = verdict["executions"]
    if not isinstance(executions, list):
        return fail("executions must be an array")
    for execution in executions:
        if not isinstance(execution, dict) or set(execution) != EXECUTION_KEYS:
            return fail("execution claim shape is invalid")
        if not isinstance(execution["command"], str) or not isinstance(execution["evidence"], str):
            return fail("execution command and evidence must be strings")
        if execution["exit_code"] is not None and not isinstance(execution["exit_code"], int):
            return fail("execution exit_code must be integer or null")

    kind = manifest.get("kind")
    identity = verdict["reviewed_identity"]
    if kind == "repo-diff":
        if not isinstance(identity, dict) or set(identity) != {"kind", "base_sha", "reviewed_sha", "payload_sha256"}:
            return fail("repo-diff verdict requires reviewed_identity")
        expected = {
            "kind": "repo-diff",
            "base_sha": manifest.get("base_sha"),
            "reviewed_sha": manifest.get("reviewed_sha"),
        }
        if any(identity.get(key) != value for key, value in expected.items()):
            return fail("reviewed_identity does not match manifest")
        if identity["payload_sha256"] is not None:
            return fail("repo-diff payload identity must be null")
        if not SHA1.fullmatch(identity.get("base_sha", "")) or not SHA1.fullmatch(identity.get("reviewed_sha", "")):
            return fail("repository identity SHA is malformed")
    else:
        if not isinstance(identity, dict) or set(identity) != {"kind", "base_sha", "reviewed_sha", "payload_sha256"}:
            return fail("artifact reviewed_identity shape is invalid")
        if identity.get("kind") != "artifact" or identity.get("payload_sha256") != manifest.get("payload_sha256"):
            return fail("artifact reviewed_identity does not match manifest")
        if identity["base_sha"] is not None or identity["reviewed_sha"] is not None:
            return fail("artifact repository identity must be null")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
