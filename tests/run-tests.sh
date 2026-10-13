#!/usr/bin/env bash
set -euo pipefail

# Checkrail smoke tests.
# Verifies quality-gate boundary conditions inside disposable scratch
# repositories. No external test framework required: Bash 4.4+, git 2.30+,
# and coreutils are enough. Python (optional) enables the kilo.jsonc
# semantic-assertion tests. The staged-secret test forces the built-in
# Gate 8 fallback scanner for determinism; the gitleaks path is exercised
# separately by the quality-gates CI workflow on pushes to main and PRs.
#
# Usage: bash tests/run-tests.sh [name-filter]

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ -x "$b" ]] && exec "$b" "$0" "$@"
    done
    echo "ERROR: run-tests.sh requires Bash 4.4+ (Git Bash / brew bash / Linux)." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$WORK_ROOT"' EXIT

PASS=0
FAIL=0
MATCHED=0
FAILED_TESTS=()
FILTER="${1:-}"

note() { printf '%s\n' "$*"; }

pass() {
    PASS=$((PASS + 1))
    note "PASS  $1"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$1")
    note "FAIL  $1 (rc=$GATES_RC)"
    note "      --- gates output ---"
    sed 's/^/      /' "$GATES_OUT_FILE" 2>/dev/null || true
    sed 's/^/      /' "$GATES_ERR_FILE" 2>/dev/null || true
}

skip() {
    note "SKIP  $1 ($2)"
}

# Run the gates inside a scratch repo with CI-only variables removed so the
# local staged-diff code path is exercised identically on every machine
# (including inside a GitHub Actions runner, where CI=true is exported).
GATES_RC=0
GATES_OUT_FILE="$WORK_ROOT/gates.out"
GATES_ERR_FILE="$WORK_ROOT/gates.err"
run_gates() {
    local s="$1"; shift
    local env_args=(
        env -u CI -u GITHUB_ACTIONS -u GITHUB_WORKFLOW -u GITHUB_EVENT_NAME
        -u GITHUB_EVENT_BEFORE -u GITHUB_REF_NAME -u GITHUB_HEAD_REF
        -u GITHUB_BASE_REF -u CI_COMMIT_REF_NAME
        -u CI_MERGE_REQUEST_TARGET_BRANCH_NAME -u SYSTEM_PULLREQUEST_TARGETBRANCH
        -u BASE_BRANCH -u STRICT_VERSIONS -u TERRAFORM_VALIDATE
        -u TERRAFORM_DIR -u INDEX_MODE -u FAST -u QUIET -u PYTEST_ARGS
        -u PYTEST_TIMEOUT -u VIRTUAL_ENV
        -u GUARDRAIL_MODIFICATION_AUTHORIZED -u NEW_GUARDRAIL_INTRODUCTION_ACK
    )
    if [[ -n "${GATES_TEST_PATH:-}" ]]; then
        env_args+=("PATH=$GATES_TEST_PATH")
    fi
    if (
        cd "$s" &&
        "${env_args[@]}" bash scripts/quality-gates.sh "$@" >"$GATES_OUT_FILE" 2>"$GATES_ERR_FILE"
    ); then
        GATES_RC=0
    else
        GATES_RC=$?
    fi
}

# PATH without any gitleaks entry, to exercise the built-in Gate 8 fallback
# scanner deterministically (an installed gitleaks binary would take over).
gitleaks_free_path() {
    printf '%s' "$PATH" | tr ':' '\n' | grep -iv 'gitleaks' | paste -sd: -
}

gates_output() { cat "$GATES_OUT_FILE" "$GATES_ERR_FILE" 2>/dev/null; }

expect_gates_pass() {
    if (( GATES_RC == 0 )); then
        pass "$1"
    else
        fail "$1"
    fi
}

expect_gates_fail() {
    local name="$1" pattern="$2"
    if (( GATES_RC != 0 )) && gates_output | grep -Eqi "$pattern"; then
        pass "$name"
    else
        fail "$name"
    fi
}

HANDOVER_BODY='# STATE: HANDOVER

[TASK] scratch
[DIFF_SUMMARY] - scratch
[GATES_STATUS] pending
[NEXT] 1. scratch
[BLOCKERS] None.
'

# Build a minimal scratch repository that satisfies every gate, then commit
# the initial state. Tests stage their violation on top of this baseline.
make_scratch() {
    local s="$WORK_ROOT/$1"
    mkdir -p "$s/scripts" "$s/docs/agent"
    (
        cd "$s"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "tests@checkrail.invalid"
        git config user.name "Checkrail Tests"
        git config core.autocrlf false
        cp "$REPO_ROOT/scripts/quality-gates.sh" scripts/
        cp "$REPO_ROOT/scripts/sync-docs.sh" scripts/
        printf '# scratch rules\n' >AGENTS.md
        printf '# scratch readme\n' >README.md
        printf '%s\n' "$HANDOVER_BODY" >docs/agent/HANDOVER.md
        cat >scripts/file-descriptions.txt <<'EOF'
# path: purpose
AGENTS.md: Scratch root rules
README.md: Scratch readme
scripts/quality-gates.sh: Gate harness under test
scripts/sync-docs.sh: Doc sync under test
scripts/file-descriptions.txt: Scratch descriptions map
docs/agent/HANDOVER.md: Session handover
EOF
        git add -A
        bash scripts/sync-docs.sh >/dev/null
        git add -A
        git commit -q -m "scratch init"
    )
    printf '%s\n' "$s"
}

