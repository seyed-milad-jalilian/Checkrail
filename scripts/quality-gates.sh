#!/usr/bin/env bash
set -euo pipefail

# macOS fallback for Bash 3.2
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ -x "$b" ]] && exec "$b" "$0" "$@"
    done
    echo "ERROR: quality-gates.sh requires Bash 4.4+." >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: quality-gates.sh must be run inside a Git repository." >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

FAST="${FAST:-false}"
QUIET="${QUIET:-false}"
STRICT_VERSIONS="${STRICT_VERSIONS:-false}"
PYTEST_TIMEOUT="${PYTEST_TIMEOUT:-300}"
TERRAFORM_VALIDATE="${TERRAFORM_VALIDATE:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged-only) QUALITY_GATES_STAGED_ONLY=true ;;
        --allow-guardrail) GUARDRAIL_MODIFICATION_AUTHORIZED=true ;;
        --ack-new-guardrail) NEW_GUARDRAIL_INTRODUCTION_ACK=true ;;
        --fast) FAST=true ;;
        --quiet) QUIET=true ;;
        --strict-versions) STRICT_VERSIONS=true ;;
        --base=*) BASE_BRANCH="${1#*=}" ;;
        --terraform-dir=*) TERRAFORM_DIR="${1#*=}" ;;
        --pytest-args=*) PYTEST_ARGS="${1#*=}" ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Normalize so "infra/" and "infra" compare the same way.
if [[ -n "${TERRAFORM_DIR:-}" ]]; then
    TERRAFORM_DIR="${TERRAFORM_DIR%/}"
fi

log() { [[ "$QUIET" == "true" ]] && return 0; printf '%s\n' "$*"; }

# Do NOT auto-source .venv/*/activate — it executes untrusted code before any
# gate runs. Instead, detect the interpreter from the environment the user has
# already activated (VIRTUAL_ENV), or fall back to system python.

# Prefer the interpreter inside the active venv. A system `python3` must not
# shadow Windows venv's Scripts/python.exe (or a venv that only ships `python`).
PYTHON_BIN=""
if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    for cand in \
        "$VIRTUAL_ENV/bin/python" \
        "$VIRTUAL_ENV/bin/python3" \
        "$VIRTUAL_ENV/Scripts/python.exe" \
        "$VIRTUAL_ENV/Scripts/python" \
        "$VIRTUAL_ENV/Scripts/python3.exe"
    do
        if [[ -x "$cand" ]]; then
            PYTHON_BIN="$cand"
            break
        fi
    done
fi
if [[ -z "$PYTHON_BIN" ]]; then
    if command -v python3 >/dev/null 2>&1; then PYTHON_BIN="python3"
    elif command -v python >/dev/null 2>&1; then PYTHON_BIN="python"; fi
fi
# Functional probe: a Windows "App execution alias" stub makes `command -v
# python3` succeed while the binary is non-functional (it prints a Store
# prompt and exits non-zero), which crashes this script under `set -e` at
# Gate 3. Verify PYTHON_BIN actually runs Python. If python3 is a stub, fall
# back to plain `python` — on Windows the real install is named `python`, not
# `python3` (so the elif above never reached it). Only clear PYTHON_BIN when
# BOTH are non-functional, so Python-dependent gates degrade gracefully.
if [[ -n "$PYTHON_BIN" ]] && ! "$PYTHON_BIN" -c 'import sys' >/dev/null 2>&1; then
    if command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
        PYTHON_BIN="python"
    else
        PYTHON_BIN=""
    fi
fi

export DEBIAN_FRONTEND=noninteractive TF_IN_AUTOMATION=1 PYTHONDONTWRITEBYTECODE=1
TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$(git rev-parse --git-path kilo-tmp)/tf-plugin-cache}"
export TF_PLUGIN_CACHE_DIR
mkdir -p "$TF_PLUGIN_CACHE_DIR"

TMP_ROOT="$(git rev-parse --git-path kilo-tmp)"
mkdir -p "$TMP_ROOT"
RUN_TMP="$(mktemp -d "$TMP_ROOT/qg.XXXXXX")"
trap 'rm -rf -- "$RUN_TMP"' EXIT

make_tmp_file() { mktemp "$RUN_TMP/f.XXXXXX"; }

run_timed() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "${secs}s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "${secs}s" "$@"
    else "$@"; fi
}

