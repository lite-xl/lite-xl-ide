-- mod-version:4


--[[
# Debugger Plugin

The debugger plugin is architected as follows:

1. A presentation layer (`init.lua`). The presentation layer is a number of dialogs that calls into the secondary layer to get information there.
2. An agnostic model layer (`debugger.lua`). This layer represents the current state of the debugger, with no debugger specific info. Manages agnostic state, described below.
3. A specific debugger layer (`gdb.lua`). Provides functions to read, and set state of the underlying debugger. Should manage as little state as possible in and of itself, purely functions to access the debugger. All functions take callbacks.

## Model Layer

### States

The model layer has the following states.

1. Inactive
2. Running
3. Stopped

#### Inactive

In the inactive state, the debugger is compeltely inactive, and only renders breakpoints.

#### Started

In a started state. Can take input about actviating breakpoints, etc..

#### Running

In the running state, the debugger renders breakpoints, and a status icon showing that the program is running.

#### Stopped

In the stopped state, renders:

* The instruction marker (which is retrieved upon immediate access to this state).
* All breakpoints
* Stack Trace
* Debugger Variables
* Hovered Variables

### Transitions

Transitions can be triggered by either the backend layer, or the user. Triggers are given as (<user> | <backend>)

#### Inactive -> Starting (`debugger.start` | )

Happens when a user manually initiates a start.

#### Starting -> Stopped  ( | `debugger.started`)

First callback from starting; debugger should pause when it's engaged at the primary entrypoint.

* Active debugger determined based on file, active debugger set to that backend.
* All breakpoints applied.
* Continue

#### Running -> Stopped (`debugger.break` | `debugger.stopped`)

Happens on breakpoint trigger, or on break.

* Watched variables queried
* Stacktrace retrieved
* Instruction point retrieved

#### Stopped -> Running (`debugger.continue`, `debugger.step_into`, `debugger.step_out`, debugger.step_over` |)

Happens when a user hits a step or continue function.

#### Stopped -> Inactive (`debugger.terminate` | `debugger.completed`)

Happens when the program completes, or the user terminates debugger.

Any other state transitions are illegal, and will throw an error.

## Backend Layer

The backend has the following functions:

* `variable(name, callback)`
* `stacktrace(callback)`
* `status(callback)`
* `instruction(callback)`
* `start(path, arguments, started, stopped, completed)`
* `continue()`
* `halt()`
* `frame(idx)`
* `terminate()`
* `add_breakpoint(path, line)`
* `remove_breakpoint(path, line)`
* `should_engage(path)`

--]]

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local Doc = require "core.doc"
local common = require "core.common"
local style  = require "core.style"
local config  = require "core.config"
local tokenizer = require "core.tokenizer"
local syntax = require "core.syntax"
local View = require "core.view"
local StatusView = require "core.statusview"

local model = require "plugins.debugger.model"

local draw_line_gutter = DocView.draw_line_gutter
local docview_on_mouse_moved = DocView.on_mouse_moved
local docview_on_mouse_pressed = DocView.on_mouse_pressed
local draw_line_text = DocView.draw_line_text
local docview_draw = DocView.draw
local docview_update = DocView.update

-- This bit is for compatiblity between mod-version 3 and 4.
local storage 
local get_selection, set_selection
if rawget(_G, "MOD_VERSION_MAJOR") == 4 then
  storage = require "core.storage"
  get_selection = function(view, ...) return view:get_selection(...) end
  set_selection = function(view, ...) return view:set_selection(...) end
else
  storage = {}
  function storage.load(module, key)
    local f = io.open(USERDIR .. PATHSEP .. module .. "-" .. key .. ".state", "rb")
    return f and load("return " .. f:read("*all"))()
  end
  function storage.save(module, key, value)
    io.open(USERDIR .. PATHSEP .. module .. "-" .. key .. ".state", "wb"):write(common.serialize(value)):close()
  end
  if not core.root_project then
    local root_project = {
      path = core.project_dir,
      absolute_path = function(self, path)
        return core.project_absolute_path(path)
      end,
      normalize_path = function(self, path)
        return common.normalize_path(path)
      end,
      get_file_info = function(self, path)
        return system.get_file_info(path)
      end
    }
    function core.root_project()
      return root_project
    end
  end
  get_selection = function(view, ...) return view.doc:get_selection(...) end
  set_selection = function(view, ...) return view.doc:set_selection(...) end
