"""bus-register.sh against a stubbed `cmux` CLI (no live app needed).

The stub reads its topology from environment variables so each test can
declare which surfaces are live and which surface the caller is.
"""
import os
import shutil
import stat
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "bus-register.sh"

CMUX_STUB = r'''#!/bin/sh
# Stub cmux: topology comes from CMUX_STUB_LIVE (space-separated surface:N)
# and CMUX_STUB_CALLER (surface:N or empty). CMUX_STUB_ALL_ONLY=1 makes a
# plain `tree` (no --all) show only the first live surface, mimicking the
# current-workspace default. With `--id-format both`, the surface named by
# CMUX_STUB_UUID_REF also shows CMUX_STUB_UUID.
json=0; both=0
for a in "$@"; do [ "$a" = "--json" ] && json=1; [ "$a" = "both" ] && both=1; done
case " $* " in
  *" tree "*)
    live=$CMUX_STUB_LIVE
    case " $* " in *" --all "*) ;; *) [ "${CMUX_STUB_ALL_ONLY:-0}" = 1 ] && live=${live%% *} ;; esac
    echo "window window:1"
    for s in $live; do
      id=""
      [ $both = 1 ] && [ "$s" = "${CMUX_STUB_UUID_REF:-}" ] && id=" $CMUX_STUB_UUID"
      echo "    surface $s$id \"pane $s\" [terminal]"
    done
    exit 0 ;;
  *" identify "*)
    if [ $json = 1 ]; then
      if [ -n "${CMUX_STUB_CALLER:-}" ]; then
        printf '{"server":{"version":"stub"},"caller":{"surface_ref":"%s","surface_type":"terminal","pane_ref":"pane:1"},"focused":{"surface_ref":"surface:1"}}\n' "$CMUX_STUB_CALLER"
      else
        printf '{"server":{"version":"stub"},"caller":{"surface_ref":null},"focused":{"surface_ref":"surface:1"}}\n'
      fi
    else
      echo "server: stub"
      echo "caller: ${CMUX_STUB_CALLER:-none}"
    fi
    exit 0 ;;
esac
echo "stub: unsupported: $*" >&2
exit 1
'''


@pytest.fixture
def bus(tmp_path):
    """Copy the scripts into a scratch repo root with a stub cmux on PATH."""
    root = tmp_path / "repo"
    (root / "scripts").mkdir(parents=True)
    shutil.copy(SCRIPT, root / "scripts" / SCRIPT.name)
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    stub = stub_dir / "cmux"
    stub.write_text(CMUX_STUB)
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    peers = root / ".agent_bus" / "peers"

    def run(*args, live="surface:1 surface:2", caller="surface:1", env=None,
            check=False):
        full_env = dict(os.environ)
        full_env["PATH"] = f"{stub_dir}{os.pathsep}{full_env['PATH']}"
        full_env["CMUX_STUB_LIVE"] = live
        full_env["CMUX_STUB_CALLER"] = caller or ""
        full_env.pop("CMUX_SURFACE_ID", None)
        full_env.update(env or {})
        proc = subprocess.run(
            ["sh", str(root / "scripts" / SCRIPT.name), *args],
            env=full_env, capture_output=True, text=True,
        )
        if check:
            assert proc.returncode == 0, proc.stderr
        return proc

    run.peers = peers
    run.root = root
    return run


def entries(peers):
    return dict(
        line.split()
        for line in peers.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    )


def test_register_parses_identify_json(bus):
    proc = bus("devin", caller="surface:2", check=True)
    assert "registered devin as surface:2" in proc.stdout
    assert entries(bus.peers) == {"devin": "surface:2"}


def test_register_without_jq_uses_sed_fallback(bus, tmp_path):
    # Hide jq behind a PATH that only contains the stub and core utilities.
    if shutil.which("jq") is None:
        pytest.skip("jq not installed; fallback is already the default path")
    nojq = tmp_path / "nojq"
    nojq.mkdir()
    for tool in ("sh", "awk", "sed", "grep", "tr", "head", "cat", "mkdir", "rmdir",
                 "mv", "sort", "sleep", "basename", "dirname", "printf",
                 "rm", "date", "stat", "ps"):
        src = shutil.which(tool)
        if src:
            os.symlink(src, nojq / tool)
    bus("devin", caller="surface:2",
        env={"PATH": f"{tmp_path / 'bin'}{os.pathsep}{nojq}"}, check=True)
    assert entries(bus.peers) == {"devin": "surface:2"}
    # unlock must actually run: peers.lock (incl. its pid file) is gone
    assert not (bus.root / ".agent_bus" / "peers.lock").exists()


def test_register_fails_outside_cmux(bus):
    proc = bus("devin", caller="")
    assert proc.returncode == 1
    assert "no caller surface" in proc.stderr
    assert not bus.peers.exists()


def test_register_falls_back_to_cmux_surface_id_env(bus):
    uuid = "0f8c5e1a-1111-4222-8333-444455556666"
    bus("devin", caller="", live="surface:1 surface:7",
        env={"CMUX_SURFACE_ID": uuid, "CMUX_STUB_UUID_REF": "surface:7",
             "CMUX_STUB_UUID": uuid}, check=True)
    assert entries(bus.peers) == {"devin": "surface:7"}


def test_reregister_same_surface_is_idempotent(bus):
    bus("devin", caller="surface:1", check=True)
    bus("devin", caller="surface:1", check=True)
    text = bus.peers.read_text()
    assert text.count("devin ") == 1
    assert entries(bus.peers) == {"devin": "surface:1"}


