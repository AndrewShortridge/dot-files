# ksession_kitty_watcher.py — kitty watcher for ksession nvim session capture
#
# Installed at ~/.config/kitty/ksession_kitty_watcher.py and referenced
# via `watcher ksession_kitty_watcher.py` in kitty.conf.
#
# Requires: msgpack-python (pip install msgpack) in kitty's Python environment.
# If msgpack is unavailable the watcher degrades gracefully — logs a warning
# and skips mksession calls without crashing kitty.

from typing import Any
import time
import threading
import socket
import os

try:
    import msgpack
except ImportError:
    msgpack = None  # type: ignore

# debounce state per window
_debounce: dict[int, float] = {}
_DEBOUNCE_S = float(os.environ.get('KSESSION_WATCHER_DEBOUNCE_MS', '500')) / 1000.0

_LOG_PATH = os.path.expanduser('~/.cache/ksession/watcher.log')


def _log(msg: str) -> None:
    """Best-effort append to log file."""
    try:
        os.makedirs(os.path.dirname(_LOG_PATH), exist_ok=True)
        with open(_LOG_PATH, 'a') as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def _run_mksession(nvim_sock: str, cache_path: str) -> None:
    """Connect to nvim via msgpack-RPC and run :mksession! to cache_path."""
    if msgpack is None:
        _log("msgpack not available")
        return
    try:
        # Ensure cache dir exists
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        sock.connect(nvim_sock)

        # msgpack-RPC: [type=0(request), msgid=1, method, params]
        msg = msgpack.packb([0, 1, "nvim_command", [f"mksession! {cache_path}"]])
        sock.sendall(msg)

        # Read response (drain to avoid broken pipe)
        try:
            sock.recv(4096)
        except socket.timeout:
            pass
        sock.close()
    except Exception as e:
        _log(f"mksession failed for {nvim_sock}: {e}")


def _maybe_capture(boss: Any, window: Any) -> None:
    """Run :mksession! into the cache path for a given window."""
    nvim_sock = window.user_vars.get('nvim_socket')
    cache_path = window.user_vars.get('ksession_cache_path')
    if not (nvim_sock and cache_path):
        return
    threading.Thread(
        target=_run_mksession,
        args=(nvim_sock, cache_path),
        daemon=True,
    ).start()


def on_set_user_var(boss: Any, window: Any, data: dict[str, Any]) -> None:
    """Fires when nvim emits OSC 1337 SetUserVar nvim_dirty=<ts>."""
    if data.get('key') != 'nvim_dirty':
        return
    now = time.monotonic()
    last = _debounce.get(window.id, 0)
    if now - last < _DEBOUNCE_S:
        return
    _debounce[window.id] = now
    _maybe_capture(boss, window)


def on_cmd_startstop(boss: Any, window: Any, data: dict[str, Any]) -> None:
    """Fires on shell command finish. Triggers refresh on nvim windows in same OS window."""
    if data.get('is_start'):
        return
    for w in boss.all_windows:
        if w.user_vars.get('nvim_socket'):
            _maybe_capture(boss, w)
