#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$0")
OPENPILOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "$OPENPILOT_DIR/.venv/bin/python3" ]; then
  PYTHON="$OPENPILOT_DIR/.venv/bin/python3"
else
  PYTHON="python3"
fi

export PASSIVE="0"
export NOBOARD="1"
export SIMULATION="1"
export SKIP_FW_QUERY="1"
export FINGERPRINT="SUBARU_IMPREZA"
export PYTHONPATH="$OPENPILOT_DIR"

export BLOCK="${BLOCK},camerad,loggerd,encoderd,micd,logmessaged,manage_athenad,manage_sunnylinkd"
if [[ "$CI" ]]; then
  export BLOCK="${BLOCK},ui"
fi

"$PYTHON" -c "from openpilot.selfdrive.test.helpers import set_params_enabled; set_params_enabled()"

"$PYTHON" -c "
from openpilot.common.params import Params
p = Params()
p.put_bool('SubaruBrakeHold', True)
p.put('SubaruBrakeHoldTimer', 2)
"

cd "$OPENPILOT_DIR/system/manager" && exec "$PYTHON" manager.py
