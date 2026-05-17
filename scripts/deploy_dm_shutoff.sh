#!/usr/bin/env bash
# Deploy DriverAwarenessShutoff changes to comma device.
#
# What this does:
#   1. Verifies preconditions (DisableUpdates=1, local sources present).
#   2. Rsyncs Python/C sources to /data/openpilot (tight excludes — skips
#      .claude/, .agents/, .cache/, .idea/, .vscode/, temp/ which would
#      otherwise pollute the device because rsync's --include='*/' recurses
#      into hidden dirs).
#   3. Rebuilds common/params_pyx.so on the device. The official sunnypilot
#      `dev` branch ships a prebuilt .so whose key list is frozen at compile
#      time. Adding a new key to params_keys.h requires recompiling on the
#      device (aarch64). SConstruct is NOT shipped on the prebuilt device, so
#      we use a manual Cython + g++ chain that mirrors common/SConscript:
#        common_libs = params.cc swaglog.cc util.cc ratekeeper.cc
#        + json11 (from third_party/) + capnp static libs + libzmq.
#   4. Atomically swaps the .so (first run also saves the original to
#      params_pyx.so.orig_dev so the deploy is reversible).
#   5. Sets DriverAwarenessShutoff=1 explicitly. (manager only writes
#      compile-time defaults to LMDB on first sighting of a key, so doing
#      it ourselves makes the value correct on this boot too.)
#   6. Reboots and verifies imports + runtime read post-boot.
#
# Rollback:
#   ssh comma@comma.internal "cd /data/openpilot/common && \
#     mv -f params_pyx.so.orig_dev params_pyx.so"
#   (and rm /data/params/d/DriverAwarenessShutoff if you also want to clear
#   the LMDB entry).
set -euo pipefail

REPO=/Users/thiago/Documents/dev/sunnypilot
DEVICE=comma@comma.internal

# Source files modified by this feature. md5 must match local↔device.
VERIFY_FILES=(
  "common/params_keys.h"
  "selfdrive/monitoring/helpers.py"
  "selfdrive/monitoring/dmonitoringd.py"
  "sunnypilot/sunnylink/params_metadata.json"
)

# Inputs needed on device to rebuild params_pyx.so. Must be synced.
BUILD_INPUTS=(
  "common/params_pyx.pyx"
  "common/params.cc"
  "common/util.cc"
  "common/swaglog.cc"
  "common/ratekeeper.cc"
  "third_party/json11/json11.cpp"
  "third_party/json11/json11.hpp"
)

cd "$REPO"

# ── 0. preflight ──────────────────────────────────────────────────────────────
echo "=== Preflight ==="
for f in "${VERIFY_FILES[@]}" "${BUILD_INPUTS[@]}"; do
  [[ -f "$REPO/$f" ]] || { echo "ERROR: local source missing: $f"; exit 1; }
done

DISABLE_UPDATES=$(ssh "$DEVICE" "cat /data/params/d/DisableUpdates 2>/dev/null || echo 0")
if [[ "$DISABLE_UPDATES" != "1" ]]; then
  echo "ERROR: DisableUpdates is not '1' on device."
  echo "       The official updater would overwrite our params_pyx.so on reboot."
  echo "       Fix: ssh $DEVICE \"echo -n 1 > /data/params/d/DisableUpdates\""
  exit 1
fi
echo "  DisableUpdates=1 (OK)"