# Split PYTEST_ARGS with POSIX shlex so --pytest-args='-k "foo bar"' stays intact.
pytest_extra=()
if [[ -n "${PYTEST_ARGS:-}" ]]; then
    if [[ -n "$PYTHON_BIN" ]]; then
        while IFS= read -r -d '' arg; do
            pytest_extra+=("$arg")
        done < <("$PYTHON_BIN" -c '
import shlex, sys
args = shlex.split(sys.argv[1])
sys.stdout.buffer.write(b"\0".join(a.encode() for a in args) + (b"\0" if args else b""))
' "$PYTEST_ARGS")
    else
        # Last-resort split; quoted groups will not survive without Python.
        # shellcheck disable=SC2206
        pytest_extra=($PYTEST_ARGS)
    fi
fi

log "=== Kilo Generic Quality Gates ==="

# ── Gate 0: Tool versions ───────────────────────────────────────
if [[ -f ".tool-versions" ]]; then
    log "[Gate 0] Checking tool versions (major strict / minor advisory; --strict-versions enforces the pinned major.minor)"

    declare -A TOOL_BIN_MAP=(
        ["nodejs"]="node"
        ["python"]="python3"
        ["golang"]="go"
    )

    get_bin() {
        local t="$1"
        echo "${TOOL_BIN_MAP[$t]:-$t}"
    }

    while IFS=' ' read -r tool version || [[ -n "$tool" ]]; do
        [[ "$tool" =~ ^#.*$ || -z "$tool" ]] && continue

        bin="$(get_bin "$tool")"
        if ! command -v "$bin" >/dev/null 2>&1; then
            if [[ "$STRICT_VERSIONS" == "true" ]]; then
                echo "ERROR: [Gate 0] $tool ($bin) is listed in .tool-versions but not installed (--strict-versions)" >&2
                exit 1
            fi
            log "[Gate 0] WARNING: $tool ($bin) is listed in .tool-versions but is not installed"
            continue
        fi

        actual=""
        expected=""
        case "$bin" in
            gitleaks|terraform|go) vc="version" ;;
            *) vc="--version" ;;
        esac
        actual_raw="$("$bin" $vc 2>/dev/null || true)"
        if [[ "$actual_raw" =~ ([0-9]+\.[0-9]+) ]]; then
            actual="${BASH_REMATCH[1]}"
        fi
        if [[ "$version" =~ ([0-9]+\.[0-9]+) ]]; then
            expected="${BASH_REMATCH[1]}"
        fi

        if [[ -z "$expected" ]]; then
            log "[Gate 0] WARNING: $tool version '$version' has no major.minor to compare; skipping"
            continue
        fi
        if [[ -z "$actual" ]]; then
            if [[ "$STRICT_VERSIONS" == "true" ]]; then
                echo "ERROR: [Gate 0] could not parse a major.minor from \`$bin $vc\` (--strict-versions)" >&2
                exit 1
            fi
            log "[Gate 0] WARNING: could not parse a major.minor from \`$bin $vc\`; skipping"
            continue
        fi
        if [[ "$actual" != "$expected" ]]; then
            # Tiered: a MAJOR mismatch (python 2 vs 3) is genuinely breaking and
            # always fails; a MINOR mismatch (3.12 vs 3.13) is compatible and only
            # warns unless --strict-versions is set.
            if [[ "${actual%%.*}" != "${expected%%.*}" ]]; then
                echo "ERROR: [Gate 0] $tool major-version mismatch: expected $expected, got $actual (breaking)" >&2
                exit 1
            elif [[ "$STRICT_VERSIONS" == "true" ]]; then
                echo "ERROR: [Gate 0] $tool version mismatch: expected $expected, got $actual (--strict-versions)" >&2
                exit 1
            else
                log "[Gate 0] WARNING: $tool minor-version mismatch: expected $expected, got $actual (compatible; --strict-versions to enforce)"
            fi
        else
            log "[Gate 0] $tool $actual matches $expected.x"
        fi
    done < .tool-versions
fi

# ── Gate 1: Branch pattern + BASE_REF ───────────────────────────
# NOTE: the regex must not contain a `{...}` quantifier, because this whole
# default is itself inside ${BRANCH_REGEX:-...}; bash closes that expansion at
# the first '}', which would silently corrupt the pattern. [A-Z]{2,} is written
# as the equivalent [A-Z][A-Z]+ for that reason.
BRANCH_REGEX="${BRANCH_REGEX:-^(((feature|fix|chore|docs|refactor|test|hotfix|build|ci|perf|style|release|dependabot)/.+)|([A-Z][A-Z]+-[0-9]+(-.+)?))$}"

if [[ "${CI:-false}" == "true" ]]; then
    current_branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-${CI_COMMIT_REF_NAME:-$(git symbolic-ref --short HEAD 2>/dev/null || echo "HEAD")}}}"
else
    current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "HEAD")"
fi

default_branch="main"
if default_head="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
    default_branch="${default_head#refs/remotes/origin/}"
fi

if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    if [[ "${CI:-false}" != "true" ]]; then echo "ERROR: [Gate 1] Current branch cannot be determined." >&2; exit 1; fi
elif [[ "${GITHUB_EVENT_NAME:-}" == "merge_group" ]]; then
    log "[Gate 1] Merge queue context; skipping branch name check"
