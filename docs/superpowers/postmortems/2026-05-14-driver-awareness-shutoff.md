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
- **Process replay on lain produces a pre-existing failure**: lain is on the Subaru brake hold branch. Process replay for `dmonitoringd` fails with "0.00% valid messages" even with the original unmodified `dmonitoringd.py` — confirming the failure is caused by lain's branch modifications to `helpers.py` (not our changes). Process replay cannot be used to validate `DriverAwarenessShutoff` on lain without first resolving that branch's dmonitoringd validity issue.

## Risks left open

- **`params_pyx.so` rebuild required for device deployment**: `params_keys.h` adding `DriverAwarenessShutoff` requires recompiling `params_pyx.so` on the comma device (ARM). The `scripts/deploy_subaru_avh.sh` referenced in CLAUDE.md does not exist in this repo. Deploying `dmonitoringd.py` to a device with an old compiled `.so` will crash with `UnknownKeyName` on the first `params.get_bool("DriverAwarenessShutoff")` call. Mitigation: compile on device via `scons -u -j4 --minimal common`, or wrap the param read in try/except for the transition period.
- **Face icon still animates with shrinking awareness under shutoff**: the UI face icon's eyes narrow as awareness decays (because telemetry still flows). Users who know what that means may find it confusing even though there are no alerts.
- **No UI toggle yet**: param is set by writing directly to LMDB. A future UI toggle task is needed.

## Recommendations for next time

- When gating inside a complex method that mixes state mutation and event emission, read the full method first before choosing the gate position. An early return that saves lines can break state that downstream code depends on.
- For testing params defaults, prefer `Params.get_default_value(key)` over `Params.get_bool(key)` after `remove`. Document this in any plan that tests param defaults.
- When adding a new param key that will be read in a daemon, always include a "rebuild `params_pyx.so`" step in the deploy plan for the comma device.
- When suppressing a runtime nag, also audit install-time and onboarding gates that depend on the same concept. The runtime gate ≠ the install gate (see addendum below).

---

## Addendum (2026-05-16): install-time training modal gap

### What was missed

The original research doc and plan covered the runtime DM nag chain end-to-end but never surveyed the install-time onboarding flow. After deploying, the user reported that a fresh install was still forced through the multi-step "driver awareness camera" training modal before being able to use the system — exactly what the feature was meant to avoid.

Two parallel gates were the actual blockers, both keying on `CompletedTrainingVersion == training_version ("0.2.0")`:

1. **`system/hardware/hardwared.py:310`** — `startup_conditions["completed_training"]` blocks the device from entering onroad. This is the *functional* blocker; without it, the UI modal alone would just be cosmetic noise.
2. **`selfdrive/ui/layouts/onboarding.py:180`** and the mici variant at `selfdrive/ui/mici/layouts/onboarding.py:348` — push `OnboardingWindow` over the home screen and force-click through 19 image steps.

Neither was mentioned in the original research doc §11 "Side-effects". Both are independent of `dmonitoringd` and have nothing to do with the DM event ladder.

### The fix

Single seed in `system/manager/manager.py` `manager_init()`, placed **after** the default-population loop:

```python
from openpilot.system.version import get_build_metadata, training_version
# ...
if params.get_bool("DriverAwarenessShutoff") and params.get("CompletedTrainingVersion") != training_version:
  params.put("CompletedTrainingVersion", training_version)
```

Both UIs and `hardwared` see the same param, so one write satisfies all three gates.

### Why "after the default loop" was the only correct position

Reusing the prior post-mortem finding: `Params.get_bool` returns `False` for unset keys regardless of the declared default in `params_keys.h`. The default loop at `manager.py:58-61` is what writes `"1"` to `DriverAwarenessShutoff` on first boot. Placing the seed at line 52 next to the `RecordFrontLock` block — which was the first instinct — would silently no-op on every fresh install: the exact bug being fixed. This is the second time the same gotcha cost time; documented in the recommendations above.

### What was deliberately NOT changed

- Terms acceptance, SunnyLink consent — independent gates, still shown to the user.
- `RecordFront` — left at default `False` (no driver-camera upload), matching the privacy-safe answer of the YES/NO prompt at training step 9 (`DM_RECORD_STEP`).
- Both onboarding UI files — untouched; the seed at manager level is sufficient.
- `hardwared.py` — untouched.
- All `DriverAwarenessShutoff=False` behavior — the seed is guarded on the shutoff being True, so flipping the param off restores full upstream onboarding (verified in Task 17 Step 6).

### Surprises

- The `RecordFront` param defaults to `False` when unset (no default value in the `BOOL` declaration at `common/params_keys.h:112`). Skipping the modal therefore preserves the privacy-safe default rather than auto-enabling driver-camera upload. Confirmed by reading the declaration and the conditional in `system/loggerd/loggerd.h:98`.
- Two parallel onboarding code paths exist: the default raylib UI and a `mici/` variant for the comma 3X hardware family. The manager-level seed sidesteps the need to patch both.

### Risks left open

- If a future upstream sync bumps `training_version` to "0.3.0", the seed re-fires on first boot after the bump (because of the `!= training_version` guard), which is the desired behavior — users opted out of training, so they stay opted out across version bumps.
- The training modal cannot be re-shown to a user who flips `DriverAwarenessShutoff` to False later, unless they also clear `CompletedTrainingVersion` manually. Documented in research doc §14.3; not a defect.

---

## Addendum (2026-05-17): device deploy — overlay revert loop and params path bug

