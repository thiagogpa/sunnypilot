# Test Comparison Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a two-worktree test comparison tool that runs the full pytest suite on baseline commit `18406e77ee` and latest commit `c6d5d89ea7`, then diffs the JUnit XML results to surface regressions, fixes, and new tests.

**Architecture:** A shell orchestrator (`compare_tests.sh`) creates two git worktrees, runs pytest with `--junit-xml` in each, then calls a Python script (`diff_test_results.py`) that parses both XMLs with stdlib `xml.etree` and prints a markdown report. Both XMLs are written to the main repo's `tools/test_results/` directory so path references are consistent.

**Tech Stack:** bash, Python 3 stdlib (`xml.etree.ElementTree`), pytest `--junit-xml`, git worktrees

---

## Files

| Action | Path | Purpose |
|--------|------|---------|
| Modify | `.gitignore` | Add `tools/test_results/` |
| Create | `tools/test_results/.gitkeep` | Keep directory in tree |
| Create | `tools/diff_test_results.py` | Parse and diff JUnit XMLs |
| Create | `tools/compare_tests.sh` | Orchestrate worktrees + runs |

---

## Task 1: Add `tools/test_results/` to `.gitignore`

**Files:**
- Modify: `.gitignore`
- Create: `tools/test_results/.gitkeep`

- [ ] **Step 1: Add gitignore entry**

Open `.gitignore` and add after the `.worktrees/` line (line 97):

```
tools/test_results/
```

- [ ] **Step 2: Create the directory with a placeholder**

```bash
mkdir -p tools/test_results
touch tools/test_results/.gitkeep
```

