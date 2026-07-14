#!/usr/bin/env python3
"""Check the subset of strict JSON Schema required by Codex response formats."""

import json
import sys
from pathlib import Path


def check(node: object, path: str = "$" ) -> list[str]:
    if not isinstance(node, dict):
        return []
    errors: list[str] = []
    node_type = node.get("type")
    if node_type == "object":
        properties = node.get("properties")
        required = node.get("required")
        if node.get("additionalProperties") is not False:
            errors.append(f"{path}: additionalProperties must be false")
        if not isinstance(properties, dict):
            errors.append(f"{path}: properties must be an object")
        elif not isinstance(required, list) or set(required) != set(properties):
            errors.append(f"{path}: required must contain every property exactly once")
        if isinstance(properties, dict):
            for name, child in properties.items():
                errors.extend(check(child, f"{path}.properties.{name}"))
    if node_type == "array" and "items" in node:
        errors.extend(check(node["items"], f"{path}.items"))
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-response-schema.py SCHEMA", file=sys.stderr)
        return 2
    try:
        schema = json.loads(Path(sys.argv[1]).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(exc, file=sys.stderr)
        return 1
    errors = check(schema)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
