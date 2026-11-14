"""Unit tests for ksession_kitty_watcher debounce logic."""

import sys
import os
import time
from unittest.mock import patch, MagicMock

# Add scripts dir to path so we can import the watcher
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))

import ksession_kitty_watcher as watcher


class FakeWindow:
    """Minimal mock of a kitty window object."""

    def __init__(self, window_id: int, user_vars: dict | None = None):
        self.id = window_id
        self.user_vars = user_vars or {}


class FakeBoss:
    """Minimal mock of the kitty boss object."""

    def __init__(self, windows: list | None = None):
        self.all_windows = windows or []


class TestDebounce:
    """Tests for on_set_user_var debounce behavior."""

    def setup_method(self):
        # Reset debounce state between tests
        watcher._debounce.clear()

    @patch.object(watcher, '_maybe_capture')
    def test_two_calls_within_debounce_window_fires_once(self, mock_capture):
        """Two on_set_user_var calls within 100ms should only trigger one capture."""
        window = FakeWindow(1, {'nvim_socket': '/tmp/nvim.sock', 'ksession_cache_path': '/tmp/s.vim'})
        boss = FakeBoss()
        data = {'key': 'nvim_dirty', 'value': '1716000000'}

        watcher.on_set_user_var(boss, window, data)
        # Simulate second call 100ms later (well within 500ms debounce)
        time.sleep(0.1)
        watcher.on_set_user_var(boss, window, data)

        assert mock_capture.call_count == 1

    @patch.object(watcher, '_maybe_capture')
    def test_two_calls_outside_debounce_window_fires_twice(self, mock_capture):
        """Two on_set_user_var calls 600ms apart should both trigger capture."""
        window = FakeWindow(2, {'nvim_socket': '/tmp/nvim.sock', 'ksession_cache_path': '/tmp/s.vim'})
        boss = FakeBoss()
        data = {'key': 'nvim_dirty', 'value': '1716000000'}

        watcher.on_set_user_var(boss, window, data)
        # Wait beyond the 500ms debounce window
        time.sleep(0.6)
        watcher.on_set_user_var(boss, window, data)

        assert mock_capture.call_count == 2

    @patch.object(watcher, '_maybe_capture')
    def test_different_key_ignored(self, mock_capture):
        """on_set_user_var with a key other than 'nvim_dirty' is a no-op."""
        window = FakeWindow(3)
        boss = FakeBoss()
        data = {'key': 'some_other_var', 'value': 'hello'}

        watcher.on_set_user_var(boss, window, data)

        mock_capture.assert_not_called()


class TestCmdStartStop:
    """Tests for on_cmd_startstop behavior."""

    @patch.object(watcher, '_maybe_capture')
    def test_is_start_is_noop(self, mock_capture):
        """on_cmd_startstop with is_start=True should not trigger capture."""
        window = FakeWindow(10, {'nvim_socket': '/tmp/nvim.sock'})
        boss = FakeBoss([window])
        data = {'is_start': True}

        watcher.on_cmd_startstop(boss, window, data)

        mock_capture.assert_not_called()

    @patch.object(watcher, '_maybe_capture')
    def test_cmd_stop_triggers_capture_on_nvim_windows(self, mock_capture):
        """on_cmd_startstop on command finish should trigger capture for nvim windows."""
        nvim_window = FakeWindow(11, {'nvim_socket': '/tmp/nvim.sock', 'ksession_cache_path': '/tmp/s.vim'})
        plain_window = FakeWindow(12, {})
        boss = FakeBoss([nvim_window, plain_window])
        data = {'is_start': False}

        watcher.on_cmd_startstop(boss, plain_window, data)

        # Should capture the nvim window, not the plain one
        mock_capture.assert_called_once_with(boss, nvim_window)


if __name__ == '__main__':
    import pytest
    pytest.main([__file__, '-v'])
