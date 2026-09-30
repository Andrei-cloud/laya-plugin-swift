"""Plugin switch state — profile layer over shared layer (D6 dual-named).

State file:  <layer>/laya/state.json   (canonical)
             <layer>/jev/state.json    (alias path — same FILE via the
             resolver below; never two divergent states)

Precedence (spec-v2 §3: "profile > shared"):
  <profile>/laya/state.json  >  <hermes_root>/laya/state.json  >  defaults
Defaults are OFF/OFF/OFF with merge_requests ON (the upstream safe default —
a plugin install changes nothing until someone flips a switch).

`/laya routing on [all]` writes the shared layer; without `all` it writes the
profile layer. The state module is the ONLY writer (DRY; the slash command
and the CLI both call set_switch).
"""
import json
import os
import threading
from pathlib import Path

from naming import env_alias, hermes_root

_lock = threading.Lock()
DEFAULTS = {"routing": "off", "skills": "off", "notice": "off",
            "merge_requests": "on", "handoff": "off"}

OWN_NAME = "laya"           # namespace this plugin writes under
ALIAS_NAME = "jev"          # read as alias for pre-existing setups
_owner_note = None          # set when an upstream co-installed plugin owns a name


def _profile_dir():
    """The MACHINE-WIDE layer (pre-profile installs): ~/.hermes.

    NOTE the historical inversion: with a profile-scoped plugin install
    under a multiplexed host, ``hermes_root()`` answers the SERVED
    profile's home (profiles/<p>), so "shared" here = the served
    profile — while ``_profile_dir()`` used to pin the launch home and
    let machine-wide switches silently outrank the served profile's own
    state.json. Under a served profile the layers are reordered in
    _layer_path so the served profile wins; with hermes_root() outside
    ~/.hermes/profiles (single-profile / daemon / CLI) both layers
    collapse to hermes_root() — byte-identical to the old behaviour."""
    return Path(env_alias("PROFILE_DIR") or os.path.expanduser("~/.hermes"))


def _served_profile_dir():
    """The SERVED profile layer when hermes_root() points at a named
    profile under the machine home (~/.hermes/profiles/<p>); None
    otherwise. This is where a per-profile soak flips its switches and
    where the plugin's own state.json already lives."""
    root = hermes_root()
    profiles = _profile_dir() / "profiles"
    try:
        root.relative_to(profiles)
    except ValueError:
        return None
    return root


def _layer_state_path(base: Path) -> Path:
    """The state file under `base`: canonical laya/ unless ONLY the
    pre-existing jev/ alias exists (D6 — never fork two states)."""
    canon = base / OWN_NAME / "state.json"
    alias = base / ALIAS_NAME / "state.json"
    return canon if canon.exists() or not alias.exists() else alias


def _layer_order():
    """Ordered (label, dir) layers, FIRST WINS (setting() fills omitted
    keys from later layers). Single-profile host: (shared, profile) ==
    (~/.hermes, ~/.hermes) — the historical shape, kept byte-identical.
    Served named profile under a multiplex host: the SERVED profile
    leads, then machine-wide ~/.hermes, then the launch home only when
    it is a distinct directory (a named-profile launch — a stray
    launch-time state.json there must never outrank the served one)."""
    served = _served_profile_dir()
    if served is not None:
        machine = _profile_dir()
        dirs = [served, machine]
        launch = hermes_root()
        if launch not in dirs:
            dirs.append(launch)
        return [("served", d) for d in dirs]
    return [("shared", _profile_dir()), ("profile", hermes_root())]


def _read(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def setting(key: str, default=None):
    """First layer wins, later layers fill missing keys."""
    if default is None:
        default = DEFAULTS.get(key, "off")
    with _lock:
        for _label, base in _layer_order():
            v = _read(_layer_state_path(base)).get(key)
            if v is not None:
                return v
    return default


def set_switch(key: str, value: str, shared: bool = False) -> str:
    """The ONLY state mutation path (slash command + CLI both call this).
    Returns a human line naming the layer written (auditability).
    shared=True (the /laya ... [all] flag) writes the machine-wide
    ~/.hermes layer; the default writes the SERVED profile's own layer
    (the launch home on a single-profile host)."""
    with _lock:
        base = _profile_dir() if shared else _layer_order()[0][1]
        path = _layer_state_path(base)
        state = _read(path)
        state[key] = value
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    scope = ("the machine-wide default for EVERY profile (a profile's own "
             "setting still wins)" if shared
             else "set for this profile")
    return f"Laya {key} = {value}, {scope}."


def state_overview() -> dict:
    """Safe summary for /laya and doctor: effective switches with the
    layer each came from. Never any secret."""
    out = {}
    order = _layer_order()
    for key in DEFAULTS:
        layer = "default"
        val = DEFAULTS.get(key, "off")
        with _lock:
            for label, base in order:
                v = _read(_layer_state_path(base)).get(key)
                if v is not None:
                    val, layer = v, label
                    break
        out[key] = {"value": val, "layer": layer}
    return out


def ownership_note(note: str = None):
    """Remember (and surface) that a name collided with a co-installed
    upstream plugin — never silently shadow it."""
    global _owner_note
    if note is not None:
        _owner_note = note
    return _owner_note
