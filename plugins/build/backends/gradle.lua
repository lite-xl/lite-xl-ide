local core = require "core"
local build = require "plugins.build"

local gradle = { }

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end


function gradle.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "gradlew") and { 
    { name = "build" }
  }
end

function gradle.can_build(target) return target.task ~= "executable" end
function gradle.can_run(target) return target.task == "executable" end
function gradle.run(target)
  return build.execute_command(build.get_shell_command(target, "./gradlew", { target.name }))
end
function gradle.build(target, callback)
  build.run_tasks({ { "./gradlew", target.name } }, function(status)
    local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
    if callback then callback(status == 0 and #filtered_messages or 1) end
  end)
end


function gradle.clean(target, callback)
  build.run_tasks({ { "./gradlew", "clean" } }, callback)
end


return gradle
