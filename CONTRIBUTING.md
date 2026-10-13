# Contributing to Checkrail

Thank you for your interest in contributing to **Checkrail**! This project enforces strict governance, security, and quality standards for AI agent orchestration and development workflows.

---

## 🛠️ Development Workflow

1. **Prerequisites**:
   - Bash 4.4+ (Git Bash / Homebrew bash / Linux; on macOS the scripts re-exec through Homebrew's bash automatically)
   - Git 2.30+
   - Python 3.12+ (optional locally for static QA and `kilo.jsonc` semantic checks; required in CI)
   - Gitleaks (optional locally; fallback heuristic regex is used if absent)

2. **Create a Conventioned Branch**:
   Branch names are enforced by Gate 1 and must match:
   `feature/…`, `fix/…`, `chore/…`, `docs/…`, `refactor/…`, `test/…`, `hotfix/…`, `build/…`, `ci/…`, `perf/…`, `style/…`, `release/…`, `dependabot/…`, or an issue ticket ID like `PROJ-123-description`.
   ```bash
   git checkout -b docs/my-change
   ```
   Pushes to `main` are treated as integration commits; all other branch names must follow the pattern above.

3. **Verify Environment**:
   Run the doctor script to verify tool installations and repository integrity:
   ```bash
   bash scripts/doctor.sh
   ```

4. **Making Changes**:
   - Keep diffs surgical and focused.
   - If you add, delete, or rename files, record their purpose in `scripts/file-descriptions.txt`.
   - Synchronize the file documentation index:
     ```bash
     bash scripts/sync-docs.sh
     git add docs/file-index.md
     ```

5. **Running Tests**:
   Before pushing any change to the gate scripts, sync tooling, or guardrail policy, run the scratch-repo smoke tests:
   ```bash
   bash tests/run-tests.sh
   ```
   CI runs the same suite on every push and pull request.

6. **Running Quality Gates**:
   Before committing, run the full verification harness:
   ```bash
   bash scripts/quality-gates.sh
   ```

---

## 🛡️ Guardrails & Protected Files

Certain files are protected against accidental modifications by autonomous agents (e.g. `AGENTS.md`, `kilo.jsonc`, `scripts/quality-gates.sh`, `scripts/doctor.sh`, `scripts/sync-docs.sh`, `.github/workflows/*`, `docs/agent/SUMMARY.md`).

If you are intentionally updating a protected file as a maintainer:
```bash
bash scripts/quality-gates.sh --allow-guardrail
SKIP=kilo-quality-gates git commit -m "your commit message"
```

Introducing a **new** protected file (for example a new CI workflow) additionally requires an explicit acknowledgement:
```bash
bash scripts/quality-gates.sh --allow-guardrail --ack-new-guardrail
```

In CI these acknowledgements are controlled by the repository variables `GUARDRAIL_MODIFICATION_AUTHORIZED` and `NEW_GUARDRAIL_INTRODUCTION_ACK`, which only a repository admin can set. Keep them off by default; if you enable one to land an authorized guardrail change, remove it afterwards. Never use `git commit --no-verify`.

---

## 📜 Code of Conduct & Standards

- Adhere to semantic versioning and clear commit messages.
- Ensure zero secrets or private credentials are included in any commit.
- Keep documentation clean and synchronized at all times.
- Do not weaken a gate, a deny rule, or a protected path without an explicit, reviewed authorization.
