# Post-mortem: DriverAwarenessShutoff (2026-05-14)

## What was built

Added a `DriverAwarenessShutoff` param (default `True`) that suppresses the full driver-monitoring nag chain — silent/orange/red alert banners, distracted audio loop, and engagement lockout via `DriverTooDistracted` — while keeping awareness telemetry flowing for the UI face icon. The gate lives in `DriverMonitoring._update_events`: when `awareness_shutoff=True`, the lockout check and all event emission are skipped, but the awareness decay math still runs so internal state is honest for runtime flips. Stale `DriverTooDistracted` lockouts from prior drives are cleared on daemon startup when shutoff is active. The param hot-reloads every 40 frames (~2s).

## What worked

- **Gating at the event-emission boundary** (not an early return from the entire method) was the right architecture. An early return after `_reset_events()` broke the awareness decay, which is needed so that flipping shutoff=False mid-drive doesn't give the driver a falsely-attentive budget. Restructuring into two `if not self.awareness_shutoff:` guards (one at top for lockout/tooDistracted, one near bottom before alert emission) solved it cleanly.
- **Backwards-compat default `awareness_shutoff=False`** in the constructor meant all 20 upstream test cases stayed green with zero changes.
- **`get_default_value`** (not `get_bool` after `remove`) is the right way to test that a param's compile-time default is `True`. The params LMDB only contains the default after manager writes it on first boot; `get_bool` after `remove` returns `False`.

## What didn't work

- **Early return after `_reset_events()`** (the plan's originally specified gate position) broke `test_shutoff_does_not_freeze_awareness_decay` and two runtime-flip tests because the awareness decay at line 378 of `_update_events` was inside the early-returned region, not in `_update_states` as the plan assumed.
- **Monkeypatching `Params.put_bool_nonblocking` via `type(Params).put_bool_nonblocking`** fails because `type(Params)` is the metaclass `type`, not the Params class itself. The Cython extension type doesn't expose `put_bool_nonblocking` on its metaclass. The test was replaced with an equivalent internal-state check (`DM.too_distracted is False` and `DM.terminal_alert_cnt == 0`).

## Surprises / non-obvious findings

- Awareness decay happens inside `_update_events`, not `_update_states`. The plan doc said "awareness math in `_update_states` / `_set_policy`" but the step-change subtraction (`self.awareness = max(self.awareness - self.step_change, -0.1)`) is at `helpers.py:378` inside `_update_events`. This is the key structural insight that drove the gate restructure.
- `test_param_default_is_true`: openpilot's `Params.get_bool` returns `False` for missing keys regardless of the `params_keys.h` declared default. The default is only written to LMDB by manager at first boot. Use `Params.get_default_value(key)` to test compile-time defaults.
- **Process replay on lain was skipped**: lain is on the Subaru brake hold branch with unrelated changes, so syncing was not safe. Process replay for `dmonitoringd` would show a diff (events list empty under default-True shutoff) — this is expected behavior and should be documented if submitted upstream.

## Risks left open

- **`params_pyx.so` rebuild required for device deployment**: `params_keys.h` adding `DriverAwarenessShutoff` requires recompiling `params_pyx.so` on the comma device (ARM). The `scripts/deploy_subaru_avh.sh` referenced in CLAUDE.md does not exist in this repo. Deploying `dmonitoringd.py` to a device with an old compiled `.so` will crash with `UnknownKeyName` on the first `params.get_bool("DriverAwarenessShutoff")` call. Mitigation: compile on device via `scons -u -j4 --minimal common`, or wrap the param read in try/except for the transition period.
- **Face icon still animates with shrinking awareness under shutoff**: the UI face icon's eyes narrow as awareness decays (because telemetry still flows). Users who know what that means may find it confusing even though there are no alerts.
- **No UI toggle yet**: param is set by writing directly to LMDB. A future UI toggle task is needed.

## Recommendations for next time

- When gating inside a complex method that mixes state mutation and event emission, read the full method first before choosing the gate position. An early return that saves lines can break state that downstream code depends on.
- For testing params defaults, prefer `Params.get_default_value(key)` over `Params.get_bool(key)` after `remove`. Document this in any plan that tests param defaults.
- When adding a new param key that will be read in a daemon, always include a "rebuild `params_pyx.so`" step in the deploy plan for the comma device.
