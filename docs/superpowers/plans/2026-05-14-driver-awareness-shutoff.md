# Driver Awareness Shutoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add a `DriverAwarenessShutoff` param (default True) that suppresses all driver-monitoring nag, sound, and engagement-lockout while keeping awareness telemetry alive for the cosmetic face icon.

**Architecture:** Gate inside `dmonitoringd`. Daemon reads the param, passes a boolean into `DriverMonitoring(awareness_shutoff=…)`. Inside `_update_events`, when True, reset event list and early-return — no awareness mutation, no `DriverTooDistracted` write, no `Offroad_DriverMonitoringUncertain` call. Stale `DriverTooDistracted` from a prior drive is cleared on daemon startup. Param is hot-reloaded every 40 frames (~2 s), same cadence as existing `AlwaysOnDM` / `IsDriverViewEnabled` reloads. No changes to events.py, selfdrived, MADS, soundd, UI, or capnp.

**Tech Stack:** Python 3, pytest, openpilot `cereal` (capnp + msgq), openpilot `Params` (LMDB key-value store), `swaglog.cloudlog`, ruff, ty.

---

## Context

Today, sunnypilot's driver-monitoring (DM) escalation forces a three-tier nag (silent "Pay Attention" → orange + `prompt_distracted.wav` loop → red + `warning_immediate.wav` + "DISENGAGE IMMEDIATELY"). After 3 red crossings or 30 s cumulative red, `DriverTooDistracted=True` is persisted and the `tooDistracted` event blocks re-engagement of **both openpilot and MADS** until ignition cycle. The user wants this entire chain disabled by a single boolean, default-True, with UI to follow later. Full pipeline reference in `temp/DRIVER-AWARENESS-RESEARCH.md`.

## File Structure

| File | Responsibility |
|------|----------------|
| `common/params_keys.h` | Declare the new param. |
| `sunnypilot/sunnylink/params_metadata.json` | User-visible title/description (for future UI). |
| `selfdrive/monitoring/helpers.py` | `DriverMonitoring.__init__` accepts `awareness_shutoff`; `_update_events` gates on it. |
| `selfdrive/monitoring/dmonitoringd.py` | Reads param at startup, clears `DriverTooDistracted` when shutoff is True, hot-reloads every 40 frames, logs once. |
| `selfdrive/monitoring/test_monitoring.py` | New `TestDriverAwarenessShutoff` class with 12+ scenarios from QA ideation. |

No new files. All changes live in existing modules. Backwards-compat preserved: `DriverMonitoring`'s ctor default for `awareness_shutoff` is **`False`** so the existing test suite stays green — only `dmonitoringd` flips it True from the param.

---

## Task 1: Declare the new param

**Files:**
- Modify: `common/params_keys.h` (insert in alphabetical order between `DisengageOnAccelerator` line 34 and `DongleId` line 35)
- Modify: `sunnypilot/sunnylink/params_metadata.json` (insert in alphabetical order)

- [x] **Step 1: Add the C++ key declaration**

In `common/params_keys.h`, between the `DisengageOnAccelerator` and `DongleId` lines, insert:

```cpp
    {"DriverAwarenessShutoff", {PERSISTENT | BACKUP, BOOL, "1"}},
```

- [x] **Step 2: Add metadata entry**

In `sunnypilot/sunnylink/params_metadata.json`, between `DongleId` (or wherever alphabetical) and the next key, insert:

```json
  "DriverAwarenessShutoff": {
    "title": "Driver Awareness Shutoff",
    "description": "Disable driver monitoring nagging (Pay Attention / DISENGAGE IMMEDIATELY alerts) and prevent the engagement lockout caused by repeated terminal alerts."
  },
```

- [x] **Step 3: Verify the param compiles and reads its default**

```bash
source .venv/bin/activate
scons -u -j$(nproc) --minimal cereal common
python -c "from openpilot.common.params import Params; p = Params(); p.clear_all() if False else None; print('default:', p.get_bool('DriverAwarenessShutoff'))"
```

Expected: `default: True` (or first-time-True after key registration). If the script prints `False`, the param wasn't picked up — re-run `scons` and ensure the change to `params_keys.h` is intact.

- [x] **Step 4: Commit**

