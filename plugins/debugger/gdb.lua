
local core = require "core"
local common = require "core.common"
local style  = require "core.style"
local config  = require "core.config"

local gdb = {
  running_program = nil,
  command_queue = { },
  breakpoints = { },
  debugger_stopped = nil,
  debugger_completed = nil
}

local function chomp(str)
  return str:gsub("[\n\r]+$", "")
end

local function gdb_parse_string(str)
  local offset = 0
  while offset ~= nil do
    offset = str:find('"', offset+1)
    if offset and str:sub(offset - 1, offset - 1) ~= "\\" then
      return str:sub(1, offset - 1):gsub("\\\"", "\""), offset + 1
    end
  end
end

local gdb_parse_status_attributes
local gdb_parse_status_array

local function gdb_parse_status_value(value)
  if value:sub(1, 1) == "{" then
    return gdb_parse_status_attributes(value:sub(2))
  elseif value:sub(1,1) == "[" then
    return gdb_parse_status_array(value:sub(2))
  elseif value:sub(1,1) == "\"" then
    return gdb_parse_string(value:sub(2))
  end
  return nil
end

gdb_parse_status_array = function(values)
  local array = { }
  local offset = 1
  if values:sub(offset, offset) == "]" then
    return array
  end
  while true do
    local value, length = gdb_parse_status_value(values:sub(offset))
    table.insert(array, value)
    offset = offset + length
    if values:sub(offset, offset) == "," then
      offset = offset + 1
    elseif values:sub(offset, offset) == "]" then
      return array, offset+1
    end
  end
end


gdb_parse_status_attributes = function(attributes)
  local obj = { }
  local offset = 1
  while true do
    local equal_idx = attributes:find("=", offset)
    local attr_name = attributes:sub(offset, equal_idx-1)
    local attr_value, length = gdb_parse_status_value(attributes:sub(equal_idx+1))
    if not length then
      return obj, offset + 1
    end
    obj[attr_name] = attr_value
    offset = length + equal_idx + 1
    if attributes:sub(offset, offset) == "," then
      offset = offset + 1
    else
      return obj, offset+1
    end
  end
  return offset
end

local function gdb_parse_status_line(line)
  line = chomp(line)
  local idx = line:find(",")
  local type = line:sub(1, 1)
  if idx and type == "*" or type == "=" then
    return type, line:sub(2, idx - 1), gdb_parse_status_attributes(line:sub(idx+1))
  elseif type == "~" then
    return type, gdb_parse_string(line:sub(3))
  elseif type == "^" then
    local quote = line:find('"')
    if idx and (not quote or idx < quote) then
      return type, line:sub(2, idx - 1), gdb_parse_status_attributes(line:sub(idx+1))
    else
      return type, line:sub(2)
    end
  else
    return type
  end
end

function gdb:cmd(command, on_finish)
  table.insert(self.command_queue, { command, on_finish })
  if self.running_thread and core.threads[self.running_thread] then
    coroutine.resume(core.threads[self.running_thread].cr)
  end
end

function gdb:should_engage(path) return true end
function gdb:step_into()  self:cmd("step") end
function gdb:step_over()  self:cmd("next") end
function gdb:step_out()   self:cmd("finish") end
function gdb:continue()   self:cmd("cont") end
function gdb:halt()       self.running_program:interrupt() end
function gdb:terminate()  self.running_program:terminate() end
function gdb:frame(idx)   self:cmd("f " .. idx) end



function gdb:add_breakpoint(path, line)
  self:cmd("b " .. path .. ":" .. line, function(type, category, attributes)
    if attributes["bkpt"] then
      self.breakpoints[path .. ":" .. line] = tonumber(attributes["bkpt"]["number"])
    end
  end)
end

function gdb:remove_breakpoint(path, line)
  if self.breakpoints[path .. ":" .. line] then self:cmd("d " .. self.breakpoints[path .. ":" .. line]) end
  self.breakpoints[path .. ":" .. line] = nil
end


function gdb:print(expr, on_finish)
  self:cmd("p " .. expr, function(t, category, result)
    if result and type(result) == "table" then
      local equals = result[1] and result[1]:find("=")
      if equals then
        on_finish(result[1]:sub(equals+1))
      else
        on_finish(result[1])
      end
    else
        on_finish(result)
    end
  end)
