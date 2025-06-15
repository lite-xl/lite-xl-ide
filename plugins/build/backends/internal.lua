local core = require "core"
local common = require "core.common"
local config = require "core.config"
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
-- `srcs` specifies the folders where your source is located.
-- { name = string, cc = "gcc", cxx = "g++", ar = "ar", binary = path, ignored_files = { "src/api.c" }, cflags = string, ldflags = string, files = {}, obj = path, srcs = { "." } }

if not config.plugins.build.internal then config.plugins.build.internal = {} end
local internal = common.merge({
  threads = build.threads,
  running_programs = nil,
  remaining_programs = {},
  interval = 0.1,
  priority = 10
}, config.plugins.build.internal)

local function split(str, splitter)
  local t = {}
  local s = 1
  while true do
    local ns, e = str:find(splitter, s)
    if not ns then break end
    table.insert(t, str:sub(s, ns - 1))
    s = e + 1
  end
  table.insert(t, str:sub(s))
  return t
end
local function table_concat(t1, t2)
  local t = {}
  for i,v in ipairs(t1) do table.insert(t, v) end
  for i,v in ipairs(t2) do table.insert(t, v) end
  return t
end


local function get_field(target, path, field) if path and target and  target.files and target.files[path] then return target.files[path][field] or target[field] or internal[field] end return target[field] or internal[field] or build[field] end
local function get_cflags(target, path) return get_field(target, path, "cflags") end
local function get_cxxflags(target, path) return get_field(target, path, "cxxflags") end
local function get_type(target) return get_field(target, nil, "type") end
local function get_ldflags(target) return get_field(target, nil, "ldflags") end
local function get_binary(target) return get_field(target, nil, "binary") end
local function get_compiler(target, path)
  if not path then return get_field(target, path, "cc") end
  if path:find("%.c$") then return split(get_field(target, path, "cc"), "%s+") end
  if path:find("%.cc$") or path:find("%.cpp$") then return split(get_field(target, path, "cxx"), "%s+") end
  return nil
end
local function get_archiver(target) return get_field(target, nil, "ar") end
local function get_linker(target) return get_field(target, nil, "ld") end

local function get_source_files(target)
  local files = {}
  for project, file in core.root_project():files() do
    local file = file.filename
    for i, src in ipairs(target.srcs) do
      local path = core.root_project():absolute_path(src)
      if file:find(path, 1, true) == 1 and get_compiler(target, file) then 
        table.insert(files, file)
        break
      end  
    end
  end
  return files
end


local function get_compile_flags(target, file)
  if file:find("%.cpp$") or file:find("%.cc") then return get_field(target, file, "cxxflags") end
  return get_field(target, file, "cflags")
end

function internal.infer()
  -- autodetect
  local srcs = nil
  if system.get_file_info(core.root_project():absolute_path("src")) then
    return {
      { name = "debug", binary = common.basename(core.root_project().path) .. "-debug" .. (PLATFORM == "Windows" and ".exe" or ""), cflags = {"-g", "-O0" }, cxxflags = { "-g", "-O0" }, srcs = { "src" } },
      { name = "release", binary = common.basename(core.root_project().path) .. "-release" .. (PLATFORM == "Windows" and ".exe" or ""), cflags = { "-O3" }, cxxflags = { "-O3" }, srcs = { "src" } },
    }
  end
end

function internal.build(target, callback)
  local commands = {}
  local files = get_source_files(target)
  if #files == 0 then error("can't find source files for project") end
  local has_cpp = false
  for i, v in ipairs(files) do if v:find(".cpp$") or v:find("*.cc") then has_cpp = true end end
  -- pick targets for dependency generation
  local dependencies = {}
  local objects = {}
  local stats = {}
  local max_ostat = nil
  common.mkdirp(core.root_project():absolute_path(target.obj or "obj"))
  for i, v in ipairs(files) do
    local handle = (target.name .. v):gsub("[/\\]+", "_")
    dependencies[i] = (target.obj or core.root_project():absolute_path("obj")) .. PATHSEP .. handle .. ".d"
    objects[i] = (target.obj or core.root_project():absolute_path("obj")) .. PATHSEP .. handle .. ".o"
    stats[i] = system.get_file_info(v)
  end
  local dependency_jobs = {}
  for i, d in ipairs(dependencies) do
    local d_stat = system.get_file_info(d)
    if not d_stat or d_stat.modified < stats[i].modified then
      table.insert(dependency_jobs, table_concat(get_compiler(target, files[i]), { "-MM", core.root_project():normalize_path(files[i]), "-MF", core.root_project():normalize_path(d), table.unpack(get_compile_flags(target, files[i])) }))
    end
  end

  build.run_tasks(dependency_jobs, function(status)
    if status ~= 0 then if callback then callback(status) end return end
    local compile_jobs = {}
    for i, d in ipairs(dependencies) do
      local o_stat = system.get_file_info(objects[i])
      if o_stat and (not max_ostat or o_stat.modified > max_ostat) then max_ostat = o_stat.modified end
      local compile = not o_stat or o_stat.modified < stats[i].modified
      if not compile then
        for j, h in ipairs(split(io.open(d, "rb"):read("*all"):gsub("^[^:]+:%s*", ""), "[%s\\]+")) do
          if h then
            local h_stat = system.get_file_info(h)
            if h_stat and o_stat.modified < h_stat.modified then
              compile = true
              break
            end
          end
        end
      end
      if compile then
        table.insert(compile_jobs, table_concat(get_compiler(target, core.root_project():normalize_path(files[i])), { "-fdiagnostics-color=always", "-c", core.root_project():normalize_path(files[i]), "-o", core.root_project():normalize_path(objects[i]), table.unpack(get_compile_flags(target, files[i])) }))
      end
    end
    build.run_tasks(compile_jobs, function(status)
      if status ~= 0 then if callback then callback(status) end return end
      local link_job = {}
      local type = get_type(target)
      local linker = get_linker(target) or (has_cpp and split(get_field(target, nil, "cxx"), "%s+") or split(get_field(target, nil, "cc"), "%s+"))
      local binary = get_binary(target)
      local binary_stat = system.get_file_info(binary)
      if not binary_stat or #compile_jobs > 0 or (max_ostat and binary_stat.modified < max_ostat) then
        local binary_folder = common.dirname(binary)
        if binary_folder then common.mkdirp(binary_folder) end
        if not type or type == "executable" then
          link_job = table_concat(linker, { "-o", binary })
        elseif type == "static" then
          link_job = { get_archiver(target), "-r", "-s", binary }
        elseif type == "shared" then
          link_job = table_concat(linker, { "-shared", "-o", binary })
        end
        for i, object in ipairs(objects) do table.insert(link_job, object) end
        for i, ldflag in ipairs(get_ldflags(target) or {}) do table.insert(link_job, ldflag) end
        build.run_tasks({ link_job }, callback)
      else
        if callback then callback(0) end
      end
    end)
  end)
end


function internal.clean(target, callback)
  local files = get_source_files(target)
  for i, v in ipairs(files) do
    local handle = (target.name .. v):gsub("[/\\]+", "_")
    local dependency = (target.obj or "obj") .. PATHSEP .. handle .. ".d"
    local object = (target.obj or "obj") .. PATHSEP .. handle .. ".o"
    if system.get_file_info(dependency) then os.remove(dependency) end
    if system.get_file_info(object) then os.remove(object) end
  end
  if system.get_file_info(get_binary(target)) then os.remove(get_binary(target)) end
  if callback then callback() end
end


return internal
