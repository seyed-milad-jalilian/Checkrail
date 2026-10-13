# Repository Agent Protocol

Layer 2. Not auto-loaded. Read only when `docs/agent/SUMMARY.md` was not enough.

[Task lifecycle]
1. Classify against the root trigger table. Read only that layer.
2. Touch only the intended edit set.
3. Honor `kilo.jsonc`. `deny` → stop. `ask` → wait. Same normalized path (`./.env` = `.env`) blocked/ask-rejected twice → stop/report. Equivalent path is bypass.
4. Stage intended path add/remove/rename first.
5. If tracked set changed or `scripts/file-descriptions.txt` changed:
   - `bash scripts/sync-docs.sh`
   - stage `docs/file-index.md`
6. Overwrite `docs/agent/HANDOVER.md` entirely (max 40 lines) and STAGE it; set `[GATES_STATUS]=pending`.
   Required sections: `[TASK]` `[DIFF_SUMMARY]` `[GATES_STATUS]` `[NEXT]` `[BLOCKERS]`.
7. `bash scripts/quality-gates.sh`
   - local protected-file edits: `bash scripts/quality-gates.sh --allow-guardrail`
     (or pass --ack-new-guardrail specifically for new guardrail files)
   - hook / partial tree: `bash scripts/quality-gates.sh --staged-only --fast`
     (`--staged-only` skips Gate 2 clean-tree check; `--fast` skips Gate 5+6. All other gates still run.)
   Never prefix the **gates** command with `ENV=value` (ask-trapped). Flags only. (`SKIP=…` is for `git commit`, not gates.)
   CI may set CI=true, STRICT_VERSIONS=true, TERRAFORM_VALIDATE=true in the job environment (not on the argv). Defaults: advisory versions, no terraform validate.
   Gate 2 validates the HANDOVER **structure** (sections + length), not the literal `[GATES_STATUS]` value.
8. Do NOT rewrite HANDOVER after gates. Non-protected edits: `git commit` (hook re-runs gates). Protected/bootstrap edits: hook would re-hit Gate 3, so `SKIP=kilo-quality-gates git commit` after step 7's `--allow-guardrail`. `[GATES_STATUS]` may stay `pending`.

[Protected commit workflow]
If you edited a Gate 3 protected file (it prints the exact list on failure):
1. Run `bash scripts/quality-gates.sh --allow-guardrail`
2. Commit using `SKIP=kilo-quality-gates git commit`
Never use `--no-verify` as it bypasses all local safety hooks.

[Kilo specifics]
- Only root `AGENTS.md` is auto-loaded.
- Context-exclude file is `.kilocodeignore`.
- Compound bash (`;`, `&&`, `|`, backticks, `$(...)`, redirects `>`) is ask-trapped. Run one argv.

[Tool versions]
- `.tool-versions` is checked tiered: a MAJOR mismatch (e.g. python 2 vs 3) always fails;
  a MINOR mismatch (3.12 vs 3.13) only warns, so the pack runs on any environment.
  Pass `--strict-versions` to fail on minor mismatches too. In CI, set
  `STRICT_VERSIONS=true` in the job environment. Patch-level differences are
  never compared: `8.18` accepts any `8.18.x`.

[Tests]
- Smoke tests live in `tests/run-tests.sh`; run `bash tests/run-tests.sh` before
  pushing any change to the gate scripts, sync-docs, or guardrail policy.
- CI runs them on every push/PR via `.github/workflows/tests.yml`.
