PREFIX ?= $(HOME)/.local
BIN_DIR ?= $(PREFIX)/bin
LUA_DIR ?= $(PREFIX)/share/nvim/site/lua
SHARE_DIR ?= $(PREFIX)/share/ksession
BIN_NAME ?= ksession

# Watcher + nvim plugin install targets (PRD-0010)
KITTY_CONF_DIR ?= $(HOME)/.config/kitty
NVIM_SITE_DIR ?= $(HOME)/.local/share/nvim/site/plugin

.PHONY: build test install uninstall clean \
	install-watcher install-nvim-plugin install-shell-hook install-all \
	uninstall-watcher uninstall-nvim-plugin uninstall-shell-hook uninstall-all

build:
	cargo build --release

test:
	cargo test

install: build
	install -Dm755 target/release/$(BIN_NAME) $(BIN_DIR)/$(BIN_NAME)
	install -Dm755 target/release/scrollback_injector $(BIN_DIR)/scrollback_injector
	install -Dm644 assets/lua/ksession_restore.lua $(LUA_DIR)/ksession_restore.lua
	install -Dm644 scripts/ksession-trace-lib.sh $(SHARE_DIR)/ksession-trace-lib.sh

uninstall:
	rm -f $(BIN_DIR)/$(BIN_NAME)
	rm -f $(BIN_DIR)/scrollback_injector
	rm -f $(LUA_DIR)/ksession_restore.lua
	rm -f $(SHARE_DIR)/ksession-trace-lib.sh

install-watcher: scripts/ksession_kitty_watcher.py
	@mkdir -p $(KITTY_CONF_DIR)
	cp scripts/ksession_kitty_watcher.py $(KITTY_CONF_DIR)/ksession_kitty_watcher.py
	@echo "Installed watcher to $(KITTY_CONF_DIR)/ksession_kitty_watcher.py"
	@echo "Add 'watcher ksession_kitty_watcher.py' to kitty.conf"

install-nvim-plugin: scripts/ksession_nvim_dirty.lua
	@mkdir -p $(NVIM_SITE_DIR)
	cp scripts/ksession_nvim_dirty.lua $(NVIM_SITE_DIR)/ksession_nvim_dirty.lua
	@echo "Installed nvim plugin to $(NVIM_SITE_DIR)/ksession_nvim_dirty.lua"
	@echo "Plugin auto-loads on next nvim start"

install-shell-hook: scripts/ksession_shell_history.sh
	@mkdir -p $(SHARE_DIR)
	install -Dm644 scripts/ksession_shell_history.sh $(SHARE_DIR)/ksession_shell_history.sh
	@echo "Installed shell history hook to $(SHARE_DIR)/ksession_shell_history.sh"
	@echo ""
	@echo "Add one of the following to your shell rc file:"
	@echo "  Bash:  echo '. $(SHARE_DIR)/ksession_shell_history.sh' >> ~/.bashrc"
	@echo "  Zsh:   echo '. $(SHARE_DIR)/ksession_shell_history.sh' >> ~/.zshrc"

install-all: install install-watcher install-nvim-plugin install-shell-hook

uninstall-watcher:
	rm -f $(KITTY_CONF_DIR)/ksession_kitty_watcher.py

uninstall-nvim-plugin:
	rm -f $(NVIM_SITE_DIR)/ksession_nvim_dirty.lua

uninstall-shell-hook:
	rm -f $(SHARE_DIR)/ksession_shell_history.sh

uninstall-all: uninstall uninstall-watcher uninstall-nvim-plugin uninstall-shell-hook

clean:
	cargo clean
