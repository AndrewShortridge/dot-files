local base = require("andrew.vault.completion_base")
-- NB: patterns below are completion-specific trigger detectors (partial input
-- being typed).  They intentionally differ from pat.INLINE_FIELD_BRACKET et al.
-- which match *complete* fields.  See patterns.lua for the canonical forms.

local source = base.create_source({
  name = "inline_fields",
  build = base.build_kv_fields("inline_fields", ":: "),

  get_completions = base.kv_get_completions(function(before, _ctx, _bufnr)
    -- Value: standalone "key:: partial" (cheap, anchored) — always tried
    -- (cf. pat.INLINE_FIELD_STANDALONE — partial, no anchored value)
    -- (the optional %s*/[-*]?/%s* prefix already subsumes a bare "key:: ")
    local standalone_key = before:match("^%s*[-*]?%s*([%w_%-]+)::%s+")
    if standalone_key then return standalone_key end

    -- Value: bracketed/parenthesized "[key:: " / "(key:: " — both need '::'.
    -- Plain-byte pre-gate avoids the unanchored backtracking matches on prose.
    if before:find("::", 1, true) then
      -- (cf. pat.INLINE_FIELD_BRACKET — partial, unclosed bracket)
      local bracket_key = before:match("%[([%w_%-]+)::%s+[^%]]*$")
      if bracket_key then return bracket_key end
      -- (cf. pat.INLINE_FIELD_PAREN — partial, unclosed paren)
      local paren_key = before:match("%(([%w_%-]+)::%s+[^%)]*$")
      if paren_key then return paren_key end
    end

    -- Key: after [ (not [[) — needs a literal '[' (cf. pat.HAS_WIKILINK exclusion)
    if before:find("[", 1, true) then
      if before:match("%[[%w_%-]*$") and not before:match("%[%[[%w_%-]*$") then
        return false
      end
    end

    -- Key: after ( — needs a literal '(' (exclude markdown link targets ](url)
    if before:find("(", 1, true) then
      if before:match("%([%w_%-]*$") and not before:match("%]%([%w_%-]*$") then
        return false
      end
    end

    -- Key: standalone at line start (2+ chars)
    local line_key_prefix = before:match("^%s*[-*]%s+([%w_%-]+)$")
      or before:match("^([%w_%-]+)$")
    if line_key_prefix and #line_key_prefix >= 2 then
      return false
    end

    -- No context matched
    return nil
  end),
})

function source:get_trigger_characters()
  return { ":" }
end

return source
