# cross-model-validation

**A poll-based bridge that lets different AI model families independently review each other's work, with no human relaying messages between them.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

One model authors the work; a model from a *different* family judges it. The judge is given the artefact, the acceptance criteria, and the deterministic evidence the bridge itself produced, not the author's own write-up of its work. A verdict is forced into a fixed schema and bound to the exact thing that was reviewed, so it cannot be bluffed from a summary.

The point is not that either model is smarter. It is that **their mistakes are uncorrelated.** When a model reviews its own family's work, both sides share the same training and therefore the same blind spots. A judge from a different lineage fails differently, so it catches the class of error self-review structurally cannot.

---

## Why this exists

Self-review by a language model has a structural weakness: it tends to accept plausible-but-wrong work, including tests that quietly prove nothing. An independent judge from a different model family does not share those specific blind spots.

In practice this has caught real defects that a full self-verification pass had already marked green, including test suites that were fabricating their own evidence while every check reported success. That is the failure mode this bridge exists to close.

## How it works

```
author drops a package  ->  a timer picks it up  ->  a different-family model
        (queue dir)            (cron, inspects)        judges it, schema-forced
                                                                  |
   verdict lands back  <-  recorded in an append-only ledger  <--/
   (to the other side)     and a human-readable notice file
```

1. **An author drops a package.** Finished work goes into a queue directory: either files to review, or a pointer to a specific commit on a branch, plus a manifest stating the acceptance criteria (what "good" means for this piece).
2. **A timer picks it up.** A cron job checks the queues every couple of minutes. It is cheap when idle: no model is invoked unless a package is waiting and marked ready.
3. **A different-family model reviews it.** It inspects the actual code or tree and the deterministic check evidence, constrained to inspection: the Codex-judging lane runs in a strict read-only sandbox, and the Claude-judging lane under a restricted tool allowlist. It is given the criteria, not the author's own write-up of its work.
4. **The verdict is forced into a fixed shape.** `pass`, `needs-changes`, or `fail`, plus specific findings and a field naming exactly what was inspected, bound to the identity of what was reviewed.
5. **The verdict returns automatically.** It is written back to the other side, appended to a human-readable notice, and recorded in an append-only ledger. Nothing needs to be relayed by hand.

Both directions are symmetric: either family can author, and the other judges.

## The trust model (what makes a verdict hard to fake)

This is the part that matters, and where the bridge differs from simply asking another model "does this look right?"

- **Bridge-recorded evidence beats the judge's prose.** Any declared checks (lint, tests, and so on) are executed by the bridge itself, in a disposable, no-network sandbox, *before* the judge runs. The recorded results are authoritative. A model's claim that it ran a command is treated as a claim, not as proof. A `pass` is refused if declared checks did not all succeed.
- **Immutable review.** Repository work is judged in a detached checkout pinned to an exact commit, never the author's live working tree. The diff cannot shift underneath the reviewer. If the branch head moves after submission, the verdict is stale and cannot merge.
- **Identity binding.** A verdict is bound to the exact commit SHA or payload hash it reviewed. A verdict for one thing cannot be passed off as a verdict for another.
- **The author never merges its own reviewed work.** Merge authority is separate from authorship, and merges are fast-forward only, pushing exactly the reviewed commit or nothing.
- **Honest failure.** If a model is unavailable (quota, auth, capacity), the package is *held* for a human decision, not silently failed or faked into a pass. Held work is requeued manually, by running the `requeue-held.sh` helper once the model is available again.

A schema field that names what the judge inspected is useful context, not proof. The recorded execution evidence is the evidence layer. The same discipline applies in both directions.

## Quickstart

Requirements: `bash`, `git`, `python3`, `bubblewrap` (`bwrap`) for the check sandbox, and standard utilities including `flock` and `rsync`, plus the CLIs for whichever model families you use as author and judge.

```bash
git clone https://github.com/echoazulai/cross-model-validation.git ~/ai-handoff
```

Wire the poller into cron (every two minutes; cheap when idle):

```cron
*/2 * * * * ~/ai-handoff/bin/poll.sh >> ~/ai-handoff/logs/cron.log 2>&1
```

