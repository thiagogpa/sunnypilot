#!/usr/bin/env bash
# Deploy integration/avh-and-dm-nag to comma device in a single reboot.
#
# Combines deploy_subaru_avh.sh and deploy_dm_shutoff.sh:
#   1. Preflight (DisableUpdates=1)
#   2. Build panda firmware locally
#   3. Run Subaru brake-hold safety tests
#   4. Rsync all sources (DM-style thorough excludes)
#   5. Verify md5sums for all key files (AVH + DM)
#   6. Rebuild params_pyx.so on device (needed for DriverAwarenessShutoff key)
#   7. Smoke-test new .so before swapping
#   8. Atomic swap of params_pyx.so
#   9. Set DriverAwarenessShutoff=1 and overlay-swap guards
#  10. Pre-reboot import + read check
#  11. Single reboot
#  12. Post-reboot verification: firmware md5 + DM params + dmonitoringd
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE=comma@comma.internal
PANDA_BIN=panda/board/obj/panda_h7.bin.signed

# Files md5-verified after rsync (union of both feature scripts)
VERIFY_FILES=(
  # AVH
  "$PANDA_BIN"
  "opendbc_repo/opendbc/car/subaru/carcontroller.py"
  "opendbc_repo/opendbc/car/subaru/carstate.py"
  "opendbc_repo/opendbc/car/subaru/subarucan.py"
  "opendbc_repo/opendbc/safety/modes/subaru.h"
  "opendbc_repo/opendbc/sunnypilot/car/subaru/subarucan_ext.py"
  "opendbc_repo/opendbc/sunnypilot/car/subaru/values_ext.py"
  "opendbc_repo/opendbc/sunnypilot/car/interfaces.py"
  # DM-nag
  "common/params_keys.h"
  "selfdrive/monitoring/helpers.py"
  "selfdrive/monitoring/dmonitoringd.py"
  "sunnypilot/sunnylink/params_metadata.json"
)

# Extra files needed on device to rebuild params_pyx.so
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
  # Skip the panda binary in the local-file check — it doesn't exist until step 2
  [[ "$f" == "$PANDA_BIN" ]] && continue
  [[ -f "$REPO/$f" ]] || { echo "ERROR: local source missing: $f"; exit 1; }
done

DISABLE_UPDATES=$(ssh "$DEVICE" "cat /data/params/d/DisableUpdates 2>/dev/null || echo 0")
if [[ "$DISABLE_UPDATES" != "1" ]]; then
  echo "ERROR: DisableUpdates is not '1' on device."
  echo "       Fix: ssh $DEVICE \"echo -n 1 > /data/params/d/DisableUpdates\""
  exit 1
fi
echo "  DisableUpdates=1 (OK)"

# ── 1. venv ───────────────────────────────────────────────────────────────────
# Use absolute paths instead of `source .venv/bin/activate`: the activate script
# bakes in VIRTUAL_ENV at creation time, which breaks if the repo is moved.
export VIRTUAL_ENV="$REPO/.venv"
export PATH="$VIRTUAL_ENV/bin:$PATH"

# ── 2. build panda firmware ───────────────────────────────────────────────────
echo "=== Building panda firmware ==="
cd panda
scons -u -j"$(sysctl -n hw.ncpu)"
EXPECTED_PANDA_VERSION=$(cat board/obj/version)
echo "  Built firmware version: $EXPECTED_PANDA_VERSION"
cd "$REPO"

# ── 3. run Subaru brake-hold safety tests ─────────────────────────────────────
echo "=== Running Subaru brake-hold safety tests ==="
python -m pytest opendbc_repo/opendbc/safety/tests/test_subaru_brake_hold.py -q

# ── 4. rsync sources to device (DM-style excludes — most thorough) ────────────
echo "=== Syncing sources to device ==="
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
  --include='*.bin.signed' \
  --exclude='*' \
  "$REPO/" \
  "$DEVICE:/data/openpilot/"

# ── 5. verify md5sums ─────────────────────────────────────────────────────────
echo "=== Verifying md5sums ==="
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

# ── 6. rebuild params_pyx.so on device ────────────────────────────────────────
echo "=== Rebuilding params_pyx.so on device ==="
ssh "$DEVICE" 'bash -se' <<'BUILD_REMOTE'
set -euo pipefail
cd /data/openpilot/common

CYTHON=/usr/local/venv/bin/cython
CAPNP_INC=/usr/local/venv/lib/python3.12/site-packages/capnproto/install/include
CAPNP_LIB=/usr/local/venv/lib/python3.12/site-packages/capnproto/install/lib
JSON11=/data/openpilot/third_party/json11
PY_INC=$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')

