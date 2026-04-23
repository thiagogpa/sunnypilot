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
    
    # 2. Simulate camera malfunction (no packets)
    self.sd.sm.alive['driverCameraState'] = False
    self.sd.sm.valid['driverCameraState'] = False
    
    # 3. Update events
    cs = car.CarState.new_message()
    self.sd.update_events(cs)
    
    # 4. Verify no cameraMalfunction or commIssue events
    assert EventName.cameraMalfunction not in self.sd.events.names
    assert EventName.commIssue not in self.sd.events.names
    
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