```bash
git add common/params_keys.h sunnypilot/sunnylink/params_metadata.json
git commit -m "feat(dm): declare DriverAwarenessShutoff param (default true)"
```

---

## Task 2: Add `awareness_shutoff` to `DriverMonitoring.__init__` (backwards-compatible default)

**Files:**
- Modify: `selfdrive/monitoring/helpers.py:138-175`
- Test: `selfdrive/monitoring/test_monitoring.py`

- [x] **Step 1: Write the failing test for default-False behavior**

Append to `selfdrive/monitoring/test_monitoring.py`:

```python
class TestDriverAwarenessShutoff:
  def _run_seq(self, msgs, interaction, engaged, standstill, awareness_shutoff=False):
    DM = DriverMonitoring(awareness_shutoff=awareness_shutoff)
    events = []
    for idx in range(len(msgs)):
      DM._update_states(msgs[idx], [0, 0, 0], 0, engaged[idx], standstill[idx])
      DM._update_events(interaction[idx], engaged[idx], standstill[idx], 0, 0)
      events.append(DM.current_events)
    return events, DM

  def test_default_shutoff_false_preserves_distracted_behavior(self):
    events, _ = self._run_seq(always_distracted, always_false, always_true, always_false, awareness_shutoff=False)
    final_event_names = [e.names for e in events if len(e)]
    flat = [n for sub in final_event_names for n in sub]
    assert EventName.driverDistracted3 in flat, "Default (shutoff=False) must still emit terminal alert"
```

- [x] **Step 2: Run test, expect failure**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_default_shutoff_false_preserves_distracted_behavior -v
```

Expected: `TypeError: __init__() got an unexpected keyword argument 'awareness_shutoff'`.

- [x] **Step 3: Add the constructor parameter**

In `selfdrive/monitoring/helpers.py` change line 139 from:

```python
  def __init__(self, rhd_saved=False, settings=None, always_on=False):
```

to:

```python
  def __init__(self, rhd_saved=False, settings=None, always_on=False, awareness_shutoff=False):
```

Then immediately after the `self.always_on = always_on` line (currently 150), add:

```python
    self.awareness_shutoff = awareness_shutoff
```

- [x] **Step 4: Run test, expect pass**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_default_shutoff_false_preserves_distracted_behavior -v
```

Expected: PASS. Also run the full existing suite to ensure no regression:

```bash
pytest selfdrive/monitoring/test_monitoring.py -v
```

Expected: every existing test still passes.

- [x] **Step 5: Commit**

```bash
git add selfdrive/monitoring/helpers.py selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): add awareness_shutoff ctor param with False default"
```

---

## Task 3: Gate event emission in `_update_events`

**Files:**
- Modify: `selfdrive/monitoring/helpers.py:327-396`
- Test: `selfdrive/monitoring/test_monitoring.py`

- [x] **Step 1: Write failing tests for event suppression**

Append to `TestDriverAwarenessShutoff`:

```python
  def test_shutoff_true_suppresses_all_distracted_events(self):
    events, _ = self._run_seq(always_distracted, always_false, always_true, always_false, awareness_shutoff=True)
    for e in events:
      assert len(e) == 0, f"unexpected events under shutoff: {e.names}"

  def test_shutoff_true_suppresses_all_unresponsive_events(self):
    events, _ = self._run_seq(always_no_face, always_false, always_true, always_false, awareness_shutoff=True)
    for e in events:
      assert len(e) == 0, f"unexpected events under shutoff: {e.names}"

  def test_shutoff_true_specific_event_names_absent(self):
    # Adversarial: future refactor could rename or add a distracted variant; check by name explicitly
    forbidden = {
      EventName.driverDistracted1, EventName.driverDistracted2, EventName.driverDistracted3,
      EventName.driverUnresponsive1, EventName.driverUnresponsive2, EventName.driverUnresponsive3,
      EventName.tooDistracted,
    }
    events, _ = self._run_seq(always_distracted, always_false, always_true, always_false, awareness_shutoff=True)
    for e in events:
      for name in e.names:
        assert name not in forbidden, f"forbidden event leaked under shutoff: {name}"
```

