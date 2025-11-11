--mod-version:4 --priority: 1
local config = require "core.config"
local common = require "core.common"

config.plugins.w64devkit = common.merge({
  -- whether or not the devkit should take precedence over the system path
  -- in the shell
  priority = false
}, config.plugins.w64devkit)


if PLATFORM == "Windows" then
  local w64devkitpath = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "w64devkit" .. PATHSEP .. "w64devkit"
  local PATH
  if config.plugins.w64devkit.priority then
    PATH = w64devkitpath .. PATHSEP .. "bin" .. ";" .. os.getenv("PATH")
  else
    PATH = os.getenv("PATH") .. ";" .. w64devkitpath .. PATHSEP .. "bin"
  end
  
  local function resolve_path(program)
    for path in PATH:gmatch("([^;]+)") do
      if system.get_file_info(path .. PATHSEP .. program) then
        return path .. PATHSEP .. program
      end
    end
  end
  
  if not config.plugins.terminal.shell then config.plugins.terminal.shell = resolve_path("sh.exe") end
  if not config.plugins.build.cc then config.plugins.build.cc = resolve_path("gcc.exe") end
  if not config.plugins.build.cxx then config.plugins.build.cxx = resolve_path("g++.exe") end
  if not config.plugins.build.ar then config.plugins.build.ar = resolve_path("ar.exe") end
  config.plugins.terminal.environment = common.merge({
    PATH = PATH,
    PS1 = '$PWD $ '
  }, config.plugins.terminal.environment or {})
end
