"""
Copyright (c) 2021-, rav4kumar, Haibin Wen, sunnypilot, and a number of other contributors.

This file is part of sunnypilot and is licensed under the MIT License.
See the LICENSE.md file in the root directory for more details.
"""

from cereal import custom
import numpy as np
from openpilot.common.realtime import DT_MDL
from openpilot.common.params import Params

AccelPersonality = custom.LongitudinalPlanSP.AccelerationPersonality
ACCEL_PERSONALITY_OPTIONS = [AccelPersonality.eco, AccelPersonality.normal, AccelPersonality.sport]


MAX_ACCEL_BP = [0.0, 3.0, 6.0, 10.0, 15.0, 22.0, 30.0, 40.0]  # m/s

MAX_ACCEL_V = {
  AccelPersonality.eco:    [2.00, 1.40, 1.00, 0.70, 0.48, 0.30, 0.15, 0.06],
  AccelPersonality.normal: [2.00, 1.55, 1.15, 0.85, 0.60, 0.40, 0.20, 0.08],
  AccelPersonality.sport:  [2.00, 1.75, 1.40, 1.08, 0.80, 0.55, 0.28, 0.10],
}

MIN_ACCEL_BP = [0.0, 5.0, 10.0, 18.0, 28.0, 40.0]  # m/s

MIN_ACCEL_V = {
  AccelPersonality.eco:    [-0.10, -0.18, -0.28, -0.45, -0.65, -0.85],
  AccelPersonality.normal: [-0.18, -0.30, -0.46, -0.70, -0.95, -1.20],
  AccelPersonality.sport:  [-0.30, -0.50, -0.75, -1.10, -1.45, -1.80],
}


JERK_ACCEL_BP = [0.0,  8.0,  20.0,  35.0]   # m/s
JERK_ACCEL_V  = [0.80, 0.55,  0.40,  0.30]   # m/s² per s

JERK_DECEL_BP = [0.0,  8.0,  20.0,  35.0]   # m/s
JERK_DECEL_V  = [0.60, 0.40,  0.28,  0.20]   # m/s² per s

_MIN_MAX_GAP = 0.05


class AccelPersonalityController:
  def __init__(self):
    self.params = Params()
    self.frame = 0
    self.first_run = True
    self._last_max = 2.0
    self._last_min = -0.18
    self._cache_v: float | None = None
    self._cache_min: float = -0.18
    self._cache_max: float = 2.0

    val = self.params.get('AccelPersonality')
    self._accel_personality = val if val is not None else AccelPersonality.normal
    self._enabled = self.params.get_bool('AccelPersonalityEnabled')

  def update(self, sm=None):
    self.frame += 1
    self._cache_v = None
    if self.frame % max(1, int(1.0 / DT_MDL)) == 0:
      val = self.params.get('AccelPersonality')
      self._accel_personality = val if val is not None else AccelPersonality.normal
      self._enabled = self.params.get_bool('AccelPersonalityEnabled')

  @property
  def accel_personality(self) -> int:
    return self._accel_personality

  def get_accel_personality(self) -> int:
    return int(self._accel_personality)

  def set_accel_personality(self, personality: int):
    if personality in ACCEL_PERSONALITY_OPTIONS:
      self._accel_personality = personality
      self.params.put('AccelPersonality', personality)

  def cycle_accel_personality(self) -> int:
    current = self._accel_personality
    idx = ACCEL_PERSONALITY_OPTIONS.index(current) if current in ACCEL_PERSONALITY_OPTIONS else 0
    next_p = ACCEL_PERSONALITY_OPTIONS[(idx + 1) % len(ACCEL_PERSONALITY_OPTIONS)]
    self.set_accel_personality(next_p)
    return int(next_p)

  def _step(self, v_ego: float) -> tuple[float, float]:
    target_max = float(np.interp(v_ego, MAX_ACCEL_BP, MAX_ACCEL_V[self._accel_personality]))
    target_min = float(np.interp(v_ego, MIN_ACCEL_BP, MIN_ACCEL_V[self._accel_personality]))

    if self.first_run:
      self._last_max = target_max
      self._last_min = target_min
      self.first_run = False
      return target_min, target_max

    a_rate = float(np.interp(v_ego, JERK_ACCEL_BP, JERK_ACCEL_V)) * DT_MDL
    d_rate = float(np.interp(v_ego, JERK_DECEL_BP, JERK_DECEL_V)) * DT_MDL

    new_max = float(np.clip(target_max, self._last_max - a_rate, self._last_max + a_rate))
    new_min = float(np.clip(target_min, self._last_min - d_rate, self._last_min + d_rate))
    new_min = min(new_min, new_max - _MIN_MAX_GAP)

    self._last_max = new_max
    self._last_min = new_min
    return new_min, new_max

  def get_accel_limits(self, v_ego: float) -> tuple[float, float]:
    v_ego = max(0.0, v_ego)
    if self._cache_v is not None and abs(self._cache_v - v_ego) < 0.01:
      return self._cache_min, self._cache_max
    self._cache_min, self._cache_max = self._step(v_ego)
    self._cache_v = v_ego
    return self._cache_min, self._cache_max

  def get_min_accel(self, v_ego: float) -> float:
    return self.get_accel_limits(v_ego)[0]

  def get_max_accel(self, v_ego: float) -> float:
    return self.get_accel_limits(v_ego)[1]

  def is_enabled(self) -> bool:
    return self._enabled

  def set_enabled(self, enabled: bool):
    self._enabled = bool(enabled)
    self.params.put_bool('AccelPersonalityEnabled', self._enabled)

  def toggle_enabled(self) -> bool:
    self.set_enabled(not self._enabled)
    return self._enabled

  def reset(self, personality: int = None):
    new_p = personality if personality in ACCEL_PERSONALITY_OPTIONS else AccelPersonality.normal
    self._accel_personality = new_p
    self.params.put('AccelPersonality', new_p)
    self.frame = 0
    self._last_max = 2.0
    self._last_min = -0.18
    self._cache_v = None
    self.first_run = True
