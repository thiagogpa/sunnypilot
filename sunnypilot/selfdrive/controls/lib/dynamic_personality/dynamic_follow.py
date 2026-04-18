"""
Copyright (c) 2021-, rav4kumar, Haibin Wen, sunnypilot, and a number of other contributors.

This file is part of sunnypilot and is licensed under the MIT License.
See the LICENSE.md file in the root directory for more details.
"""

from cereal import log
import numpy as np
from openpilot.common.realtime import DT_MDL
from openpilot.common.params import Params

LongPersonality = log.LongitudinalPersonality

FOLLOW_BREAKPOINTS = [0.,  4.0,  8.0,  14.,  22.,  32.,  40.]  # m/s

FOLLOW_PROFILES = {
  LongPersonality.relaxed:    [1.75, 1.80, 1.90, 1.95, 2.05, 1.95, 2.10],
  LongPersonality.standard:   [1.45, 1.50, 1.58, 1.62, 1.70, 1.62, 1.72],
  LongPersonality.aggressive: [1.20, 1.24, 1.30, 1.34, 1.40, 1.34, 1.42],
}

ALPHA_HOLD     = 0.95   # normal following — high inertia
ALPHA_SNAP     = 0.70   # emergency/large error — fast response
ERROR_THRESHOLD = 0.15  # multiplier gap above which we blend toward ALPHA_SNAP
SPEED_BOOST_BP  = [0.0,  36.0]   # m/s
SPEED_BOOST_V   = [0.00,  0.02]  # additional alpha at highway (tiny extra smoothness)

PERSONALITY_CHANGE_COOLDOWN_S = 2.0


class FollowDistanceController:
  def __init__(self):
    self.params = Params()
    self.frame = 0
    self.current_multiplier = 1.45
    self.first_run = True
    self.personality_change_cooldown = 0
    self.personality_cooldown_frames = int(PERSONALITY_CHANGE_COOLDOWN_S / DT_MDL)
    val = self.params.get('LongitudinalPersonality')
    self._personality = val if val is not None else LongPersonality.standard
    self._enabled = self.params.get_bool('DynamicFollow')

  def _get_alpha(self, v_ego: float, target: float) -> float:
    error = abs(target - self.current_multiplier)
    blend = float(np.clip(error / ERROR_THRESHOLD, 0.0, 1.0))
    alpha = ALPHA_HOLD * (1.0 - blend) + ALPHA_SNAP * blend
    alpha += float(np.interp(v_ego, SPEED_BOOST_BP, SPEED_BOOST_V))
    return float(min(0.97, alpha))

  def is_enabled(self) -> bool:
    return self._enabled

  def set_enabled(self, enabled: bool):
    self._enabled = enabled
    self.params.put_bool('DynamicFollow', enabled)

  def toggle(self) -> bool:
    current = self._enabled
    self.set_enabled(not current)
    return not current

  @property
  def personality(self) -> int:
    return self._personality

  def get_personality(self) -> int:
    return int(self._personality)

  def set_personality(self, personality: int):
    if personality not in [LongPersonality.relaxed, LongPersonality.standard, LongPersonality.aggressive]:
      return
    self._personality = personality
    self.params.put('LongitudinalPersonality', personality)
    self.personality_change_cooldown = self.personality_cooldown_frames

  def cycle_personality(self) -> int:
    personalities = [LongPersonality.relaxed, LongPersonality.standard, LongPersonality.aggressive]
    current_idx = personalities.index(self._personality)
    next_p = personalities[(current_idx + 1) % len(personalities)]
    self.set_personality(next_p)
    return int(next_p)

  def get_follow_distance_multiplier(self, v_ego: float) -> float:
    v_ego = max(0.0, v_ego)
    target = float(np.interp(v_ego, FOLLOW_BREAKPOINTS, FOLLOW_PROFILES[self._personality]))

    if self.first_run:
      self.current_multiplier = target
      self.first_run = False
      return float(self.current_multiplier)

    if self.personality_change_cooldown > 0:
      return float(self.current_multiplier)

    alpha = self._get_alpha(v_ego, target)
    self.current_multiplier = alpha * self.current_multiplier + (1.0 - alpha) * target
    return float(self.current_multiplier)

  def reset(self):
    self._personality = LongPersonality.standard
    self.params.put('LongitudinalPersonality', LongPersonality.standard)
    self.frame = 0
    self.current_multiplier = 1.45
    self.first_run = True
    self.personality_change_cooldown = 0

  def update(self):
    self.frame += 1
    if self.personality_change_cooldown > 0:
      self.personality_change_cooldown -= 1
    if self.frame % max(1, int(1.0 / DT_MDL)) == 0:
      val = self.params.get('LongitudinalPersonality')
      self._personality = val if val is not None else LongPersonality.standard
      self._enabled = self.params.get_bool('DynamicFollow')
