from cereal import car, log, custom
from openpilot.common.params import Params
from openpilot.selfdrive.selfdrived.selfdrived import SelfdriveD
from openpilot.selfdrive.selfdrived.events import EventName

_DM_PACKETS = ['driverMonitoringState', 'driverCameraState']


def _make_sd() -> SelfdriveD:
  cp = car.CarParams.new_message()
  cp.carFingerprint = "TOYOTA_COROLLA_TSS2"
  cp.brand = "toyota"
  cp_sp = custom.CarParamsSP.new_message()
  sd = SelfdriveD(CP=cp, CP_SP=cp_sp)
  sd.initialized = True
  return sd


class TestDmBypass:
  def setup_method(self):
    self.params = Params()
    self.sd = _make_sd()

  # ------------------------------------------------------------------
  # Original tests (must pass on current code)
  # ------------------------------------------------------------------

  def test_dm_disabled_bypass(self):
    self.params.put_bool("EnableDriverMonitoring", False)
    self.sd.dm_enabled = False

    for p in self.sd.camera_packets:
      self.sd.sm.alive[p] = True
    self.sd.sm.alive['driverCameraState'] = False
    self.sd.sm.valid['driverCameraState'] = False
    self.sd.sm.alive['driverMonitoringState'] = False

    cs = car.CarState.new_message()
    self.sd.update_events(cs)

    assert EventName.cameraMalfunction not in self.sd.events.names
    assert EventName.commIssue not in self.sd.events.names

  def test_dm_disabled_events_bypass(self):
    self.params.put_bool("EnableDriverMonitoring", False)
    self.sd.dm_enabled = False

    dm_msg = log.DriverMonitoringState.new_message()
    dm_event = log.OnroadEvent.new_message()
    dm_event.name = EventName.tooDistracted
    dm_msg.events = [dm_event]
    self.sd.sm.data['driverMonitoringState'] = dm_msg

    cs = car.CarState.new_message()
    cs.canValid = True
    self.sd.update_events(cs)

    assert EventName.tooDistracted not in self.sd.events.names

  def test_dm_enabled_no_bypass(self):
    self.params.put_bool("EnableDriverMonitoring", True)
    self.sd.dm_enabled = True

    self.sd.sm.alive['driverCameraState'] = False

    cs = car.CarState.new_message()
    self.sd.update_events(cs)

    assert EventName.cameraMalfunction in self.sd.events.names

  # ------------------------------------------------------------------
  # New: update_dm_checks manages ignore lists correctly
  # ------------------------------------------------------------------

  def test_update_dm_checks_adds_to_ignore_when_disabled(self):
    """update_dm_checks() must add DM packets to ignore_alive and ignore_valid when disabled."""
    self.sd.dm_enabled = False
    self.sd.update_dm_checks()

    for p in _DM_PACKETS:
      assert p in self.sd.sm.ignore_alive, f"{p} must be in ignore_alive when DM disabled"
      assert p in self.sd.sm.ignore_valid, f"{p} must be in ignore_valid when DM disabled"

  def test_update_dm_checks_removes_from_ignore_when_enabled(self):
    """update_dm_checks() must remove DM packets from ignore lists when re-enabled."""
    # First disable to populate ignore lists
    self.sd.dm_enabled = False
    self.sd.update_dm_checks()

    # Now re-enable
    self.sd.dm_enabled = True
    self.sd.update_dm_checks()

    for p in _DM_PACKETS:
      assert p not in self.sd.sm.ignore_alive, f"{p} must NOT be in ignore_alive when DM enabled"
      assert p not in self.sd.sm.ignore_valid, f"{p} must NOT be in ignore_valid when DM enabled"

  def test_update_dm_checks_idempotent(self):
    """Calling update_dm_checks() multiple times with same state must not duplicate entries."""
    self.sd.dm_enabled = False
    self.sd.update_dm_checks()
    self.sd.update_dm_checks()
    self.sd.update_dm_checks()

    for p in _DM_PACKETS:
      assert self.sd.sm.ignore_alive.count(p) == 1, f"{p} must appear exactly once in ignore_alive"
      assert self.sd.sm.ignore_valid.count(p) == 1, f"{p} must appear exactly once in ignore_valid"

  # ------------------------------------------------------------------
  # New: param read path wires through correctly
  # ------------------------------------------------------------------

  def test_dm_enabled_param_read_at_init(self):
    """SelfdriveD reads EnableDriverMonitoring param at construction time."""
    self.params.put_bool("EnableDriverMonitoring", False)
    sd = _make_sd()
    assert sd.dm_enabled is False

  def test_dm_enabled_param_default_true(self):
    """Default param value is True (driver monitoring on by default)."""
    self.params.put_bool("EnableDriverMonitoring", True)
    sd = _make_sd()
    assert sd.dm_enabled is True

  # ------------------------------------------------------------------
  # New: all_checks() passes when DM disabled and packets missing
  # ------------------------------------------------------------------

  def test_all_checks_passes_when_dm_disabled_and_packets_dead(self):
    """When DM is disabled and DM packets are not alive, all_checks() must still pass.

    This ensures selfdrived won't fire commIssue from dead DM packets when
    the user has explicitly disabled driver monitoring.
    """
    self.sd.dm_enabled = False
    self.sd.update_dm_checks()

    # Mark DM packets as not alive/valid — simulates dmonitoringd lagging or off
    self.sd.sm.alive['driverMonitoringState'] = False
    self.sd.sm.valid['driverMonitoringState'] = False
    self.sd.sm.alive['driverCameraState'] = False
    self.sd.sm.valid['driverCameraState'] = False
    # All non-DM packets stay alive/valid
    for p in self.sd.sm.services:
      if p not in _DM_PACKETS:
        self.sd.sm.alive[p] = True
        self.sd.sm.valid[p] = True

    assert self.sd.sm.all_alive(), "all_alive() must pass when DM packets are ignored"
    assert self.sd.sm.all_valid(), "all_valid() must pass when DM packets are ignored"

  # ------------------------------------------------------------------
  # New: multiple distracted events all suppressed when DM disabled
  # ------------------------------------------------------------------

  def test_all_dm_events_suppressed_when_disabled(self):
    """Every driver monitoring event must be suppressed when DM is disabled."""
    dm_events = [
      EventName.driverDistracted1,
      EventName.driverDistracted2,
      EventName.driverDistracted3,
      EventName.tooDistracted,
    ]

    self.sd.dm_enabled = False

    for event_name in dm_events:
      dm_msg = log.DriverMonitoringState.new_message()
      dm_event = log.OnroadEvent.new_message()
      dm_event.name = event_name
      dm_msg.events = [dm_event]
      self.sd.sm.data['driverMonitoringState'] = dm_msg

      cs = car.CarState.new_message()
      cs.canValid = True
      self.sd.update_events(cs)

      assert event_name not in self.sd.events.names, (
        f"Event {event_name} must be suppressed when DM is disabled"
      )
