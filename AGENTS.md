# Repository Rules (Lean) — Kilo

Auto-loaded from root. One trigger → one file. No prefetch. No tree listing.

| When | Read |
|------|------|
| Architecture, stack, deploy | `docs/agent/SUMMARY.md` |
| Workflow still blocking after SUMMARY | `docs/agent/protocol.md` |
| User says continue / resume | `docs/agent/HANDOVER.md` |
| User asks for repo map / inventory | `docs/file-index.md` |

Else: read/edit only paths the user named.

[Invariants]
- Surgical diffs only. No drive-by refactors, dependency churn, or lockfile edits unless named. HANDOVER is the exception: overwrite fully.
- Honor `kilo.jsonc`. deny=stop. ask=wait. Same normalized path blocked/ask-rejected twice → stop/report. `./.env` = `.env`; equivalent paths are bypass.
- No secrets/env/keys/certs. Engine deny wins even if the user named the path; editing `kilo.jsonc` is a separate ask, not a bypass.
- Read/Search for content. Never dump via bash: no `cat`, `head`, `grep`, `find`,
  `git show`, `git log -p`, `git diff -p`, `git blame`, `git grep`.
  Prefer Read/Search even if the engine asks — bash dump wastes tokens and may expose secrets.
- No destructive commands unless user named exact command.
- Do not Read/Search `kilo.jsonc` (engine enforces `ask`; user may approve for debugging) or list repo with `git ls-files` / recursive `ls`.
- Path add/remove/rename or `scripts/file-descriptions.txt` changes: stage those paths → `bash scripts/sync-docs.sh` (engine will ask; no flags — compact default, `--full` breaks Gate 7 check) → stage `docs/file-index.md`.
- Before gates: everything except HANDOVER must be staged — no other unstaged/untracked files (`--staged-only` skips this).
- Pre-done: `bash scripts/quality-gates.sh` (flags only: `--allow-guardrail`, `--ack-new-guardrail`, `--staged-only`, `--fast`).
  No `ENV=value` prefix on the gates command (ask-trapped); `SKIP=…` is for `git commit`, not gates. Other flags (`--quiet`, `--strict-versions`, etc.) are for humans/CI.
  `--staged-only` skips only Gate 2's clean-tree check; `--fast` skips only Gate 5 (Python) and Gate 6 (Terraform).
- Gate/sync/guardrail changes: also run `bash tests/run-tests.sh` (scratch-repo smoke tests; CI runs them via `tests.yml`).
- Protected files: `AGENTS.md`, `kilo.jsonc`, `scripts/quality-gates.sh`, `scripts/sync-docs.sh`, `scripts/doctor.sh`, `scripts/file-descriptions.txt`, `.pre-commit-config.yaml`, `.kilocodeignore`, `docs/agent/SUMMARY.md`, `docs/agent/protocol.md` (gates will tell you if unsure).
- Protected commit: run gates with `--allow-guardrail` (or `--ack-new-guardrail` specifically for new guardrail files).
  Then `SKIP=kilo-quality-gates git commit`. No `--no-verify`.
- HANDOVER: overwrite fully and STAGE before gates; `[GATES_STATUS]` may be `pending`. Gate 2 checks structure (max 40 lines; sections: `[TASK]` `[DIFF_SUMMARY]` `[GATES_STATUS]` `[NEXT]` `[BLOCKERS]`); Gate 8 also scans it for secrets. Do NOT rewrite after gates. Commit normally (the hook re-runs/re-scans); use `SKIP=kilo-quality-gates git commit` ONLY for protected/bootstrap edits.
- Never hand-edit `docs/file-index.md`.
- Environment broken? `bash scripts/doctor.sh` first (no flags). Exit 1 = missing/symlink/CRLF/syntax or index drift (fix with sync-docs; not a protected commit).
- Local fallback secret scan is heuristic (not exhaustive); CI requires gitleaks for authoritative scanning.
- Token budget: L0 auto-loaded. L1/L2: 1 read per trigger (chain only if still stuck). Stop and report if blocked twice on same path.
