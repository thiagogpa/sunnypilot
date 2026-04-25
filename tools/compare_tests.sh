#!/usr/bin/env bash
# compare_tests.sh — Run full pytest suite on two commits and diff the results.
#
# Creates two git worktrees (baseline and latest), runs pytest with --junit-xml
# in each, then calls diff_test_results.py to print a markdown comparison report.
#
# Usage: bash tools/compare_tests.sh [--force-baseline]
#   --force-baseline  Re-run baseline even if tools/test_results/baseline.xml exists
set -euo pipefail

BASELINE_COMMIT="18406e77ee"
LATEST_COMMIT="c6d5d89ea7"
FORCE_BASELINE="${1:-}"

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TOOLS_DIR="$REPO_ROOT/tools"
RESULTS_DIR="$REPO_ROOT/tools/test_results"
WORKTREE_BASE="$REPO_ROOT/.worktrees"

BASELINE_DIR="$WORKTREE_BASE/baseline"
LATEST_DIR="$WORKTREE_BASE/latest"
BASELINE_XML="$RESULTS_DIR/baseline.xml"
LATEST_XML="$RESULTS_DIR/latest.xml"

# Same exclusions as run_all_tests_summary.py, plus -k to exclude ALL parametrized
# variants of test_panda_safety_carstate_fuzzy (--deselect only matches the base class).
PYTEST_ARGS=(
  -v -n auto --dist loadgroup
  -k "not test_panda_safety_carstate_fuzzy"
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
)

cleanup() {
  echo ""
  echo "Cleaning up worktrees..."
  git -C "$REPO_ROOT" worktree remove --force "$BASELINE_DIR" 2>/dev/null || true
  git -C "$REPO_ROOT" worktree remove --force "$LATEST_DIR"   2>/dev/null || true
}
trap cleanup EXIT

# Symlink compiled Cython extensions from the main repo into a worktree.
# Worktrees don't have build artifacts; the .so files are identical across
# these close commits so symlinking is safe and avoids a full scons rebuild.
link_extensions() {
  local worktree="$1"
  local so_paths=(
    "common/params_pyx.so"
    "msgq_repo/msgq/ipc_pyx.so"
    "msgq_repo/msgq/ipc_pyx.cpython-312-darwin.so"
    "msgq_repo/msgq/visionipc/visionipc_pyx.so"
    "msgq_repo/msgq/visionipc/visionipc_pyx.cpython-312-darwin.so"
    "rednose_repo/rednose/helpers/ekf_sym_pyx.so"
    "rednose_repo/rednose/helpers/ekf_sym_pyx.cpython-312-darwin.so"
    "selfdrive/controls/lib/lateral_mpc_lib/c_generated_code/acados_ocp_solver_pyx.so"
    "selfdrive/controls/lib/longitudinal_mpc_lib/c_generated_code/acados_ocp_solver_pyx.so"
  )
  for rel in "${so_paths[@]}"; do
    src="$REPO_ROOT/$rel"
    dst="$worktree/$rel"
    if [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$dst")"
      ln -sf "$src" "$dst"
    fi
  done
}

mkdir -p "$RESULTS_DIR"

# ── Baseline worktree ────────────────────────────────────────────────────────
if [[ -f "$BASELINE_XML" && "$FORCE_BASELINE" != "--force-baseline" ]]; then
  echo "==> Skipping baseline run (XML exists). Pass --force-baseline to re-run."
else
  echo "==> Creating baseline worktree at $BASELINE_COMMIT"
  git -C "$REPO_ROOT" worktree remove --force "$BASELINE_DIR" 2>/dev/null || true
  git -C "$REPO_ROOT" worktree add "$BASELINE_DIR" "$BASELINE_COMMIT"

  echo "==> Initialising submodules in baseline"
  git -C "$BASELINE_DIR" submodule update --init --recursive

  echo "==> Linking compiled extensions to baseline worktree"
  link_extensions "$BASELINE_DIR"

  echo "==> Running tests in baseline"
  cd "$BASELINE_DIR"
  set +e
  "$REPO_ROOT/.venv/bin/python" -m pytest \
    --junit-xml="$BASELINE_XML" \
    "${PYTEST_ARGS[@]}"
  set -e
  cd "$REPO_ROOT"
fi

# ── Latest worktree ──────────────────────────────────────────────────────────
echo ""
echo "==> Creating latest worktree at $LATEST_COMMIT"
git -C "$REPO_ROOT" worktree remove --force "$LATEST_DIR" 2>/dev/null || true
git -C "$REPO_ROOT" worktree add "$LATEST_DIR" "$LATEST_COMMIT"

echo "==> Initialising submodules in latest (except opendbc_repo)"
# Explicitly list submodules to avoid the opendbc_repo fetch — that commit is
# local-only (not pushed to remote). opendbc_repo is cloned from local below.
git -C "$LATEST_DIR" submodule update --init --recursive -- \
  msgq_repo panda rednose_repo "sunnypilot/neural_network_data" teleoprtc_repo tinygrad_repo

echo "==> Cloning opendbc_repo from local (commit not pushed to remote)"
git clone --local "$REPO_ROOT/opendbc_repo" "$LATEST_DIR/opendbc_repo"

echo "==> Linking compiled extensions to latest worktree"
link_extensions "$LATEST_DIR"

echo "==> Running tests in latest"
cd "$LATEST_DIR"
set +e
"$REPO_ROOT/.venv/bin/python" -m pytest \
  --junit-xml="$LATEST_XML" \
  "${PYTEST_ARGS[@]}"
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
