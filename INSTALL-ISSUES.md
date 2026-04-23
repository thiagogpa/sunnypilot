# Installation Issues, Root Causes & Fixes

This document covers every issue encountered installing `feat/subaru-manual-brake-hold`
on a comma 4 via SSH, what caused each one, how it was fixed, and what to do differently next time.

---

## Issue 1 — Default brake hold timer was 1s, not instant

**Symptom:** Brake hold activates after a 1-second delay by default.

**Root cause:** `SubaruBrakeHoldTimer` was initialised to `"1"` in two places:
- `common/params_keys.h` — the persistent param default
- `opendbc_repo/opendbc/sunnypilot/car/interfaces.py` — the Python fallback in `params_dict.get(..., 1)`

The UI already supported `0` as "Instant" but the defaults disagreed.

**Fix:** Changed both defaults to `"0"` / `0`.

**Future:** When adding a param with a meaningful default, set it in both places at the same time and add a unit test that reads the default and asserts the expected value.

---

## Issue 2 — opendbc submodule commits not pushed to any remote

**Symptom:** `git submodule update --init --recursive` on the device failed:
```
fatal: Fetched in submodule path 'opendbc_repo', but it did not contain
64defc58af7292be7855ee6ef089db36f051512b. Direct fetching of that commit failed.
```

**Root cause:** All opendbc changes (safety flags, brake hold logic, param plumbing) were committed
locally inside the `opendbc_repo` submodule but never pushed to any remote.
The parent `sunnypilot` repo's `.gitmodules` pointed to `sunnypilot/opendbc.git`,
which had none of those commits.

**Fix:**
1. Pushed the opendbc branch to `thiagogpa/opendbc` (`feat/subaru-manual-brake-hold`).
2. Updated `.gitmodules` to point `opendbc_repo` at `https://github.com/thiagogpa/opendbc.git`.
3. Committed and pushed the parent repo.

**Future:** Before pushing the parent repo, always verify submodule commits are reachable
from the remote URL in `.gitmodules`:
```bash
# For each submodule, confirm the pinned commit exists on the remote
git -C opendbc_repo branch -r --contains HEAD
```
If the commit only exists locally, push the submodule first.

---

## Issue 3 — Stale submodule directories blocked git clone

**Symptom:** `git submodule update --init` failed with:
```
fatal: destination path '/data/openpilot/msgq_repo' already exists
and is not an empty directory.
```

**Root cause:** The device was running a different sunnypilot fork. Its submodule directories
(`msgq_repo`, `opendbc_repo`, `panda`, `rednose_repo`, `tinygrad_repo`) existed as plain
directories with no `.git` metadata and no entry in `.git/modules/`. Git tried to clone
into them and refused because they were non-empty.

**Fix:** Removed the stale directories and re-ran submodule init:
```bash
cd /data/openpilot
rm -rf msgq_repo opendbc_repo panda rednose_repo tinygrad_repo
git submodule sync --recursive
git submodule update --init --recursive
```

**Future:** The SSH install guide (Method A) should include this cleanup step when switching
from a different fork. Add a check before checkout:
```bash
# If coming from a different fork, clear untracked submodule dirs first
git submodule deinit --all -f
rm -rf $(git submodule foreach --quiet 'echo $name')
```

---

## Issue 4 — Some submodules silently empty after update

**Symptom:** `git submodule status` showed correct commit hashes (no `+` or `-` prefix),
but `rednose_repo` and `panda` directories were completely empty. Build failed:
```
scons: *** No tool module 'rednose_filter' found
scons: *** missing SConscript file 'panda/SConscript'
```

**Root cause:** The `--recursive` flag on `git submodule update` silently skipped some
submodules — likely because their git index state was inconsistent after the stale-dir
cleanup. Git reported them as registered at the right commit but never checked out content.

**Fix:** Force-updated each empty submodule individually:
```bash
git submodule update --init --force rednose_repo
git submodule update --init --force panda
```

**Future:** After any submodule update, verify content not just commit hashes:
```bash
for sub in msgq_repo opendbc_repo panda rednose_repo tinygrad_repo; do
  count=$(ls /data/openpilot/$sub 2>/dev/null | wc -l)
  echo "$sub: $count files"
done
```
Any submodule showing 0 files needs a `--force` re-init.

---

## Issue 5 — `capnp | None` union type crashes at runtime

**Symptom:** Manager failed to start:
```
TypeError: unsupported operand type(s) for |: '_StructModule' and 'NoneType'
  File ".../sunnypilot/selfdrive/car/car_specific.py", line 27
    def update(self, CS: structs.CarState, events: Events, CS_SP: custom.CarStateSP | None = None):
```

**Root cause:** pycapnp's `_StructModule` does not implement `__or__`, so the `X | None`
union type syntax (PEP 604) fails when Python evaluates the annotation at class definition
time. This only surfaces at runtime on the device (pycapnp 2.1.0) — dev machines may use
a different pycapnp version or `from __future__ import annotations` may already be present
in other files that get imported first.

Affected files:
- `sunnypilot/selfdrive/car/car_specific.py`
- `selfdrive/ui/sunnypilot/ui_state.py`

**Fix:** Added `from __future__ import annotations` to both files. This makes Python treat
all annotations as strings (deferred evaluation), so the `|` operator is never invoked
at class definition time.

**Future:**
- Add `from __future__ import annotations` to every file that uses capnp types in
  annotations with `|` / `Optional`.
- Or use `Optional[X]` from `typing` instead of `X | None` for capnp types to be safe.
- A simple grep can catch these before pushing:
  ```bash
  grep -rn "capnp\|custom\.\|structs\." --include="*.py" | grep "| None"
  ```

---

## Issue 6 — INSTALL-SUBARU.md assumed device was on same fork

**Symptom:** The original install guide added a `thiagogpa` remote and did `git checkout`,
but didn't handle a dirty working tree or cross-fork submodule URL mismatches.

**Root cause:** The guide was written assuming a clean same-fork switch. In practice:
- The device had a different fork's submodule dirs (Issue 3)
- The opendbc submodule URL pointed to the wrong remote (Issue 2)
- No `git reset --hard HEAD` before checkout risked dirty-tree failures

**Fix:** Rewrote the install guide with:
- Two explicit methods (git remote vs fresh clone)
- `git reset --hard HEAD` before checkout
- `2>/dev/null || true` on `git remote add` to handle re-runs
- A note that the approach works regardless of which fork is currently installed

---

## Summary — Checklist Before Next On-Device Install

Before pushing and installing a branch that modifies submodules:

- [ ] All submodule commits pushed to a remote reachable from `.gitmodules` URL
- [ ] `.gitmodules` URLs updated if submodule lives in a fork, not upstream
- [ ] `from __future__ import annotations` present in any file using capnp types with `|`
- [ ] Param defaults consistent across `params_keys.h` and Python fallback values
- [ ] After submodule update on device, verify all dirs are non-empty before rebooting
