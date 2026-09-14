-- Reuse the pinned rime-ice correction table without modifying upstream files.
local upstream = require('corrector')
local M = {}

function M.init(env)
    upstream.init(env)
    env.corrections = upstream.corrections
end

local function syllables(text)
    local result = {}
    for value in text:gmatch("[^ '%s]+") do
        -- These are accepted ü spellings, not typing mistakes.
        value = value:gsub('^([jqxy])v', '%1u'):gsub('^([nl])ue$', '%1ve')
        result[#result + 1] = value
    end
    return result
end

local function corrected(preedit, pinyin)
    local typed, canonical = syllables(preedit), syllables(pinyin)
    -- Compare the engine's syllable boundaries, including partial candidates.
    -- A shorter final syllable (or omitted trailing syllables) is completion.
    if #typed == 0 or #typed > #canonical then return false end
    for i, value in ipairs(typed) do
        local full = canonical[i]
        local initial = full:sub(1, 1)
        local digraph = full:match('^([zcs]h)')
        if value ~= full and value ~= initial and value ~= digraph
            and not (i == #typed and full:sub(1, #value) == value) then
            return true
        end
    end
    return false
end

function M.func(input, env)
    local hide_hints = env.engine.context:get_option('q_hide_correction_hints')
    for cand in input:iter() do
        local pinyin = cand.comment:match('^［(.-)］$')
        if pinyin and #pinyin > 0 then
            local correction = env.corrections[pinyin]
            local comment = ''
            if correction and cand.text == correction.text then
                comment = '（' .. correction.comment .. '）'
            elseif corrected(cand.preedit, pinyin) or env.keep_comment then
                comment = '（' .. pinyin .. '）'
            end
            cand:get_genuine().comment = hide_hints and '' or comment
        end
        yield(cand)
    end
end

return M
