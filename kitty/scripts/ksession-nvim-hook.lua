-- ksession-nvim-hook.lua
--
-- Loaded from init.lua. On VimEnter this emits a single OSC 1337
-- SetUserVar sequence carrying the nvim RPC socket path (vim.v.servername).
-- Kitty stores the value on the window and exposes it via `kitty @ ls`.
-- The ksession Rust adapter reads it, skipping the multi-tier socket
-- discovery dance (descendants scan, wildcard glob, pid-tree match).
--
-- Contract: exactly one key, ksession_nvim_sock = vim.v.servername.
--
-- Note: if vim.v.servername is empty (e.g. nvim --clean, or explicitly
-- cleared) the hook silently no-ops by design — there is no socket to
-- advertise, so ksession falls back to its multi-tier discovery.
--
-- Install hint:
--   Add to init.lua: dofile(vim.fn.expand('~/.config/kitty/scripts/ksession-nvim-hook.lua'))

-- Load guard: prevents double registration of the VimEnter autocmd on re-dofile.
if vim.g._ksession_nvim_hook_loaded then return end
vim.g._ksession_nvim_hook_loaded = true

-- Pure-Lua base64 fallback. Used only when vim.base64.encode is unavailable
-- (Neovim < 0.10). Encodes a Lua string (treated as bytes) to RFC 4648 base64
-- with no line wrapping.
local function b64_lua(data)
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local out = {}
    local len = #data
    local i = 1
    while i <= len - 2 do
        local b1, b2, b3 = data:byte(i, i + 2)
        local n = b1 * 65536 + b2 * 256 + b3
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = alphabet:sub(c1 + 1, c1 + 1)
        out[#out + 1] = alphabet:sub(c2 + 1, c2 + 1)
        out[#out + 1] = alphabet:sub(c3 + 1, c3 + 1)
        out[#out + 1] = alphabet:sub(c4 + 1, c4 + 1)
        i = i + 3
    end
    local rem = len - (i - 1)
    if rem == 1 then
        local b1 = data:byte(i)
        local n = b1 * 65536
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        out[#out + 1] = alphabet:sub(c1 + 1, c1 + 1)
        out[#out + 1] = alphabet:sub(c2 + 1, c2 + 1)
        out[#out + 1] = '=='
    elseif rem == 2 then
        local b1, b2 = data:byte(i, i + 1)
        local n = b1 * 65536 + b2 * 256
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        out[#out + 1] = alphabet:sub(c1 + 1, c1 + 1)
        out[#out + 1] = alphabet:sub(c2 + 1, c2 + 1)
        out[#out + 1] = alphabet:sub(c3 + 1, c3 + 1)
        out[#out + 1] = '='
    end
    return table.concat(out)
end

local function encode(s)
    if vim.base64 and vim.base64.encode then
        return vim.base64.encode(s)
    end
    return b64_lua(s)
end

vim.api.nvim_create_autocmd('VimEnter', {
    callback = function()
        local s = vim.v.servername
        if not s or s == '' then
            return
        end
        local payload = ('\27]1337;SetUserVar=ksession_nvim_sock=%s\a'):format(encode(s))
        -- io.write may buffer; flush explicitly so the OSC reaches kitty
        -- before any other terminal output.
        io.stdout:write(payload)
        io.stdout:flush()
    end,
})
