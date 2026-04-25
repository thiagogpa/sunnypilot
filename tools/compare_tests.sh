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
