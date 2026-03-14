local core = require "core"
local common = require "core.common"
local build = require "plugins.build"

local ant = {}

local function grep(t, cond)
  local nt = {}
  for i, v in ipairs(t) do
    if cond(v, i) then table.insert(nt, v) end
  end
  return nt
end

function ant.infer()
  if system.get_file_info(core.root_project().path .. PATHSEP .. "build.xml") then
    return {
      { name = "clean",   backend = "ant", run = { "ant", "clean" } },
      { name = "compile", backend = "ant", run = { "ant", "compile" } },
      { name = "jar",     backend = "ant", run = { "ant", "jar" } },
      { name = "run",     backend = "ant", run = { "ant", "run" } }
    }
  end
end

function ant.build(target, callback)
  build.run_tasks({ target.run }, function(status)
    local filtered = grep(build.message_view.messages, function(v)
      return type(v) == "table" and v[1] == "error"
    end)
    if callback then
      callback(status == 0 and #filtered or 1)
    end
  end, function(line)
    build.message_view:add_message(build.parse_compile_line(line))
  end)
end

return ant
