import pytest
from cereal import car, log, custom
from openpilot.common.params import Params
from openpilot.selfdrive.selfdrived.selfdrived import SelfdriveD
from openpilot.selfdrive.selfdrived.events import EventName

class TestDmBypass:
  def setup_method(self):
    self.params = Params()
    # Mock CarParams for a supported car
    cp = car.CarParams.new_message()
    cp.carFingerprint = "TOYOTA_COROLLA_TSS2"
    cp.brand = "toyota"
    
    cp_sp = custom.CarParamsSP.new_message()
    self.sd = SelfdriveD(CP=cp, CP_SP=cp_sp)
    self.sd.initialized = True
    
  def test_dm_disabled_bypass(self):
    # 1. Disable DM toggle
    self.params.put_bool("EnableDriverMonitoring", False)
    self.sd.dm_enabled = False
    
    # 2. Simulate camera malfunction (no driver packets, but others alive)
    for p in self.sd.camera_packets:
      self.sd.sm.alive[p] = True
    self.sd.sm.alive['driverCameraState'] = False
    self.sd.sm.valid['driverCameraState'] = False
    self.sd.sm.alive['driverMonitoringState'] = False
    
    # 3. Update events
    cs = car.CarState.new_message()
    self.sd.update_events(cs)
    
    # 4. Verify no cameraMalfunction or commIssue events
    assert EventName.cameraMalfunction not in self.sd.events.names
    assert EventName.commIssue not in self.sd.events.names

  def test_dm_disabled_events_bypass(self):
    # 1. Disable DM toggle
    self.params.put_bool("EnableDriverMonitoring", False)
    self.sd.dm_enabled = False
    
    # 2. Simulate a DM event (e.g. distracted)
    dm_msg = log.DriverMonitoringState.new_message()
    dm_event = log.OnroadEvent.new_message()
    dm_event.name = EventName.tooDistracted
    dm_msg.events = [dm_event]
    self.sd.sm.data['driverMonitoringState'] = dm_msg
    
    # 3. Update events
    cs = car.CarState.new_message()
    cs.canValid = True
    self.sd.update_events(cs)
    
    # 4. Verify tooDistracted is NOT present
    assert EventName.tooDistracted not in self.sd.events.names

  def test_dm_enabled_no_bypass(self):
    # 1. Enable DM toggle
    self.params.put_bool("EnableDriverMonitoring", True)
    self.sd.dm_enabled = True
    
    # 2. Simulate camera malfunction
    self.sd.sm.alive['driverCameraState'] = False
    
    # 3. Update events
    cs = car.CarState.new_message()
    self.sd.update_events(cs)
    
    # 4. Verify cameraMalfunction is present
    assert EventName.cameraMalfunction in self.sd.events.names
