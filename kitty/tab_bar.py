"""`{custom}` for tab_title_template / active_tab_title_template in kitty.conf.

kitty's template only exposes `title`, which is the tab's manual name if one
was set (set_tab_title, `new_tab <name>` in a session file) and otherwise the
active window's title (whatever the foreground program sets). The tab bar
wants the cwd basename in the second case, so resolve the manual name here
and fall back to the directory.
"""

from typing import Any

from kitty.fast_data_types import get_boss


def draw_title(data: dict[str, Any]) -> str:
    accessor = data["tab"]
    tab = get_boss().tab_for_id(accessor.tab_id)
    name = tab.name if tab is not None else ""
    return name or accessor.active_wd.rsplit("/", 1)[-1]