def test_name_collision_with_live_surface_is_rejected(bus):
    bus("devin", caller="surface:1", check=True)
    proc = bus("devin", caller="surface:2")
    assert proc.returncode == 1
    assert "already registered to live surface surface:1" in proc.stderr
    assert entries(bus.peers) == {"devin": "surface:1"}


def test_force_takes_over_name(bus):
    bus("devin", caller="surface:1", check=True)
    bus("devin", "--force", caller="surface:2", check=True)
    assert entries(bus.peers) == {"devin": "surface:2"}


def test_dead_holder_can_be_replaced_without_force(bus):
    bus("devin", caller="surface:1", check=True)
    # surface:1 closed; a new agent claims the same name.
    bus("devin", live="surface:2", caller="surface:2", check=True)
    assert entries(bus.peers) == {"devin": "surface:2"}


def test_prune_drops_dead_entries_including_last_line(bus):
    bus.peers.parent.mkdir(parents=True)
    bus.peers.write_text(
        "# header\n"
        "alive surface:1\n"
        "\n"
        "garbage-without-ref\n"
        "gone surface:9\n"
    )
    proc = bus("--prune", live="surface:1", check=True)
    assert proc.stdout == ""
    assert bus.peers.read_text() == "# header\nalive surface:1\n\n"


def test_prune_keeps_non_surface_refs(bus):
    bus.peers.parent.mkdir(parents=True)
    bus.peers.write_text("byuuid 0f8c5e1a-1111-4222-8333-444455556666\n")
    bus("--prune", check=True)
    assert entries(bus.peers) == {"byuuid": "0f8c5e1a-1111-4222-8333-444455556666"}


def test_list_prunes_before_printing(bus):
    bus("devin", caller="surface:1", check=True)
    bus("codex", caller="surface:2", check=True)
    proc = bus("--list", live="surface:1", check=True)
    assert "devin surface:1" in proc.stdout
    assert "codex" not in proc.stdout
    assert entries(bus.peers) == {"devin": "surface:1"}


def test_prune_sees_all_workspaces(bus):
    bus("devin", caller="surface:1", check=True)
    bus("codex", caller="surface:2", check=True)
    # Plain `cmux tree` would show only surface:1; --all must be used.
    bus("--prune", env={"CMUX_STUB_ALL_ONLY": "1"}, check=True)
    assert entries(bus.peers) == {"devin": "surface:1", "codex": "surface:2"}


def test_register_requires_caller_in_live_tree(bus):
    proc = bus("devin", live="surface:1", caller="surface:5")
    assert proc.returncode == 1
    assert "not in the live tree" in proc.stderr


def test_invalid_name_and_usage(bus):
    assert bus("bad name!").returncode == 1
    assert bus().returncode == 2
    assert bus("--list", "devin").returncode == 2
    assert bus("--bogus").returncode == 2


def test_no_live_surfaces_is_an_error(bus):
    proc = bus("devin", live="")
    assert proc.returncode == 1
    assert "cannot reach cmux socket" in proc.stderr


def test_stale_lock_is_broken(bus):
    bus.peers.parent.mkdir(parents=True)
    (bus.peers.parent / "peers.lock").mkdir()
    proc = bus("devin", env={"BUS_LOCK_TIMEOUT": "1"}, check=True)
    assert entries(bus.peers) == {"devin": "surface:1"}
    assert not (bus.peers.parent / "peers.lock").exists()


def test_concurrent_registrations_do_not_lose_entries(bus):
    names = [f"agent{i}" for i in range(12)]
    live = " ".join(f"surface:{i}" for i in range(1, len(names) + 1))
    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        procs = list(pool.map(
            lambda pair: bus(pair[0], live=live, caller=pair[1]),
            zip(names, live.split()),
        ))
    for proc in procs:
        assert proc.returncode == 0, proc.stderr
    assert entries(bus.peers) == dict(zip(names, live.split()))
    assert not (bus.peers.parent / "peers.lock").exists()


def test_lock_from_dead_process_is_reclaimed(bus):
    dead = subprocess.Popen(["true"])
    dead.wait()
    lockdir = bus.peers.parent / "peers.lock"
    lockdir.mkdir(parents=True)
    (lockdir / "pid").write_text(str(dead.pid))
    bus("devin", caller="surface:1", check=True)
    assert entries(bus.peers) == {"devin": "surface:1"}
    assert not lockdir.exists()


def test_lock_from_live_process_is_not_stolen(bus):
    sleeper = subprocess.Popen(["sleep", "60"])
    lockdir = bus.peers.parent / "peers.lock"
    lockdir.mkdir(parents=True)
    (lockdir / "pid").write_text(str(sleeper.pid))
    try:
        proc = bus("devin", caller="surface:1",
                   env={"BUS_LOCK_WAIT_TIMEOUT": "2"})
        assert proc.returncode == 1
        assert "held by live pid" in proc.stderr
        assert lockdir.exists()
    finally:
        sleeper.kill()
        sleeper.wait()


def test_lock_with_recycled_pid_is_reclaimed(bus):
    # The pid in the lock is alive but belongs to a process that started
    # AFTER the lock dir was created - i.e. the crashed writer's pid was
    # recycled. Registration must still reclaim the lock.
    sleeper = subprocess.Popen(["sleep", "60"])
    lockdir = bus.peers.parent / "peers.lock"
    try:
        lockdir.mkdir(parents=True)
        (lockdir / "pid").write_text(str(sleeper.pid))
        # Writing pid bumped the dir mtime; age it so the lock predates
        # the process regardless of wall-clock granularity.
        old = time.time() - 100
        os.utime(lockdir, (old, old))
        bus("devin", caller="surface:1", check=True)
        assert entries(bus.peers) == {"devin": "surface:1"}
        assert not lockdir.exists()
    finally:
        sleeper.kill()
        sleeper.wait()