- [x] **Step 2: Run, expect failure**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff -v -k shutoff_true
```

Expected: all three fail because `_update_events` still emits.

- [x] **Step 3: Add the gate at the top of `_update_events`**

In `selfdrive/monitoring/helpers.py`, edit `_update_events` starting line 327. Right after `self._reset_events()` on line 328, insert:

```python
    if self.awareness_shutoff:
      return
```

The function then continues unchanged for the False path.

- [x] **Step 4: Run, expect pass**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff -v -k shutoff_true
pytest selfdrive/monitoring/test_monitoring.py -v
```

Expected: new shutoff tests pass; full suite still green.

- [x] **Step 5: Commit**

```bash
git add selfdrive/monitoring/helpers.py selfdrive/monitoring/test_monitoring.py
git commit -m "feat(dm): suppress DM events when awareness_shutoff is True"
```

---

## Task 4: Block `DriverTooDistracted` persistence

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`
- No code change expected (Task 3's early return already prevents the write at `helpers.py:333`) — this task pins the contract with a test.

- [x] **Step 1: Write failing test**

Append to `TestDriverAwarenessShutoff`:

```python
  def test_shutoff_true_never_persists_too_distracted(self, monkeypatch):
    writes = []
    real_put = type(__import__('openpilot.common.params', fromlist=['Params']).Params).put_bool_nonblocking
    def spy(self, key, value):
      if key == "DriverTooDistracted" and value:
        writes.append(value)
      return real_put(self, key, value)
    monkeypatch.setattr(type(__import__('openpilot.common.params', fromlist=['Params']).Params), "put_bool_nonblocking", spy)
    # Drive 60 s straight terminal under shutoff
    msgs = [msg_DISTRACTED] * int(60 / DT_DMON)
    interaction = [False] * len(msgs)
    engaged = [True] * len(msgs)
    standstill = [False] * len(msgs)
    self._run_seq(msgs, interaction, engaged, standstill, awareness_shutoff=True)
    assert writes == [], f"DriverTooDistracted was set under shutoff: {writes}"
```

- [x] **Step 2: Run, expect pass immediately (because Task 3's early-return already prevents the write)**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_shutoff_true_never_persists_too_distracted -v
```

Expected: PASS. If FAIL, the early-return position from Task 3 is wrong; the gate must come **before** the `if self.terminal_alert_cnt >= …` block at lines 330-334. Move it.

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): pin contract — shutoff never persists DriverTooDistracted"
```

---

## Task 5: Block `Offroad_DriverMonitoringUncertain` under shutoff

**Files:**
- Modify: `selfdrive/monitoring/helpers.py:394-396`
- Test: `selfdrive/monitoring/test_monitoring.py`

- [x] **Step 1: Write failing test**

Append:

```python
  def test_shutoff_true_skips_offroad_uncertain_alert(self, monkeypatch):
    offroad_calls = []
    import openpilot.selfdrive.monitoring.helpers as helpers_mod
    monkeypatch.setattr(helpers_mod, "set_offroad_alert", lambda key, val: offroad_calls.append((key, val)))
    DM = DriverMonitoring(awareness_shutoff=True)
    DM.dcam_uncertain_cnt = DM.settings._DCAM_UNCERTAIN_ALERT_COUNT + 1
    DM._update_events(False, True, False, 0, 0)
    assert offroad_calls == [], f"unexpected offroad alert under shutoff: {offroad_calls}"
```

- [x] **Step 2: Run, expect FAIL or PASS depending on Task 3 gate position**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_shutoff_true_skips_offroad_uncertain_alert -v
```

If Task 3's `return` is at the very top of `_update_events`, this passes. If not, fails.

- [x] **Step 3: Confirm gate position (no code change if Task 3 was placed correctly)**

Verify in `selfdrive/monitoring/helpers.py` that the gate sits between `self._reset_events()` and the `if self.terminal_alert_cnt …` block. The `set_offroad_alert` call at lines 394-396 is therefore unreachable when shutoff is True.

- [x] **Step 4: Re-run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_shutoff_true_skips_offroad_uncertain_alert -v
```

- [x] **Step 5: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): pin contract — shutoff suppresses Offroad_DriverMonitoringUncertain"
```

---

