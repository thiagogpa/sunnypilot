import traceback
import cereal.messaging as messaging

from opendbc.can.packer import CANPacker
from openpilot.common.params import Params
from openpilot.selfdrive.pandad.pandad_api_impl import can_list_to_can_capnp
from openpilot.tools.sim.lib.common import SimulatorState


class SimulatedSubaruCar:
  """Simulates a Subaru Impreza Gen1 (panda state + CAN messages) to OpenPilot"""
  packer = CANPacker("subaru_global_2017_generated")

  def __init__(self):
    self.pm = messaging.PubMaster(['can', 'pandaStates'])
    self.sm = messaging.SubMaster(['carControl', 'controlsState', 'carParams', 'selfdriveState'])
    self.idx = 0
    self.params = Params()

  def send_can_messages(self, simulator_state: SimulatorState):
    if not simulator_state.valid:
      return

    speed_kph = simulator_state.speed * 3.6
    msg = []

    # *** powertrain bus (bus 0) ***

    # Wheel speeds → vEgoRaw + standstill
    msg.append(self.packer.make_can_msg("Wheel_Speeds", 0, {
      "FL": speed_kph, "FR": speed_kph, "RL": speed_kph, "RR": speed_kph,
    }))

    # Steering angle and torque (steeringAngleDeg, steeringPressed)
    msg.append(self.packer.make_can_msg("Steering_Torque", 0, {
      "Steering_Angle": simulator_state.steering_angle,
      "Steer_Torque_Sensor": simulator_state.user_torque,
      "Steer_Torque_Output": 0,
      "Steer_Error_1": 0,
      "Steer_Warning": 0,
    }))

    # Brake pressed — Gen1 non-PREGLOBAL uses Brake_Status.Brake, not Brake_Pedal
    msg.append(self.packer.make_can_msg("Brake_Status", 0, {
      "Brake": 1 if simulator_state.user_brake > 0 else 0,
    }))

    # Throttle / gas
    msg.append(self.packer.make_can_msg("Throttle", 0, {
      "Throttle_Pedal": simulator_state.user_gas * 255,
    }))

    # Cruise state — Cruise_On=1 keeps cruise available; Cruise_Activated follows engagement
    msg.append(self.packer.make_can_msg("CruiseControl", 0, {
      "Cruise_Activated": int(simulator_state.is_engaged),
      "Cruise_On": 1,
    }))

    # ES_Status — copied by carstate for forwarding, keep zeroed
    msg.append(self.packer.make_can_msg("ES_Status", 0, {}))

    # Dashlights — blinkers, seatbelt, units
    msg.append(self.packer.make_can_msg("Dashlights", 0, {
      "LEFT_BLINKER": int(simulator_state.left_blinker),
      "RIGHT_BLINKER": int(simulator_state.right_blinker),
      "SEATBELT_FL": 0,  # latched
      "UNITS": 0,        # metric
    }))

    # BodyInfo — all doors closed
    msg.append(self.packer.make_can_msg("BodyInfo", 0, {
      "DOOR_OPEN_FL": 0, "DOOR_OPEN_FR": 0,
      "DOOR_OPEN_RL": 0, "DOOR_OPEN_RR": 0,
    }))

    # Transmission — Drive
    msg.append(self.packer.make_can_msg("Transmission", 0, {
      "Gear": 121,  # D
    }))

    # *** camera bus (bus 2) ***

    # ES_DashStatus — cruise set speed + state
    msg.append(self.packer.make_can_msg("ES_DashStatus", 2, {
      "Cruise_On": 1,
      "Cruise_Set_Speed": 50,
      "Cruise_State": 0,
      "Conventional_Cruise": 0,
    }))

    # ES_LKAS_State — no alerts
    msg.append(self.packer.make_can_msg("ES_LKAS_State", 2, {
      "LKAS_Alert": 0,
    }))

    # ES_Distance — no cruise fault
    msg.append(self.packer.make_can_msg("ES_Distance", 2, {
      "Cruise_Fault": 0,
    }))

    # ES_Brake — no AEB
    msg.append(self.packer.make_can_msg("ES_Brake", 2, {
      "AEB_Status": 0,
      "Brake_Pressure": 0,
    }))

    self.pm.send('can', can_list_to_can_capnp(msg))

  def send_panda_state(self, simulator_state: SimulatorState):
    self.sm.update(0)

    dat = messaging.new_message('pandaStates', 1)
    dat.valid = True
    dat.pandaStates[0] = {
      'ignitionLine': simulator_state.ignition,
      'pandaType': "blackPanda",
      'controlsAllowed': True,
      'controlsAllowedLateral': True,
      'controlsAllowedLongitudinal': True,
      'safetyModel': 'subaru',
      'alternativeExperience': self.sm["carParams"].alternativeExperience,
      'safetyParam': 0,
    }
    self.pm.send('pandaStates', dat)

  def update(self, simulator_state: SimulatorState):
    try:
      self.send_can_messages(simulator_state)

      if self.idx % 50 == 0:  # panda states at 2 Hz
        self.send_panda_state(simulator_state)

      self.idx += 1
    except Exception:
      traceback.print_exc()
      raise