[[ -x "$CYTHON" ]]              || { echo "ERROR: cython missing"; exit 1; }
command -v g++     >/dev/null   || { echo "ERROR: g++ not in PATH"; exit 1; }
[[ -d "$CAPNP_INC" ]]           || { echo "ERROR: capnp includes missing"; exit 1; }
[[ -f "$CAPNP_LIB/libcapnp.a" ]]|| { echo "ERROR: libcapnp.a missing"; exit 1; }
[[ -f "$CAPNP_LIB/libkj.a" ]]   || { echo "ERROR: libkj.a missing"; exit 1; }
[[ -f "$JSON11/json11.cpp" ]]   || { echo "ERROR: json11.cpp missing"; exit 1; }

rm -f /tmp/params_pyx_new.so /tmp/params_pyx.cpp \
      /tmp/params.o /tmp/util.o /tmp/swaglog.o /tmp/ratekeeper.o /tmp/json11.o

CXX="g++ -fPIC -O2 -std=c++17 -D__TICI__ -I. -I/data/openpilot -I$CAPNP_INC -I$JSON11"

"$CYTHON" --cplus params_pyx.pyx --output-file /tmp/params_pyx.cpp
$CXX -c params.cc            -o /tmp/params.o
$CXX -c util.cc              -o /tmp/util.o
$CXX -c swaglog.cc           -o /tmp/swaglog.o
$CXX -c ratekeeper.cc        -o /tmp/ratekeeper.o
$CXX -c "$JSON11/json11.cpp" -o /tmp/json11.o

g++ -shared -fPIC -O2 -std=c++17 \
  -o /tmp/params_pyx_new.so \
  /tmp/params_pyx.cpp \
  /tmp/params.o /tmp/util.o /tmp/swaglog.o /tmp/ratekeeper.o /tmp/json11.o \
  -I"$PY_INC" -I/data/openpilot -I"$CAPNP_INC" -I"$JSON11" \
  "$CAPNP_LIB/libcapnp.a" "$CAPNP_LIB/libkj.a" \
  -lzmq -lpthread -lpython3.12

rm -f /tmp/params_pyx.cpp \
      /tmp/params.o /tmp/util.o /tmp/swaglog.o /tmp/ratekeeper.o /tmp/json11.o

ls -la /tmp/params_pyx_new.so
echo "build OK"
BUILD_REMOTE

# ── 7. smoke-test new .so before swapping ─────────────────────────────────────
echo "=== Smoke-testing new params_pyx.so ==="
ssh "$DEVICE" "cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
import sys, importlib.util, os
sys.path.insert(0, '/data')
spec = importlib.util.spec_from_file_location('openpilot.common.params_pyx', '/tmp/params_pyx_new.so')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.modules['openpilot.common.params_pyx'] = mod
from openpilot.common.params import Params
p = Params()
val = p.get_default_value('DriverAwarenessShutoff')
assert val is True, f'Expected True default, got {val!r}'
_ = p.get_default_value('DongleId')
p.put_bool('DisableUpdates', True)
actual_path = '/data/params/d/DisableUpdates'
assert os.path.exists(actual_path), f'put_bool wrote to wrong path — -D__TICI__ may be missing'
print('  smoke test OK — DriverAwarenessShutoff recognised, Params() path correct')
\""

# ── 8. atomic swap params_pyx.so ──────────────────────────────────────────────
echo "=== Swapping params_pyx.so on device ==="
ssh "$DEVICE" "
set -euo pipefail
cd /data/openpilot/common
if [[ ! -f params_pyx.so.orig_dev ]]; then
  cp -p params_pyx.so params_pyx.so.orig_dev
  echo '  backup created: params_pyx.so.orig_dev'
else
  echo '  backup already exists (preserved)'
fi
mv -f /tmp/params_pyx_new.so params_pyx.so
ls -la params_pyx.so params_pyx.so.orig_dev
"

# ── 9. set params + overlay-swap guards ───────────────────────────────────────
echo "=== Setting params and disabling overlay updater ==="
ssh "$DEVICE" "
set -euo pipefail
cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
from openpilot.common.params import Params
p = Params()
p.put_bool('DriverAwarenessShutoff', True)
p.put_bool('DisableUpdates', True)
print('  DriverAwarenessShutoff=True')
print('  DisableUpdates=True')
\"
rm -f /data/openpilot/.overlay_init
rm -rf /data/safe_staging/finalized
echo '  overlay-swap guards set'
"