end

local debugger = {
  drawer_visible = nil,
  state = nil,
  instruction = nil,
  last_exited = 0,
  state = nil
}

if not style.debugger then style.debugger = {} end
style.debugger.breakpoint = style.debugger.breakpoint or { common.color "#ca3434" }
style.debugger.instruction = style.debugger.instruction or { common.color "#3434ca" }
style.debugger.font = style.code_font:copy(style.code_font:get_height()*0.7)

debugger.state = storage.load("debugger", "state") or { breakpoints = { } }
for file, lines in pairs(debugger.state.breakpoints) do
  for line in pairs(lines) do
    model:add_breakpoint(file, line)
  end
end
function debugger:save()
  storage.save("debugger", "state", debugger.state)
end

config.plugins.debugger = common.merge({
  step_refresh_watches = true,
  hide_drawer_after = 3,
  interval = 0.01,
  drawer_size = 200,
  hover_time_watch = 0.5,
  time_to_trigger_uninteractable_background = 0.1,
  hover_symbol_pattern_backward = "[^%s%+%-%(%)%*/;,]*%a",
  hover_symbol_pattern_forward = "[^%s%+%-%(%)%[%*%./;,]+",
  skip_files = { 
    "/usr/include/*",
    "/usr/include/*/*",
    "/usr/include/*/*/*",
    "/usr/include/*/*/*/*"
  }
}, config.plugins.debugger)

for i,v in ipairs(config.plugins.debugger.skip_files) do table.insert(model.skip_files, v) end

local function jump_to_file(file, line)
  -- Check to see if the file is in the project. If it is, open it, and go to the line.
  if file and system.get_file_info(file) then
    local view = core.root_view:open_doc(core.open_doc(file))
    if line then
      view:scroll_to_line(line, true, true)
      set_selection(view, line, 1, line, 1)
    end
  end
end

function debugger:set_instruction(path, line)
  self.instruction = path and { path, line } or nil
  if path then jump_to_file(path, line) end
end

function debugger:refresh()
  model:stacktrace(function(frames)
    local frame = frames[1]
    for i,v in ipairs(frames) do
      local func, args, file, line = table.unpack(v)
      if system.get_file_info(file) then
        frame = v
        break
      end
    end
    if frame then self:set_instruction(frame[3], frame[4]) end
  end)
  if self:should_show_drawer() then
    self.stack_view:refresh()
    self.watch_result_view:refresh()
  end
end

function debugger:paused()
  self:refresh()
end

function debugger:exited()
  debugger.instruction = nil
  debugger.last_exited = system.get_time()
  debugger.stack_view.stack = { }
  if self.drawer_visible then self.drawer_visible = false end
end

function debugger:should_show_drawer()
  return self.drawer_visible == true or (self.drawer_visible == nil and model.state ~= "inactive" or (system.get_time() - debugger.last_exited) < (config.plugins.debugger.hide_drawer_after or 0))
end

