local core = require "core"
local common = require "core.common"
local build = require "plugins.build"

local gradle = {}

local gradlew = PLATFORM == "Windows" and core.root_project().path .. PATHSEP .. "gradlew.bat" or core.root_project().path .. PATHSEP .. "gradlew"

local function grep(t, cond)
  local nt = {}
  for i, v in ipairs(t) do
    if cond(v, i) then table.insert(nt, v) end
  end
  return nt
end

-- TODO: get name of folder that contains the Gradle build file
-- TODO: ptm integration to set base targets (tasks in gradle terms) and lifecycles
function gradle.infer()
  -- TODO: REFACTOR: setup integration (through project_module) for source folder name
  if system.get_file_info(core.root_project().path .. PATHSEP .. "app" or "src" .. "build.gradle")
  or system.get_file_info(core.root_project().path .. PATHSEP .. "app" or "src" .. "build.gradle.kts") then
    return {
      -- Tasks
      { name = "clean", backend = "gradle", run = { gradlew, "clean" } },
      { name = "build", backend = "gradle", run = { gradlew, "build" } },
      { name = "test",  backend = "gradle", run = { gradlew, "test" } },
      { name = "run",   backend = "gradle", run = { gradlew, "run" } },
      -- Lifecycle
      -- {
      --   name = "lifecycle_base",
      --   backend = "gradle",
      --   -- FIX
      --   run = {
      --     gradlew, "build",
      --     gradlew, "run"
      --   }
      -- }
    }
  end
end

function gradle.build(target, callback)
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

return gradle
