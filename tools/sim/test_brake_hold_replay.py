#!/usr/bin/env python3
"""
Replay brake hold controller against real comma log data.
Drives BrakeHoldController frame-by-frame using carState/carControl
from the log and prints state transitions.
"""
import sys
from pathlib import Path

REPO = Path(__file__).parents[2]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "opendbc_repo"))

from opendbc.car import structs, DT_CTRL
from opendbc.car.interfaces import CarStateBase
from opendbc.sunnypilot.car.subaru.stop_and_go import BrakeHoldController
from opendbc.sunnypilot.car.subaru.values_ext import SubaruFlagsSP
from openpilot.tools.lib.logreader import LogReader


def make_cp(fingerprint: str, openpilot_long: bool) -> structs.CarParams:
    cp = structs.CarParams()
    cp.carFingerprint = fingerprint
    cp.openpilotLongitudinalControl = openpilot_long
    return cp


def make_cp_sp(brake_hold: bool, timer_seconds: float = 0.0) -> structs.CarParamsSP:
    cp_sp = structs.CarParamsSP()
    cp_sp.flags = SubaruFlagsSP.BRAKE_HOLD if brake_hold else 0
    cp_sp.subaruBrakeHoldTimer = timer_seconds
    return cp_sp


def run_replay(log_path: str, hold_timer: float = 0.5, verbose: bool = False):
    print(f"\n{'='*60}")
    print(f"Log: {Path(log_path).name}")
    print(f"Brake hold timer: {hold_timer}s")
    print(f"{'='*60}")

    lr = LogReader(log_path)
    msgs = list(lr)

    # Pull car params from log
    cp_log = next((m.carParams for m in msgs if m.which() == "carParams"), None)
    if cp_log is None:
        print("ERROR: no carParams in log")
        return

    fingerprint = cp_log.carFingerprint
    openpilot_long = cp_log.openpilotLongitudinalControl
    print(f"Car:                     {fingerprint}")
    print(f"openpilotLongitudinalControl: {openpilot_long}")

    cp = make_cp(fingerprint, openpilot_long)
    cp_sp = make_cp_sp(brake_hold=True, timer_seconds=hold_timer)
    controller = BrakeHoldController(cp, cp_sp)

    # Build frame timeline: align carState + carControl by logMonoTime
    car_states = {m.logMonoTime: m.carState for m in msgs if m.which() == "carState"}
    car_controls = {m.logMonoTime: m.carControl for m in msgs if m.which() == "carControl"}

    # Pair them up — carState and carControl are published at the same rate
    state_times = sorted(car_states)
    control_times = sorted(car_controls)

    # Match each carState to nearest carControl
    pairs = []
    ci = 0
    for t in state_times:
        while ci + 1 < len(control_times) and abs(control_times[ci + 1] - t) < abs(control_times[ci] - t):
            ci += 1
        pairs.append((t, car_states[t], car_controls[control_times[ci]]))

    print(f"Frames to replay:        {len(pairs)}")

    # Stats
    transitions = []
    prev_state = controller.state
    standstill_frames = 0
    brake_pressed_frames = 0
    enabled_frames = 0
    holding_frames = 0
    peak_brake_output = 0
    drift_detections = 0

    for frame, (t, cs_msg, cc_msg) in enumerate(pairs):
        # Build minimal CarStateBase.out-like struct
        cs_out = structs.CarState()
        cs_out.standstill = cs_msg.standstill
        cs_out.vEgo = cs_msg.vEgo
        cs_out.brakePressed = cs_msg.brakePressed
        cs_out.gasPressed = cs_msg.gasPressed
        cs_out.cruiseState.enabled = cs_msg.cruiseState.enabled

        # Wrap in a minimal CarStateBase duck-type
        class FakeCS:
            out = cs_out
        fake_cs = FakeCS()

        # Build CC
        cc = structs.CarControl()
        cc.enabled = cc_msg.enabled
        cc.longActive = cc_msg.longActive

        controller.update(cc, fake_cs, frame)

        # Track stats
        if cs_out.standstill:
            standstill_frames += 1
        if cs_out.brakePressed:
            brake_pressed_frames += 1
        if cc.enabled:
            enabled_frames += 1
        if controller.state == BrakeHoldController.State.HOLDING:
            holding_frames += 1
        brake_out = controller.get_brake_output()
        if brake_out > peak_brake_output:
            peak_brake_output = brake_out
        if controller.drift_detected:
            drift_detections += 1

        if controller.state != prev_state:
            t_sec = t / 1e9
            transitions.append((frame, t_sec, prev_state, controller.state, cs_out, cc))
            if verbose or True:
                print(f"\n  [{frame:5d}] t={t_sec:.1f}s  {prev_state} → {controller.state}")
                print(f"          standstill={cs_out.standstill}  brakePressed={cs_out.brakePressed}"
                      f"  gasPressed={cs_out.gasPressed}  vEgo={cs_out.vEgo:.2f}"
                      f"  CC.enabled={cc.enabled}  CC.longActive={cc.longActive}"
                      f"  cruise.enabled={cs_out.cruiseState.enabled}")
            prev_state = controller.state

    print(f"\n{'─'*60}")
    print(f"Summary")
    print(f"{'─'*60}")
    total = len(pairs)
    print(f"  Total frames:          {total}  ({total * DT_CTRL:.1f}s)")
    print(f"  Standstill frames:     {standstill_frames}  ({standstill_frames/total*100:.1f}%)")
    print(f"  Brake pressed frames:  {brake_pressed_frames}  ({brake_pressed_frames/total*100:.1f}%)")
    print(f"  CC enabled frames:     {enabled_frames}  ({enabled_frames/total*100:.1f}%)")
    print(f"  HOLDING frames:        {holding_frames}  ({holding_frames/total*100:.1f}%)")
    print(f"  Peak brake output:     {peak_brake_output}")
    print(f"  Drift detections:      {drift_detections}")
    print(f"  State transitions:     {len(transitions)}")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="*", default=[
        "comma_logs/dde08cad3a74cd94_0000000f--ee2bbc885c--0--rlog.zst",
        "comma_logs/dde08cad3a74cd94_00000011--6b5de0b401--0--rlog.zst",
    ])
    parser.add_argument("--timer", type=float, default=0.5, help="Hold timer in seconds (default 0.5)")
    args = parser.parse_args()

    for log in args.logs:
        run_replay(log, hold_timer=args.timer)