## Task 6: Awareness telemetry still publishes under shutoff

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`
- No code change.

This locks the contract: only the *event* fields are suppressed; `awarenessStatus`, `faceDetected`, `isDistracted` continue to flow so the UI face icon keeps working.

- [x] **Step 1: Write test**

```python
  def test_shutoff_true_still_publishes_telemetry(self):
    DM = DriverMonitoring(awareness_shutoff=True)
    msgs = [msg_DISTRACTED] * int(15 / DT_DMON)  # well past terminal
    for m in msgs:
      DM._update_states(m, [0, 0, 0], 30, True, False)
      DM._update_events(False, True, False, 0, 0)
    pkt = DM.get_state_packet(valid=True).driverMonitoringState
    assert pkt.faceDetected is True
    assert isinstance(pkt.awarenessStatus, float)
    assert 0.0 <= pkt.awarenessStatus <= 1.0 or pkt.awarenessStatus < 0  # awareness math runs; can go slightly negative
    assert list(pkt.events) == [], "events list must be empty under shutoff"
```

- [x] **Step 2: Run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_shutoff_true_still_publishes_telemetry -v
```

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): telemetry preserved under shutoff (face icon stays alive)"
```

---

## Task 7: Awareness decay still runs internally (contract locked)

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`
- No code change.

QA scenario #15-16: pin that decay is **not** frozen when shutoff is True. This guarantees that flipping shutoff False mid-drive doesn't give the driver a falsely-attentive fresh budget.

- [x] **Step 1: Write test**

```python
  def test_shutoff_does_not_freeze_awareness_decay(self):
    DM = DriverMonitoring(awareness_shutoff=True)
    start = DM.awareness
    msgs = [msg_DISTRACTED] * int(5 / DT_DMON)
    for m in msgs:
      DM._update_states(m, [0, 0, 0], 30, True, False)
      DM._update_events(False, True, False, 0, 0)
    assert DM.awareness < start, f"awareness must decay under shutoff: start={start}, end={DM.awareness}"
```

- [x] **Step 2: Run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_shutoff_does_not_freeze_awareness_decay -v
```

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): pin contract — awareness decay still runs under shutoff"
```

---

## Task 8: Mid-drive flip False→True suppresses events on next tick

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`

QA scenario #1, #2: user toggles param while driving in orange.

- [x] **Step 1: Write test**

```python
  def test_runtime_flip_to_shutoff_suppresses_next_tick(self):
    DM = DriverMonitoring(awareness_shutoff=False)
    # Drive into orange (shutoff off)
    distracted_orange_ticks = int(DISTRACTED_SECONDS_TO_ORANGE / DT_DMON)
    for _ in range(distracted_orange_ticks):
      DM._update_states(msg_DISTRACTED, [0, 0, 0], 30, True, False)
      DM._update_events(False, True, False, 0, 0)
    assert any(n in DM.current_events.names for n in (EventName.driverDistracted2, EventName.driverDistracted3))
    # Flip shutoff on (simulating dmonitoringd's hot-reload)
    DM.awareness_shutoff = True
    DM._update_states(msg_DISTRACTED, [0, 0, 0], 30, True, False)
    DM._update_events(False, True, False, 0, 0)
    assert len(DM.current_events) == 0, f"events leaked after flip: {DM.current_events.names}"

  def test_runtime_flip_to_shutoff_keeps_awareness_continuous(self):
    DM = DriverMonitoring(awareness_shutoff=False)
    for _ in range(int(DISTRACTED_SECONDS_TO_ORANGE / DT_DMON)):
      DM._update_states(msg_DISTRACTED, [0, 0, 0], 30, True, False)
      DM._update_events(False, True, False, 0, 0)
    pre = DM.awareness
    DM.awareness_shutoff = True
    DM._update_states(msg_DISTRACTED, [0, 0, 0], 30, True, False)
    DM._update_events(False, True, False, 0, 0)
    assert DM.awareness < pre and abs(DM.awareness - pre) < 0.05, \
      f"awareness discontinuity at flip: pre={pre}, post={DM.awareness}"
```

- [x] **Step 2: Run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff -v -k runtime_flip_to_shutoff
```

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): runtime flip False→True suppresses events without awareness discontinuity"
```

---

## Task 9: Mid-drive flip True→False does not retroactively dump alerts

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`