### What was broken

Every deploy was silently undone on the next reboot. The device reverted to stock sunnypilot code, clearing `DriverAwarenessShutoff` and resetting settings. Three root causes, all connected:

**1. Overlay swap chain** (`launch_chffrplus.sh` + `updated.py`)

sunnypilot's update system uses overlayfs. On each boot, `launch_chffrplus.sh` checks:
- `.overlay_init` exists in BASEDIR
- `.git` not newer than `.overlay_init` (always true after our rsync — we don't touch `.git`)
- `finalized/.overlay_consistent` exists
- `old_openpilot` doesn't exist

If all four are true, it moves `/data/openpilot` to `old_openpilot` and installs the finalized stock update. `updated.py` (the updater daemon) runs on boot and calls `init_overlay()` which: (a) deletes `/data/safe_staging` including `old_openpilot` — removing the guard against re-swapping — then creates a fresh overlay and touches `.overlay_init`. `finalize_update()` then copies the overlay into `finalized` with stock code. On the next boot, conditions 1–4 are met and the swap fires.

**2. `Hardware::PC() = True` in our compiled `params_pyx.so`**

`system/hardware/hw.h` selects between `HardwareTici` (PC()=False, params at `/data/params`) and `HardwarePC` (PC()=True, params at `~/.comma/params`) via `#if __TICI__`. Our manual Cython compile chain on device never passed `-D__TICI__`, so every `Params()` call from our `.so` resolved to `~/.comma/params/d/` instead of `/data/params/d/`.

Consequences:
- `p.put_bool('DisableUpdates', True)` wrote to `~/.comma/params/d/DisableUpdates` (not `/data/params/d/`)
- `updated.py` imported our `.so` and read `DisableUpdates` from the wrong path — saw the default "0" in `/data/params/d/` — and proceeded to run the full overlay update cycle
- `manager_init()`'s default-population loop wrote default values to the wrong path; the actual `/data/params/d/DriverAwarenessShutoff` was deleted by `params.clear_all(CLEAR_ON_MANAGER_START)` on stock `.so` boot (unknown key → deleted)

**3. `params.clear_all` deletes unknown keys**

When the overlay swap restored the stock `params_pyx.so`, that `.so` doesn't know `DriverAwarenessShutoff`. `clear_all(CLEAR_ON_MANAGER_START)` iterates `/data/params/d/` and deletes any key not in the compiled keys map. So `DriverAwarenessShutoff` was erased from disk on every stock boot.

### The fixes

**Fix 1 — `-D__TICI__` compile flag** (the critical fix):

Added `-D__TICI__` to the `CXX` line in `scripts/deploy_dm_shutoff.sh`'s remote build block:
```bash
CXX="g++ -fPIC -O2 -std=c++17 -D__TICI__ -I. -I/data/openpilot -I$CAPNP_INC -I$JSON11"
```
This makes our compiled `params_pyx.so` use `HardwareTici` → `PC()=False` → params path `/data/params`. All `Params()` calls from all processes using our `.so` now write to the correct location.

**Fix 2 — Delete `.overlay_init` and `finalized` on deploy**:

Step 6 of the deploy script removes both before reboot:
```bash
rm -f /data/openpilot/.overlay_init
rm -rf /data/safe_staging/finalized
```
Without `.overlay_init`, the launch script skips the swap entirely. Without `finalized`, even if `.overlay_init` were recreated, no swap can complete.

**Fix 3 — Smoke test validates `Params()` path**:

The smoke test now uses `Params()` (no explicit path) and asserts that `put_bool('DisableUpdates', True)` lands in `/data/params/d/DisableUpdates`. If `-D__TICI__` is ever dropped from the compile flags, this test fails before the `.so` is installed.

### Verification script

`scripts/verify_dm_shutoff.sh` — SSH to device, checks all 7 invariants in ~3s. Exits 0/1. Run after any reboot to confirm deployment is intact.

### Surprises / non-obvious findings

- `p.get_bool('DriverAwarenessShutoff')` returned `True` even when the deploy was broken — because it was reading from the wrong path (`~/.comma/params/d/`) where we had previously written "1". The correct file `/data/params/d/DriverAwarenessShutoff` didn't exist. Apparent success masked total failure.
- `init_overlay()` calls `sudo rm -rf /data/safe_staging` which deletes `old_openpilot` — the very guard that would have prevented the next swap. The swap loop is self-perpetuating: each run clears the protection against the next run.
- Our rsync never touches `.git`, so the `.git` timestamp stays older than `.overlay_init` on every deploy. The "skip if repo was modified" check in the launch script therefore never fires for us.
- `DisableUpdates` in `/data/params/d/` had timestamp `May 16 21:08` (an earlier manual write via raw `echo`). Our deploy's `put_bool('DisableUpdates', True)` silently went to the wrong path for several iterations without any error.

### Recommendations for next time

- When manually compiling a `.so` on device, always add `-D__TICI__` (or verify `Hardware::PC()` returns false). Every openpilot C++ file that includes `system/hardware/hw.h` is affected — not just params.
- Add a params-path canary to any smoke test for custom-compiled `.so` files: write a known key, assert the file exists in `/data/params/d/`, not `~/.comma/params/d/`.
- `DisableUpdates` must be in `/data/params/d/` — that's where `updated.py` reads it. Verify with `cat`, not with `Params.get_bool`, since `get_bool` can lie if the `.so` resolves to the wrong path.
