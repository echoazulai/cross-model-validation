#!/usr/bin/env python3
"""Execute manifest-declared checks in an isolated disposable work tree."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

OUTPUT_LIMIT = 20_000
LOG_LIMIT = 1_000_000


def now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def trimmed(data: bytes) -> tuple[str, bool]:
    text = data.decode("utf-8", "replace")
    if len(text) <= OUTPUT_LIMIT:
        return text, False
    return text[:OUTPUT_LIMIT] + "\n[bridge output truncated]\n", True


def git_common_dir(workroot: Path) -> Path | None:
    """Absolute git common dir for a worktree checkroot, else None.

    The bridge builds repo-diff check roots with `git worktree add`, so the
    checkout's `.git` is a file pointing at `<repo>/.git/worktrees/<name>`, whose
    objects/refs live in the shared common dir `<repo>/.git`. None of that is under
    the checkout, so git resolves nothing inside the sandbox unless the common dir
    is exposed at its real absolute path. It is bound read-only: checks may inspect
    history but can never rewrite the reviewed refs/objects (immutable-SHA).
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(workroot), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, text=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    if not out:
        return None
    path = Path(out) if os.path.isabs(out) else (workroot / out)
    try:
        path = path.resolve()
    except OSError:
        return None
    return path if path.is_dir() else None


def declared_dep_binds(manifest: dict) -> list[Path]:
    """Absolute paths the author declared their checks need (e.g. a venv).

    The bridge cannot infer external dependencies from opaque command strings, so
    they are declared and exposed here read-only at their real path, preserving the
    no-network read-only isolation. Non-absolute, unsafe, or absent paths are
    dropped: a genuinely missing dependency then surfaces as the command's own
    "No such file" failure rather than aborting the whole sandbox.
    """
    binds: list[Path] = []
    deps = manifest.get("check_deps", [])
    if not isinstance(deps, list):
        return binds
    for dep in deps:
        if not isinstance(dep, str) or not os.path.isabs(dep) or ".." in Path(dep).parts:
            continue
        path = Path(dep)
        if path == Path("/") or not path.exists():
            continue
        binds.append(path)
    return binds


def extra_ro_binds(workroot: Path, manifest: dict) -> list[Path]:
    """Read-only mounts, at their real absolute paths, that checks need to resolve.

    Git worktree metadata is derived automatically (the bridge created the
    worktree); external test dependencies come from the manifest's `check_deps`.
    De-duplicated, and any path that is `/work` or an ancestor of it is skipped so
    the disposable checkout mount is never shadowed.
    """
    candidates: list[Path] = []
    # Git metadata only for repo-diff, whose check root is a bridge-made worktree.
    # Artifact roots are plain copied trees; probing git there could otherwise bind an
    # unrelated ancestor repo's .git.
    if manifest.get("kind") == "repo-diff":
        common = git_common_dir(workroot)
        if common is not None:
            candidates.append(common)
    candidates.extend(declared_dep_binds(manifest))
    workroot_resolved = workroot.resolve()
    seen: set[Path] = set()
    binds: list[Path] = []
    for path in candidates:
        if path in seen:
            continue
        if path == workroot_resolved or path in workroot_resolved.parents:
            continue
        seen.add(path)
        binds.append(path)
    return binds


def sandbox_command(workroot: Path, command: str, ro_binds: list[Path]) -> list[str]:
    args = [
        os.environ.get("BRIDGE_BWRAP", "bwrap"), "--die-with-parent", "--unshare-net",
        # --unshare-pid: a check must not see or signal host processes. Without
        # it the check shares the host PID namespace and a check can kill the
        # bridge's own poll/pickup workers (this happened twice on 2026-07-13,
        # killing a live review). Combined with the existing --proc /proc, the
        # sandbox sees only its own namespace-local process tree.
        "--unshare-pid",
        "--ro-bind", "/usr", "/usr",
        "--ro-bind", "/bin", "/bin",
        "--ro-bind", "/lib", "/lib",
        "--ro-bind", "/lib64", "/lib64",
        "--ro-bind", "/etc", "/etc",
        "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
        "--dir", "/home", "--bind", str(workroot), "/work",
    ]
    for path in ro_binds:
        args += ["--ro-bind", str(path), str(path)]
    args += [
        "--chdir", "/work",
        "--setenv", "HOME", "/tmp/home", "--setenv", "NO_PROXY", "*",
        "bash", "-lc", command,
    ]
    return args


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: run-checks.py MANIFEST WORKROOT PACKAGE", file=sys.stderr)
        return 2
    manifest_path, workroot, package = map(Path, sys.argv[1:4])
    manifest = json.loads(manifest_path.read_text())
    checks = manifest.get("checks", [])
    if not isinstance(checks, list) or any(not isinstance(item, dict) for item in checks):
        print("manifest checks are malformed", file=sys.stderr)
        return 2
    log_dir = package / "check-logs"
    log_dir.mkdir(exist_ok=True)
    ro_binds = extra_ro_binds(workroot, manifest)
    results: list[dict[str, object]] = []
    run_started = now()
    for index, check in enumerate(checks, 1):
        command = check.get("command")
        timeout_seconds = check.get("timeout_seconds", 300)
        if not isinstance(command, str) or not command or not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 3600:
            print("invalid declared check", file=sys.stderr)
            return 2
        started = now()
        timed_out = False
        try:
            completed = subprocess.run(
                sandbox_command(workroot, command, ro_binds),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout_seconds,
                check=False,
            )
            exit_code: int | None = completed.returncode
            stdout_raw, stderr_raw = completed.stdout, completed.stderr
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            exit_code = None
            stdout_raw = exc.stdout or b""
            stderr_raw = exc.stderr or b""
        combined = stdout_raw + (b"\n" if stdout_raw and stderr_raw else b"") + stderr_raw
        retained = combined[:LOG_LIMIT]
        log_path = log_dir / f"{index:03d}.log"
        log_path.write_bytes(retained)
        stdout, stdout_truncated = trimmed(stdout_raw)
        stderr, stderr_truncated = trimmed(stderr_raw)
        results.append(
            {
                "command": command,
                "started_at": started,
                "finished_at": now(),
                "exit_code": exit_code,
                "timed_out": timed_out,
                "stdout": stdout,
                "stderr": stderr,
                "output_truncated": stdout_truncated or stderr_truncated or len(combined) > LOG_LIMIT,
                "log_path": str(log_path.relative_to(package)),
                "log_sha256": hashlib.sha256(retained).hexdigest(),
            }
        )
    evidence = {
        "schema_version": 1,
        "started_at": run_started,
        "finished_at": now(),
        "sandbox": "bubblewrap-no-network-disposable-worktree",
        "readonly_binds": [str(path) for path in ro_binds],
        "all_passed": all(item["exit_code"] == 0 and not item["timed_out"] for item in results),
        "results": results,
    }
    (package / "check-results.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