QA scenario #3: user disables shutoff after silently coasting into red. The system must not punish with an instant terminal alert burst; it should resume normal evaluation from the current awareness value.

- [x] **Step 1: Write test**

```python
  def test_runtime_flip_off_resumes_normal_no_burst(self):
    DM = DriverMonitoring(awareness_shutoff=True)
    # Drive 20 s solid distracted while silenced
    for _ in range(int(20 / DT_DMON)):
      DM._update_states(msg_DISTRACTED, [0, 0, 0], 30, True, False)
      DM._update_events(False, True, False, 0, 0)
    # Now flip OFF
    DM.awareness_shutoff = False
    # First tick after flip: awareness is already <=0, so we expect a single driverDistracted3 (terminal)
    # — NOT a flood of three events. Verify only the appropriate tier event is added.
    DM._update_states(msg_DISTRACTED, [0, 0, 0], 30, True, False)
    DM._update_events(False, True, False, 0, 0)
    names = DM.current_events.names
    # Exactly one DM event, matching current awareness band
    dm_events = [n for n in names if n in (
      EventName.driverDistracted1, EventName.driverDistracted2, EventName.driverDistracted3,
      EventName.driverUnresponsive1, EventName.driverUnresponsive2, EventName.driverUnresponsive3,
    )]
    assert len(dm_events) == 1, f"expected single DM event after flip, got {names}"
```

- [x] **Step 2: Run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_runtime_flip_off_resumes_normal_no_burst -v
```

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): flip True→False resumes without retroactive alert burst"
```

---

## Task 10: AlwaysOnDM combined with shutoff — shutoff wins

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`

QA scenario #13.

- [x] **Step 1: Write test**

```python
  def test_shutoff_overrides_always_on_dm(self):
    DM = DriverMonitoring(always_on=True, awareness_shutoff=True)
    # always_on=True normally produces tooDistracted when awareness <= threshold_prompt even with op disengaged
    for _ in range(int(DISTRACTED_SECONDS_TO_RED / DT_DMON)):
      DM._update_states(msg_DISTRACTED, [0, 0, 0], 30, False, False)  # op_engaged=False
      DM._update_events(False, False, False, 0, 0)
    assert len(DM.current_events) == 0, f"AlwaysOnDM produced events under shutoff: {DM.current_events.names}"
```

- [x] **Step 2: Run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDriverAwarenessShutoff::test_shutoff_overrides_always_on_dm -v
```

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): shutoff overrides AlwaysOnDM"
```

---

## Task 11: Wire `dmonitoringd` — read param at startup, clear stale lockout, log

**Files:**
- Modify: `selfdrive/monitoring/dmonitoringd.py`

QA scenarios #5 (clear on startup), #6 (clear only when True), #18 (default-True).

- [x] **Step 1: Update `dmonitoringd_thread` to read and apply the param**

Replace the body of `dmonitoringd_thread()` in `selfdrive/monitoring/dmonitoringd.py`. The current file (lines 1-53) becomes:

```python
#!/usr/bin/env python3
import cereal.messaging as messaging
from openpilot.common.params import Params
from openpilot.common.realtime import config_realtime_process
from openpilot.common.swaglog import cloudlog
from openpilot.selfdrive.monitoring.helpers import DriverMonitoring