The `.gitkeep` file itself is NOT gitignored (it's tracked). Only the XML files inside will be ignored.

Wait — if the directory is in `.gitignore`, `.gitkeep` won't be tracked either. Instead: do NOT add `tools/test_results/` to `.gitignore`. Add `tools/test_results/*.xml` instead, so the directory and `.gitkeep` are tracked but the XML outputs are not.

Correct `.gitignore` entry to add:

```
tools/test_results/*.xml
```

- [ ] **Step 3: Verify**

```bash
echo "test" > tools/test_results/baseline.xml
git status tools/test_results/
# Expected: baseline.xml NOT shown (ignored), .gitkeep shown as new file
rm tools/test_results/baseline.xml
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore tools/test_results/.gitkeep
git commit -m "chore: add tools/test_results dir for test comparison XML output"
```

---

## Task 2: Write `tools/diff_test_results.py`

**Files:**
- Create: `tools/diff_test_results.py`

- [ ] **Step 1: Create the file with the full implementation**

```python
#!/usr/bin/env python3
"""Compare two pytest JUnit XML results and report regressions, fixes, and new tests.

Usage:
    python tools/diff_test_results.py <baseline.xml> <latest.xml>
"""

import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

BASELINE_COMMIT = "18406e77ee"
LATEST_COMMIT = "c6d5d89ea7"


def parse_xml(path: str) -> dict:
  """Parse JUnit XML, return {test_id: status}.

  Status is one of: 'pass', 'fail', 'error', 'skip'.
  Test ID is '{classname}::{name}' as produced by pytest.
  """
  tree = ET.parse(path)
  root = tree.getroot()
  results = {}
  for tc in root.findall('.//testcase'):
    classname = tc.get('classname', '')
    name = tc.get('name', '')
    test_id = f"{classname}::{name}" if classname else name
    if tc.find('failure') is not None:
      status = 'fail'
    elif tc.find('error') is not None:
      status = 'error'
    elif tc.find('skipped') is not None:
      status = 'skip'
    else:
      status = 'pass'
    results[test_id] = status
  return results


def compare(baseline: dict, latest: dict) -> dict:
  """Categorize each test ID by how its status changed between runs."""
  all_ids = set(baseline) | set(latest)
  categories = defaultdict(list)
  for tid in sorted(all_ids):
    b = baseline.get(tid)
    l = latest.get(tid)
    if b is None:
      categories['new'].append((tid, l))
    elif l is None:
      categories['removed'].append((tid, b))
    elif b == 'pass' and l in ('fail', 'error'):
      categories['regressed'].append(tid)
    elif b in ('fail', 'error') and l == 'pass':
      categories['fixed'].append(tid)
    elif b == 'pass' and l == 'pass':
      categories['stable_pass'].append(tid)
    elif b in ('fail', 'error') and l in ('fail', 'error'):
      categories['stable_fail'].append(tid)
    else:
      # skip in either run — treat as neutral
      categories['stable_pass'].append(tid)
  return dict(categories)


def print_report(categories: dict) -> None:
  """Print markdown-formatted comparison report to stdout."""
  def count(cat):
    return len(categories.get(cat, []))

  print(f"## Test Comparison: baseline ({BASELINE_COMMIT}) → latest ({LATEST_COMMIT})")
  print()
  print("### Summary")
  print("| Category        | Count |")
  print("|-----------------|-------|")
  rows = [
    ('regressed',   'Regressed       '),
    ('fixed',       'Fixed           '),
    ('new',         'New (latest)    '),
    ('removed',     'Removed         '),
    ('stable_pass', 'Stable pass     '),
    ('stable_fail', 'Stable fail     '),
  ]
  for cat, label in rows:
    print(f"| {label} | {count(cat):5} |")

  if categories.get('regressed'):
    print()
    print("### Regressions (passed → failed)")
    for tid in categories['regressed']:
      print(f"- {tid}")

  if categories.get('fixed'):
    print()
    print("### Fixed (failed → passed)")
    for tid in categories['fixed']:
      print(f"- {tid}")

  if categories.get('new'):
    print()
    print("### New tests in latest")
    for tid, status in categories['new']:
      icon = "PASS" if status == 'pass' else "FAIL"
      print(f"- {icon} {tid}")

  if categories.get('removed'):
    print()
    print("### Removed tests (only in baseline)")
    for tid, status in categories['removed']:
      print(f"- {tid}")

  if categories.get('stable_fail'):
    print()
    print("### Pre-existing failures (failed in both)")
    for tid in categories['stable_fail']:
      print(f"- {tid}")


def main():
  if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <baseline.xml> <latest.xml>", file=sys.stderr)
    sys.exit(1)

  baseline_path, latest_path = sys.argv[1], sys.argv[2]

  try:
    baseline = parse_xml(baseline_path)
  except FileNotFoundError:
    print(f"ERROR: baseline XML not found: {baseline_path}", file=sys.stderr)
    sys.exit(2)
  except ET.ParseError as e:
    print(f"ERROR: baseline XML parse error: {e}", file=sys.stderr)
    sys.exit(2)

  try:
    latest = parse_xml(latest_path)
  except FileNotFoundError:
    print(f"ERROR: latest XML not found: {latest_path}", file=sys.stderr)
    sys.exit(2)
  except ET.ParseError as e:
    print(f"ERROR: latest XML parse error: {e}", file=sys.stderr)
    sys.exit(2)

  categories = compare(baseline, latest)
  print_report(categories)

  # Exit 1 if there are regressions so CI can catch them
  if categories.get('regressed'):
    sys.exit(1)


if __name__ == '__main__':
  main()
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tools/diff_test_results.py
```

- [ ] **Step 3: Smoke test with synthetic XML**

Create a quick inline test to verify parse + compare logic:

```bash
python3 - <<'EOF'
import sys
sys.path.insert(0, 'tools')

# Write two tiny synthetic XML files
import tempfile, os

BASELINE_XML = """<?xml version="1.0" ?>
<testsuites>
  <testsuite name="pytest" tests="3">
    <testcase classname="test_mod.TestA" name="test_pass"/>
    <testcase classname="test_mod.TestA" name="test_fail"><failure message="x"/></testcase>
    <testcase classname="test_mod.TestA" name="test_only_baseline"/>
  </testsuite>
</testsuites>"""

LATEST_XML = """<?xml version="1.0" ?>
<testsuites>
  <testsuite name="pytest" tests="3">
    <testcase classname="test_mod.TestA" name="test_pass"/>
    <testcase classname="test_mod.TestA" name="test_fail"/>
    <testcase classname="test_mod.TestA" name="test_new"/>
  </testsuite>
</testsuites>"""

with tempfile.NamedTemporaryFile('w', suffix='.xml', delete=False) as f:
  f.write(BASELINE_XML); bpath = f.name
with tempfile.NamedTemporaryFile('w', suffix='.xml', delete=False) as f:
  f.write(LATEST_XML); lpath = f.name

import importlib.util
spec = importlib.util.spec_from_file_location("diff", "tools/diff_test_results.py")
mod = importlib.util.load_from_spec(spec)
spec.loader.exec_module(mod)

b = mod.parse_xml(bpath)
l = mod.parse_xml(lpath)
cats = mod.compare(b, l)

assert cats['fixed'] == ['test_mod.TestA::test_fail'], f"fixed: {cats.get('fixed')}"
assert len(cats['new']) == 1 and cats['new'][0][0] == 'test_mod.TestA::test_new'
assert len(cats['removed']) == 1 and cats['removed'][0][0] == 'test_mod.TestA::test_only_baseline'
assert 'test_mod.TestA::test_pass' in cats['stable_pass']
print("All assertions passed ✓")

os.unlink(bpath); os.unlink(lpath)
EOF
```

Expected output: `All assertions passed ✓`

- [ ] **Step 4: Commit**

```bash
git add tools/diff_test_results.py
git commit -m "feat(tools): add diff_test_results.py to compare JUnit XML test runs"
```

---

## Task 3: Write `tools/compare_tests.sh`

**Files:**
- Create: `tools/compare_tests.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# compare_tests.sh — Run full pytest suite on two commits and diff the results.
#
# Creates two git worktrees (baseline and latest), runs pytest with --junit-xml
# in each, then calls diff_test_results.py to print a markdown comparison report.
#
# Usage: bash tools/compare_tests.sh
set -euo pipefail

BASELINE_COMMIT="18406e77ee"
LATEST_COMMIT="c6d5d89ea7"

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TOOLS_DIR="$REPO_ROOT/tools"
RESULTS_DIR="$REPO_ROOT/tools/test_results"
WORKTREE_BASE="$REPO_ROOT/.worktrees"

BASELINE_DIR="$WORKTREE_BASE/baseline"
LATEST_DIR="$WORKTREE_BASE/latest"
BASELINE_XML="$RESULTS_DIR/baseline.xml"
LATEST_XML="$RESULTS_DIR/latest.xml"

# Same exclusions as run_all_tests_summary.py
DESELECT=(
  --deselect "selfdrive/controls/tests/test_leads.py"
  --deselect "selfdrive/locationd/test/test_locationd_scenarios.py"
  --deselect "common/tests/test_file_helpers.py::test_read_file"
  --deselect "common/tests/test_file_helpers.py::test_create_directories"
  --deselect "common/tests/test_file_helpers.py::test_file_exists"
  --deselect "system/athena/tests/test_athenad.py"
  --deselect "common/tests/test_common"
  --deselect "system/loggerd/tests/test_uploader.py"
  --deselect "system/loggerd/tests/test_logger"
  --deselect "cereal/messaging/tests/test_messaging.py::TestMessaging::test_recv_one_retry"
  --deselect "system/updated/tests/test_git.py"
  --deselect "tools/sim/tests/test_metadrive_bridge.py"
  --deselect "cereal/messaging/tests/test_pub_sub_master.py::TestSubMaster::test_update_timeout"
  --deselect "selfdrive/test/longitudinal_maneuvers/test_longitudinal.py"
  --deselect "system/athena/tests/test_athenad.py::TestAthenadMethods::test_start_local_proxy"
  --deselect "selfdrive/car/tests/test_models.py::TestCarModelBase::test_panda_safety_carstate_fuzzy"
)

cleanup() {
  echo ""
  echo "Cleaning up worktrees..."
  git -C "$REPO_ROOT" worktree remove --force "$BASELINE_DIR" 2>/dev/null || true
  git -C "$REPO_ROOT" worktree remove --force "$LATEST_DIR"   2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$RESULTS_DIR"

# ── Baseline worktree ────────────────────────────────────────────────────────
echo "==> Creating baseline worktree at $BASELINE_COMMIT"
git -C "$REPO_ROOT" worktree remove --force "$BASELINE_DIR" 2>/dev/null || true
git -C "$REPO_ROOT" worktree add "$BASELINE_DIR" "$BASELINE_COMMIT"

echo "==> Initialising submodules in baseline"
git -C "$BASELINE_DIR" submodule update --init --recursive

echo "==> Running tests in baseline"
cd "$BASELINE_DIR"
set +e
"$REPO_ROOT/.venv/bin/python" -m pytest -v -n auto --dist loadgroup \
  --junit-xml="$BASELINE_XML" \
  "${DESELECT[@]}"
set -e
cd "$REPO_ROOT"

# ── Latest worktree ──────────────────────────────────────────────────────────
echo ""
echo "==> Creating latest worktree at $LATEST_COMMIT"
git -C "$REPO_ROOT" worktree remove --force "$LATEST_DIR" 2>/dev/null || true
git -C "$REPO_ROOT" worktree add "$LATEST_DIR" "$LATEST_COMMIT"

echo "==> Initialising submodules in latest"
git -C "$LATEST_DIR" submodule update --init --recursive

echo "==> Running tests in latest"
cd "$LATEST_DIR"
set +e
"$REPO_ROOT/.venv/bin/python" -m pytest -v -n auto --dist loadgroup \
  --junit-xml="$LATEST_XML" \
  "${DESELECT[@]}"
set -e
cd "$REPO_ROOT"

# ── Comparison ───────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  COMPARISON REPORT"
echo "================================================================"
echo ""

if [[ ! -f "$BASELINE_XML" ]]; then
  echo "ERROR: baseline XML missing — pytest likely crashed entirely" >&2
  exit 3
fi
if [[ ! -f "$LATEST_XML" ]]; then
  echo "ERROR: latest XML missing — pytest likely crashed entirely" >&2
  exit 3
fi

python3 "$TOOLS_DIR/diff_test_results.py" "$BASELINE_XML" "$LATEST_XML" || true
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tools/compare_tests.sh
```

- [ ] **Step 3: Dry-run check — verify script parses without errors**

```bash
bash -n tools/compare_tests.sh
echo "Syntax OK"
```

Expected: `Syntax OK`

- [ ] **Step 4: Commit**

```bash
git add tools/compare_tests.sh
git commit -m "feat(tools): add compare_tests.sh orchestrator for two-commit test diff"
```

---

## Task 4: Full Integration Run

**Files:** (no changes — this is execution only)

- [ ] **Step 1: Run the comparison**

This will take 10–30 minutes (two full pytest suites). Run from repo root:

```bash
bash tools/compare_tests.sh 2>&1 | tee tools/test_results/compare_run.log
```

The `tee` saves the full output to a log file for later review.

- [ ] **Step 2: Verify XML files were produced**

```bash
ls -lh tools/test_results/
# Expected: baseline.xml and latest.xml both present, non-empty
```

- [ ] **Step 3: Re-run comparison standalone if needed**

If you want to re-run just the diff without re-running tests:

```bash
python3 tools/diff_test_results.py \
  tools/test_results/baseline.xml \
  tools/test_results/latest.xml
```

- [ ] **Step 4: Review the report**

Check for:
- **Regressions**: any tests that passed on baseline but fail on latest — these need investigation
- **New tests**: should see all our new tests (DM bypass, brake hold, subarucan) in the "New (latest)" section, all PASS
- **Stable fail**: pre-existing failures (e.g. `test_fw_version_format`) — confirm these match known issues

- [ ] **Step 5: Commit the log (optional)**

If you want to keep the run log:

```bash
# Add exception for the log file in .gitignore or commit directly
git add -f tools/test_results/compare_run.log
git commit -m "chore: add test comparison run log"
```

---

## Self-Review

**Spec coverage check:**
- ✅ Two worktrees at baseline + latest — Task 3
- ✅ `git submodule update --init --recursive` in each — Task 3
- ✅ Same exclusions as `run_all_tests_summary.py` — Task 3 (DESELECT array matches exactly)
- ✅ JUnit XML output — Task 3 (`--junit-xml`)
- ✅ XML written to main repo `tools/test_results/` — Task 3
- ✅ Python diff script — Task 2
- ✅ Report categories: regressed/fixed/new/removed/stable_pass/stable_fail — Task 2
- ✅ Markdown report format — Task 2
- ✅ Cleanup on exit via `trap` — Task 3
- ✅ Idempotent worktree creation (remove-before-add) — Task 3
- ✅ Error if XML missing after run — Task 3
- ✅ `.gitignore` for XML files — Task 1

**Placeholder scan:** None found.

**Type consistency:** `parse_xml` returns `dict`, `compare` accepts two `dict` args, `print_report` accepts `dict` — consistent throughout.