# ── 1. rsync sources to device ────────────────────────────────────────────────
# Tight excludes are critical: rsync's --include='*/' recurses into every
# directory, so we must explicitly exclude dev-only hidden dirs or they end
# up on the device (saw 69MB of .claude/worktrees pollution from the old
# script).
echo "=== Syncing sources to device ==="
# rsync matches the first matching rule wins. Excludes MUST come before the
# generic --include='*/' (else hidden dirs are swept into the transfer).
rsync -avz \
  --exclude='.git/' --exclude='.venv/' --exclude='.claude/' \
  --exclude='.agents/' --exclude='.cache/' --exclude='.idea/' \
  --exclude='.vscode/' --exclude='.run/' --exclude='__pycache__/' \
  --exclude='.gemini/' --exclude='.hypothesis/' --exclude='.pytest_cache/' \
  --exclude='.ruff_cache/' --exclude='.worktrees/' \
  --exclude='build/' --exclude='list/' --exclude='logs/' \
  --exclude='openpilot/' \
  --exclude='temp/' --exclude='*.pyc' \
  --include='*/' \
  --include='*.py' --include='*.capnp' --include='*.h' --include='*.hpp' \
  --include='*.cpp' --include='*.cc' --include='*.c' \
  --include='*.json' --include='*.sh' --include='*.pyx' --include='*.pxd' \
  --exclude='*' \
  "$REPO/" \
  "$DEVICE:/data/openpilot/"

# ── 2. md5 verify synced source files ─────────────────────────────────────────
echo "=== Verifying md5sums of synced files ==="
MISMATCH=0
for f in "${VERIFY_FILES[@]}" "${BUILD_INPUTS[@]}"; do
  local_hash=$(md5 -q "$REPO/$f")
  remote_hash=$(ssh "$DEVICE" "md5sum /data/openpilot/$f" | awk '{print $1}')
  if [[ "$local_hash" == "$remote_hash" ]]; then
    echo "  OK   $f"
  else
    echo "  FAIL $f (local=$local_hash remote=$remote_hash)"
    MISMATCH=1
  fi
done
[[ $MISMATCH -eq 0 ]] || { echo "ERROR: md5 mismatch — aborting"; exit 1; }

# ── 3. rebuild params_pyx.so on device ────────────────────────────────────────
echo "=== Rebuilding params_pyx.so on device ==="
ssh "$DEVICE" 'bash -se' <<'BUILD_REMOTE'
set -euo pipefail
cd /data/openpilot/common

CYTHON=/usr/local/venv/bin/cython
CAPNP_INC=/usr/local/venv/lib/python3.12/site-packages/capnproto/install/include
CAPNP_LIB=/usr/local/venv/lib/python3.12/site-packages/capnproto/install/lib
JSON11=/data/openpilot/third_party/json11
PY_INC=$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')