# Regenerate the scratch index after tracked files change, so Gate 7 stays in
# sync and the test targets the gate under scrutiny.
resync() {
    local s="$1"
    ( cd "$s" && bash scripts/sync-docs.sh >/dev/null && git add docs/file-index.md )
}

want() {
    if [[ -z "$FILTER" ]]; then
        return 0
    fi
    if [[ "$1" == *"$FILTER"* ]]; then
        MATCHED=$((MATCHED + 1))
        return 0
    fi
    return 1
}

# ── Tests ───────────────────────────────────────────────────────

t_clean_staged_change() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch clean)"
    ( cd "$s" && printf 'more\n' >>README.md && git add README.md )
    run_gates "$s"
    expect_gates_pass "$FUNCNAME: clean staged change passes all gates"
}

t_protected_file_blocked() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch protected)"
    ( cd "$s" && printf 'tamper\n' >>AGENTS.md && git add AGENTS.md )
    run_gates "$s"
    expect_gates_fail "$FUNCNAME: protected file modification blocked" "Protected files modified"
}

t_protected_file_allowed_with_flag() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch protected-allow)"
    ( cd "$s" && printf 'tamper\n' >>AGENTS.md && git add AGENTS.md )
    run_gates "$s" --allow-guardrail
    expect_gates_pass "$FUNCNAME: --allow-guardrail authorizes protected edit"
}

t_new_guardrail_needs_ack() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch new-guard)"
    ( cd "$s" && mkdir -p .github/workflows \
        && printf 'name: evil\n' >.github/workflows/evil.yml \
        && git add .github )
    run_gates "$s"
    expect_gates_fail "$FUNCNAME: new guardrail file blocked without ack" "New guardrail files introduced"
}

t_new_guardrail_ack() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch new-guard-ack)"
    ( cd "$s" && mkdir -p .github/workflows \
        && printf 'name: evil\n' >.github/workflows/evil.yml \
        && git add .github )
    resync "$s"
    run_gates "$s" --ack-new-guardrail
    expect_gates_pass "$FUNCNAME: --ack-new-guardrail authorizes new guardrail file"
}

t_staged_symlink_rejected() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch symlink)"
    local blob
    blob="$( cd "$s" && printf 'README.md' | git hash-object -w --stdin )"
    ( cd "$s" && git update-index --add --cacheinfo "120000,$blob,AGENTS.md" )
    # --staged-only skips the Gate 2 clean-tree check; on filesystems without
    # native symlinks the working-tree copy stays a regular file, and the
    # staged-mode (120000) defense is the part under test.
    run_gates "$s" --staged-only
    expect_gates_fail "$FUNCNAME: staged symlink at protected path rejected" "symlink"
}

t_handover_missing_section() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch handover-section)"
    ( cd "$s" && sed -i '/BLOCKERS/d' docs/agent/HANDOVER.md \
        && git add docs/agent/HANDOVER.md )
    run_gates "$s"
    expect_gates_fail "$FUNCNAME: HANDOVER missing [BLOCKERS] rejected" "missing \[BLOCKERS\]"
}

t_handover_line_limit() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch handover-long)"
    (
        cd "$s"
        { printf '%s\n' "$HANDOVER_BODY"; for i in $(seq 1 40); do printf 'filler %d\n' "$i"; done; } \
            >docs/agent/HANDOVER.md
        git add docs/agent/HANDOVER.md
    )
    run_gates "$s"
    expect_gates_fail "$FUNCNAME: HANDOVER over 40 lines rejected" "max 40"
}

t_staged_secret_rejected() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch secret)"
    # Assembled at runtime so no literal secret pattern lands in this file.
    # Not the AWS docs example key: that one is allowlisted by gitleaks.
    local fake; fake="AKIA""Q7ZXF2K9M4TL1B8W"
    ( cd "$s" && printf 'aws_access_key_id = %s\n' "$fake" >creds.txt \
        && git add creds.txt )
    resync "$s"
    # Force the Gate 8 fallback scanner (strip gitleaks from PATH) so this
    # test is deterministic regardless of which gitleaks build is installed.
    GATES_TEST_PATH="$(gitleaks_free_path)" run_gates "$s"
    expect_gates_fail "$FUNCNAME: staged secret rejected by fallback scanner" \
        "Fallback scan found probable secrets"
}

t_index_drift_rejected() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch drift)"
    ( cd "$s" && printf '| rogue | row |\n' >>docs/file-index.md \
        && git add docs/file-index.md )
    run_gates "$s"
    expect_gates_fail "$FUNCNAME: out-of-sync file index rejected" "out of sync"
}