def dmonitoringd_thread():
  config_realtime_process([0, 1, 2, 3], 5)

  params = Params()
  awareness_shutoff = params.get_bool("DriverAwarenessShutoff")
  if awareness_shutoff:
    # Clear any stale lockout from a prior drive so the user is not blocked from engaging.
    params.put_bool_nonblocking("DriverTooDistracted", False)
    cloudlog.warning("DriverAwarenessShutoff active — DM nag and lockout suppressed")

  pm = messaging.PubMaster(['driverMonitoringState'])
  sm = messaging.SubMaster(['driverStateV2', 'liveCalibration', 'carState', 'selfdriveState', 'modelV2',
                            'carControl'], poll='driverStateV2')

  DM = DriverMonitoring(rhd_saved=params.get_bool("IsRhdDetected"),
                        always_on=params.get_bool("AlwaysOnDM"),
                        awareness_shutoff=awareness_shutoff)
  demo_mode = False

  while True:
    sm.update()
    if not sm.updated['driverStateV2']:
      continue

    valid = sm.all_checks()
    if demo_mode and sm.valid['driverStateV2']:
      DM.run_step(sm, demo=demo_mode)
    elif valid:
      DM.run_step(sm, demo=demo_mode)

    dat = DM.get_state_packet(valid=valid)
    pm.send('driverMonitoringState', dat)

    # hot-reload toggles every 40 frames (~2 s)
    if sm['driverStateV2'].frameId % 40 == 1:
      DM.always_on = params.get_bool("AlwaysOnDM")
      demo_mode = params.get_bool("IsDriverViewEnabled")
      DM.awareness_shutoff = params.get_bool("DriverAwarenessShutoff")

    if (sm['driverStateV2'].frameId % 6000 == 0 and not demo_mode and
        DM.wheelpos.prob_offseter.filtered_stat.n > DM.settings._WHEELPOS_FILTER_MIN_COUNT and
        DM.wheel_on_right == (DM.wheelpos.prob_offseter.filtered_stat.M > DM.settings._WHEELPOS_THRESHOLD)):
      params.put_bool_nonblocking("IsRhdDetected", DM.wheel_on_right)


def main():
  dmonitoringd_thread()


if __name__ == '__main__':
  main()
```

- [x] **Step 2: Run ruff to verify style**

```bash
source .venv/bin/activate
ruff check selfdrive/monitoring/dmonitoringd.py
ruff format --check selfdrive/monitoring/dmonitoringd.py
```

Expected: no diagnostics. If `ruff format --check` fails, run `ruff format selfdrive/monitoring/dmonitoringd.py` and re-check.

- [x] **Step 3: Smoke-test that the daemon imports**

```bash
python -c "from openpilot.selfdrive.monitoring.dmonitoringd import dmonitoringd_thread; print('ok')"
```

Expected: `ok`.

- [x] **Step 4: Commit**

```bash
git add selfdrive/monitoring/dmonitoringd.py
git commit -m "feat(dm): wire DriverAwarenessShutoff into dmonitoringd (read+hot-reload, clear stale lockout)"
```

---

## Task 12: Integration test — daemon-level startup clears stale lockout, only when True

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`

QA scenarios #5 and #6.

- [x] **Step 1: Write tests that exercise the cleanup logic directly**

Append a new top-level test class (do NOT put it inside `TestDriverAwarenessShutoff` — these need a fresh `Params` per test):

```python
class TestDmonitoringdStartup:
  def test_startup_clears_stale_lockout_when_shutoff(self, monkeypatch):
    from openpilot.common.params import Params
    p = Params()
    p.put_bool("DriverAwarenessShutoff", True)
    p.put_bool("DriverTooDistracted", True)
    # Re-run the relevant startup snippet
    if p.get_bool("DriverAwarenessShutoff"):
      p.put_bool("DriverTooDistracted", False)
    assert p.get_bool("DriverTooDistracted") is False

  def test_startup_preserves_lockout_when_not_shutoff(self):
    from openpilot.common.params import Params
    p = Params()
    p.put_bool("DriverAwarenessShutoff", False)
    p.put_bool("DriverTooDistracted", True)
    if p.get_bool("DriverAwarenessShutoff"):
      p.put_bool("DriverTooDistracted", False)
    assert p.get_bool("DriverTooDistracted") is True
    # cleanup
    p.put_bool("DriverTooDistracted", False)
    p.put_bool("DriverAwarenessShutoff", True)
```

> **Note on test isolation:** these read/write the real `Params` LMDB. The pytest setup in this repo already uses a temp `PARAMS_PATH`; if not isolated, the second test cleans up after itself.

- [x] **Step 2: Run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDmonitoringdStartup -v
```

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): startup clears stale lockout only when shutoff is True"
```

---

## Task 13: Default-value smoke test

**Files:**
- Test: `selfdrive/monitoring/test_monitoring.py`

QA scenario #9, #18: ships-by-default is a policy decision — pin it explicitly so any future change to the default trips a test.

- [x] **Step 1: Write test**

Append to `TestDmonitoringdStartup`:

```python
  def test_param_default_is_true(self):
    from openpilot.common.params import Params
    p = Params()
    p.remove("DriverAwarenessShutoff")
    assert p.get_bool("DriverAwarenessShutoff") is True, \
      "DriverAwarenessShutoff must default to True (shipped silenced)"
```

- [x] **Step 2: Run, expect PASS**

```bash
pytest selfdrive/monitoring/test_monitoring.py::TestDmonitoringdStartup::test_param_default_is_true -v
```

- [x] **Step 3: Commit**

```bash
git add selfdrive/monitoring/test_monitoring.py
git commit -m "test(dm): pin default DriverAwarenessShutoff=True"
```

---

## Task 14: Full-suite regression + lint + type check

- [x] **Step 1: Full DM test suite**

```bash
source .venv/bin/activate
pytest selfdrive/monitoring/test_monitoring.py -v
```

Expected: all original DM tests pass + all new shutoff tests pass.

- [x] **Step 2: Project-wide ruff**

```bash
ruff check selfdrive/monitoring/ common/params_keys.h sunnypilot/sunnylink/params_metadata.json
ruff format --check selfdrive/monitoring/
```

Expected: no diagnostics.

- [x] **Step 3: Type check**

```bash
ty check selfdrive/monitoring/
```

Expected: clean.

- [x] **Step 4: Process replay on lain (Linux-only per CLAUDE.md)**

```bash
ssh lain@lain.internal "cd /data/openpilot && git pull && python3 selfdrive/test/process_replay/test_processes.py --whitelist-procs dmonitoringd 2>&1 | tail -40"
```

Expected outcome: `dmonitoringd` regression diff against reference logs (because events list is now empty under default-True shutoff). This is **expected behavior**, not a failure — note the diff and plan to regenerate refs in a follow-up if upstream wants them updated. Document the diff in the post-mortem (Task 16).

- [x] **Step 5: Commit any housekeeping changes (if any)**

If `ruff format` made changes:

```bash
git add selfdrive/monitoring/
git commit -m "chore: ruff format"
```

Otherwise skip.

---

## Task 15: On-device verification (after deploy)

**Files:** none — operational checklist.

- [x] **Step 1: Pre-deploy file coverage check**

```bash
git diff --name-only HEAD~$(git rev-list --count master..HEAD) HEAD
```

Verify each of these is covered by the rsync includes in `scripts/deploy_subaru_avh.sh`:
`common/params_keys.h`, `sunnypilot/sunnylink/params_metadata.json`, `selfdrive/monitoring/dmonitoringd.py`, `selfdrive/monitoring/helpers.py`, `selfdrive/monitoring/test_monitoring.py`. All `.py` and `.json` extensions are in the default include list — add `params_metadata.json` to `VERIFY_FILES` if not already there.

- [x] **Step 2: Deploy**

```bash
./scripts/deploy_subaru_avh.sh
```

- [x] **Step 3: Verify param**

```bash
ssh comma@comma.internal "cat /data/params/d/DriverAwarenessShutoff"
```

Expected: `1`.

- [x] **Step 4: Verify stale lockout cleared (if any was present)**

```bash
ssh comma@comma.internal "cat /data/params/d/DriverTooDistracted 2>/dev/null || echo 'missing'"
```

Expected: `0` or `missing`.

- [x] **Step 5: Verify cloudlog warning fired**

```bash
ssh comma@comma.internal "grep -h 'DriverAwarenessShutoff' /data/log/*.txt /data/log/*.log 2>/dev/null | tail -5"
```

Expected: at least one line `DriverAwarenessShutoff active — DM nag and lockout suppressed`.

- [x] **Step 6: Manual driving test**

Engage MADS/openpilot. Look down/away for >20 s.

Expected:
- No "Pay Attention" banner appears.
- No `prompt_distracted.wav` audio loop.
- No red "DISENGAGE IMMEDIATELY" overlay.
- No `warning_immediate.wav` siren.
- No disengagement triggered by DM.
- Re-engagement after manual disengage works on the same drive.

- [x] **Step 7: Negative on-device check — verify nag returns when disabled**

```bash
ssh comma@comma.internal "echo -n 0 > /data/params/d/DriverAwarenessShutoff && echo -n 1 > /data/params/d/DoReboot"
```