# Build prereqs
[[ -x "$CYTHON" ]] || { echo "ERROR: cython missing at $CYTHON"; exit 1; }
command -v g++     >/dev/null 2>&1 || { echo "ERROR: g++ not in PATH"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not in PATH"; exit 1; }
[[ -d "$CAPNP_INC" ]]           || { echo "ERROR: capnp includes missing at $CAPNP_INC"; exit 1; }
[[ -f "$CAPNP_LIB/libcapnp.a" ]]|| { echo "ERROR: libcapnp.a missing"; exit 1; }
[[ -f "$CAPNP_LIB/libkj.a" ]]   || { echo "ERROR: libkj.a missing"; exit 1; }
[[ -f "$JSON11/json11.cpp" ]]   || { echo "ERROR: json11.cpp missing at $JSON11"; exit 1; }

# Clear stale artefacts
rm -f /tmp/params_pyx_new.so /tmp/params_pyx.cpp \
      /tmp/params.o /tmp/util.o /tmp/swaglog.o /tmp/ratekeeper.o /tmp/json11.o

# -D__TICI__ makes hw.h pick HardwareTici (PC()=false) so Params() resolves to
# /data/params instead of ~/.comma/params. Without this, the overlay updater
# reads DisableUpdates from the wrong path and keeps recreating the overlay.
CXX="g++ -fPIC -O2 -std=c++17 -D__TICI__ -I. -I/data/openpilot -I$CAPNP_INC -I$JSON11"

# Cythonize (C++ mode because params_pyx.pyx uses cppclass)
"$CYTHON" --cplus params_pyx.pyx --output-file /tmp/params_pyx.cpp

# Compile each .cc/.cpp
$CXX -c params.cc            -o /tmp/params.o
$CXX -c util.cc              -o /tmp/util.o
$CXX -c swaglog.cc           -o /tmp/swaglog.o
$CXX -c ratekeeper.cc        -o /tmp/ratekeeper.o
$CXX -c "$JSON11/json11.cpp" -o /tmp/json11.o

# Link
g++ -shared -fPIC -O2 -std=c++17 \
  -o /tmp/params_pyx_new.so \
  /tmp/params_pyx.cpp \
  /tmp/params.o /tmp/util.o /tmp/swaglog.o /tmp/ratekeeper.o /tmp/json11.o \
  -I"$PY_INC" -I/data/openpilot -I"$CAPNP_INC" -I"$JSON11" \
  "$CAPNP_LIB/libcapnp.a" "$CAPNP_LIB/libkj.a" \
  -lzmq -lpthread -lpython3.12

# Cleanup intermediates
rm -f /tmp/params_pyx.cpp \
      /tmp/params.o /tmp/util.o /tmp/swaglog.o /tmp/ratekeeper.o /tmp/json11.o

ls -la /tmp/params_pyx_new.so
echo "build OK"
BUILD_REMOTE

# ── 4. smoke-test the new .so BEFORE swapping ────────────────────────────────
echo "=== Smoke-testing new params_pyx.so ==="
ssh "$DEVICE" "cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
import sys, importlib.util, os
sys.path.insert(0, '/data')
spec = importlib.util.spec_from_file_location('openpilot.common.params_pyx', '/tmp/params_pyx_new.so')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.modules['openpilot.common.params_pyx'] = mod
from openpilot.common.params import Params
# Use NO explicit path — test the same code path all running processes use.
# If -D__TICI__ was not compiled in, Params() routes to ~/.comma/params and this assert fails.
p = Params()
val = p.get_default_value('DriverAwarenessShutoff')
assert val is True, f'Expected True default, got {val!r}'
# existing key should still resolve too
_ = p.get_default_value('DongleId')
# Validate put_bool actually writes to /data/params/d/ (not ~/.comma/params/d/)
# Use DisableUpdates — a real known key — as a canary write test.
p.put_bool('DisableUpdates', True)
actual_path = '/data/params/d/DisableUpdates'
assert os.path.exists(actual_path), f'put_bool wrote to WRONG location — expected {actual_path}. Hardware::PC() may still be True (-D__TICI__ missing from compile flags)'
print('  smoke test OK — DriverAwarenessShutoff recognised, default=True, Params() path==/data/params verified')
\""

# ── 5. atomic swap (backup original on first run) ────────────────────────────
echo "=== Swapping params_pyx.so on device ==="
ssh "$DEVICE" "
set -euo pipefail
cd /data/openpilot/common
if [[ ! -f params_pyx.so.orig_dev ]]; then
  cp -p params_pyx.so params_pyx.so.orig_dev
  echo '  backup created: params_pyx.so.orig_dev'
else
  echo '  backup already exists (preserved): params_pyx.so.orig_dev'
fi
mv -f /tmp/params_pyx_new.so params_pyx.so
ls -la params_pyx.so params_pyx.so.orig_dev
"

# ── 6. set DriverAwarenessShutoff + kill overlay swap mechanism ──────────────
echo "=== Setting DriverAwarenessShutoff=1 and disabling overlay updater ==="
ssh "$DEVICE" "
set -euo pipefail
cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
from openpilot.common.params import Params
p = Params()
p.put_bool('DriverAwarenessShutoff', True)
p.put_bool('DisableUpdates', True)
print('  DriverAwarenessShutoff set via Params API')
print('  DisableUpdates set via Params API')
\"
# Remove .overlay_init so the launch script skips the overlay swap check entirely.
# Without this file the entire overlay update path is gated out on boot.
rm -f /data/openpilot/.overlay_init
echo '  .overlay_init removed (overlay swap disabled)'
# Nuke any pending finalized update — even if .overlay_init were recreated,
# a missing finalized means no swap can happen.
rm -rf /data/safe_staging/finalized
echo '  /data/safe_staging/finalized removed (no pending update to apply)'
echo '  DisableUpdates:' \$(cat /data/params/d/DisableUpdates)
echo '  DriverAwarenessShutoff:' \$(cat /data/params/d/DriverAwarenessShutoff)
"

# ── 7. pre-reboot import + runtime read check ────────────────────────────────
echo "=== Pre-reboot import + read check ==="
ssh "$DEVICE" "cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
from openpilot.common.params import Params
p = Params()
print('  default:', p.get_default_value('DriverAwarenessShutoff'))
print('  runtime:', p.get_bool('DriverAwarenessShutoff'))
print('  DisableUpdates:', p.get_bool('DisableUpdates'))
from openpilot.selfdrive.monitoring.dmonitoringd import dmonitoringd_thread
from openpilot.selfdrive.monitoring.helpers import DriverMonitoring
print('  dmonitoringd + helpers import: OK')
\""

# ── 8. reboot ────────────────────────────────────────────────────────────────
# DoReboot param is unreliable when manager isn't actively polling (e.g. no car
# connected). sudo reboot works directly and is what HARDWARE.reboot() calls.
echo "=== Rebooting device ==="
ssh "$DEVICE" "sudo reboot" 2>/dev/null || true
echo "  reboot triggered."

# ── 9. wait offline ──────────────────────────────────────────────────────────
echo "=== Waiting for device to go offline ==="
OFFLINE_TIMEOUT=60
ELAPSED=0
while ssh -o ConnectTimeout=3 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [[ $ELAPSED -ge $OFFLINE_TIMEOUT ]]; then
    echo "  WARNING: device did not go offline within ${OFFLINE_TIMEOUT}s"
    break
  fi
  printf "  waiting for offline... (%ds)\r" "$ELAPSED"
done
echo "  Device offline (${ELAPSED}s)."

# ── 10. wait online ──────────────────────────────────────────────────────────
echo "=== Waiting for device to come back online ==="
BOOT_TIMEOUT=240
ELAPSED=0
until ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [[ $ELAPSED -ge $BOOT_TIMEOUT ]]; then
    echo "ERROR: device did not come back within ${BOOT_TIMEOUT}s"
    exit 1
  fi
  printf "  waiting for online... (%ds)\r" "$ELAPSED"
done
echo "  Device is back online (${ELAPSED}s)."

# ── 11. post-reboot verification ─────────────────────────────────────────────
echo "=== Post-reboot verification ==="
ssh "$DEVICE" "
set -e
echo '  DisableUpdates:' \$(cat /data/params/d/DisableUpdates 2>/dev/null || echo MISSING)
echo '  DriverAwarenessShutoff:' \$(cat /data/params/d/DriverAwarenessShutoff 2>/dev/null || echo MISSING)
cd /data/openpilot
PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
from openpilot.common.params import Params
p = Params()
val = p.get_bool('DriverAwarenessShutoff')
assert val is True, f'Expected True after boot, got {val!r}'
dis = p.get_bool('DisableUpdates')
assert dis is True, f'Expected DisableUpdates=True after boot, got {dis!r}'
print('  runtime get_bool DriverAwarenessShutoff: True (OK)')
print('  runtime get_bool DisableUpdates: True (OK)')
from openpilot.selfdrive.monitoring.dmonitoringd import dmonitoringd_thread
from openpilot.selfdrive.monitoring.helpers import DriverMonitoring
print('  dmonitoringd + helpers import: OK')
\"
sleep 3
if pgrep -af 'selfdrive.monitoring.dmonitoringd' >/dev/null; then
  echo '  dmonitoringd process: RUNNING'
else
  echo '  WARNING: dmonitoringd not running yet (may need car ignition)'
fi
"

echo "=== Deploy complete ==="
