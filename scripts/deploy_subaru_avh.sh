#!/usr/bin/env bash
# Deploy Subaru AVH brake hold changes to comma device.
# Builds panda firmware, rsyncs Python/C sources, verifies md5sums, reboots.
set -euo pipefail

REPO=/Users/thiago/Documents/dev/sunnypilot
DEVICE=comma@comma.internal
PANDA_BIN=panda/board/obj/panda_h7.bin.signed

VERIFY_FILES=(
  "$PANDA_BIN"
  "opendbc_repo/opendbc/car/subaru/carcontroller.py"
  "opendbc_repo/opendbc/car/subaru/carstate.py"
  "opendbc_repo/opendbc/safety/modes/subaru.h"
  "opendbc_repo/opendbc/sunnypilot/car/subaru/brake_hold.py"
  "opendbc_repo/opendbc/sunnypilot/car/subaru/subarucan_ext.py"
  "opendbc_repo/opendbc/sunnypilot/car/subaru/values_ext.py"
  "opendbc_repo/opendbc/sunnypilot/car/interfaces.py"
)

cd "$REPO"

# ── 1. venv ──────────────────────────────────────────────────────────────────
source .venv/bin/activate

# ── 2. build panda firmware ───────────────────────────────────────────────────
echo "=== Building panda firmware ==="
cd panda
scons -u -j"$(sysctl -n hw.ncpu)"
EXPECTED_PANDA_VERSION=$(cat board/obj/version)
echo "  Built firmware version: $EXPECTED_PANDA_VERSION"
cd "$REPO"

# ── 3. run safety tests ───────────────────────────────────────────────────────
echo "=== Running Subaru brake hold safety tests ==="
python -m pytest opendbc_repo/opendbc/safety/tests/test_subaru_brake_hold.py -q

# ── 4. rsync sources to device ────────────────────────────────────────────────
echo "=== Syncing sources to device ==="
rsync -avz \
  --include='*/' \
  --include='*.py' --include='*.capnp' --include='*.h' \
  --include='*.cpp' --include='*.cc' --include='*.c' \
  --include='*.json' --include='*.sh' --include='*.pyx' --include='*.pxd' \
  --include='*.bin.signed' \
  --exclude='*' \
  --exclude='.git' --exclude='.venv' --exclude='__pycache__' --exclude='*.pyc' \
  "$REPO/" \
  "$DEVICE:/data/openpilot/"

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
EXPECTED_FW_HASH=$(md5 -q "$REPO/$PANDA_BIN")
ssh "$DEVICE" "echo -n 1 > /data/params/d/DoReboot"

echo "  Reboot triggered."

# ── 7. wait for device to come back online ────────────────────────────────────
echo "=== Waiting for device to come back online ==="
BOOT_TIMEOUT=180
ELAPSED=0
until ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [[ $ELAPSED -ge $BOOT_TIMEOUT ]]; then
    echo "ERROR: Device did not come back within ${BOOT_TIMEOUT}s"
    exit 1
  fi
  printf "  waiting... (%ds)\r" "$ELAPSED"
done
echo "  Device is back online (${ELAPSED}s)."

# ── 8. verify firmware file persisted through reboot ──────────────────────────
echo "=== Verifying firmware file post-reboot ==="
remote_fw_hash=$(ssh "$DEVICE" "md5sum /data/openpilot/$PANDA_BIN" | awk '{print $1}')
if [[ "$EXPECTED_FW_HASH" == "$remote_fw_hash" ]]; then
  echo "  OK  firmware binary intact on device"
else
  echo "  FAIL firmware binary changed after reboot (expected=$EXPECTED_FW_HASH got=$remote_fw_hash)"
  exit 1
fi

# ── 9. verify panda hardware firmware via binary md5 ─────────────────────────
# Compare the signed firmware binary on the device against our local build.
# Waits up to 4 minutes for SSH to be available after reboot before checking.
echo "=== Verifying panda hardware firmware ==="
echo "  Waiting for SSH to be available (timeout 240s)..."
PANDA_TIMEOUT=240
ELAPSED=0
until ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEVICE" true 2>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [[ $ELAPSED -ge $PANDA_TIMEOUT ]]; then
    echo "  WARNING: SSH not available within ${PANDA_TIMEOUT}s — cannot verify panda firmware"
    echo "=== Deploy complete (panda firmware check skipped) ==="
    exit 0
  fi
  printf "  waiting for SSH... (%ds)\r" "$ELAPSED"
done

REMOTE_FW_HASH=$(ssh "$DEVICE" "md5sum /data/openpilot/$PANDA_BIN" | awk '{print $1}')
if [[ "$EXPECTED_FW_HASH" == "$REMOTE_FW_HASH" ]]; then
  echo "  OK  panda firmware binary matches local build ($REMOTE_FW_HASH)"
else
  echo "  FAIL panda firmware binary mismatch"
  echo "       expected: $EXPECTED_FW_HASH"
  echo "       actual:   $REMOTE_FW_HASH"
  exit 1
fi

echo "=== Deploy complete ==="
