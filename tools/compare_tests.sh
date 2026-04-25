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
# Init writes .git/config entries without fetching
git -C "$LATEST_DIR" submodule init
# Override opendbc_repo URL to use local copy — the latest commit may not be
# pushed to the remote yet, but the objects are in the local repo.
git -C "$LATEST_DIR" config submodule.opendbc_repo.url "file://$REPO_ROOT/opendbc_repo/.git"
# Update all submodules (opendbc_repo clones from local, others from remote)
git -C "$LATEST_DIR" submodule update --recursive

echo "==> Linking compiled extensions to latest worktree"
link_extensions "$LATEST_DIR"

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
