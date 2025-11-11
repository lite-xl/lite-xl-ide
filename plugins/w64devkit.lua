--mod-version:4
local config = require "core.config"

if PLATFORM == "Windows" then
  local w64devkitpath = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "w64devkit" .. PATHSEP .. "w64devkit"
  config.plugins.terminal.shell = w64devkitpath .. PATHSEP .. "bin" .. PATHSEP .. "sh.exe"
  config.plugins.build.cc = w64devkitpath .. PATHSEP .. "bin" .. PATHSEP .. "gcc.exe"
  config.plugins.build.cxx = w64devkitpath .. PATHSEP .. "bin" .. PATHSEP .. "g++.exe"
  config.plugins.build.ar = w64devkitpath .. PATHSEP .. "bin" .. PATHSEP .. "ar.exe"
  config.plugins.terminal.environment = {
    PS1 = '$PWD$ '
  }
end