Create a `config.env` and set which model each tier maps to (see [Configuration](#configuration)).

## Creating work packages

Review a set of files (an "artifact"):

```bash
bin/drop-for-codex.sh <slug> \
  --criteria "what good means for this piece" \
  --check "command that must pass" \
  --payload path/to/file_or_dir
```

Review a branch against a base ("repo-diff"), pinned to the current head:

```bash
bin/drop-for-codex.sh <slug> --kind repo-diff \
  --target /path/to/repo --base main \
  --criteria "..." --check ".venv/bin/python -m pytest -q" --check-dep /abs/path/to/.venv
```

`drop-for-claude.sh` is the mirror image (the other family authors, this side judges). Declared `--check` commands run in a disposable, no-network sandbox from an immutable checkout, and their results are recorded as evidence before the judge sees the work. Acceptance criteria should describe *requirements and expected failure behaviour*, and should always insist that tests genuinely assert their claims rather than being tautological, because the criteria author is the party being judged.

## Repository layout

```
bin/          the pipeline: drop-*, *-pickup, poll, run-checks, validators, deploy
tests/        deterministic trust-boundary tests
CONTRACT.md   the operating contract between the two sides (the governance layer)
verdict.schema.json   the fixed shape every verdict is forced into
```

Runtime state (queues, the ledger, held packages, the notice file) lives under the deployment root at run time; it is not part of the source tree.

## Configuration

Configuration lives in a `config.env` sourced by the shared library. The main knobs:

- **Per-tier judge models.** Work declares a tier (light / standard / full); the bridge picks the judge for that tier. On the Codex-judging lane a blanket `CODEX_MODEL` override beats the tier map when set; the Claude-judging lane is configured per tier only.
- **Escalate-on-fail.** A `fail` or `needs-changes` from a lower-tier judge can be re-judged once by the top-tier judge before it stands. Cheap passes stay cheap, and both verdicts are kept as signal: the initial lower-tier verdict is retained for the record, but the escalated top-tier verdict is the one that stands.
- **Merge-on-pass.** Opt-in per package: on a `pass`, fast-forward the reviewed commit onto its base. Blocked if the branch moved, checks did not all pass, an unresolved high-severity finding remains, or the work is top-tier (which always requires explicit human acceptance).

## Status and honest limitations

This works and is useful, but it is not magic:

- **A pass is not proof.** The judge is a language model; it misses things, and a confident pass can be wrong. The bridge lowers *correlated* risk; it does not produce certainty.
- **The two lanes are not equally sandboxed.** The Codex-judging lane runs in a strict, no-network read-only sandbox. The Claude-judging lane runs under a restricted tool allowlist, which is inspection-focused but not a hard sandbox, so it is a weaker isolation guarantee.
- **A repository judge can read history.** For repo work the judge can run `git log` and `git show`, so anything an author records in commit messages is visible to it. "Not given the author's write-up" is about what the bridge hands over, not a guarantee the judge can see nothing else.
- **The verdict is only as good as the criteria.** Vague or leading acceptance criteria make the judge validate the wrong thing.
- **Invisible by default.** Runs are headless. Silence and "nothing happened" look identical unless you check the notice file or ledger.
- **Single machine, polling latency, shared usage.** Everything depends on one host with a healthy cron, and reviews spend the same model-usage allowance as interactive use.
- **Disagreements escalate to a human.** When the two sides genuinely disagree, the design deliberately asks a person rather than letting either model win.

## Design and contract

[`CONTRACT.md`](CONTRACT.md) is the operating contract between the two sides: authority, work tiers, the verdict schema, immutable review, deterministic checks, escalation, merge-on-pass, and the recovery model. It is the reference for how and why the bridge behaves as it does.

## Origin

This began as a two-party bridge (one model authoring, another judging) extracted from a personal setup, and is generalising toward an N-model arrangement: a small council of independent judges rather than a single pair. The core idea holds at any size. Never trust a model's account of its own work, and check every claim against the actual artefact.

## Licence

[MIT](LICENSE).
