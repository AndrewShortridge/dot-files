-- ksession_nvim_dirty.lua
-- Installed via Makefile to ~/.local/share/nvim/site/plugin/
-- Auto-loaded on nvim startup; emits OSC 1337 SetUserVar sequences
-- so the kitty watcher knows the nvim socket and last-dirty timestamp.

local function emit_dirty()
    local ts = tostring(math.floor(vim.uv.hrtime() / 1000000))
    local b64 = vim.base64.encode(ts)
    io.stdout:write(string.format("\027]1337;SetUserVar=nvim_dirty=%s\027\\", b64))
    io.stdout:flush()
end

local function register_socket()
    local sock = vim.v.servername
    if sock and sock ~= "" then
        local b64 = vim.base64.encode(sock)
        io.stdout:write(string.format("\027]1337;SetUserVar=nvim_socket=%s\027\\", b64))
        io.stdout:flush()
    end
end

vim.api.nvim_create_autocmd("VimEnter", { callback = register_socket })
vim.api.nvim_create_autocmd(
    { "BufWritePost", "CursorHold", "VimLeavePre", "BufEnter" },
    { callback = emit_dirty }
)