# ── 10. pre-reboot import + read check ────────────────────────────────────────
echo "=== Pre-reboot import + read check ==="
ssh "$DEVICE" "cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
from openpilot.common.params import Params
p = Params()
print('  DriverAwarenessShutoff default:', p.get_default_value('DriverAwarenessShutoff'))
print('  DriverAwarenessShutoff runtime:', p.get_bool('DriverAwarenessShutoff'))
print('  DisableUpdates:', p.get_bool('DisableUpdates'))
from openpilot.selfdrive.monitoring.dmonitoringd import dmonitoringd_thread
from openpilot.selfdrive.monitoring.helpers import DriverMonitoring
from opendbc.car.subaru.carcontroller import CarController
from opendbc.car.subaru.subarucan import create_es_brake_hold
print('  dmonitoringd + helpers import: OK')
print('  Subaru AVH brake-hold imports: OK')
\""

# ── 11. reboot ────────────────────────────────────────────────────────────────
echo "=== Rebooting device ==="
EXPECTED_FW_HASH=$(md5 -q "$REPO/$PANDA_BIN")
ssh "$DEVICE" "sudo reboot" 2>/dev/null || true
echo "  reboot triggered."

# ── 12. wait offline ──────────────────────────────────────────────────────────
echo "=== Waiting for device to go offline ==="
OFFLINE_TIMEOUT=60
ELAPSED=0
while ssh -o ConnectTimeout=3 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  [[ $ELAPSED -ge $OFFLINE_TIMEOUT ]] && { echo "  WARNING: device did not go offline within ${OFFLINE_TIMEOUT}s"; break; }
  printf "  waiting for offline... (%ds)\r" "$ELAPSED"
done
echo "  Device offline (${ELAPSED}s)."

# ── 13. wait online ───────────────────────────────────────────────────────────
echo "=== Waiting for device to come back online ==="
BOOT_TIMEOUT=240
ELAPSED=0
until ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  [[ $ELAPSED -ge $BOOT_TIMEOUT ]] && { echo "ERROR: device did not come back within ${BOOT_TIMEOUT}s"; exit 1; }
  printf "  waiting for online... (%ds)\r" "$ELAPSED"
done
echo "  Device is back online (${ELAPSED}s)."

# ── 14. post-reboot verification ──────────────────────────────────────────────
echo "=== Post-reboot verification ==="

# AVH: panda firmware md5
remote_fw_hash=$(ssh "$DEVICE" "md5sum /data/openpilot/$PANDA_BIN" | awk '{print $1}')
if [[ "$EXPECTED_FW_HASH" == "$remote_fw_hash" ]]; then
  echo "  OK   panda firmware binary intact ($remote_fw_hash)"
else
  echo "  FAIL panda firmware changed after reboot (expected=$EXPECTED_FW_HASH got=$remote_fw_hash)"
  exit 1
fi

# DM + AVH: params, imports, process
ssh "$DEVICE" "
set -e
echo '  DisableUpdates:' \$(cat /data/params/d/DisableUpdates 2>/dev/null || echo MISSING)
echo '  DriverAwarenessShutoff:' \$(cat /data/params/d/DriverAwarenessShutoff 2>/dev/null || echo MISSING)
cd /data/openpilot
PYTHONPATH=/data /usr/local/venv/bin/python3 -c \"
from openpilot.common.params import Params
p = Params()
assert p.get_bool('DriverAwarenessShutoff') is True, 'DriverAwarenessShutoff not True post-reboot'
assert p.get_bool('DisableUpdates') is True, 'DisableUpdates not True post-reboot'
print('  runtime get_bool DriverAwarenessShutoff: True (OK)')
print('  runtime get_bool DisableUpdates: True (OK)')
from openpilot.selfdrive.monitoring.dmonitoringd import dmonitoringd_thread
from openpilot.selfdrive.monitoring.helpers import DriverMonitoring
from opendbc.car.subaru.carcontroller import CarController
from opendbc.car.subaru.subarucan import create_es_brake_hold
print('  dmonitoringd + helpers import: OK')
print('  Subaru AVH brake-hold imports: OK')
\"
sleep 3
if pgrep -af 'selfdrive.monitoring.dmonitoringd' >/dev/null; then
  echo '  dmonitoringd process: RUNNING'
else
  echo '  WARNING: dmonitoringd not running yet (may need car ignition)'
fi
"

echo "=== Deploy complete ==="
