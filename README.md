<div align="center">

# 🛡️ Checkrail

### Deterministic Quality Gates & Hierarchical Context Scaffolding for AI Coding Agents

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI / Quality Gates](https://github.com/seyed-milad-jalilian/checkrail/actions/workflows/quality-gates.yml/badge.svg)](https://github.com/seyed-milad-jalilian/checkrail/actions/workflows/quality-gates.yml)
[![Tests](https://github.com/seyed-milad-jalilian/checkrail/actions/workflows/tests.yml/badge.svg)](https://github.com/seyed-milad-jalilian/checkrail/actions/workflows/tests.yml)
[![Bash 4.4+](https://img.shields.io/badge/Bash-4.4%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Python 3.12+](https://img.shields.io/badge/Python-3.12%2B-blue.svg)](https://www.python.org/)
[![Security: Gitleaks](https://img.shields.io/badge/Security-Gitleaks-brightgreen.svg)](https://github.com/gitleaks/gitleaks)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

*An open-source verification harness and hierarchical context scaffolding designed to enforce deterministic boundaries and multi-tier quality gates for autonomous AI coding agents.*

> **Disclaimer:** Checkrail is an independent open-source engineering project. It is not affiliated with, endorsed by, or associated with any other project, commercial platform, or trademark holder.

</div>

---

## 📌 Project Status

**Experimental (pre-1.0)**. Checkrail is under active development. Gate specifications, file formats, and runtime interfaces may evolve across releases. Use in production environments at your own discretion. No benchmark results have been published yet for token optimization claims. The gate harness is covered by scratch-repo smoke tests (`tests/run-tests.sh`) that run in CI on every push.

---

## 🔬 Scientific & Industrial Rationale

As Large Language Models (LLMs) and autonomous agent frameworks (**Kilo**, **Claude Code**, **OpenCode**, **Cursor**, **Devin**) transition from exploratory code-completion to fully autonomous codebase refactoring and CI/CD operations, they introduce critical failure modes:

1. **Context Bloat & Token Degradation (Attention Bleed)**: Recursive file-tree scanning and unfiltered context dumps exhaust attention mechanisms, increasing operational latency, API costs, and hallucination rates.
2. **Guardrail & Security Erosion**: Unconstrained agents inadvertently modify security manifests, weaken CI checks, or bypass permission boundaries.
3. **Secret Ingestion & Exfiltration**: Accidental ingestion and staging of `.env` files, SSH credentials, and private keys.
4. **Repository Documentation Drift**: Autonomous changes break manual architectural maps, invalidating agent grounding on subsequent turns.
5. **Session Amnesia & State Loss**: Fragmented state transitions between multi-turn or multi-agent worktree handovers.

**Checkrail** introduces a **multi-tiered, deterministic verification and context-management harness** that enforces formal safety boundaries and is architecturally designed to mitigate context degradation and enforce policy and quality gate compliance before code reaches review.

---

## 🏛️ Architectural Taxonomy & Core Pillars

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Layer 0: AGENTS.md (Root Invariants)                  │
│           Deterministic trigger routing • Lean L0 context routing           │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
                ┌──────────────────────┴──────────────────────┐
                ▼                                             ▼
┌───────────────────────────────┐             ┌───────────────────────────────┐
│   Layer 1: Architecture Core  │             │   Layer 2: Protocol Engine    │
│    (docs/agent/SUMMARY.md)    │             │   (docs/agent/protocol.md)    │
│  Domain context, Stack & Flow │             │   Deep workflows & fallback   │
└───────────────────────────────┘             └───────────────────────────────┘
                │                                             │
                └──────────────────────┬──────────────────────┘
                                       │
┌──────────────────────────────────────┴──────────────────────────────────────┐
│                    Automated Governance & Verification Harness              │
│  ├── 9-Tier Quality Verification (scripts/quality-gates.sh)                 │
│  ├── Zero-Drift Compact Indexing (scripts/sync-docs.sh)                     │
│  ├── Scratch-Repo Smoke Tests (tests/run-tests.sh)                          │
│  ├── Sandboxed Permission Rules (kilo.jsonc)                                │
│  ├── Guardrail Implementation Notes (docs/agent/bootstrap-audit.md)         │
│  └── Deterministic State Handover (docs/agent/HANDOVER.md)                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1. ⚡ Hierarchical Context Minimization
Checkrail discards monolithic prompts in favor of an indexed 3-layer architecture:
- **Layer 0 (`AGENTS.md`)**: Always-on routing table. Directs agents to exact files without recursive exploration.
- **Layer 1 (`docs/agent/SUMMARY.md`)**: High-level domain, stack specifications, and pipeline models.
- **Layer 2 (`docs/agent/protocol.md`)**: Deep execution workflows, loaded strictly when blocking ambiguities arise.

### 2. 🛡️ 9-Tier Quality Verification Gates (`scripts/quality-gates.sh`)
Every agent and developer change is passed through a deterministic nine-tier verification pipeline (Gate 0 – Gate 8):
* **Gate 0: Tooling Prerequisite Check** — Verifies major/minor version compliance (`.tool-versions`; patch levels are not compared).
* **Gate 1: Base Branch & Differential Scoping** — Isolates target diffs and prevents unanchored commits.
* **Gate 2: Clean Tree & Working-Copy Integrity** — Validates staging consistency and rejects untracked drift.
* **Gate 3: Protected Guardrail Defense** — Blocks agent mutations to security, CI, and policy files unless explicitly authorized with `--allow-guardrail`.
* **Gate 4: Shell Syntax & POSIX/LF Compliance** — Strict `bash -n` validation and line-ending verification.
* **Gate 5: Static Analysis & Code Quality** — Python static typing, linting (`ruff`), and QA harnesses.
* **Gate 6: Infrastructure & Configuration Verification** — Validates Terraform and cloud orchestration manifests.
* **Gate 7: Deterministic Documentation Verification** — Fails if documentation index (`docs/file-index.md`) drifts from disk state.
* **Gate 8: Anti-Leak Cryptographic & Secret Scan** — Integrated Gitleaks analysis and fallback heuristic scanning.

### 3. 📑 Zero-Drift Repository Indexing (`scripts/sync-docs.sh`)
- Generates a compact, deterministic inventory in `docs/file-index.md` from `scripts/file-descriptions.txt`.
- Provides structural grounding to agents within a bounded token budget (≤ 20 KB, enforced by `sync-docs.sh`).

### 4. 🔒 Engine Sandbox & Permission Map (`kilo.jsonc`)
- Strict deny/ask rules for destructive actions (`rm -rf`, raw `.env` reading, unconstrained shell execution).

### 5. 🔄 Bounded State Handover Protocol (`docs/agent/HANDOVER.md`)
- Bounded 40-line invariant state schema (`[TASK]`, `[DIFF_SUMMARY]`, `[GATES_STATUS]`, `[NEXT]`, `[BLOCKERS]`) providing continuous context across distributed worktrees and agent sessions.

### 6. 🧪 Scratch-Repo Smoke Tests (`tests/run-tests.sh`)
- A dependency-free Bash test suite that rebuilds disposable scratch repositories and asserts the gate boundary conditions end-to-end: protected-file modifications blocked, `--allow-guardrail` / `--ack-new-guardrail` authorization, staged symlinks rejected, HANDOVER section and line-limit enforcement, staged-secret rejection, index-drift detection, branch-name enforcement, `.tfvars` rejection, and `kilo.jsonc` semantic assertions.
- Runs in CI on every push and pull request ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)), and locally with a single command:
  ```bash
  bash tests/run-tests.sh
  ```

---

## 📋 Guardrail Implementation Notes

Checkrail documents its actually-implemented defenses — boundary scoping, protected-file and symlink defense, `kilo.jsonc` semantic assertions, HANDOVER validation, drift control, and secret scanning — together with an explicit scope statement of what is **not** claimed, in [`docs/agent/bootstrap-audit.md`](docs/agent/bootstrap-audit.md). This file is an implementation note, not a formal security audit.

### Verified by tests
The boundary behavior of every gate scenario is asserted by the scratch-repo smoke tests in [`tests/run-tests.sh`](tests/run-tests.sh):

| Scenario | Expected outcome |
|---|---|
| Clean staged change | All gates pass |
| Protected file modified (no flag) | Gate 3 blocks |
| Protected file modified (`--allow-guardrail`) | Gates pass |
| New guardrail file (no ack) | Gate 3 blocks |
| New guardrail file (`--ack-new-guardrail`) | Gates pass |
| Staged symlink at a protected path | Gate 3 blocks |
| HANDOVER missing a section / over 40 lines | Gate 2 blocks |
| Secret in a staged file | Gate 8 blocks |
| `docs/file-index.md` drift | Gate 7 blocks |
| Non-conventioned branch name | Gate 1 blocks |
| `.tfvars` file staged | Gate 6 blocks |
| `kilo.jsonc` policy-compliant / tampered | Gate 3 accepts / rejects |

---

## ⚖️ Honest Limitations

1. **Not a Formal Proof or Audit**: Checkrail enforces deterministic static checks, shell validation, and git boundaries. It does not mathematically prove the runtime semantic correctness of generated application code, and no third-party security audit has been performed.
2. **Token Metrics Are Architectural**: Token efficiency gains stem from structured context separation (L0/L1/L2) avoiding full-tree reads. Empirical benchmark quantification is ongoing and not yet published.
3. **POSIX / Linux Centric**: Checkrail is built primarily for Bash-compatible environments (Linux, macOS, WSL2). Native Windows environments without a POSIX layer are not supported.
4. **No Semantic Logic Guarantee**: The gates verify syntax, diff scope, secret absence, and structure—not whether the business logic meets user intent.
5. **Version Pinning Is major.minor**: Gate 0 compares major and minor versions only; patch-level drift of pinned tools is never enforced, even with `--strict-versions`.
6. **Test Scope Is Bounded**: The smoke tests assert gate boundary conditions in scratch repositories; they do not enumerate every possible bypass, and the local secret fallback is a heuristic regex rather than a full scanner.

---

## 🚀 Quick Start

### 1. Installation & Environment Verification
```bash
git clone https://github.com/seyed-milad-jalilian/checkrail.git
cd checkrail

# Run full diagnostic verification
bash scripts/doctor.sh
```

### 2. Pre-Commit Integration
```bash
# Register quality gates into local git hooks
pre-commit install
```

### 3. Documentation Synchronization
Whenever repository files or modules change:
```bash
# Update descriptions in scripts/file-descriptions.txt, then:
bash scripts/sync-docs.sh

# Stage the regenerated index
git add docs/file-index.md
```

### 4. Smoke Tests
```bash
# Verify gate boundary conditions in disposable scratch repositories
bash tests/run-tests.sh
```

### 5. Quality Gate Execution
```bash
# Fast-tier gate for staged changes (Pre-Commit)
bash scripts/quality-gates.sh --staged-only --fast

# Complete 9-tier verification suite (CI Equivalent)
bash scripts/quality-gates.sh
```

---

## 🛠️ Script Harness Reference

| Script | Function | Key Flags |
|---|---|---|
| `scripts/doctor.sh` | Health check for environment, dependencies, CRLF, and pack integrity. | None |
| `scripts/quality-gates.sh` | Comprehensive 9-tier automated quality and security gates. | `--staged-only`, `--fast`, `--allow-guardrail`, `--ack-new-guardrail`, `--quiet`, `--strict-versions` |
| `scripts/sync-docs.sh` | Deterministic documentation indexer and drift detector. | `--check`, `--compact`, `--full` |
| `tests/run-tests.sh` | Scratch-repo smoke tests for gate boundary conditions. | Optional name filter, e.g. `bash tests/run-tests.sh symlink` |

---

## 📂 Repository Topology

```text
checkrail/
├── .github/
│   ├── workflows/
│   │   ├── quality-gates.yml        # Production CI Verification Pipeline
│   │   └── tests.yml                # Scratch-Repo Smoke Test Pipeline
│   ├── ISSUE_TEMPLATE/              # Standardized Bug & Feature Blueprints
│   ├── PULL_REQUEST_TEMPLATE.md     # Gate-Enforced Pull Request Checklist
│   ├── dependabot.yml               # Automated Dependency & Action Updates
│   └── CODEOWNERS                   # Access & Ownership Matrix
├── .kilo/                           # Autonomous Agent Workspace & Subagent Runtime
├── docs/
│   ├── agent/
│   │   ├── SUMMARY.md               # Layer 1 Architectural Context
│   │   ├── protocol.md              # Layer 2 Execution Protocol
│   │   ├── HANDOVER.md              # Standardized State Handover File
│   │   └── bootstrap-audit.md       # Guardrail Implementation Notes & Scope
│   └── file-index.md                # Auto-Generated Compact File Inventory
├── scripts/
│   ├── doctor.sh                    # Environment Diagnostic & Health Script
│   ├── file-descriptions.txt        # Canonical File Description Register
│   ├── quality-gates.sh             # 9-Tier Security & Quality Gate Harness
│   └── sync-docs.sh                 # Zero-Drift Documentation Synchronizer
├── tests/
│   └── run-tests.sh                 # Scratch-Repo Smoke Test Suite
├── .gitattributes                   # LF Enforcement & Normalization Policy
├── .gitignore                       # Comprehensive VCS Ignore Register
├── .kilocodeignore                  # LLM Context Exclusion Filter
├── .pre-commit-config.yaml          # Pre-commit Hook Hookpack Configuration
├── .tool-versions                   # Pinned Tool Runtime Versions
├── AGENTS.md                        # Layer 0 Root Agent Rulebook & Invariants
├── CITATION.cff                     # Formal Academic Citation Metadata
├── CONTRIBUTING.md                  # Engineering & Contribution Guidelines
├── kilo.jsonc                       # Engine Security Sandbox & Permissions
├── LICENSE                          # MIT Open-Source License
├── README.md                        # Comprehensive Technical Specification
└── SECURITY.md                      # Security Vulnerability & Disclosure Policy
```

---

## 📑 Citation & Academic Reference

If you incorporate **Checkrail** in academic papers, research benchmarks, or industrial autonomous frameworks, please cite:

```bibtex
@software{jalilian2026checkrail,
  author = {Jalilian, Seyed Milad},
  title = {Checkrail: Deterministic Quality Gates and Hierarchical Context Scaffolding for AI Coding Agents},
  year = {2026},
  url = {https://github.com/seyed-milad-jalilian/checkrail},
  version = {0.1.0}
}
```

---

## 🤝 Contributing

We welcome contributions from engineers and researchers. Please review [CONTRIBUTING.md](CONTRIBUTING.md) for workflow protocols and gate standards.

---

## 🛡️ Security

For vulnerability disclosures and security policies, refer to [SECURITY.md](SECURITY.md).

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file.

Copyright (c) 2026 **Seyed Milad Jalilian**
