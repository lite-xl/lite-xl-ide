local core = require "core"
local build = require "plugins.build"

local shell = { }

--[[
target.runner_name = name of runner     (default = sh)
target.script_name = path to script     (default = build.sh)
target.args_build  = list of build args (default = )
target.args_clean  = list of clean args (default = clean)
]]

local function get_script_name(target)
    return target.command or "build.sh"
end
local function get_runner_name(target)
    return target.runner or "sh"
end
local function get_args_clean(target)
    return table.unpack(target.args_clean or {"clean"})
end
local function get_args_build(target)
    return table.unpack(target.arguments or target.args_build or {})
end

function shell.infer()
  return system.get_file_info(core.root.project().path .. PATHSEP .. "build.sh") and {
    { name = "debug", arguments = { "-g" } },
    { name = "release" }
  }
end

function shell.build(target, callback)
  build.run_tasks({ { get_runner_name(target), get_script_name(target), get_args_build(target) } }, function(status)
    if callback then callback(status) end
  end, function(line)
    build.message_view:add_message(build.parse_compile_line(line))
  end)
end


function shell.clean(target, callback)
  build.run_tasks({ { get_runner_name(target), get_script_name(target), get_args_clean(target) } }, callback)
end


return shell
