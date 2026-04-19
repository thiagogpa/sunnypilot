# Installing feat/subaru-manual-brake-hold on a Comma Device

This guide covers installing the brake hold branch on a comma 3/4 device,
configuring it for a Gen1 Subaru, and recording a test drive.

---

## Prerequisites

- Comma 3 or comma 4 device already set up with sunnypilot
- SSH access to the device (`ssh comma@<device-ip>` or via the comma app)
- Gen1 Subaru (Ascent, Forester, Impreza, Impreza 2020, Forester 2022, Crosstrek non-hybrid)
  — **not** Outback, Legacy, Outback 2023, Ascent 2023 (those are Gen2, brake hold not supported)
  — **not** Crosstrek Hybrid (excluded by hybrid flag)
  — Note: the non-hybrid Crosstrek fingerprints as `SUBARU_IMPREZA` in openpilot/sunnypilot
- `openpilotLongitudinalControl` must be enabled in sunnypilot settings

---

## Install methods

Two options depending on the current state of the device:

| Situation | Method |
|---|---|
| Device already running **any** openpilot/sunnypilot fork | [SSH + git remote](#method-a-ssh--git-remote-fastest) (fastest — no reinstall) |
| Fresh device, or you want a clean slate | [SSH + fresh clone](#method-b-ssh--fresh-clone-clean-install) |

The branch lives at `https://github.com/thiagogpa/sunnypilot` on the
`feat/subaru-manual-brake-hold` branch. The device doesn't need to be running
this fork already — the steps below work regardless of what fork is currently installed.

---

## Step 1 — SSH into the device

```bash
ssh comma@<device-ip>
```

The IP is shown in the comma device's network settings, or use the comma app
to open an SSH tunnel.

---

## Method A: SSH + git remote (fastest)

Works as long as `/data/openpilot` exists (device is already running any openpilot fork).
This is a fork of `sunnypilot/sunnypilot` so they share git history — only the delta is downloaded.

```bash
cd /data/openpilot

# Discard any local modifications on the device (compiled artifacts, etc.)
git reset --hard HEAD

# Add the fork as a remote (safe to re-run if already added)
git remote add thiagogpa https://github.com/thiagogpa/sunnypilot.git 2>/dev/null || true

# Fetch the branch
git fetch thiagogpa feat/subaru-manual-brake-hold

# Check out the branch (creates a local tracking branch)
git checkout -b feat/subaru-manual-brake-hold thiagogpa/feat/subaru-manual-brake-hold

# Update submodules (important — opendbc changes are in the submodule)
git submodule update --init --recursive
```

Then skip to [Step 3 — Reboot](#step-3--reboot).

---

## Method B: SSH + fresh clone (clean install)

Use this on a fresh device or when you want to wipe the existing install.

```bash
# Stop openpilot if running
sudo systemctl stop openpilot 2>/dev/null || true

# Replace the repo
cd /data
rm -rf openpilot
git clone --branch feat/subaru-manual-brake-hold \
  https://github.com/thiagogpa/sunnypilot.git openpilot

# Update submodules
cd openpilot
git submodule update --init --recursive
```

---

## Step 3 — Reboot

```bash
sudo reboot
```

On first boot, the device will detect the panda firmware hash has changed
(our `subaru.h`/`subaru_common.h` safety changes) and automatically compile
and flash panda firmware. You will see an "Updating firmware" message on screen.
**No separate panda install step needed** — it is fully automatic.

Verify by checking Settings → Software — it should show the branch name.

---

## Step 4 — Enable brake hold

Either via the UI or SSH.

**Via UI:**
1. Settings → Vehicle → Subaru
2. Toggle **Brake Hold** → ON
3. **Brake Hold Timer** defaults to `0` (Instant) — leave it or increase it if you want a delay before hold activates

**Via SSH (must be parked/offroad):**
```bash
echo -n "1" > /data/params/d/SubaruBrakeHold
echo -n "0" > /data/params/d/SubaruBrakeHoldTimer
```

---

## Step 5 — Record a test drive

### Goal
Capture at least **3 clean brake hold events** in one drive — car fully stopped
with openpilot engaged, held for the timer duration, then resumed.

### Drive conditions
- A road with **traffic lights or stop-and-go traffic** works best
- openpilot must have **longitudinal control** (not just lane keep)

### How to drive

1. Engage openpilot at normal driving speed (both lateral and longitudinal)
2. Approach a red light or stopped car — **keep openpilot engaged, do not disengage**
3. Let openpilot decelerate the car fully to a standstill
4. Remain stopped for at least **4–5 seconds** (longer than the 2s timer)
5. Brake hold should activate — car stays held even after openpilot's ACC would normally release
6. Resume: press the gas pedal or re-engage ACC
7. Repeat at least 3 times

### Drive length

**5–10 minutes** is sufficient. One segment (~1 min) is the minimum needed for
process replay, but more stop events give better coverage.

---

## Step 6 — Extract the route

Routes auto-upload to [connect.comma.ai](https://connect.comma.ai) after the drive.

1. Open connect.comma.ai and find the drive
2. The route ID is in the URL: `{dongle_id}/{date}--{time}`
   Example: `a1b2c3d4e5f6a7b8/2026-04-18--14-30-00`
3. Note the segment number(s) where brake hold fired — look for the stops

The route ID is all that's needed to add it as a process replay test segment.

---

## Step 7 — Add the route to process replay

Once you have the route ID, add it to `selfdrive/test/process_replay/test_processes.py`:

```python
# In the segments list, replace or add a SUBARU entry:
("SUBARU", "your_dongle_id/2026-04-18--14-30-00--1"),  # SUBARU.YOUR_CAR brake hold event
```

Then run on `lain` to generate reference logs:
```bash
ssh lain
cd ~/sunnypilot
.venv/bin/python3 selfdrive/test/process_replay/test_processes.py \
  --whitelist-cars SUBARU --whitelist-procs controlsd --jobs 1
```

---

## Reverting to previous branch

If you want to go back to the original sunnypilot branch:

```bash
cd /data/openpilot
git checkout master   # or whichever branch you were on before
git submodule update --init --recursive
sudo reboot
```
