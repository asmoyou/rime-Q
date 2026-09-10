-- Rime Q adapter for rime-ice's lunar translator (GPL-3.0).
-- Keep the upstream formatter/database and resolve bundled read-only data
-- explicitly; the bundled librime-lua resolves relative ReverseDb paths in
-- the user directory. No lunar database is copied into personal data.
local lunar = require('lunar')
local M = { func = lunar.func }

function M.init(env)
    local config = env.engine.schema.config
    env.db = ReverseDb(rime_api.get_shared_data_dir() .. '/lua/lunar.db')
    env.lunar_call_prefix = config:get_string('lunar') or 'nl'
    env.seg_tag = 'gregorian_to_lunar'
    local template = config:get_string('lunar_template') or '{干支年}{生肖}年{俗称农历月}{农历日}'
    env.lunar_template_fields = {}
    env.lunar_format = template:gsub('{([^}]+)}', function(field)
        env.lunar_template_fields[#env.lunar_template_fields + 1] = field
        return '%s'
    end)
end

return M