end

function gdb:variable(variable, on_finish)
  self:print(variable, function(result)
    on_finish(result:gsub("\\n$", ""))
  end)
end

function gdb:stacktrace(on_finish)
  self:cmd("backtrace", function(type, category, frames)
    local stack = { }
    for i,v in ipairs(frames) do
      local str = string.gsub(v, "[%xx]+ in ", "")
      local s,e = str:find(" at ")
      if not s then
        s,e = str:find(" from ")
      end
      if s then
        local _, _, n, func, args = string.find(str:sub(1, s-1), "#(%d+)%s+(%S+) (.+)")
        local _, _, file, line = string.find(str:sub(e + 1), "([^:]+):?(%d*)")
        table.insert(stack, { func, args, file:gsub("\\n", ""), line and tonumber(line) })
      end
    end
    on_finish(stack)
  end)
end

function gdb:instruction(on_finish)
  if self.stack_frame then
    on_finish(table.unpack(self.stack_frame))
  end
end


function gdb:loop()
  local result = self.running_program and self.running_program:read_stdout()
  if result == nil then return false end
  if #result > 0 then
    self.saved_result = self.saved_result .. result
    while #self.saved_result > 0 do
      local newline = self.saved_result:find("\n")
      if not newline then break end
      local line = self.saved_result:sub(1, newline-1)
      local type, category, attributes = gdb_parse_status_line(line)
      self.saved_result = self.saved_result:sub(newline + 1)
      if type == "*" then
        if category == "stopped" then
          if attributes.reason == "exited-normally" or attributes.reason == "exited" then
            self.debugger_completed()
          elseif attributes.frame and attributes.bkptno == "1" then
            self.debugger_started()
            self:continue()
          elseif attributes.reason == "end-stepping-range" and attributes.frame and attributes.frame.file and attributes.frame.line then
            self.stack_frame = {
              attributes.frame.file,
              tonumber(attributes.frame.line),
              attributes.frame.func
            }
            self.debugger_stopped()
          else
            if attributes.frame and attributes.frame.file and attributes.frame.line then
              self.stack_frame = {
                attributes.frame.file,
                tonumber(attributes.frame.line),
                attributes.frame.func
              }
            end
            self.debugger_stopped()
            self.accumulator = {}
          end
        end
      elseif type == "^" then
        if (category == "done" or category == "error") and self.waiting_on_result then
          self.waiting_on_result(type, category, category == "error" and attributes["msg"] or self.accumulator)
          self.waiting_on_result = nil
          self.accumulator = {}
        end
      elseif type == "~" then
        table.insert(self.accumulator, category)
      elseif type == "=" and self.waiting_on_result then
        self.waiting_on_result(type, category, attributes)
        self.waiting_on_result = nil
      end
    end
  end
  if not self.waiting_on_result and #self.command_queue > 0 then
    self.accumulator = {}
    if self.running_program:write(self.command_queue[1][1] .. "\n") then
      if self.command_queue[1][2] then
        self.waiting_on_result = self.command_queue[1][2]
      end
      table.remove(self.command_queue, 1)
    end
  end
  coroutine.yield(config.plugins.debugger.interval)
  return true
end

local function start(gdb, program_or_terminal, arguments, started, stopped, completed)
  gdb.debugger_started = started
  gdb.debugger_stopped = stopped
  gdb.debugger_completed = completed
  gdb.running_thread = core.add_thread(function()
    if type(program_or_terminal) == "string" then
      gdb.running_program = process.start({ "gdb", "-q", "-nx", "--interpreter=mi3", "--args", program_or_terminal, table.unpack(arguments) })
      gdb.waiting_on_result = function(type, category, attributes)
        gdb:cmd("set filename-display absolute")
        gdb:cmd("start")
      end
    else
      gdb.running_program = program_or_terminal
      gdb:cmd("set filename-display absolute")
      gdb:cmd("start")
    end
    gdb.saved_result = ""
    gdb.accumulator = {}
    while gdb:loop() do end
    gdb.running_program = nil
    gdb.running_thread = nil
  end)
end

function gdb:start(program, arguments, started, stopped, completed)
  return start(self, program, arguments, started, stopped, completed)
end


function gdb:attach(terminal, started, stopped, completed)
  start(self, terminal, nil, started, stopped, completed)
end

return gdb
