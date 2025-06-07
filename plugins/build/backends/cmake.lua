local core = require "core"
local common = require "core.common"
local build = require "plugins.build"
local config = require "core.config"
local json = require "libraries.json"

local cmake = {}

local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end

local function get_build_directory(target)
  return core.root_project().path .. PATHSEP .. (target.build_directory or ("build-" .. target.name:lower():gsub("%W+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")))
end

function cmake.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "CMakeLists.txt") and {
    { name = "debug" },
    { name = "release", buildtype = "release" }
  }
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

function cmake.build(target, callback)
  local bd = get_build_directory(target)
  local tasks = { }

  local make_build = function()
    build.run_tasks({ { "make", "-C", bd, "-j", build.threads } }, function(status)
      local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
      if callback then callback(status == 0 and #filtered_messages or 1) end
    end, function(line)
      build.message_view:add_message(build.parse_compile_line(line))
    end)
  end

  if not system.get_file_info(bd) then
    common.mkdirp(bd)
    build.run_tasks({ { "cmake", "-B" .. bd, "-S" .. core.root_project().path, "-DCMAKE_BUILD_TYPE=" .. (target.buildtype or "debug") } }, function(status)
      core.add_thread(function()
        make_build()
      end)
    end)
  else
    if not target.checked then
      core.add_thread(function()
        make_build()
      end)
    else
      make_build()
    end
  end
end


function cmake.clean(target, callback)
  if system.get_file_info(get_build_directory(target)) then common.rm(get_build_directory(target), true) end
  callback(0)
end


return cmake
