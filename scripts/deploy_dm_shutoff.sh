#!/usr/bin/env bash
# Deploy DriverAwarenessShutoff changes to comma device.
# Rsyncs Python/C sources, rebuilds params_pyx.so on device, verifies files, reboots.
set -euo pipefail

REPO=/Users/thiago/Documents/dev/sunnypilot
DEVICE=comma@comma.internal

VERIFY_FILES=(
  "common/params_keys.h"
  "selfdrive/monitoring/helpers.py"
  "selfdrive/monitoring/dmonitoringd.py"
  "sunnypilot/sunnylink/params_metadata.json"
)

cd "$REPO"

# ── 1. venv ──────────────────────────────────────────────────────────────────
source .venv/bin/activate

# ── 2. rsync sources to device ────────────────────────────────────────────────
echo "=== Syncing sources to device ==="
rsync -avz \
  --include='*/' \
  --include='*.py' --include='*.capnp' --include='*.h' \
  --include='*.cpp' --include='*.cc' --include='*.c' \
  --include='*.json' --include='*.sh' --include='*.pyx' --include='*.pxd' \
  --exclude='*' \
  --exclude='.git' --exclude='.venv' --exclude='__pycache__' --exclude='*.pyc' \
  "$REPO/" \
  "$DEVICE:/data/openpilot/"

# ── 3. rebuild params_pyx.so on device ───────────────────────────────────────
# params_keys.h is a compiled Cython extension — adding a new key requires
# rebuilding params_pyx.so on the ARM device.
echo "=== Rebuilding params_pyx.so on device ==="
ssh "$DEVICE" "cd /data/openpilot && source .venv/bin/activate 2>/dev/null || true && scons -u -j4 common 2>&1 | tail -10"

# ── 4. smoke-test the new param ───────────────────────────────────────────────
echo "=== Verifying DriverAwarenessShutoff is known to params ==="
ssh "$DEVICE" "cd /data/openpilot && python3 -c \"
from openpilot.common.params import Params
p = Params()
default = p.get_default_value('DriverAwarenessShutoff')
print('default_value:', default)
assert default is True, 'Expected default True'
print('param OK')
\""

# ── 5. verify md5sums ─────────────────────────────────────────────────────────
echo "=== Verifying md5sums ==="
MISMATCH=0
for f in "${VERIFY_FILES[@]}"; do
  local_hash=$(md5 -q "$REPO/$f")
  remote_hash=$(ssh "$DEVICE" "md5sum /data/openpilot/$f" | awk '{print $1}')
  if [[ "$local_hash" == "$remote_hash" ]]; then
    echo "  OK  $f"
  else
    echo "  FAIL $f (local=$local_hash remote=$remote_hash)"
    MISMATCH=1
  fi
done

if [[ $MISMATCH -ne 0 ]]; then
  echo "ERROR: md5sum mismatch — aborting reboot"
  exit 1
fi

# ── 6. reboot ─────────────────────────────────────────────────────────────────
echo "=== Rebooting device ==="
ssh "$DEVICE" "echo -n 1 > /data/params/d/DoReboot"
echo "  Reboot triggered."

# ── 7. wait for device to go offline ─────────────────────────────────────────
echo "=== Waiting for device to go offline ==="
OFFLINE_TIMEOUT=60
ELAPSED=0
while ssh -o ConnectTimeout=3 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [[ $ELAPSED -ge $OFFLINE_TIMEOUT ]]; then
    echo "  WARNING: Device did not go offline within ${OFFLINE_TIMEOUT}s — reboot may have stalled"
    break
  fi
  printf "  waiting for offline... (%ds)\r" "$ELAPSED"
done
echo "  Device offline (${ELAPSED}s)."

# ── 8. wait for device to come back online ────────────────────────────────────
echo "=== Waiting for device to come back online ==="
BOOT_TIMEOUT=240
ELAPSED=0
until ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [[ $ELAPSED -ge $BOOT_TIMEOUT ]]; then
    echo "ERROR: Device did not come back within ${BOOT_TIMEOUT}s"
    exit 1
  fi
  printf "  waiting for online... (%ds)\r" "$ELAPSED"
done
echo "  Device is back online (${ELAPSED}s)."

# ── 9. post-reboot verification ───────────────────────────────────────────────
echo "=== Post-reboot: verifying param and dmonitoringd import ==="
ssh "$DEVICE" "cd /data/openpilot && python3 -c \"
from openpilot.common.params import Params
p = Params()
shutoff = p.get_bool('DriverAwarenessShutoff')
print('DriverAwarenessShutoff:', shutoff)
from openpilot.selfdrive.monitoring.dmonitoringd import dmonitoringd_thread
print('dmonitoringd import: OK')
\""

echo "=== Deploy complete ==="
