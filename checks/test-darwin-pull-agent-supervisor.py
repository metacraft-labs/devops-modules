"""Exercise the launchd protocol without access to the builder's system domain."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


supervisor, worker_plist, poller_before, poller_after = sys.argv[1:]
assert json.loads(poller_before) != json.loads(poller_after), "fixture must change its own plist"

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    backend = root / "launchctl"
    backend.write_text(
        "#!" + sys.executable + "\n" + r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["LAUNCHD_FIXTURE"])
path = root / "state.json"
state = json.loads(path.read_text())
args = sys.argv[1:]
state["calls"].append(args)
code = 0
if args[0] == "print-disabled":
    print('"probe" => ' + str(state.get("disabled", False)).lower())
elif args[0] == "print":
    if args[1] not in state["jobs"]:
        code = 113
    elif args[1] == "system/probe-transaction":
        if state.get("switch_pending"):
            # Model nix-darwin replacing the poller's changed plist. Its
            # transaction remains a distinct launchd job, not its child.
            state["jobs"].pop("system/probe", None)
            state["switch_pending"] = False
            print("pid = 123")
        elif state.get("live"):
            print("pid = 123")
        else:
            print("last exit code = " + str(state.get("result", 0)))
    else:
        print("pid = 456")
elif args[0] == "bootstrap":
    label = "system/probe" if args[2] == str(root / "probe.plist") else "system/probe-transaction"
    state["jobs"][label] = True
elif args[0] == "bootout":
    del state["jobs"][args[1]]
else:
    raise AssertionError(args)
path.write_text(json.dumps(state))
sys.exit(code)
'''
    )
    backend.chmod(0o755)
    plist = root / "probe.plist"
    plist.touch()
    env = dict(os.environ, LAUNCHD_FIXTURE=directory)

    def run(mode, state, expected=0):
        state["calls"] = []
        (root / "state.json").write_text(json.dumps(state))
        args = ["probe-transaction", worker_plist] if mode == "poll" else ["probe", str(plist)]
        result = subprocess.run([supervisor, str(backend), mode, *args], env=env, timeout=30)
        assert result.returncode == expected, (state, result.returncode, expected)
        return json.loads((root / "state.json").read_text())

    # Both success and health/rollback failure propagate the transaction's
    # result, even though activation removed the original poller's changed job.
    for result in (0, 1, 75):
        state = run("poll", {"jobs": {"system/probe": True}, "switch_pending": True, "result": result}, result)
        assert "system/probe" not in state["jobs"]
        assert "system/probe-transaction" not in state["jobs"]
        assert ["bootstrap", "system", worker_plist] in state["calls"]

    # A replacement poller reattaches instead of replaying activation.
    state = run("poll", {"jobs": {"system/probe-transaction": True}, "result": 1}, 1)
    assert not any(call[0] == "bootstrap" for call in state["calls"])

    for jobs, disabled, live, should_load in (
        ({}, False, False, True),
        ({}, True, False, False),
        ({"system/probe": True}, False, False, False),
        ({"system/probe-transaction": True}, False, True, False),
        ({"system/probe-transaction": True}, False, False, True),
    ):
        state = run("recover", {"jobs": jobs, "disabled": disabled, "live": live})
        assert any(call[0] == "bootstrap" for call in state["calls"]) == should_load

print("Darwin changed-plist transaction, reattachment and recovery checks passed")