function debugger:get_hovering_token(docview, line, col)
  local _, s = docview.doc.lines[line]:reverse():find(config.plugins.debugger.hover_symbol_pattern_backward, #docview.doc.lines[line] - col - 1)
  if s and not docview.doc.lines[line]:sub(col, col):find("[=%s%[%(]") then
    local _, e = docview.doc.lines[line]:find(config.plugins.debugger.hover_symbol_pattern_forward, col)
    s, e = #docview.doc.lines[line] - s + 1, e or col
    local token = docview.doc.lines[line]:sub(s, e):gsub("\n$", "")
    return token, line, s, line, e
  end
end

function DocView:on_mouse_pressed(button, x, y, clicks)
  if self.hovering_gutter and command.perform("debugger:toggle-line-breakpoint", self.hovering_gutter) then 
    return true 
  end
  return docview_on_mouse_pressed(self, button, x, y, clicks)
end

function DocView:on_mouse_moved(x, y, ...)
  self.last_moved_time = { x, y, system.get_time() }
  self.watch_hover_value = nil
  self.watch_token = nil
  if docview_on_mouse_moved(self, x, y, ...) then return true end
  local minline, maxline = self:get_visible_line_range()
  local _, docy = self:get_line_screen_position(minline)
  if x > self.position.x and x < self.position.x + self:get_gutter_width() then
    self.cursor = "arrow"
    local line = minline + math.floor((y - docy) / self:get_line_height())
    self.hovering_gutter = self.get_dline and self:get_dline(line) or line
  end
end

function DocView:draw_line_gutter(vline, x, y, width)
  local idx = self.get_dline and self:get_dline(vline) or vline
  if model:has_breakpoint(self.doc.abs_filename, idx) then
    renderer.draw_rect(x, y, self:get_gutter_width(), self:get_line_height(), style.debugger.breakpoint)
  end
  if model.state == "stopped" and debugger.instruction and debugger.instruction[1] == self.doc.abs_filename and idx == debugger.instruction[2] then
    renderer.draw_rect(x, y+1, self:get_gutter_width(), self:get_line_height()-2, style.debugger.instruction)
  end
  draw_line_gutter(self, vline, x, y, width)
end

function DocView:update()
  docview_update(self)
  if model.state == "stopped" and self:is(DocView) and core.active_view == self and self.doc and debugger.instruction and debugger.instruction[1] == self.doc.abs_filename and self.watch_token == nil and self.last_moved_time and
      system.get_time() - math.max(debugger.last_start_time, self.last_moved_time[3]) > config.plugins.debugger.hover_time_watch then
    local x, y = self.last_moved_time[1], self.last_moved_time[2]
    local line, col = self:resolve_screen_position(x, y)
    local token, line1, col1, line2, col2 = debugger:get_hovering_token(self, line, col)
    if token then
      if #token > 0 and not self.watch_token then
        model:variable(token, function(result)
          self.watch_hover_value = result
        end)
      end
      self.watch_token = { line1, col1, col2 }
    else
      self.watch_token = false
    end
  end
end


function DocView:draw_line_text(vline, x, y)
  if self.watch_token and self.watch_token[1] == vline then
    local x1, y = self:get_line_screen_position(vline, self.watch_token[2])
    local x2 = self:get_line_screen_position(vline, self.watch_token[3] + 1)
    renderer.draw_rect(x1, y, x2 - x1, self:get_line_height(), style.text)
  end
  return draw_line_text(self, vline, x, y)
end

function DocView:draw()
  docview_draw(self)
  if self.watch_hover_value then
    local x, y = self.last_moved_time[1], self.last_moved_time[2]
    local w, h = style.font:get_width(self.watch_hover_value) + style.padding.x*2, style.font:get_height() + style.padding.y * 2
    renderer.draw_rect(x, y, w, h, style.accent)
    renderer.draw_rect(x+1, y+1, w-2, h-2, style.background3)
    renderer.draw_text(style.font, self.watch_hover_value, x + style.padding.x, y + style.padding.y, style.text)
  end
end

function debugger:should_look_uninteractable()
  if model.state == "running" then
    self.last_change_state = self.last_change_state or system.get_time()
  elseif model.state == "starting" then
    self.last_change_state = 0
  else
    self.last_change_state = nil
  end
  if self.last_change_state then
    if system.get_time() - self.last_change_state > config.plugins.debugger.time_to_trigger_uninteractable_background then
      return true
    end
    core.redraw = true
  end
  return false
end

local DebuggerWatchVariableDoc = Doc:extend()
function DebuggerWatchVariableDoc:new()
  DebuggerWatchVariableDoc.super.new(self)
end

local DebuggerWatchHalf = DocView:extend()
function DebuggerWatchHalf:new(title, doc)
  DebuggerWatchHalf.super.new(self, doc)
  self.title = title
  self.is_debugger_view = true
  self.target_size = config.plugins.debugger.drawer_size
  self.init_size = true
end
function DebuggerWatchHalf:try_close(do_close) end
function DebuggerWatchHalf:get_scrollable_size() return self.size.y end
function DebuggerWatchHalf:get_gutter_width() return 0 end
function DebuggerWatchHalf:draw_line_gutter(idx, x, y) end
function DebuggerWatchHalf:get_font() return style.debugger.font end
function DebuggerWatchHalf:get_line_height() return style.debugger.font:get_height() + style.padding.y * 2 end
function DebuggerWatchHalf:draw_background(color) 
  DebuggerWatchHalf.super.draw_background(self, debugger:should_look_uninteractable() and style.dim or style.background3)
end

function DebuggerWatchHalf:update()
  local dest = debugger:should_show_drawer() and self.target_size or 0
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  DebuggerWatchHalf.super.update(self)
end
function DebuggerWatchHalf:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end
function DebuggerWatchHalf:draw_line_body(idx, x, y)
  renderer.draw_rect(x - style.padding.x, y + self:get_line_height(), self.size.x, 1, style.divider)
  return DebuggerWatchHalf.super.draw_line_body(self, idx, x, y)
end

function DebuggerWatchHalf:resolve_screen_position(x, y)
  return DebuggerWatchHalf.super.resolve_screen_position(self, x, y - self:get_line_height())
end

if rawget(_G, "MOD_VERSION_MAJOR") == 4 then
  function DebuggerWatchHalf:get_vline_position(line, col)
    local x,y = DebuggerWatchHalf.super.get_vline_position(self, line, col)
    return x,y + self:get_line_height()
  end
else
  function DebuggerWatchHalf:get_line_screen_position(line, col)
    local x,y = DebuggerWatchHalf.super.get_line_screen_position(self, line, col)
    return x,y + self:get_line_height()
  end
end

function DebuggerWatchHalf:draw()
  DebuggerWatchHalf.super.draw(self)
  common.draw_text(style.font, style.text, self.title, "left", self.position.x + style.padding.x, self.position.y, self.size.x, self:get_line_height())
  renderer.draw_rect(self.position.x, self.position.y + self:get_line_height(), self.size.x, 1, style.divider)
end

local DebuggerWatchResultView = DebuggerWatchHalf:extend()
function DebuggerWatchResultView:new()
  DebuggerWatchResultView.super.new(self, "Watch Values", DebuggerWatchVariableDoc(self))
end

function DebuggerWatchResultView:refresh(idx)
  local lines = debugger.watch_variable_view.doc.lines
  local total_lines = lines[1]:find("%S") and #lines or 0
  if idx then
    self.doc:remove(i, 1, i, #self.doc.lines[i])
  else
    self.doc:insert(total_lines+1, 1, '')
  end
  for i = 1, #lines do
    if not idx or idx == i then
      if lines[i]:find("%S") and model.state == "stopped" then
        model:variable(lines[i]:gsub("\n$", ""), function(value)
          self.doc:remove(i, 1, i, self.doc.lines[i] and #self.doc.lines[i] or 1)
          self.doc:insert(i, 1, (value or "undefined") .. (i == #self.doc.lines and "\n" or ""))
        end)
      else
        self.doc:remove(i, 1, i, self.doc.lines[i] and #self.doc.lines[i] or 1)
      end
    end
  end
  if lines[#lines] ~= "\n" then
    debugger.watch_variable_view.doc:insert(#lines + 1, 1, "\n")
  end
  if #self.doc.lines > #lines then
    self.doc:remove(#lines, 1, #self.doc.lines, #self.doc.lines[#self.doc.lines])
  end
end


local DebuggerWatchVariableView = DebuggerWatchHalf:extend()
function DebuggerWatchVariableView:new()
  DebuggerWatchVariableView.super.new(self, "Watch Expressions", DebuggerWatchVariableDoc(self))
end


local DebuggerStackView = View:extend()
debugger.DebuggerStackView = DebuggerStackView

function DebuggerStackView:new()
  DebuggerStackView.super.new(self)
  self.stack = { }
  self.is_debugger_view = true
  self.target_size = config.plugins.debugger.drawer_size
  self.scrollable = true
  self.init_size = true
  self.hovered_frame = nil
  self.active_frame = nil
end

function DebuggerStackView:update()
  local dest = debugger:should_show_drawer() and self.target_size or 0
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  DebuggerStackView.super.update(self)
end

function DebuggerStackView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end

local c_syntax
function DebuggerStackView:set_stack(stack)
  self.stack = stack
  self.stack_tokens = {}

  c_syntax = c_syntax or syntax.get(".c")
  for i,v in ipairs(stack) do
    local tokens, state = tokenizer.tokenize(c_syntax, v[2])
    self.stack_tokens[i] = {}
    for j, type, text in tokenizer.each_token(tokens) do
      table.insert(self.stack_tokens[i], { type, text })
    end
  end

  self.hovered_frame = nil

  self.active_frame = 1
  for i,v in ipairs(stack) do
    local func, args, file, line = table.unpack(v)
    if core.root_project():get_file_info(file) then
      self.active_frame = i
      model:frame(i - 1)
      break
    end
  end
  
  core.redraw = true
end

function DebuggerStackView:get_item_height() return style.debugger.font:get_height() + style.padding.y end
function DebuggerStackView:get_scrollable_size() return #self.stack and self:get_item_height() * (#self.stack + 1) end
function DebuggerStackView:get_h_scrollable_size() return #self.stack and math.huge end

function DebuggerStackView:on_mouse_moved(px, py, ...)
  DebuggerStackView.super.on_mouse_moved(self, px, py, ...)
  if self.dragging_scrollbar then return end
  local ox, oy = self:get_content_offset()
  local offset = math.floor((py - oy) / self:get_item_height())
  if px >= self.position.x and px < self.position.x + self.size.x then
    self.hovered_frame = offset >= 1 and offset <= #self.stack and offset
  else
    self.hovered_frame = nil
  end
end


function DebuggerStackView:draw()
  self:draw_background(((self.refreshing and (#self.stack == 0 or system.get_time() - self.refreshing > config.plugins.debugger.time_to_trigger_uninteractable_background)) or debugger:should_look_uninteractable()) and style.dim or style.background3)
  if not core.root_project() then return end
  local h = style.debugger.font:get_height()
  local item_height = self:get_item_height()
  local ox, oy = self:get_content_offset()
  common.draw_text(style.font, style.text, "Stack Trace", "left", ox + style.padding.x, oy, 0, item_height)
  for i,v in ipairs(self.stack) do
    local yoffset = i*item_height
    local y = oy + yoffset
    if y + h + style.padding.y*2 >= self.position.y and y < self.position.y + self.size.y then
      if not debugger:should_look_uninteractable() and (self.hovered_frame == i or self.active_frame == i) then
        -- should be math.huge, but for some reason doesn't draw the rect.
        renderer.draw_rect(ox, y, 1000000000, item_height, self.active_frame == i and style.debugger.instruction or style.line_highlight)
      end
      local tx = ox + style.padding.y
      tx = common.draw_text(style.debugger.font, style.accent, "#" .. i .. " ", "left", tx, oy + yoffset, 0, item_height)
      tx = common.draw_text(style.debugger.font, style.text, v[1] .. " ", "left", tx, oy + yoffset, 0, item_height)
      for _,  token in ipairs(self.stack_tokens[i]) do
        local type, text = table.unpack(token)
        if tx < self.position.x + self.size.x then
          tx = common.draw_text(style.debugger.font, style.syntax[type] or style.text, text, "left", tx, oy + yoffset, 0, item_height)
        end
      end
      if tx < self.position.x + self.size.x then
        tx = common.draw_text(style.debugger.font, style.text, " " .. core.root_project():normalize_path(v[3]) .. (v[4] and (" line " .. v[4]) or ""), "left", tx, oy + yoffset, 0, item_height)
      end
    end
  end
  self:draw_scrollbar()
end

function DebuggerStackView:refresh(on_finish)
  self.refreshing = system.get_time()
  model:stacktrace(function(stack)
    self.refreshing = nil
    self:set_stack(stack)
    if on_finish then
      on_finish(stack)
    end
  end)
end


local has_terminal, terminal = pcall(require, 'plugins.terminal')
local TerminalView = terminal and terminal.class
debugger.stack_view = DebuggerStackView()
debugger.watch_variable_view = DebuggerWatchVariableView()
debugger.watch_result_view = DebuggerWatchResultView()
debugger.terminal_view = has_terminal and TerminalView({ shell = "DUMMY", font = style.debugger.font })
if debugger.terminal_view then debugger.terminal_view.is_debugger_view = true end

local old_set_active_view = core.set_active_view
function core.set_active_view(view)
  old_set_active_view(view)
  if model.state == "inactive" and view.is_debugger_view and (config.plugins.debugger.hide_drawer_after and (system.get_time() - debugger.last_exited) < config.plugins.debugger.hide_drawer_after) then
    debugger.drawer_visible = true
  end
end

core.add_thread(function()
  local node = core.root_view:get_active_node()
  debugger.stack_view_node = node:split("down", debugger.stack_view, { y = true }, true)
  if debugger.terminal_view then
    debugger.terminal_view_node = debugger.stack_view_node:split("right", debugger.terminal_view, { y = false }, true)
    debugger.watch_variable_view_node = debugger.terminal_view_node:split("up", debugger.watch_variable_view, { y = false }, true)
    debugger.watch_result_view_node = debugger.watch_variable_view_node:split("right", debugger.watch_result_view, { y = false }, true)
  else
    debugger.watch_variable_view_node = debugger.stack_view_node:split("right", debugger.watch_variable_view, { y = true }, true)
    debugger.watch_result_view_node = debugger.watch_variable_view_node:split("right", debugger.watch_result_view, { y = true }, true)
  end
end)

core.add_thread(function() 
  local item = core.status_view:add_item({
    predicate = function() return config.target_binary or model.state ~= "inactive" end,
    name = "debugger:status",
    alignment = StatusView.Item.RIGHT,
    command = function()
      if model.state == "inactive" then
        command.perform("debugger:start")
      elseif model.state == "stopped" then
        command.perform("debugger:continue")
      elseif model.state == "running" then
        command.perform("debugger:halt")
      end
    end
  })
  item.on_draw = function(x, y, h, calc_only)
    local color = {
      stopped = style.debugger.breakpoint,
      running = style.good,
      starting = style.warn
    }
    local size = (h - style.padding.y * 2) / 2
    renderer.draw_rect(x, y  + (h - size) / 2, size, size, color[model.state] or style.dim)
    local nx = common.draw_text(style.font, style.text, model.state, "left", x + size + style.padding.x / 2, y, nil, h)
    return nx - x
  end
end)

local has_build, build = pcall(require, 'plugins.build')

command.add(function()
  return model.state == "stopped"
end, {
  ["debugger:continue"] = function()
    model:continue()
  end
})
command.add(function()
  return model.state == "running"
end, {
  ["debugger:halt"] = function()
    model:halt()
  end
})

command.add(function()
  return config.target_binary and system.get_file_info(core.root_project():absolute_path(config.target_binary)) and model.state == "inactive"
end, {
  ["debugger:start"] = function()
    debugger.last_start_time = system.get_time()
    if debugger.terminal_view then debugger.terminal_view.terminal:clear() end
    model:start(config.target_binary, config.target_binary_arguments, function()
      debugger:paused()
    end, function()
      debugger:exited()
    end, function(line, source)
      if debugger.terminal_view then
        debugger.terminal_view:input(line .. "\r\n")
      else
        print(line)
      end
    end)
  end
})

command.add(function()
  return config.target_binary and (system.get_file_info(core.root_project():absolute_path(config.target_binary)) or has_build) and model.state ~= "running"
end, {
  ["debugger:start-or-continue"] = function()
    if not system.get_file_info(core.root_project():absolute_path(config.target_binary)) then
      command.perform("build:build")
    else
      command.perform(model.state == "stopped" and "debugger:continue" or "debugger:start")
    end
  end
})

command.add(function()
  return core.active_view and core.active_view.doc
end, {
  ["debugger:toggle-line-breakpoint"] = function(line)
    if not line then line = get_selection(core.active_view, true) end
    if line then
      local file = core.active_view.doc.abs_filename
      if not model:has_breakpoint(file, line) then
        model:add_breakpoint(file, line)
        if not debugger.state.breakpoints then debugger.state.breakpoints = {} end
        if not debugger.state.breakpoints[file] then debugger.state.breakpoints[file] = {} end
        debugger.state.breakpoints[file][line] = true
      else
        model:remove_breakpoint(file, line)
        if debugger.state.breakpoints[file] then debugger.state.breakpoints[file][line] = nil end
      end
      debugger:save()
    end
  end
})

command.add(function()
  return core.active_view and core.active_view:is(DebuggerStackView) and core.active_view.hovered_frame, core.active_view
end, {
  ["debugger:jump-hovered-frame"] = function(view)
    jump_to_file(view.stack[view.hovered_frame][3], view.stack[view.hovered_frame][4])
  end
})
    
command.add(function()
  return core.active_view and core.active_view:is(DebuggerStackView) and core.active_view.hovered_frame and model.state == "stopped", core.active_view
end, {
  ["debugger:select-hovered-frame"] = function(view)
    model:frame(view.hovered_frame - 1, function()
      debugger.watch_result_view:refresh()
    end)
    view.active_frame = view.hovered_frame
    debugger:set_instruction(view.stack[view.hovered_frame][3], view.stack[view.hovered_frame][4])
  end
})

command.add(nil, {
  ["debugger:toggle-drawer"] = function() debugger.drawer_visible = not debugger.drawer_visible end
})

command.add(function()
  return model.state == "running" or model.state == "stopped"
end, {
  ["debugger:terminate"] = function() model:terminate() end
})

command.add(DebuggerWatchVariableView, {
  ["debugger:refresh-watches"] = function() 
    debugger.watch_result_view:refresh()
    core.set_active_view(core.next_active_view or core.last_active_view) 
  end
})


command.add(function()
  return model.state == "stopped"
end, {
  ["debugger:step-over"] = function() model:step_over() end,
  ["debugger:step-into"] = function() model:step_into() end,
  ["debugger:step-out"] =  function() model:step_out() end,
})

keymap.add {
  ["1lclick"]            = "debugger:jump-hovered-frame",
  ["2lclick"]            = "debugger:select-hovered-frame",
  ["return"]             = "debugger:refresh-watches",
  ["keypad enter"]       = "debugger:refresh-watches",
  ["f7"]                 = "debugger:step-over",
  ["shift+f7"]           = "debugger:step-into",
  ["ctrl+f7"]            = "debugger:step-out",
  ["f8"]                 = { "debugger:start-or-continue", "debugger:halt" },
  ["shift+f8"]           = "debugger:terminate",
  ["f9"]                 = "debugger:toggle-line-breakpoint",
  ["f12"]                = "debugger:toggle-drawer",
}

if has_terminal then
  command.add(function()
    return terminal and model.state == "inactive" and core.active_view and core.active_view:is(TerminalView)
  end, {
    ["debugger:attach"] = function()
      local attached_view = core.active_view
      debugger.last_start_time = system.get_time()

      local proc = {
        buffer = "",
        view = core.active_view,
        read_stdout = function(self)
          local a = self.buffer
          self.buffer = ""
          return a
        end,
        interrupt = function(self) self.view.terminal:input("\x03") end,
        terminate = function(self) self.view.terminal:input("\x03quit\n") end,
        write = function(self, chunk)
          self.view.terminal:input(chunk)
          return #chunk;
        end
      }

      local old_update = core.active_view.terminal.update
      core.active_view.terminal.old_update = core.active_view.terminal.update
      core.active_view.terminal.update = function(self)
        return old_update(self, function(chunk)
          proc.buffer = proc.buffer .. chunk
        end)
      end
      model:attach(proc, model.backends.gdb, function()
        debugger:paused()
      end, function()
        debugger:exited()
      end)
    end,
    ["debugger:insert-run"] = function()
      core.active_view.terminal:input("gdb -q -nx --interpreter=mi3 --args ")
    end
  })
  command.add(function()
    return terminal and model.state ~= "inactive" and core.active_view and core.active_view:is(TerminalView)
  end, {
    ["debugger:detach"] = function()
      model:terminate()
      core.active_view.terminal.update = core.active_view.terminal.old_update
    end
  })
  keymap.add {
    ["f8"]                 = { "debugger:attach", "debugger:detach" },
    ["ctrl+shift+d"]       = "debugger:insert-run"
  }
end

if has_build then
  -- overwrite the build plugins' "play" toolbar button to activate the debugger, if this is a debug build.
  build.build_bar_view.toolbar_commands[2] = { symbol = '"', command = "debugger:start-or-continue"}
  build.build_bar_view.toolbar_commands[4] = { symbol = '$', command = "debugger:terminate"}
end

return debugger
