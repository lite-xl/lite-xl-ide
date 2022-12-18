local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local Doc = require "core.doc"
local common = require "core.common"
local style  = require "core.style"
local config  = require "core.config"
local View = require "core.view"
local StatusView = require "core.statusview"

-- General debugger framework.
local model = {
  breakpoints = {},
  backends = {
    gdb = require "plugins.debugger.gdb"
  },
  state = "inactive",
  active = nil
}


function model:has_breakpoint(path, line)
  return self.breakpoints[path] and self.breakpoints[path][line] ~= nil
end

function model:add_breakpoint(path, line)
  if self.state ~= "stopped" and self.state ~= "inactive" then error("can only add breakpoints while stopped, or inactive, not while " .. self.state) end
  self.breakpoints[path] = self.breakpoints[path] or { }
  self.breakpoints[path][line] = true
  if self.state == "stopped" then self.active:add_breakpoint(path, line) end
end

function model:remove_breakpoint(path, line)
  if self.state ~= "stopped" and self.state ~= "inactive" then error("can only add breakpoints while stopped, or inactive, not while " .. self.state) end
  if self.state == "stopped" then self.active:remove_breakpoint(path, line) end
  if self.breakpoints[path] ~= nil then self.breakpoints[path][line] = nil end
end


function model:start(path, arguments, paused, exited)
  if not path then error("requires a path") end
  if self.state ~= "inactive" then error("can only start from inactive state") end
  for k,v in pairs(self.backends) do if v.should_engage(path) then self.active = v break end end
  if not self.active then error("can't find appropriate backend for " .. path) end
  self.state = "starting"
  self.view_paused = paused
  self.view_exited = exited
  self.active:start(path, arguments or {}, function(...) self:started() end, function(...) self:stopped(...) end, function(...) self:completed(...) end)
end

function model:started()
  if self.state ~= "starting" then error("can only started from starting state, not while " .. self.state) end
  self.state = "stopped"
  for path, lines in pairs(self.breakpoints) do for line, has in pairs(lines) do if has then self:  add_breakpoint(path, line) end end end
  self:continue()
end

function model:continue()
  if self.state ~= "stopped" then error("can only be continued from stopped state, not while " .. self.state) end
  self.state = "running"
  self.active:continue()
end

function model:step_into()
  if self.state ~= "stopped" then error("can only be stepped from stopped state, not while " .. self.state) end
  self.state = "running"
  self.active:step_into()
end

function model:step_over()
  if self.state ~= "stopped" then error("can only be stepped from stopped state, not while " .. self.state) end
  self.state = "running"
  self.active:step_over()
end

function model:step_out()
  if self.state ~= "stopped" then error("can only be stepped from stopped state, not while " .. self.state) end
  self.state = "running"
  self.active:step_out()
end

function model:halt()
  if self.state ~= "running" then error("can only be halted from running state, not while " .. self.state) end
  self.state = "stopped"
  self.active:halt()
  self.view_paused()
end

function model:terminate()
  if self.state == "inactive" then error("can only be terminated from any running state, not while " .. self.state) end
  self.state = "inactive"
  self.active:terminate()
  self.view_exited()
  self.active = nil
end

function model:stopped()
  if self.state ~= "stopped" then
    if self.state ~= "running" then error("can only be stopped from running state, not while " .. self.state) end
    self.state = "stopped"
    self.view_paused()
  end
end

function model:completed()
  if self.state ~= "running" then error("can only be completed from running state, not while " .. self.state) end
  self.state = "inactive"
  self.view_exited()
  self.active = nil
end

function model:frame(idx)
  if self.state ~= "stopped" then error("can only be completed from stopped state, not while " .. self.state) end
  return self.active:frame(idx)
end

function model:stacktrace(callback)
  if self.state ~= "stopped" then error("can only be completed from stopped state, not while " .. self.state) end
  return self.active:stacktrace(callback)
end

function model:variable(name, callback)
  if self.state ~= "stopped" then error("can only be completed from stopped state, not while " .. self.state) end
  return self.active:variable(name, callback)
end

function model:instruction(callback)
  if self.state ~= "stopped" then error("can only be completed from stopped state, not while " .. self.state) end
  return self.active:instruction(callback)
end

return model
