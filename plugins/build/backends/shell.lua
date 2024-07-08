local core = require "core"
local build = require "plugins.build"

local shell = { }

function shell.infer()
  if system.get_file_info("build.sh") then
    return {
      { name = "debug", arguments = { "-g" } },
      { name = "release" }
    }
  end
  return {}
end

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end
function shell.build(target, callback)
  build.run_tasks({ { "./build.sh", table.unpack(target.arguments or {}) } }, function(status)
    local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
    if callback then callback(status == 0 and #filtered_messages or 1) end
  end)
end


function shell.clean(target, callback)
  build.run_tasks({ { "./build.sh", "clean" } }, callback)
end


return shell
