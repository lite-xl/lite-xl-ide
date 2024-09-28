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
  skip_files = {},
  backends = {
    gdb = require "plugins.debugger.gdb",
    dap = require "plugins.debugger.dap"
  },
  state = "inactive",
  active = nil
}


function model:has_breakpoint(path, line)
  return self.breakpoints[path] and self.breakpoints[path][line] ~= nil
end

function model:add_breakpoint(path, line)
  local state = self.state
  if (state ~= "stopped" and state ~= "inactive") then self.active:halt() end
  self.breakpoints[path] = self.breakpoints[path] or { }
  self.breakpoints[path][line] = true
  if state ~= "inactive" then 
    self.active:add_breakpoint(path, line, state ~= "stopped" and function() self.active:continue() end) 
  end
end

function model:remove_breakpoint(path, line)
  local state = self.state
  if state ~= "stopped" and state ~= "inactive" then self.active:halt() end
  if state ~= "inactive" then 
    self.active:remove_breakpoint(path, line, state ~= "stopped" and function() self.active:continue() end) 
  end
  if self.breakpoints[path] ~= nil then self.breakpoints[path][line] = nil end
end


function model:start(path, arguments, paused, exited, out)
  assert(path, "requires a path")
  if self.state ~= "inactive" then error("can only start from inactive state") end
  for k,v in pairs(self.backends) do if v.should_engage(path) then self.active = v break end end
  if not self.active then error("can't find appropriate backend for " .. path) end
  self.state = "starting"
  self.view_paused = paused
  self.view_exited = exited
  self.view_out = out
  self.active:start(path, arguments or {}, function(...) self:started() end, function(...) self:stopped(...) end, function(...) self:completed(...) end, function(...) self:out(...) end)
end

function model:attach(terminal, backend, paused, exited, out)
  assert(self.state == "inactive", "can only start from inactive state")
  self.active = backend
  self.state = "starting"
  self.view_paused = paused
  self.view_exited = exited
  self.view_out = out
  self.active:attach(terminal, function(...) self:started() end, function(...) self:stopped(...) end, function(...) self:completed(...) end, function(...) self:out(...) end)
end

function model:run()
  self.saved_stacktrace = nil
  self.state = "running"
end

function model:started()
  assert(self.state == "starting", "can only started from starting state, not while " .. self.state)
  self.state = "stopped"
  for path, lines in pairs(self.breakpoints) do for line, has in pairs(lines) do if has then self:add_breakpoint(path, line) end end end
  for i, files in ipairs(self.skip_files) do self.active:skip_file(files) end
  self:run()
end

function model:continue()
  assert(self.state == "stopped", "can only be continued from stopped state, not while " .. self.state)
  self:run()
  self.active:continue()
end

function model:step_into()
  assert(self.state == "stopped", "can only be stepped from stopped state, not while " .. self.state)
  self:run()
  self.active:step_into()
end

function model:step_over()
  assert(self.state == "stopped", "can only be stepped from stopped state, not while " .. self.state)
  self:run()
  self.active:step_over()
end

function model:step_out()
  assert(self.state == "stopped", "can only be stepped from stopped state, not while " .. self.state)
  self:run()
  self.active:step_out()
end

function model:halt()
  assert(self.state == "running", "can only be halted from running state, not while " .. self.state)
  self.state = "stopped"
  self.active:halt()
  self.view_paused()
end

function model:terminate()
  assert(self.state ~= "inactive", "can only be terminated from any running state, not while " .. self.state)
  self.state = "inactive"
  self.active:terminate()
  self.view_exited()
  self.active = nil
end

function model:stopped()
  if self.state ~= "stopped" then
    assert(self.state == "running", "can only be stopped from running state, not while " .. self.state)
    self.state = "stopped"
    self.view_paused()
  end
end

function model:completed()
  assert(self.state == "running", "can only be completed from running state, not while " .. self.state)
  self.state = "inactive"
  self.view_exited()
  self.active = nil
end

function model:out(line, source)
  if self.view_out then self.view_out(line, source) end
end

function model:frame(idx, callback)
  assert(self.state == "stopped", "can only be completed from stopped state, not while " .. self.state)
  return self.active:frame(idx, callback)
end

function model:stacktrace(callback)
  assert(self.state == "stopped", "can only be stack traced from stopped state, not while " .. self.state)
  if self.saved_stacktrace then callback(self.saved_stacktrace) end
  if not self.stack_callbacks then
    self.stack_callbacks = { callback }
    self.active:stacktrace(function(stack)
      self.saved_stacktrace = stack
      for i,v in ipairs(self.stack_callbacks) do v(stack) end
      self.stack_callbacks = nil
    end)
  else
    table.insert(self.stack_callbacks, callback)
  end
end

function model:variable(name, callback)
  assert(self.state == "stopped", "can only be completed from stopped state, not while " .. self.state)
  return self.active:variable(name, callback)
end

function model:instruction(callback)
  assert(self.state == "stopped", "can only be completed from stopped state, not while " .. self.state)
  return self.active:instruction(callback)
end

return model
