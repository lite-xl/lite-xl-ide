
local core = require "core"
local common = require "core.common"
local style  = require "core.style"
local config  = require "core.config"
local json = require "libraries.json"

local dap = {
  running_program = nil,
  command_queue = { },
  breakpoints = { },
  debugger_stopped = nil,
  debugger_completed = nil,
  idx = 1,
  thread_id = 1,
  frame_id = 1,
  debug = config.plugins.debugger.debug
}

local function parse_request(requests)
  local s,e,length = requests:find("^Content%-Length: (%d+)\r\n\r\n")
  if not s then return end
  return json.decode(requests:sub(e + 1, e + length)), requests:sub(e + length + 1)
end

function dap:cmd(command, arguments, on_finish)
  local cmd = json.encode({
    seq = self.idx,
    type = "request",
    command = command,
    arguments = arguments
  }):gsub("\"arguments\":%[%]", "\"arguments\":{}")
  if self.debug then print("<<<", cmd) end
  self.running_program:write("Content-Length: " .. #cmd .. "\r\n\r\n" .. cmd)
  if on_finish then self.command_queue[self.idx] = on_finish end
  self.idx = self.idx + 1
end
function dap:should_engage(path) return false end
function dap:step_into()  self:cmd("stepIn") end
function dap:step_over()  self:cmd("next") end
function dap:step_out()   self:cmd("stepOut") end
function dap:continue()   self:cmd("continue", { threadId = 1 }) end
function dap:halt()       self.running_program:interrupt() end
function dap:terminate()  self.running_program:terminate() end
function dap:frame(idx)   self.frame_id = idx end

function dap:refresh_breakpoints(path)
  local breakpoints = {}
  if self.breakpoints[path] then
    for line,v in pairs(self.breakpoints[path]) do
      table.insert(breakpoints, { line = line })
    end
  end
  self:cmd("setBreakpoints", {
    source = { path = path },
    breakpoints = breakpoints
  })
end

function dap:add_breakpoint(path, line)
  if not self.breakpoints[path] then self.breakpoints[path] = {} end
  self.breakpoints[path][line] = true
  self:refresh_breakpoints(path)
end

function dap:remove_breakpoint(path, line)
  if self.breakpoints[path] and self.breakpoints[path][line]  then
    self.breakpoints[path][line] = false
    self:refresh_breakpoints(path)
  end
end


function dap:print(expr, on_finish)
  self:cmd("evaluate", {}, on_finish)
  if self.running_thread and core.threads[self.running_thread] then
    coroutine.resume(core.threads[self.running_thread].cr)
  end
end

function dap:variable(variable, on_finish)
  self:print(variable, function(result)
    on_finish(result:gsub("\\n$", ""))
  end)
end

function dap:stacktrace(on_finish)
  self:cmd("threads", { })
  self:cmd("stackTrace", {
    threadId = self.thread_id,
  }, function(res)
    local stack = {}
    for k,v in ipairs(res.stackFrames) do
      table.insert(stack, { v.name, "", v.source.path, v.line and tonumber(line) })
    end
    on_finish(stack)
  end)
end

function dap:instruction(on_finish)
  if self.stack_frame then
    on_finish(table.unpack(self.stack_frame))
  end
end


function dap:loop()
  local chunk = self.running_program:read_stdout()
  if chunk and #chunk > 0 then
    if self.debug then print(">>>", chunk) end
    self.accumulator = self.accumulator .. chunk
  end
  while true do
    local request, remainder = parse_request(self.accumulator)
    if not request then break end
    self.accumulator = remainder
    if request['type'] == 'response' then
      if not request['success'] and request['message'] then
        core.error(request['message'])
      end
      if request['request_seq'] and self.command_queue[request['request_seq']] then
        self.command_queue[request['request_seq']](request)
        self.command_queue[request['request_seq']] = nil
        local has_any = false
        for k,v in pairs(self.command_queue) do if v then has_any = true end end
        if not has_any then self.command_queue = {} end
      end
    elseif request['type'] == 'event' then
      if request['event'] == 'stopped' then
        self.debugger_stopped()
      elseif request['event'] == 'terminated' or request['event'] == 'exited' then
        self.debugger_completed()
        return false
      elseif request['event'] == "output" and request.body then
        local _, _, brkptn, memory, file, line = request.body.output:find("Breakpoint (%d+) at ([^%s]+): file (.*), line (%d+).")
        if brkptn then
          self.stack_frame = {
            file,
            tonumber(line),
            memory
          }
          self.debugger_stopped()
        end
      end
    end
  end
  return true
end


function dap:start(program, arguments, started, stopped, completed)
  self.debugger_started = started
  self.debugger_stopped = stopped
  self.debugger_completed = completed
  self.running_thread = core.add_thread(function()
    self.running_program = process.start({ "gdb", "-q", "-nx", "-i=dap", "--args", program, table.unpack(arguments) })
    self.accumulator = ""
    coroutine.yield(1)
    self:cmd("intitialize", { }, function()
      self:cmd("launch", { })
      self:debugger_started()
      -- self:continue()
    end)
    while self:loop() do coroutine.yield(config.plugins.debugger.interval) end
    self.running_program = nil
    self.running_thread = nil
  end)
end

function dap:attach(terminal, started, stopped, completed)
  error("cannot attach with dap")
end

return dap
