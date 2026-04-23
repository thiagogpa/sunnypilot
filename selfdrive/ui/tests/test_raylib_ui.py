import time
from openpilot.selfdrive.test.helpers import with_processes, set_params_enabled


@with_processes(["ui"])
def test_raylib_ui():
  """Test initialization of the UI widgets is successful."""
  set_params_enabled()
  time.sleep(1)