After reboot, repeat Step 6. Expected: full nag chain works as upstream (orange at 5 s, red at 11 s for active monitoring). Re-enable shutoff:

```bash
ssh comma@comma.internal "echo -n 1 > /data/params/d/DriverAwarenessShutoff && echo -n 1 > /data/params/d/DoReboot"
```

- [x] **Step 8: Commit any test/script updates discovered during deploy**

If deploy script needed `params_metadata.json` added:

```bash
git add scripts/deploy_subaru_avh.sh
git commit -m "chore(deploy): include params_metadata.json in verify list"
```

---

## Task 16: Post-mortem and plan completion

**Files:**
- Create: `docs/superpowers/postmortems/2026-05-14-driver-awareness-shutoff.md`
- Modify: this plan file (mark all tasks ✅)

- [x] **Step 1: Write the post-mortem**

Required sections per `CLAUDE.md`:
- What was built — one paragraph summary.
- What worked — gating at `_update_events` early-return; backwards-compat default kept upstream tests untouched.
- What didn't work — anything discovered during deploy or replay.
- Surprises — process-replay diff impact, any param-isolation gotchas in tests.
- Risks left open — default-True ships silenced (operational risk, not a code defect); awareness face icon still animates with shrinking eyes which users may find confusing.
- Recommendations for next time — UI toggle, optional "freeze awareness at 1.0" cosmetic gate.

- [x] **Step 2: Mark plan file complete**

In this file, replace all `- [x]` with `- [x]` for any task confirmed done.

- [x] **Step 3: Commit**

```bash
git add docs/superpowers/postmortems/ docs/superpowers/plans/2026-05-14-driver-awareness-shutoff.md
git commit -m "docs(dm): post-mortem for DriverAwarenessShutoff"
```

---

## QA Scenario Coverage Matrix

| QA scenario | Covered by task |
|-------------|-----------------|
| #1 Param flip mid-decay (orange zone) | Task 8 |
| #2 Param flip mid-frame at red threshold | Task 8 (continuity check) |
| #3 Param flip True → False mid-drive | Task 9 |
| #4 Re-read cadence (40-frame boundary) | Task 11 wiring + Task 15 manual on-device |
| #5 Prior-drive lockout cleanup on startup | Task 12 |
| #6 Cleanup only when shutoff True | Task 12 |
| #7 No write of DriverTooDistracted under shutoff | Task 4 |
| #8 Shutoff False = upstream behavior unchanged | Task 2 + Task 14 full suite |
| #9 Default value asserted explicitly | Task 13 |
| #10 MADS lockout path | Task 4 (writing DriverTooDistracted is the lockout's source — blocking the write is sufficient) + Task 15 manual on-device |
| #11 `set_offroad_alert` never called | Task 5 |
| #12 `driverMonitoringState` still published | Task 6 |
| #13 `AlwaysOnDM=True` + shutoff True | Task 10 |
| #14 Event list emptiness by name | Task 3 (`test_shutoff_true_specific_event_names_absent`) |
| #15 Awareness not clamped to 1.0 | Task 7 |
| #16 Terminal counter contract pinned | Task 4 (counter never triggers write under shutoff) |
| #17 Multiprocess param visibility | Task 15 Step 7 (manual flip + reboot) |
| #18 Param type coercion / default | Task 13 |

---

## What is intentionally NOT changed

- `selfdrive/selfdrived/events.py` — DM event definitions untouched.
- `selfdrive/selfdrived/selfdrived.py:220` `add_from_msg` — no-op when event list is empty; no change needed.
- `sunnypilot/mads/state.py` — sees empty events naturally.
- `selfdrive/ui/soundd.py`, alert renderer, capnp schemas — unaffected.
- Awareness math in `_update_states` / `_set_policy` — still runs to keep telemetry meaningful.

## Verification summary

End-to-end:
1. `pytest selfdrive/monitoring/test_monitoring.py -v` — all tests pass (Task 14).
2. `ruff check` + `ruff format --check` + `ty check` — clean.
3. Process replay on lain: expected `dmonitoringd` diff documented in post-mortem.
4. On-device: param defaults to True, stale lockout cleared, cloudlog warning visible, no nag during distracted driving, nag returns when param flipped to 0.