t_invalid_branch_rejected() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch bad-branch)"
    ( cd "$s" && git checkout -q -b invalidbranch \
        && printf 'more\n' >>README.md && git add README.md )
    run_gates "$s"
    expect_gates_fail "$FUNCNAME: invalid branch name rejected" "must match"
}

t_valid_branch_accepted() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch good-branch)"
    ( cd "$s" && git checkout -q -b docs/smoke-branch \
        && printf 'more\n' >>README.md && git add README.md )
    run_gates "$s"
    expect_gates_pass "$FUNCNAME: conventioned branch name accepted"
}

t_tfvars_commit_rejected() {
    want "$FUNCNAME" || return 0
    local s; s="$(make_scratch tfvars)"
    ( cd "$s" && mkdir -p envs \
        && printf 'region = "us-east-1"\n' >envs/dev.tfvars \
        && git add envs/dev.tfvars )
    resync "$s"
    run_gates "$s"
    expect_gates_fail "$FUNCNAME: .tfvars commit rejected" "never be committed"
}

# kilo.jsonc semantic assertions (requires a functional Python).
have_python=false
for _cand in python3 python; do
    if command -v "$_cand" >/dev/null 2>&1 && "$_cand" -c 'import sys' >/dev/null 2>&1; then
        have_python=true
        break
    fi
done

valid_jsonc='{
  "permission": {
    "edit": {
      "docs/file-index.md": "deny",
      ".env": "deny",
      "*.tfvars": "deny",
      "*.tfvars.json": "deny",
      ".git/**": "deny",
      "*.pem": "deny",
      ".ssh/**": "deny",
      "kilo.jsonc": "ask",
      "id_rsa*": "deny",
      "id_ed25519*": "deny",
      "id_ecdsa*": "deny",
      "id_dsa*": "deny",
      ".kilo/**": "deny"
    },
    "read": {
      ".env": "deny",
      "*.tfvars": "deny",
      "*.tfvars.json": "deny",
      ".git/**": "deny",
      "*.pem": "deny",
      ".ssh/**": "deny",
      ".kilo/**": "deny",
      "id_rsa*": "deny",
      "id_ed25519*": "deny",
      "id_ecdsa*": "deny",
      "id_dsa*": "deny"
    },
    "bash": {
      "*": "ask",
      "git add": "ask",
      "*;*": "ask",
      "*&&*": "ask",
      "*||*": "ask",
      "*|*": "ask",
      "*`*": "ask",
      "*$(*": "ask",
      "*>*": "ask",
      "*>>*": "ask",
      "*<*": "ask",
      "*rm -rf*": "deny",
      "*rm -fr*": "deny",
      "*git push -f*": "deny",
      "*git reset*--hard*": "deny",
      "*sudo *": "deny"
    }
  }
}
'

t_jsonc_valid_policy() {
    want "$FUNCNAME" || return 0
    if [[ "$have_python" != "true" ]]; then
        skip "$FUNCNAME: valid kilo.jsonc accepted" "no functional Python"
        return 0
    fi
    local s; s="$(make_scratch jsonc-valid)"
    ( cd "$s" && printf '%s\n' "$valid_jsonc" >kilo.jsonc && git add kilo.jsonc )
    resync "$s"
    run_gates "$s" --ack-new-guardrail
    expect_gates_pass "$FUNCNAME: policy-compliant kilo.jsonc passes semantic checks"
}

t_jsonc_bash_default_allow_rejected() {
    want "$FUNCNAME" || return 0
    if [[ "$have_python" != "true" ]]; then
        skip "$FUNCNAME: bash default allow rejected" "no functional Python"
        return 0
    fi
    local s; s="$(make_scratch jsonc-drift)"
    ( cd "$s" \
        && printf '%s\n' "$valid_jsonc" | sed 's/"\*": "ask"/"*": "allow"/' >kilo.jsonc \
        && git add kilo.jsonc )
    resync "$s"
    run_gates "$s" --ack-new-guardrail
    expect_gates_fail "$FUNCNAME: bash default allow rejected" 'must be .ask.'
}

# ── Main ─────────────────────────────────────────────────────────

note "=== Checkrail smoke tests (scratch repos under $WORK_ROOT) ==="

t_clean_staged_change
t_protected_file_blocked
t_protected_file_allowed_with_flag
t_new_guardrail_needs_ack
t_new_guardrail_ack
t_staged_symlink_rejected
t_handover_missing_section
t_handover_line_limit
t_staged_secret_rejected
t_index_drift_rejected
t_invalid_branch_rejected
t_valid_branch_accepted
t_tfvars_commit_rejected
t_jsonc_valid_policy
t_jsonc_bash_default_allow_rejected

note ""
note "=== Result: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    note "Failed tests:"
    for t in "${FAILED_TESTS[@]+"${FAILED_TESTS[@]}"}"; do
        note "  - $t"
    done
    exit 1
fi
if [[ -n "$FILTER" ]] && (( MATCHED == 0 )); then
    note "ERROR: no tests matched filter '$FILTER'"
    exit 1
fi
exit 0
