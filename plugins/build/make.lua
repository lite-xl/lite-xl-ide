local core = require "core"
local build = require "plugins.build"

local make = { }

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end
function make.build(target, callback)
  build.run_tasks({ { "make", target.name, "-j", build.threads } }, function(status)
    local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
    if callback then callback(status == 0 and #filtered_messages or 1) end
  end)
end


function make.clean(target, callback)
  build.run_tasks({ { "make", "clean" } }, callback)
end


return make
