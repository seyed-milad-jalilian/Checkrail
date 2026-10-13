## Description
<!-- Provide a clear, concise description of the changes proposed in this pull request. -->

## Changes Checklist
- [ ] Code follows repository conventions in `AGENTS.md` and `docs/agent/SUMMARY.md`.
- [ ] Branch name matches the Gate 1 pattern (e.g. `docs/…`, `fix/…`, or `PROJ-123-…`).
- [ ] If file structure changed, updated `scripts/file-descriptions.txt` and ran `bash scripts/sync-docs.sh`.
- [ ] Quality gates passed locally (`bash scripts/quality-gates.sh`).
- [ ] Smoke tests passed (`bash tests/run-tests.sh`) — required for gate, sync, or guardrail changes.
- [ ] If protected files were modified, authorized with `--allow-guardrail` (and `--ack-new-guardrail` for new guardrail files).
- [ ] No secrets, private keys, or API tokens committed.
- [ ] Updated `docs/agent/HANDOVER.md` if working as an autonomous agent.

## Related Issues
<!-- Link related issues, e.g., Closes #123 -->
