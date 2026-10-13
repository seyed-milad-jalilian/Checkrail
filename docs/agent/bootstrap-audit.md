# Guardrail Implementation Notes

This file documents the defenses that are actually implemented in the shipped
scripts, and states plainly what is and is not verified. It is an
implementation note, **not** a formal security audit, and it makes no claims
about third-party review or certification.

The behavior described below is exercised by the scratch-repo smoke tests in
`tests/run-tests.sh` (see "Verification" at the end).

## Implemented defenses

### Boundary scoping
- The diff scope is collected **once** from a single `git diff` invocation
  (staged changes locally, `BASE_REF...HEAD` in CI) and reused by every gate.
- The base ref fails closed: if it cannot be resolved to a commit or tree,
  the run aborts instead of silently falling back to an unscoped diff.
  Only two legitimate fallbacks exist: `HEAD~1` when no remote exists, and the
  empty tree for a repository's first commit.

### Protected-file defense (Gate 3)
- Protected paths include the governance files, gate scripts, CI workflows,
  and the permissions map. Modifications to existing protected files are
  blocked unless `--allow-guardrail` is passed; *introducing* new protected
  files additionally requires `--ack-new-guardrail` (a separate, explicit
  acknowledgement).
- In CI these acknowledgements must come from repository variables
  (`GUARDRAIL_MODIFICATION_AUTHORIZED`, `NEW_GUARDRAIL_INTRODUCTION_ACK`),
  which only a repository admin can set — and can revoke after the change
  lands.
- Symlink defense: protected paths are checked both in the working tree and
  by staged git mode (`120000`), so a symlink cannot be smuggled in through
  the index. Whole pack directories (`scripts/`, `docs/`, `.github/`) staged
  as symlink entries are rejected explicitly.
- `kilo.jsonc` is semantically asserted (Python, JSONC-aware): the deny/ask
  permission floor, the `bash` default of `ask`, the metacharacter traps, the
  destructive-command deny globs, allow-key structural invariants, and
  last-match ordering rules. Both the working-tree copy and the staged blob
  are validated independently.

### State handover validation (Gate 2)
- `docs/agent/HANDOVER.md` must exist as a regular file, be present in the
  index (staged deletions are caught), stay within 40 lines, and contain all
  five required sections. Both the live working-tree copy and the staged
  blob are validated, so a valid working file cannot mask an invalid staged
  one.

### Documentation drift (Gate 7)
- `docs/file-index.md` is regenerated deterministically and compared against
  the **staged blob** of the file (what will actually be committed), not just
  the working-tree copy.
- `scripts/sync-docs.sh` refuses to read or write through symlinks and writes
  via temporary files under `.git` (never directly into a path that could be
  swapped underneath it).

### Secret scanning (Gate 8)
- CI requires gitleaks and scans the full commit range of the change.
- Locally, gitleaks is used when installed; otherwise a conservative
  fallback regex scans every staged blob for well-known key formats
  (AWS keys, private key headers, GitHub/Slack tokens). The fallback is
  heuristic, not exhaustive — it is documented as such and is not a
  substitute for gitleaks.

### Environment robustness
- All three scripts require Bash 4.4+ and re-exec through Homebrew's bash on
  macOS when the system Bash 3.2 is too old.
- Python detection probes for actual functionality (a Windows "App execution
  alias" stub makes `command -v python3` succeed while the binary is
  non-functional), so gates degrade gracefully instead of crashing under
  `set -e`.
- Arrays are expanded with `${arr[@]+...}` guards so old shells with
  `set -u` do not abort on empty arrays.
- `--staged-only` and `--fast` exist so a pre-commit hook can run the
  relevant subset; the remaining gates always run.

## What is NOT claimed
- No formal audit or third-party review has been performed on this project.
- There is no application code in this repository; the Python tooling exists
  only for the `kilo.jsonc` semantic assertions. There are no Python unit
  tests, and the smoke tests do not enumerate every possible bypass.
- Gate 0 compares `major.minor` versions only; patch-level drift of pinned
  tools is never enforced.
- The local secret fallback is a heuristic regex, not a full scanner.
- Terraform validation only runs when Terraform files change and the
  `TERRAFORM_VALIDATE` environment is enabled; the smoke tests cover the
  `.tfvars`-rejection rule, not full Terraform validation.

## Verification
- `bash -n scripts/*.sh` syntax validation (Gate 4, every run).
- `bash tests/run-tests.sh` — 15 scratch-repo smoke tests covering: clean
  change passes, protected-file modification blocked/authorized, new
  guardrail file blocked/acknowledged, staged symlink rejected, HANDOVER
  section and line-limit enforcement, staged secret rejected by the fallback
  scanner, index drift rejected, branch-name enforcement, `.tfvars`
  rejection, and `kilo.jsonc` semantic acceptance/rejection.
- CI runs the same gates on every push (`quality-gates.yml`) and the smoke
  tests on every push (`tests.yml`).
