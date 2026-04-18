local core = require "core"
local common = require "core.common"
local build = require "plugins.build"

local maven = {}

local mvn = PLATFORM == "Windows" and "mvn.bat" or "mvn"
local source_folder = system.absolute_path(".") .. PATHSEP .. ""

local function grep(t, cond)
  local nt = {}
  for i, v in ipairs(t) do
    if cond(v, i) then table.insert(nt, v) end
  end
  return nt
end

-- TODO: ptm integration to set base targets (tasks in maven terms) and lifecycles
function maven.infer()
  -- TODO: always cd into folder where pom.xml is
  if system.get_file_info(core.root_project().path .. PATHSEP .. "example" .. PATHSEP .. "pom.xml") then
    return {
      -- Tasks
      -- WIP: requires lifecycles
      { name = "clean", backend = "maven", wd = source_folder, run = { mvn, "clean" } },
      { name = "build", backend = "maven", wd = source_folder, run = { mvn, "build" } },
      { name = "test",  backend = "maven", wd = source_folder, run = { mvn, "test" } },
      { name = "run",   backend = "maven", wd = source_folder, run = { mvn, "run" } },
      -- Lifecycle
      -- {
      --   name = "lifecycle_base",
      --   backend = "maven",
      --   -- FIX
      --   run = {
      --     { mvn, "build" },
      --     { mvn, "run" }
      --   }
      -- }
    }
  end
end

function maven.build(target, callback)
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

return maven
