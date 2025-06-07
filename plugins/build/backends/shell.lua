local core = require "core"
local build = require "plugins.build"

local shell = { }

function shell.infer()
  return system.get_file_info(core.projects[1].path .. PATHSEP .. "build.sh") and {
    { name = "debug", arguments = { "-g" } },
    { name = "release" }
  }
end

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end
function shell.build(target, callback)
  build.run_tasks({ { target.command or "./build.sh", table.unpack(target.arguments or {}) } }, function(status)
    local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
    if callback then callback(status == 0 and #filtered_messages or 1) end
  end)
end


function shell.clean(target, callback)
  build.run_tasks({ { target.command or "./build.sh", "clean" } }, callback)
end


return shell
