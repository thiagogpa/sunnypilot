# Test Comparison: Baseline vs Latest

**Date:** 2026-04-25
**Status:** Approved

## Goal

Automatically compare test results between the last upstream commit before our feature work (`18406e77ee`) and the current HEAD (`c6d5d89ea7`), identifying regressions, fixes, and new tests introduced by our changes.

## Commits

| Label    | Commit      | Description                                      |
|----------|-------------|--------------------------------------------------|
| baseline | `18406e77ee` | [MICI] ui: add sunnylink info & connectivity check (#1798) — last commit before our work |
| latest   | `c6d5d89ea7` | fix(monitoring): initialize dm_enabled — current HEAD |

## Components

### 1. `tools/compare_tests.sh` — Orchestrator

Shell script that:
1. Creates two git worktrees under `.worktrees/` (already gitignored):
   - `.worktrees/baseline` at `18406e77ee`
   - `.worktrees/latest` at `c6d5d89ea7`
2. Runs `git submodule update --init --recursive` in each worktree
3. Activates the repo `.venv` in each and runs pytest with:
   - `--junit-xml=<repo_root>/tools/test_results/baseline.xml` (or `latest.xml`)
   - Same `--deselect` exclusions as `run_all_tests_summary.py`
   - `-n auto --dist loadgroup` for parallelism
4. Calls `python tools/diff_test_results.py tools/test_results/baseline.xml tools/test_results/latest.xml`
5. Cleans up both worktrees on exit (via `trap` for Ctrl-C safety)

**Error handling:**
- If a worktree already exists, remove it first (idempotent re-runs)
- pytest non-zero exit is expected (failures captured in XML) — script continues
- If either XML is missing after the run, script exits with a clear error

### 2. `tools/diff_test_results.py` — Comparison Script

Python script that:
1. Parses both JUnit XML files using `xml.etree.ElementTree` (stdlib, no extra deps)
2. Builds a dict of `{test_id: status}` for each run (`pass` / `fail` / `error` / `skip`)
3. Categorizes each test:
   - `regressed` — passed in baseline, failed/error in latest
   - `fixed` — failed/error in baseline, passed in latest
   - `new` — present only in latest (our new tests)
   - `removed` — present only in baseline
   - `stable_pass` — passed in both
   - `stable_fail` — failed in both (pre-existing)
4. Prints a markdown-formatted report to stdout

### 3. `tools/test_results/` — Output Directory

Temporary directory for XML files. Gitignored (add to `.gitignore`).

## Data Flow

```
compare_tests.sh
├── git worktree add .worktrees/baseline 18406e77ee
├── git worktree add .worktrees/latest   c6d5d89ea7
│
├── [baseline worktree]
│   ├── git submodule update --init --recursive
│   └── pytest --junit-xml=tools/test_results/baseline.xml [exclusions]
│
├── [latest worktree]
│   ├── git submodule update --init --recursive
│   └── pytest --junit-xml=tools/test_results/latest.xml [exclusions]
│
├── python tools/diff_test_results.py baseline.xml latest.xml
│
└── cleanup worktrees
```

Both XML files are written to the **main repo root** `tools/test_results/`, not inside the worktrees, so paths are consistent regardless of which worktree is running.

## Report Format

```markdown
## Test Comparison: baseline (18406e77ee) → latest (c6d5d89ea7)

### Summary
| Category        | Count |
|-----------------|-------|
| Regressed       |   N   |
| Fixed           |   N   |
| New (latest)    |   N   |
| Removed         |   N   |
| Stable pass     |   N   |
| Stable fail     |   N   |

### Regressions (passed → failed)
- path/to/test.py::Class::test_name

### New tests in latest
- PASS path/to/test.py::Class::test_name
- FAIL path/to/test.py::Class::test_name

### Pre-existing failures (failed in both)
- path/to/test.py::Class::test_name
```

## Out of Scope

- No CI integration — this is a local developer tool
- No HTML report — stdout markdown is sufficient
- No timing comparison — just pass/fail status
