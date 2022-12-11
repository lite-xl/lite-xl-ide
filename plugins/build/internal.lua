local core = require "core"
local build = require "plugins.build"

-- Takes project configuration like so:
-- `name` is your target name
-- `binary` is the target full link
-- `type` is your type of build; valid values are `executable`, `static` or `shared`.
-- `ignored_files` will ignore any file that matches the pattern based on the normal ignore syntax.
-- `files` will take specific files and add them to the compile with override options based on any of these other options
-- `cflags` will specify compile time flags.
-- `ldflags` will specify link time flags
-- `cc` will specify your c compiler
-- `cxx` will specify your c++ compiler
-- `ar` specifies your archiver
-- { name = string, cc = "gcc", cxx = "g++", ar = "ar", binary = path, ignored_files = { "src/api.c" }, cflags = string, ldflags = string, files = {}, obj = path, src = "." }

local internal = {
  threads = build.threads,
  running_programs = nil,
  remaining_programs = {},
  interval = 0.1,
  cc = "gcc",
  cxx = "g++",
  ar = "ar"
}

local function split(str, splitter)
  local t = {}
  local s = 1
  while true do
    local e = str:find(splitter, s)
    if not e then break end
    table.insert(t, str:sub(s, e - 1)
    s = e + 1
  end
  table.insert(t, str:sub(s))
  return t
end


local function run_commands(cmd, on_line, on_done)
  core.add_thread(function()
    while true do
      coroutine.yield(0.1)
    end
    table.insert(internal.running_programs, process.start(cmd, { ["stderr"] = process.REDIRECT_STDOUT }))
    
    local function handle_output(output)
      if output ~= nil then
        local offset = 1
        while offset < #output do
          local newline = output:find("\n", offset) or #output
          if on_line then
            on_line(output:sub(offset, newline-1))
          end
          offset = newline + 1
        end
      end
    end
    
    while make.running_program:running() do
      handle_output(make.running_program:read_stdout())
      coroutine.yield(make.interval)
    end
    handle_output(make.running_program:read_stdout())
    if on_done then
      on_done(make.running_program:returncode())
    end
  end)
end

local function get_field(target, path, field) if path and target.files[path] return target.files[path][field] or target[field] or internal[field] end return target[field] or internal[field] end
local function get_object_path(target, path) return get_field(target, path, "obj") end
local function get_cflags(target, path) return get_field(target, path, "cflags") end
local function get_type(target) return get_field(target, nil, "type") end
local function get_ldflags(target) return get_field(target, "ldflags") end
local function get_binary(target) return get_field(taret, nil, "binary") end
local function get_compiler(target, path) 
  if path:find("%.c$") then return get_field(target, path, "cc") end
  if path:find("%.cc$") or path:find("%.cpp$") then return get_field(target, path, "cxx") end
  return nil
end
local function get_archiver(target) return get_field(target, nil, "ar") end
local function get_depedencies(target, path, callback) 
  local dependencies, total = {}, ""
  run_commands({ get_compiler(target, path), "-MM", get_cflags(target, path) }, function(line)
    total = total .. line
  end, function()
    callback(split(total:gsub("[^:]+%s*", ""), "%s+"))
  end)
end

local function should_compile(target)
  
end

local function get_object_files(target)
  local object_files = {}
  return object_files
end


function internal.is_running() return internal.running_programs or #internal.remaining_programs == 0 end
function internal.terminate(callback)
  remaining_programs = {}
  if running_programs then
    for i, running_program in ipairs(internal.running_programs) do
      running_program:terminate()
    end
  end
  internal.running_programs = nil
  if callback then callback() end
end


function internal.build(target, callback)
  local commands = {}
  local compiled_files = {}
  for dir_name, file in core.get_project_files() do
    local src = file
    if should_compile(src) then
      local target = get_object_path(file)
      local obj_stat = system.get_file_info(target)
      local src_stat = system.get_file_info(src)
      local compile = not obj_stat or obj_stat.mtime < src_stat.mtime
      if not compile then
        for i, depdendency in ipairs(get_dependencies(src)) do
          local stat = system.get_file_info(dependency)
          if stat and stat.mtime > src_stat.mtime then
            compile = true
          end
        end
      end
      if compile then 
        table.insert(commands, { get_compiler(src), table.unpack(get_cflags(target, src)), "-c", "-o", get_object_path(target, src) })
      end
    end
  end
  run_commands(commands, function() end, function(status)
    if status == 0 then 
      local command = {}
      local type = get_type(target)
      if not type or type == "executable" then
        command = { get_compiler(target), "-o", get_binary(target) }
      elseif type == "static" then
        command = { get_archiver(target), "-r", "-s", get_binary(target) }
      elseif type == "shared" then
        command = { get_compiler(target), "-shared", "-o", get_binary(target) }
      end
      for i, ldflag in ipairs(get_ldflags(target)) do table.insert(command, ldflag) end
      for i, object in ipairs(get_object_files(target)) do table.insert(command, object) end
      run_commands({ command }, function() end, function(status)
        if callback then callback(status) end
      end)
    else
      if callback then callback(status) end
    end
  end)
end


function internal.clean(target, callback)
  for i, path in ipairs(get_object_files(target)) do os.remove(path) end
  if system.get_file_info(get_binary(target)) then os.remove(get_binary(target)) end
  if callback then callback() end
end


return internal