elif [[ "$current_branch" == "$default_branch" || "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    log "[Gate 1] Integration branch '$current_branch'"
elif [[ ! "$current_branch" =~ $BRANCH_REGEX ]]; then
    echo "ERROR: [Gate 1] Branch '$current_branch' must match $BRANCH_REGEX" >&2; exit 1
else
    log "[Gate 1] Branch OK: $current_branch"
fi

CI_TARGET="${GITHUB_BASE_REF:-${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-${SYSTEM_PULLREQUEST_TARGETBRANCH:-}}}"
CI_TARGET="${CI_TARGET#refs/heads/}"
if [[ "${CI:-false}" == "true" && -z "$CI_TARGET" && -n "${GITHUB_EVENT_BEFORE:-}" && ! "${GITHUB_EVENT_BEFORE}" =~ ^0+$ ]]; then
    CI_TARGET="$GITHUB_EVENT_BEFORE"
fi

DEFAULT_REF="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
DEFAULT_REF="${DEFAULT_REF#refs/remotes/}"
BASE_INPUT="${BASE_BRANCH:-${CI_TARGET:-${DEFAULT_REF:-origin/main}}}"

resolve_ref() {
    local ref="$1"
    [[ "$ref" =~ ^0+$ ]] && return 1
    if [[ "$ref" == origin/* || "$ref" == refs/remotes/origin/* ]]; then
        git rev-parse --verify --quiet "$ref^{commit}" >/dev/null && { printf '%s\n' "$ref"; return 0; }
        return 1
    fi
    local candidate
    for candidate in "origin/$ref" "refs/remotes/origin/$ref" "$ref"; do
        git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

is_bootstrap_fallback=false
apply_unresolved_base_fallback() {
    local why="$1"
    if git rev-parse --verify --quiet HEAD~1 >/dev/null 2>&1; then
        BASE_REF="HEAD~1"
        log "[Gate 1] WARNING: Could not resolve '$why'; falling back to HEAD~1"
    elif git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        # HEAD exists but HEAD~1 does not (single-commit repo, second commit).
        # Use empty tree for diff scope, but do NOT skip enforcement — not bootstrap.
        BASE_REF="$(git hash-object -t tree /dev/null)"
        log "[Gate 1] WARNING: Could not resolve '$why'; using empty tree for diff (not bootstrap)"
    else
        BASE_REF="$(git hash-object -t tree /dev/null)"
        is_bootstrap_fallback=true
        log "[Gate 1] WARNING: Could not resolve '$why'; using empty tree (bootstrap)"
    fi
}

if [[ "${CI:-false}" == "true" ]]; then
    if [[ "$BASE_INPUT" =~ ^0+$ ]]; then
        BASE_REF="$(git hash-object -t tree /dev/null)"
        is_bootstrap_fallback=true
    elif ! BASE_REF="$(resolve_ref "$BASE_INPUT")"; then
        # First push / missing origin default should not hard-fail CI.
        # An explicit, non-default CI target that cannot be resolved is still an error.
        if [[ -n "$CI_TARGET" && "$BASE_INPUT" != "origin/main" && "$BASE_INPUT" != "origin/master" && "$BASE_INPUT" != "main" && "$BASE_INPUT" != "master" ]]; then
            echo "ERROR: [Gate 1] Could not resolve CI base ref '$BASE_INPUT'." >&2
            exit 1
        fi
        apply_unresolved_base_fallback "$BASE_INPUT"
    fi
else
    if ! BASE_REF="$(resolve_ref "$BASE_INPUT")"; then
        apply_unresolved_base_fallback "$BASE_INPUT"
    fi
fi
log "[Gate 1] BASE_REF=$BASE_REF"

# ── Gate 2: Clean working tree + HANDOVER ─────────────────────
HANDOVER_PATH="docs/agent/HANDOVER.md"

if [[ "${CI:-false}" != "true" && "${QUALITY_GATES_STAGED_ONLY:-false}" != "true" ]]; then
    unstaged_tracked=()
    untracked_files=()
    tmp_unstaged="$(make_tmp_file)"
    tmp_untracked="$(make_tmp_file)"
    if ! git diff --name-only -z > "$tmp_unstaged" 2>/dev/null; then
        echo "ERROR: [Gate 2] git diff (unstaged) failed; cannot verify clean tree." >&2
        exit 1
    fi
    if ! git ls-files --others --exclude-standard -z > "$tmp_untracked" 2>/dev/null; then
        echo "ERROR: [Gate 2] git ls-files (untracked) failed; cannot verify clean tree." >&2
        exit 1
    fi

    while IFS= read -r -d '' f; do
        [[ -n "$f" && "$f" != "$HANDOVER_PATH" ]] && unstaged_tracked+=("$f")
    done < "$tmp_unstaged"

    while IFS= read -r -d '' f; do
        [[ -n "$f" && "$f" != "$HANDOVER_PATH" ]] && untracked_files+=("$f")
    done < "$tmp_untracked"

    if (( ${#unstaged_tracked[@]} > 0 || ${#untracked_files[@]} > 0 )); then
        echo "ERROR: [Gate 2] Working tree is not cleanly staged." >&2
        exit 1
    fi
fi

validate_handover() {
    local file="$1" label="$2"
    local handover_lines section
    handover_lines="$(awk 'END{print NR}' "$file")"
    if (( handover_lines > 40 )); then
        echo "ERROR: [Gate 2] $HANDOVER_PATH ($label) has $handover_lines lines (max 40)." >&2
        exit 1
    fi
    for section in "TASK" "DIFF_SUMMARY" "GATES_STATUS" "NEXT" "BLOCKERS"; do
        if ! grep -q "\[$section\]" "$file"; then
            echo "ERROR: [Gate 2] $HANDOVER_PATH ($label) is missing [$section] section." >&2
            exit 1
        fi
    done
}

# HANDOVER must exist as a regular file (not optional, not symlink).
if [[ ! -f "$HANDOVER_PATH" || -L "$HANDOVER_PATH" ]]; then
    echo "ERROR: [Gate 2] $HANDOVER_PATH must exist as a regular file." >&2
    exit 1
fi
# HANDOVER must also be present in the index (detect staged deletion).
if ! git rev-parse --verify --quiet ":${HANDOVER_PATH}" >/dev/null 2>&1; then
    echo "ERROR: [Gate 2] $HANDOVER_PATH must be staged in the index." >&2
    exit 1
fi

# Validate both the live working-tree copy (agent protocol) and the staged
# blob (what will actually be committed) when they differ.
handover_wt_checked=false
if [[ -f "$HANDOVER_PATH" ]]; then
    validate_handover "$HANDOVER_PATH" "working tree"
    handover_wt_checked=true
fi
if git rev-parse --verify --quiet ":${HANDOVER_PATH}" >/dev/null 2>&1; then
    staged_handover="$(make_tmp_file)"
    git show ":${HANDOVER_PATH}" > "$staged_handover"
    if [[ "$handover_wt_checked" != "true" ]] || ! cmp -s "$HANDOVER_PATH" "$staged_handover"; then
        validate_handover "$staged_handover" "staged"
    fi
fi

# ── Scope collection (one diff cache, with status) ────────────
scoped_z="$(make_tmp_file)"
if [[ "${CI:-false}" == "true" ]]; then
    ref_type="$(git cat-file -t "$BASE_REF" 2>/dev/null || echo invalid)"
    if [[ "$ref_type" == "commit" ]]; then
        if ! git diff --name-status -z --no-renames --diff-filter=ACMRDT "$BASE_REF...HEAD" > "$scoped_z" 2>/dev/null; then
            echo "ERROR: [Gate 1] Could not collect diff scope ($BASE_REF...HEAD); repository may be shallow or corrupted." >&2
            exit 1
        fi
    elif [[ "$ref_type" == "tree" ]]; then
        if ! git diff --name-status -z --no-renames --diff-filter=ACMRDT "$BASE_REF" "HEAD" > "$scoped_z" 2>/dev/null; then
            echo "ERROR: [Gate 1] Could not collect diff scope (bootstrap tree vs HEAD)." >&2
            exit 1
        fi
    else
        # Unreachable: BASE_REF always resolves to commit/tree via resolve_ref / fallback.
        echo "ERROR: [Gate 1] BASE_REF '$BASE_REF' is neither commit nor tree (ref_type=$ref_type); refusing to enforce gates on an empty diff scope." >&2
        exit 1
    fi
else
    if ! git diff --cached --name-status -z --no-renames --diff-filter=ACMRDT > "$scoped_z" 2>/dev/null; then
        echo "ERROR: [Gate 1] Could not collect staged diff scope." >&2
        exit 1
    fi
fi

all_scoped=()
declare -A scoped_status=()
while IFS= read -r -d '' st && IFS= read -r -d '' f; do
    [[ -z "$f" ]] && continue
    all_scoped+=("$f")
    scoped_status["$f"]="$st"
done < "$scoped_z"

# MUST end with `return 0`. Under `set -e`, a function's status is the status
# of its last command. A non-matching `[[ =~ ]]` on the last scoped file used
# to make this function return 1 and abort the script at the next gate.
filter_scope() {
    local _fs_dest_name="$1" _fs_regex="$2"
    local -n _fs_dest="$_fs_dest_name"
    _fs_dest=()
    local _fs_f
    for _fs_f in "${all_scoped[@]+"${all_scoped[@]}"}"; do
        if [[ "$_fs_f" =~ $_fs_regex ]]; then
            _fs_dest+=("$_fs_f")
        fi
    done
    return 0
}

# ── Gate 3: Protected files + JSONC semantic assertions ──────
protected_file_patterns=(
    '.github/CODEOWNERS' '.github/dependabot.yml'
    '.gitlab-ci.yml' 'Jenkinsfile'
    'AGENTS.md' 'kilo.jsonc' '.kilocodeignore'
    'docs/agent/SUMMARY.md' 'docs/agent/protocol.md'
    'scripts/sync-docs.sh' 'scripts/quality-gates.sh' 'scripts/file-descriptions.txt' 'scripts/doctor.sh'
    '.pre-commit-config.yaml' '.gitattributes' '.tool-versions'
)

protected_dir_patterns=(
    '.github/workflows'
    '.circleci'
    '.kilo'
)

is_protected_path() {
    local f="$1" p
    for p in "${protected_file_patterns[@]}"; do
        if [[ "$f" == "$p" ]]; then
            return 0
        fi
    done
    for p in "${protected_dir_patterns[@]}"; do
        if [[ "$f" == "$p" || "$f" == "$p"/* ]]; then
            return 0
        fi
    done
    return 1
}

assert_not_symlink() {
    local f="$1"
    # Check working tree
    [[ -e "$f" || -L "$f" ]] || return 0
    if [[ -L "$f" ]]; then
        echo "ERROR: [Gate 3] Protected path '$f' is a symlink (working tree)." >&2; exit 1
    fi
    # Check staged mode (index) — a symlink could be staged while WT is regular
    local staged_mode
    staged_mode="$(git ls-files -s -- "$f" 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$staged_mode" == "120000" ]]; then
        echo "ERROR: [Gate 3] Protected path '$f' is staged as a symlink (mode 120000)." >&2; exit 1
    fi
}

kilo_jsonc_check_file() {
    # Validate one copy of kilo.jsonc (working tree OR staged blob).
    local target="$1" label="$2"
    "$PYTHON_BIN" - "$target" "$label" <<'PY'
import pathlib, sys, json, re

target, label = sys.argv[1], sys.argv[2]

def strip_jsonc(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    in_string = False
    escape = False

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue

        if ch == "/" and nxt == "/":
            i += 2
            while i < n and text[i] not in "\r\n":
                i += 1
            continue

        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            if i + 1 < n:
                i += 2
            else:
                raise ValueError("Unclosed block comment in JSONC")
            continue

        out.append(ch)
        i += 1

    if in_string:
        raise ValueError("Unclosed string literal in JSONC")

    return "".join(out)

def strip_trailing_commas(text: str) -> str:
    """Remove commas that precede } or ], ignoring commas inside strings."""
    out = []
    i = 0
    n = len(text)
    in_string = False
    escape = False

    while i < n:
        ch = text[i]

        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue

        if ch == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                i += 1
                continue

        out.append(ch)
        i += 1

    return "".join(out)

try:
    text = pathlib.Path(target).read_text(encoding="utf-8")
    text = strip_trailing_commas(strip_jsonc(text))
    data = json.loads(text)
except (ValueError, json.JSONDecodeError, UnicodeDecodeError, OSError) as e:
    print(f"ERROR: [Gate 3] kilo.jsonc ({label}) invalid: {e}", file=sys.stderr)
    sys.exit(1)

perm = data.get("permission", {})
assertions = {
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
    }
}
for block, rules in assertions.items():
    b = perm.get(block, {})
    for k, v in rules.items():
        if b.get(k) != v:
            print(f'ERROR: [Gate 3] Semantic drift: permission.{block}["{k}"] must be "{v}"', file=sys.stderr)
            sys.exit(1)

bash_block = perm.get("bash", {})
# The bash default MUST stay "ask"; if it becomes "allow" every command is
# silently permitted and the whole policy is void.
if bash_block.get("*") != "ask":
    print('ERROR: [Gate 3] permission.bash["*"] must be "ask" (default must not be allow).', file=sys.stderr)
    sys.exit(1)
if bash_block.get("git add") != "ask":
    print('ERROR: [Gate 3] permission.bash["git add"] must be "ask".', file=sys.stderr)
    sys.exit(1)

# The bash block MUST retain its metacharacter/redirect traps and at least one
# bidirectional destructive deny glob. Removing them must not pass silently, and
# their presence makes the ordering check below non-vacuous.
required_bash_keys = {
    "*;*": "ask", "*&&*": "ask", "*||*": "ask", "*|*": "ask",
    "*`*": "ask", "*$(*": "ask", "*>*": "ask", "*>>*": "ask", "*<*": "ask",
    "*rm -rf*": "deny", "*rm -fr*": "deny",
    "*git push -f*": "deny", "*git reset*--hard*": "deny", "*sudo *": "deny",
}
for k, v in required_bash_keys.items():
    if bash_block.get(k) != v:
        print(f'ERROR: [Gate 3] Semantic drift: permission.bash["{k}"] must be "{v}"', file=sys.stderr)
        sys.exit(1)

# Ordering guard for the .env template exception: if both the broad deny
# "git add -- .env.*" and the ask override "git add -- .env.example" exist, the
# override MUST come later (last-match-wins) or templates get hard-denied.
_bg_keys = list(bash_block.keys())
def _bg_idx(k):
    return _bg_keys.index(k) if k in _bg_keys else -1
if _bg_idx("git add -- .env.example") != -1 and _bg_idx("git add -- .env.*") != -1:
    if _bg_idx("git add -- .env.example") < _bg_idx("git add -- .env.*"):
        print('ERROR: [Gate 3] "git add -- .env.example" must appear AFTER "git add -- .env.*" (template exception).', file=sys.stderr)
        sys.exit(1)

# Structural invariants on allow keys: an allow must be an exact, single
# command. A trailing '*' matches injected compound commands under loose
# matching; a shell metacharacter IS a compound/injected command. Either lets
# someone bypass the ask layer with one new key.
META = re.compile(r"[;|&`$<>]|\$\(")
for key, val in bash_block.items():
    if val == "allow" and ("*" in key or META.search(key)):
        reason = 'a wildcard "*"' if "*" in key else "a shell metacharacter"
        print(f'ERROR: [Gate 3] bash allow "{key}" has {reason}; allows must be exact single commands.', file=sys.stderr)
        sys.exit(1)

# Ordering invariant: malicious deny globs (*rm -rf*, etc.) must appear
# AFTER all allows, so last-match-wins semantics preserve them.
bash_keys = list(bash_block.keys())
deny_globs = [k for k in bash_keys if k.startswith("*") and bash_block[k] == "deny"]
if deny_globs and bash_block.get("*") == "ask":
    last_allow_idx = max(
        (i for i, k in enumerate(bash_keys) if bash_block[k] == "allow"),
        default=-1,
    )
    for dg in deny_globs:
        dg_idx = bash_keys.index(dg)
        if dg_idx < last_allow_idx:
            print(f'ERROR: [Gate 3] deny glob "{dg}" appears before an allow; last-match semantics break.', file=sys.stderr)
            sys.exit(1)

print(f"[Gate 3] kilo.jsonc ({label}) semantic assertions OK")
PY
}

kilo_jsonc_checks() {
    if [[ -z "$PYTHON_BIN" ]]; then
        if [[ "${CI:-false}" == "true" ]]; then
            echo "ERROR: [Gate 3] Python required in CI for kilo.jsonc semantic checks." >&2
            exit 1
        fi
        log "[Gate 3] Python not found, skipping JSONC semantic checks"
        return 0
    fi

    # Check the working-tree copy if present (what the agent operates on) ...
    local wt_checked=false
    if [[ -f "kilo.jsonc" ]]; then
        assert_not_symlink "kilo.jsonc"
        kilo_jsonc_check_file "kilo.jsonc" "working tree"
        wt_checked=true
    fi

    # ... and the staged blob (what will actually be committed), checked on its
    # own so a malicious staged version cannot sneak in by deleting the WT copy.
    if git rev-parse --verify --quiet ":kilo.jsonc" >/dev/null 2>&1; then
        local staged_kc
        staged_kc="$(make_tmp_file)"
        git show ":kilo.jsonc" > "$staged_kc"
        if [[ "$wt_checked" != "true" ]] || ! cmp -s "kilo.jsonc" "$staged_kc"; then
            kilo_jsonc_check_file "$staged_kc" "staged"
        fi
    fi
}

kilo_jsonc_checks

# Check ALL protected paths (files + dirs) for symlinks, not just a subset.
for p in "${protected_file_patterns[@]}" "${protected_dir_patterns[@]}"; do
    assert_not_symlink "$p"
done

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    # Truly empty repo (no commits at all). This only happens before the very
    # first git commit. Protected-file enforcement is meaningless here.
    printf '[Gate 3] No HEAD — protected-file enforcement skipped (JSONC + secret checks still active)\n' >&2
else
    protected_added=()
    protected_modified=()
    for f in "${all_scoped[@]+"${all_scoped[@]}"}"; do
        if is_protected_path "$f"; then
            case "${scoped_status[$f]:-M}" in
                A) protected_added+=("$f") ;;
                *) protected_modified+=("$f") ;;
            esac
        fi
    done

    # Reject symlinks at the individual-file level too, so the error message
    # explicitly says 'is a symlink' rather than just 'protected file modified'.
    for f in "${protected_added[@]+"${protected_added[@]}"}" "${protected_modified[@]+"${protected_modified[@]}"}"; do
        assert_not_symlink "$f"
    done

    # A whole pack directory staged as a single symlink entry (mode 120000,
    # e.g. `scripts` -> /tmp/evil) is not matched by is_protected_path. Reject it
    # explicitly so a directory-replacement symlink cannot shadow the pack.
    for f in "${all_scoped[@]+"${all_scoped[@]}"}"; do
        case "$f" in
            scripts|docs|.github|.vscode|.circleci|.kilo)
                assert_not_symlink "$f"
                ;;
        esac
    done

    allow="${GUARDRAIL_MODIFICATION_AUTHORIZED:-false}"
    ack_new="${NEW_GUARDRAIL_INTRODUCTION_ACK:-false}"

    fail_protected() {
        local kind="$1"; shift
        echo "ERROR: [Gate 3] $kind" >&2
        printf '  %s\n' "$@" >&2
        if [[ "${CI:-false}" != "true" ]]; then
            echo "1) bash scripts/quality-gates.sh --allow-guardrail [--ack-new-guardrail]" >&2
            echo "2) SKIP=kilo-quality-gates git commit     # not --no-verify" >&2
        fi
        exit 1
    }

    if (( ${#protected_added[@]} > 0 )); then
        if [[ "$ack_new" != "true" && "$allow" != "true" ]]; then
            if [[ "$is_bootstrap_fallback" == "true" ]]; then
                # Genuine first commit (empty-tree base): every guardrail file is
                # legitimately "new". You cannot ack-before-push in CI, so exempt
                # ONLY this bootstrap case from the new-guardrail check.
                log "[Gate 3] Bootstrap (empty-tree base): ${#protected_added[@]} new guardrail file(s) expected; skipping ack check"
            elif [[ "${CI:-false}" == "true" ]]; then
                echo "ERROR: [Gate 3] New guardrail files introduced in CI." >&2
                printf '  %s\n' "${protected_added[@]}" >&2
                exit 1
            else
                fail_protected "New guardrail files introduced locally (use --ack-new-guardrail or --allow-guardrail):" \
                    "${protected_added[@]}"
            fi
        fi
    fi

    if (( ${#protected_modified[@]} > 0 )); then
        if [[ "$allow" != "true" ]]; then
            if [[ "${CI:-false}" == "true" ]]; then
                echo "ERROR: [Gate 3] Protected files modified in CI." >&2
                printf '  %s\n' "${protected_modified[@]}" >&2
                exit 1
            fi
            fail_protected "Protected files modified locally:" "${protected_modified[@]}"
        fi
    fi
fi

# ── Gate 4: Shell syntax ──────────────────────────────────────
shell_files=()
filter_scope shell_files '\.sh$'
live_shell=()
for f in "${shell_files[@]+"${shell_files[@]}"}"; do
    if [[ -f "$f" ]]; then
        live_shell+=("$f")
    fi
done
if (( ${#live_shell[@]} > 0 )); then
    log "[Gate 4] Syntax-checking shell files"
    # `bash -n a.sh b.sh` only checks a.sh (b.sh becomes $1). Check each file
    # individually so a syntax error in the Nth changed script is not masked.
    for f in "${live_shell[@]}"; do
        bash -n "$f" || { echo "ERROR: [Gate 4] Syntax error in $f" >&2; exit 1; }
    done
fi

# ── Gate 5: Python (ruff + pytest) ────────────────────────────
if [[ "$FAST" == "true" ]]; then
    log "[Gate 5] Skipped (--fast)"
else
    python_files=()
    filter_scope python_files '\.py$'
    py_meta=()
    filter_scope py_meta '(pyproject\.toml|requirements.*\.txt|pytest\.ini|tox\.ini|uv\.lock|poetry\.lock)$'

    if (( ${#python_files[@]} > 0 || ${#py_meta[@]} > 0 )); then
        [[ -n "$PYTHON_BIN" ]] || { echo "ERROR: [Gate 5] Python required." >&2; exit 1; }
        live_py=()
        for f in "${python_files[@]+"${python_files[@]}"}"; do
            if [[ -f "$f" ]]; then
                live_py+=("$f")
            fi
        done

        if (( ${#live_py[@]} > 0 )); then
            ruff_cmd=()
            if [[ -n "$PYTHON_BIN" ]] && "$PYTHON_BIN" -m ruff --version >/dev/null 2>&1; then
                ruff_cmd=("$PYTHON_BIN" -m ruff)
            elif command -v ruff >/dev/null 2>&1; then
                ruff_cmd=(ruff)
            fi
            if (( ${#ruff_cmd[@]} > 0 )); then
                log "[Gate 5] Ruff checking Python files"
                ruff_rc=0
                "${ruff_cmd[@]}" format --check -- "${live_py[@]}" || ruff_rc=1
                "${ruff_cmd[@]}" check -- "${live_py[@]}" || ruff_rc=1
                if (( ruff_rc != 0 )); then
                    echo "ERROR: [Gate 5] Ruff checks failed." >&2
                    exit 1
                fi
            else
                log "[Gate 5] Ruff not found; skipping static checks"
            fi
        fi

        if [[ -d "tests" ]] && find tests -type f \( -name 'test_*.py' -o -name '*_test.py' \) -print -quit | grep -q .; then
            # Mirror ruff: skip gracefully if pytest is not installed, instead of
            # crashing with a raw "No module named pytest" under `set -e`.
            if "$PYTHON_BIN" -m pytest --version >/dev/null 2>&1; then
                log "[Gate 5] Running pytest"
                run_timed "$PYTEST_TIMEOUT" "$PYTHON_BIN" -m pytest tests/ -q "${pytest_extra[@]+"${pytest_extra[@]}"}"
            else
                log "[Gate 5] pytest not found; skipping tests (install pytest to run them)"
            fi
        fi
    fi
fi

# ── Gate 6: Terraform ─────────────────────────────────────────
if [[ "$FAST" == "true" ]]; then
    log "[Gate 6] Skipped (--fast)"
else
    tf_changed_paths=()
    filter_scope tf_changed_paths '(\.tf$|\.tf\.json$|\.terraform\.lock\.hcl$)'
    tfvars_files=()
    filter_scope tfvars_files '\.tfvars'
    real_tfvars=()
    for f in "${tfvars_files[@]+"${tfvars_files[@]}"}"; do
        case "$f" in *.tfvars.example|*.tfvars.sample) continue ;; *) real_tfvars+=("$f") ;; esac
    done
    if (( ${#real_tfvars[@]} > 0 )); then
        echo "ERROR: [Gate 6] Terraform variable files must never be committed:" >&2
        printf '  %s\n' "${real_tfvars[@]}" >&2
        exit 1
    fi

    if [[ -n "${TERRAFORM_DIR:-}" && ! -d "$TERRAFORM_DIR" ]]; then
        echo "ERROR: [Gate 6] --terraform-dir '$TERRAFORM_DIR' is not a directory." >&2
        exit 1
    fi

    if (( ${#tf_changed_paths[@]} > 0 )); then
        command -v terraform >/dev/null 2>&1 || { echo "ERROR: [Gate 6] terraform required." >&2; exit 1; }

        if [[ -n "${TERRAFORM_DIR:-}" ]]; then
            for f in "${tf_changed_paths[@]}"; do
                case "$f" in
                    "$TERRAFORM_DIR"|"$TERRAFORM_DIR"/*) ;;
                    *) log "[Gate 6] WARNING: changed '$f' is outside --terraform-dir=$TERRAFORM_DIR" ;;
                esac
            done
        fi

        tf_fmt_files=()
        for f in "${tf_changed_paths[@]}"; do
            if [[ -f "$f" && "$f" == *.tf ]]; then
                tf_fmt_files+=("$f")
            fi
        done

        # Format-check only the .tf files in this diff so an unrelated
        # unformatted file in the same module cannot fail this PR.
        if (( ${#tf_fmt_files[@]} > 0 )); then
            terraform fmt -check -diff "${tf_fmt_files[@]}"
        fi

        if [[ "$TERRAFORM_VALIDATE" == "true" ]]; then
            log "[Gate 6] Running terraform validate (TERRAFORM_VALIDATE=true)"
            declare -A tf_validate_dirs=()
            if [[ -n "${TERRAFORM_DIR:-}" ]]; then
                tf_validate_dirs["$TERRAFORM_DIR"]=1
            else
                for f in "${tf_changed_paths[@]}"; do
                    [[ -f "$f" ]] || continue
                    tf_validate_dirs["$(dirname "$f")"]=1
                done
            fi

            if (( ${#tf_validate_dirs[@]} > 0 )); then
                for d in "${!tf_validate_dirs[@]}"; do
                    if ! (
                        cd "$d" || exit 1
                        export AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock AWS_DEFAULT_REGION=us-east-1
                        export TF_DATA_DIR
                        TF_DATA_DIR="$(mktemp -d)"
                        trap 'rm -rf -- "$TF_DATA_DIR"' EXIT

                        lock_args=()
                        if [[ -f ".terraform.lock.hcl" ]]; then
                            lock_args+=("-lockfile=readonly")
                        fi

                        init_log="$(mktemp "$RUN_TMP/init.XXXXXX")"
                        if ! run_timed 180 terraform init -backend=false -input=false -upgrade=false "${lock_args[@]+"${lock_args[@]}"}" >"$init_log" 2>&1; then
                            echo "ERROR: [Gate 6] terraform init failed in $d" >&2
                            tail -n 40 "$init_log" >&2
                            exit 1
                        fi
                        run_timed 120 terraform validate -no-color || {
                            echo "ERROR: [Gate 6] terraform validate failed in $d" >&2
                            exit 1
                        }
                    ); then
                        echo "ERROR: [Gate 6] terraform validate failed in $d" >&2
                        exit 1
                    fi
                done
            fi
        else
            log "[Gate 6] terraform validate skipped (set TERRAFORM_VALIDATE=true to enable)"
        fi
    fi
fi

# ── Gate 7: Documentation sync ────────────────────────────────
if [[ ! -f "scripts/sync-docs.sh" ]]; then
    echo "ERROR: [Gate 7] scripts/sync-docs.sh is missing. Pack is incomplete." >&2
    exit 1
fi
log "[Gate 7] Verifying documentation synchronization"
bash scripts/sync-docs.sh --check

# ── Gate 8: Secret scanning ───────────────────────────────────
SECRET_RE='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|BEGIN [A-Z0-9 ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}'

scan_file_secrets() {
    local file="$1" label="${2:-$1}"
    [[ -f "$file" ]] || return 0
    if grep -Eqi "$SECRET_RE" "$file"; then
        echo "ERROR: [Gate 8] $label contains a secret" >&2
        exit 1
    fi
    return 0
}

scan_handover_secrets() {
    if [[ -f "$HANDOVER_PATH" ]]; then
        scan_file_secrets "$HANDOVER_PATH" "$HANDOVER_PATH (working tree)"
    fi
    if git rev-parse --verify --quiet ":${HANDOVER_PATH}" >/dev/null 2>&1; then
        local staged_h
        staged_h="$(make_tmp_file)"
        git show ":${HANDOVER_PATH}" > "$staged_h"
        if [[ ! -f "$HANDOVER_PATH" ]] || ! cmp -s "$HANDOVER_PATH" "$staged_h"; then
            scan_file_secrets "$staged_h" "$HANDOVER_PATH (staged)"
        fi
    fi
    return 0
}

if [[ "${CI:-false}" == "true" ]]; then
    command -v gitleaks >/dev/null 2>&1 || { echo "ERROR: [Gate 8] gitleaks required in CI." >&2; exit 1; }
    ref_type="$(git cat-file -t "$BASE_REF" 2>/dev/null || echo invalid)"
    if [[ "$ref_type" == "commit" ]]; then
        if [[ "${GITHUB_EVENT_NAME:-}" == "push" && ! "$BASE_REF" =~ ^0+$ ]]; then
            gitleaks detect --redact --log-opts="${BASE_REF}..HEAD"
        else
            gitleaks detect --redact --log-opts="${BASE_REF}...HEAD"
        fi
    elif [[ "$ref_type" == "tree" ]]; then
        log "[Gate 8] Bootstrap commit — scanning full history reachable from HEAD"
        gitleaks detect --redact --log-opts="HEAD"
    fi
else
    if command -v gitleaks >/dev/null 2>&1; then
        staged_count="$(git diff --cached --name-only | wc -l | tr -d ' ')"
        if (( staged_count > 0 )); then
            gitleaks protect --staged --redact --verbose
        else
            log "[Gate 8] No staged files to scan"
        fi
    else
        echo "[Gate 8] WARNING: gitleaks not installed; fallback scans the full staged blob (not just the hunk) and will miss unstaged / historical secrets"
        staged=("${all_scoped[@]+"${all_scoped[@]}"}")
        hits=()
        for f in "${staged[@]+"${staged[@]}"}"; do
            case "$f" in *.lock|*.min.js|*.map) continue ;; esac
            # Deleted paths have no staged blob.
            git rev-parse --verify --quiet ":$f" >/dev/null 2>&1 || continue
            if git show ":$f" 2>/dev/null | grep -Eqi "$SECRET_RE"; then
                hits+=("$f")
            fi
        done
        if (( ${#hits[@]} > 0 )); then
            echo "ERROR: [Gate 8] Fallback scan found probable secrets in:" >&2
            printf '  %s\n' "${hits[@]}" >&2; exit 1
        fi
    fi
fi

scan_handover_secrets
echo "=== All quality gates passed successfully ==="
