local core = require "core"
local common = require "core.common"
local build = require "plugins.build"
local config = require "core.config"
local json = require "libraries.json"

local meson = {
  -- ninja executes from inside a build folder, so all file references begin with `..`, and should be removed to reference the file.
  error_pattern = "^%s*%.%./([^:]+):(%d+):(%d*):? %[?(%w*)%]?:? (.+)",
  file_pattern = "^%s*%.%./([^:]+):(%d+):(%d*):? (.+)",
}

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end

local function get_build_directory(target)
  return core.root_project().path .. PATHSEP .. (target.build_directory or ("build-" .. target.name:lower():gsub("%W+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")))
end

function meson.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "meson.build") and {
    { name = "debug" },
    { name = "release", buildtype = "release" }
  }
end

function meson.parse_compile_line(line)
  local _, _, file, line_number, column, type, message = line:find(meson.error_pattern)
  if file and (type == "warning" or type == "error") then
    return { type, file, line_number, column, message }
  end
  local _, _, file, line_number, column, message = line:find(meson.file_pattern)
  return file and { "info", file, line_number, (column or 1), message } or line
end

local function run_command(args)
  local proc = process.start(args)
  local accumulator = ""
  while true do
    local chunk = proc:read_stdout(4096)
    if not chunk or (chunk == "" and not proc:running()) then break end
    accumulator = accumulator .. chunk
    coroutine.yield()
  end
  local status = proc:returncode()
  if status ~= 0 then error(proc:read_stderr(4096)) end
  return accumulator
end

function meson.build(target, callback)
  local bd = get_build_directory(target)
  local tasks = { }

  local ninja_build = function()
    build.run_tasks({ { "ninja", "-C", bd } }, function(status)
      local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
      if callback then callback(status == 0 and #filtered_messages or 1) end
    end, function(line)
      build.message_view:add_message(meson.parse_compile_line(line))
    end)
  end

  local check_executables = function()
    local info = json.decode(run_command({ "meson", "introspect", bd, "-a" }))
    -- find an executable that is built by default
    for i,v in ipairs(info.targets) do
      if v.build_by_default and v.type == "executable" and v.filename then
        target.binary = v.filename[1]
        config.target_binary = target.binary
        target.wd = common.dirname(target.binary)
      end
    end
    target.checked = true
  end

  if not system.get_file_info(bd) then
    build.run_tasks({ { "meson", "setup", bd, "--buildtype", target.buildtype or "debug" } }, function(status)
      core.add_thread(function()
        check_executables()
        ninja_build()
      end)
    end)
  else
    if not target.checked then
      core.add_thread(function()
        check_executables()
        ninja_build()
      end)
    else
      ninja_build()
    end
  end
end


function meson.clean(target, callback)
  if system.get_file_info(get_build_directory(target)) then common.rm(get_build_directory(target), true) end
  callback(0)
end


return meson
