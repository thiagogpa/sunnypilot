#!/usr/bin/env bash
# Verify DriverAwarenessShutoff deployment is intact on comma device.
set -euo pipefail

DEVICE=comma@comma.internal
CUSTOM_SO_SIZE=498712
FAIL=0

check() {
  local label="$1" result="$2" expected="$3"
  if [[ "$result" == "$expected" ]]; then
    printf "  OK   %s\n" "$label"
  else
    printf "  FAIL %s (got=%s expected=%s)\n" "$label" "$result" "$expected"
    FAIL=1
  fi
}

echo "=== Verifying DriverAwarenessShutoff deployment ==="

ssh "$DEVICE" 'bash -s' <<'REMOTE'
set -euo pipefail

CUSTOM_SO_SIZE=498712
FAIL=0

check() {
  local label="$1" result="$2" expected="$3"
  if [[ "$result" == "$expected" ]]; then
    printf "  OK   %s\n" "$label"
  else
    printf "  FAIL %s (got=%s expected=%s)\n" "$label" "$result" "$expected"
    FAIL=1
  fi
}

# params_pyx.so size
so_size=$(stat -c %s /data/openpilot/common/params_pyx.so 2>/dev/null || echo 0)
check "params_pyx.so size==${CUSTOM_SO_SIZE} (ours, not stock 3861560)" "$so_size" "$CUSTOM_SO_SIZE"

# params on disk
dis=$(cat /data/params/d/DisableUpdates 2>/dev/null || echo MISSING)
check "/data/params/d/DisableUpdates == 1" "$dis" "1"

das=$(cat /data/params/d/DriverAwarenessShutoff 2>/dev/null || echo MISSING)
check "/data/params/d/DriverAwarenessShutoff == 1" "$das" "1"

# overlay swap guards
overlay_init=$( [[ -f /data/openpilot/.overlay_init ]] && echo EXISTS || echo absent )
check ".overlay_init absent (no swap on next boot)" "$overlay_init" "absent"

finalized=$( [[ -d /data/safe_staging/finalized ]] && echo EXISTS || echo absent )
check "finalized absent (no pending update)" "$finalized" "absent"

# runtime Params() reads correct path (proves -D__TICI__ compiled in)
runtime=$(cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c "
from openpilot.common.params import Params
p = Params()
das = p.get_bool('DriverAwarenessShutoff')
dis = p.get_bool('DisableUpdates')
print('1' if (das and dis) else '0')
" 2>/dev/null || echo ERROR)
check "Params() runtime: DriverAwarenessShutoff=True DisableUpdates=True" "$runtime" "1"

# imports
import_ok=$(cd /data/openpilot && PYTHONPATH=/data /usr/local/venv/bin/python3 -c "
from openpilot.selfdrive.monitoring.helpers import DriverMonitoring
from openpilot.selfdrive.monitoring.dmonitoringd import dmonitoringd_thread
print('ok')
" 2>/dev/null || echo ERROR)
check "dmonitoringd + helpers import" "$import_ok" "ok"

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "=== PASS — deployment intact ==="
else
  echo "=== FAIL — deployment broken, re-run deploy_dm_shutoff.sh ==="
  exit 1
fi
REMOTE