"""Disposable hostile-startup control and a marker-only postcondition."""
import json
import os
from pathlib import Path
import site
import subprocess
import sys

ROOT = Path("/tmp/nats-python-hooks")
USER_MARKER = Path("/tmp/nats-user-site-hook-ran")
PATH_MARKER = Path("/tmp/nats-pythonpath-hook-ran")
CONTROL = Path("/tmp/nats-python-hook-control.json")

if sys.argv[1] == "install":
    ROOT.mkdir(exist_ok=True)
    user_site = Path(site.getusersitepackages())
    user_site.mkdir(parents=True, exist_ok=True)
    (user_site / "nats_fixture_hook.pth").write_text("import pathlib; pathlib.Path('/tmp/nats-user-site-hook-ran').write_text('ran')\n")
    (ROOT / "sitecustomize.py").write_text("from pathlib import Path\nPath('/tmp/nats-pythonpath-hook-ran').write_text('ran')\n")
    subprocess.run([sys.executable, "-c", "pass"], check=True, env={**os.environ, "PYTHONPATH": str(ROOT)})
    assert USER_MARKER.exists() and PATH_MARKER.exists(), "Non-isolated positive control did not load both hooks"
    CONTROL.write_text(json.dumps({"user_site_active": True, "pythonpath_active": True}))
    USER_MARKER.unlink()
    PATH_MARKER.unlink()
    print("Disposable startup controls proven")
elif sys.argv[1] == "probe":
    print(json.dumps({**json.loads(CONTROL.read_text()), "user_site_hook_ran": USER_MARKER.exists(), "pythonpath_hook_ran": PATH_MARKER.exists()}))
else:
    raise RuntimeError("Unknown isolation fixture mode")
