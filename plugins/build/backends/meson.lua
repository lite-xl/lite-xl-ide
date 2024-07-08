local core = require "core"
local common = require "core.common"
local build = require "plugins.build"

local meson = {
  -- ninja executes from inside a build folder, so all file references begin with `..`, and should be removed to reference the file.
  error_pattern = "^%s*%.%./([^:]+):(%d+):(%d*):? %[?(%w*)%]?:? (.+)",
  file_pattern = "^%s*%.%./([^:]+):(%d+):(%d*):? (.+)",
}

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end

local function get_build_directory(target)
  return target.build_directory or ("build-" .. target.name:lower():gsub("%W+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end

function meson.infer()
  return system.get_file_info("meson.build") and {
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

  if not system.get_file_info(bd) then
    build.run_tasks({ { "meson", "setup", bd, "--buildtype", target.buildtype or "debug" } }, function(status)
      ninja_build()
    end)
  else
    ninja_build()
  end
end


function meson.clean(target, callback)
  if system.get_file_info(get_build_directory(target)) then common.rm(get_build_directory(target), true) end
  callback(0)
end


return meson
