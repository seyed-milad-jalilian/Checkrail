# Project Architecture Context

[SYSTEM]
- Domain: AI Coding Agent Governance & CI Quality Gate Harness
- Stack: Bash 4.4+, POSIX Shell, Python 3.12+, GitHub Actions CI
- Deployment: Local Git Pre-Commit Hooks + GitHub Actions Workflows
- Constraints: Zero secret leaks, sub-second doc synchronization, strict sandbox isolation, zero drift
- Residual risk: Local secret scan uses fallback regex if gitleaks is missing. CI must install gitleaks.

[PIPELINES]
1. Developer/Agent Edit -> Pre-Commit Quality Gate (Fast Tier) -> Staged Verification
2. Git Push / PR -> GitHub Actions Quality Gate (Doctor + Full 9-Tier Gates, Gate 0-8)
   + Scratch-Repo Smoke Tests (tests/run-tests.sh) -> Merged to main

[REPO CONVENTIONS]
- Always-on rules: root `AGENTS.md`
- Permissions: root `kilo.jsonc` (engine-only; do not inject into the LLM)
- Complex workflow: `docs/agent/protocol.md` (only if still blocked after this file)
- Session state: `docs/agent/HANDOVER.md` (only on continue / resume)
- Generated map: `docs/file-index.md` (compact; do not hand-edit)
- Smoke tests: `tests/run-tests.sh` (run before pushing gate/script changes)
