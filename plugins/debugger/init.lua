-- mod-version:3 -- lite-xl 2.1


--[[ 
# Debugger Plugin

The debugger plugin is architected as follows:

1. A presentation layer (`init.lua`). The presentation layer is a number of dialogs that calls into the secondary layer to get information there.
2. An agnostic model layer (`debugger.lua`). This layer represents the current state of the debugger, with no debugger specific info. Manages agnostic state, described below.
3. A specific debugger layer (`gdb.lua`). Provides functions to read, and set state of the underlying debugger. Should manage as little state as possible in and of itself, purely functions to access the debugger. All functions take callbacks.

## Model Layer

## Functions

* `stacktrace(callback)`
* `variable(name, callback)`
* `instruction(callback)`
* `start(path, arguments, paused, exited)`
* `instruction(callback)`
* `continue()`
* `step_over()`
* `step_into()`
* `step_out()`
* `halt()`
* `stopped()`
* `frame(idx)`
* `completed()`
* `add_breakpoint(path, line)`
* `remove_breakpoint(path, line)`
* `has_breakpoint(path, line)`

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
local View = require "core.view"
local StatusView = require "core.statusview"

local model = require "plugins.debugger.model"

local draw_line_gutter = DocView.draw_line_gutter
local docview_on_mouse_moved = DocView.on_mouse_moved
local docview_on_mouse_pressed = DocView.on_mouse_pressed
local draw_line_text = DocView.draw_line_text
local docview_draw = DocView.draw
local docview_update = DocView.update


local debugger = {
  drawer_visible = false,
  state = nil,
  instruction = nil,
  
}

if not style.debugger then style.debugger = {} end
style.debugger.breakpoint = style.debugger.breakpoint or { common.color "#ca3434" }
style.debugger.instruction = style.debugger.instruction or { common.color "#3434ca" }

config.plugins.debugger = common.merge({
  step_refresh_watches = true,
  interval = 0.01,
  drawer_size = 100,
  hover_time_watch = 1,
  hover_symbol_pattern_backward = "[^%s+-%(%)%*/;,]+",
  hover_symbol_pattern_forward = "[^%s+-%(%)%[%*%./;,]+",
}, config.plugins.debugger)

local function jump_to_file(file, line)
  if not core.active_view or not core.active_view.doc or core.active_view.doc.abs_filename ~= file then
    -- Check to see if the file is in the project. If it is, open it, and go to the line.
    for i = 1, #core.project_directories do
      if common.path_belongs_to(file, core.project_dir) then
        local view = core.root_view:open_doc(core.open_doc(file))
        if line then
          view:scroll_to_line(math.max(1, line - 20), true)
          view.doc:set_selection(line, 1, line, 1)
        end
        break
      end
    end
  end
end

function debugger:set_instruction(path, line)
  if path then
    self.instruction = { path, line }
    jump_to_file(path, line)
  else
    self.instruction = nil
  end
end

function debugger:refresh()
  model:instruction(function(path, line, func) 
    self:set_instruction(path, line)
  end)
  if self.drawer_visible then
    self.stack_view:refresh()
    self.watch_result_view:refresh()
  end
end

function debugger:paused()
  self:refresh()
end

function debugger:exited()
  debugger.instruction = nil
  self.drawer_visible = false
end


function DocView:on_mouse_pressed(button, x, y, clicks)
  if self.hovering_gutter and (model.state == "stopped" or model.state == "inactive") then
    local minline, maxline = core.active_view:get_visible_line_range()
    local _, docy = core.active_view:get_line_screen_position(minline)
    local line = minline + math.floor((y - docy) / self:get_line_height())
    if not model:has_breakpoint(self.doc.abs_filename, line) then
      model:add_breakpoint(self.doc.abs_filename, line)
    else
      model:remove_breakpoint(self.doc.abs_filename, line)
    end
    return true
  end
  return docview_on_mouse_pressed(button, x, y, clicks)
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
  end
end

function DocView:draw_line_gutter(idx, x, y, width)
   if model:has_breakpoint(self.doc.abs_filename, idx) then
     renderer.draw_rect(x, y, self:get_gutter_width(), self:get_line_height(), style.debugger.breakpoint)
   end
   if debugger.instruction and debugger.instruction[1] == self.doc.abs_filename and idx == debugger.instruction[2] then
     renderer.draw_rect(x, y+1, self:get_gutter_width(), self:get_line_height()-2, style.debugger.instruction)
   end
  draw_line_gutter(self, idx, x, y, width)
end

function DocView:update()
  docview_update(self)
  if not self.watch_calulating and self:is(DocView) and core.active_view == self and not self.watch_hover_value and debugger.state == "stopped" and self.last_moved_time and 
      system.get_time() - math.max(debugger.last_start_time, self.last_moved_time[3]) > config.plugins.debugger.hover_time_watch then
    local x, y = self.last_moved_time[1], self.last_moved_time[2]
    local line, col = self:resolve_screen_position(x, y)
    local _, s = self.doc.lines[line]:reverse():find(config.plugins.debugger.hover_symbol_pattern_backward, #self.doc.lines[line] - col - 1)
    if s then
      local _, e = self.doc.lines[line]:find(config.plugins.debugger.hover_symbol_pattern_forward, col)
      s, e = #self.doc.lines[line] - s + 1, e or col
      local token = self.doc.lines[line]:sub(s, e)
      if #token > 1 and not self.watch_token then
        debugger.print(token, function(result)
          self.watch_hover_value = result:gsub("\\n", "")
        end)
      end
      self.watch_token = { line, s, e }
    end
  end
end


function DocView:draw_line_text(line, x, y)
  if self.watch_token and self.watch_token[1] == line then
    local x1, y = self:get_line_screen_position(line, self.watch_token[2])
    local x2 = self:get_line_screen_position(line, self.watch_token[3] + 1)
    renderer.draw_rect(x1, y, x2 - x1, self:get_line_height(), style.text)
  end
  draw_line_text(self, line, x, y)
end

function DocView:draw()
  docview_draw(self)
  if self.watch_hover_value then
    local x, y = self.last_moved_time[1], self.last_moved_time[2]
    local w, h = style.font:get_width(self.watch_hover_value) + style.padding.x*2, style.font:get_height() + style.padding.y * 2
    renderer.draw_rect(x, y, w, h, style.dim)
    renderer.draw_text(style.font, self.watch_hover_value, x + style.padding.x, y + style.padding.y, style.text)
  end
end

local DebuggerWatchResultView = View:extend()
function DebuggerWatchResultView:new()
  DebuggerWatchResultView.super.new(self)
  self.results = { }
  self.target_size = config.plugins.debugger.drawer_size
  self.init_size = true
end
function DebuggerWatchResultView:update()
  local dest = debugger.drawer_visible and self.target_size or 0
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  DebuggerWatchResultView.super.update(self)
end
function DebuggerWatchResultView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end
function DebuggerWatchResultView:get_item_height() return style.font:get_height() end
function DebuggerWatchResultView:get_scrollable_size() return 0 end
function DebuggerWatchResultView:draw()
  self:draw_background(style.background2)
  local h = style.code_font:get_height()
  local ox, oy = self:get_content_offset()
  common.draw_text(style.font, style.text, "Watch Values", "left", ox + style.padding.x, oy, self.size.x, h)
  for i,v in ipairs(self.results) do
    local yoffset = i * style.font:get_height()
    common.draw_text(style.code_font, style.text, v, "left", ox + style.padding.x, oy + yoffset, 0, h)
  end
end
function DebuggerWatchResultView:refresh(idx)
  local lines = debugger.watch_variable_view.doc.lines
  local total_lines = lines[1]:find("%S") and #lines or 0
  if idx then
    self.results[idx] = ""
  else
    self.results[total_lines+1] = nil
  end
  for i = 1, #lines do
    if lines[i]:find("%S") and not idx or idx == i then
      model:variable(lines[i]:gsub("\n$", ""), function(value)
        self.results[i] = value
      end)
    end
  end
end


local DebuggerWatchVariableDoc = Doc:extend()
function DebuggerWatchVariableDoc:new()
  DebuggerWatchVariableDoc.super.new(self)
end
function DebuggerWatchVariableDoc:text_input(text)
  if self:has_selection() then
    self:delete_to()
  end
  local newline = text:find("\n")
  if newline then
    local line, col = self:get_selection()
    
    if #text == 1 and col == 1 and #self.lines[line] == 1 then
      if #debugger.watch_result_view.results >= line then
        table.remove(debugger.watch_result_view.results, line)
      end
      if #self.lines > line then
        self:raw_remove(line, 1, line+1, 1, self.undo_stack, system.get_time())
      end
    else
      self:insert(line, col, text:sub(1, newline))
      self:move_to(newline-1)
      debugger.watch_result_view:refresh(line)
    end
    core.set_active_view(core.root_view)
  else
    local line, col = self:get_selection()
    self:insert(line, col, text)
    self:move_to(#text)
  end
end
function DebuggerWatchVariableDoc:delete_to(...)
  local line, col = self:get_selection(true)
  if self:has_selection() then
    self:remove(self:get_selection())
  elseif col > 1 then
    local line2, col2 = self:position_offset(line, col, ...)
    self:remove(line, col, line2, col2)
    line, col = sort_positions(line, col, line2, col2)
  end
  self:set_selection(line, col)
end
function DebuggerWatchVariableDoc:remove(line1, col1, line2, col2)
  if line1 == line2 then
    DebuggerWatchVariableDoc.super.remove(self, line1, col1, line2, col2)
  end
end
function DebuggerWatchVariableDoc:set_selection(line1, col1, line2, col2, swap)
  assert(not line2 == not col2, "expected 2 or 4 arguments")
  if swap then line1, col1, line2, col2 = line2, col2, line1, col1 end
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2 or line1, col2 or col1)
  if line2 ~= line1 then
    line2 = line1
    col2 = #self.lines[line1] - 1
  end
  self.selections = { line1, col1, line2, col2 }
end
local DebuggerWatchVariableView = DocView:extend()
function DebuggerWatchVariableView:new()
  DebuggerWatchVariableView.super.new(self, DebuggerWatchVariableDoc(self))
  self.target_size = config.plugins.debugger.drawer_size
  self.init_size = true
end
function DebuggerWatchVariableView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end
function DebuggerWatchVariableView:try_close(do_close) end
function DebuggerWatchVariableView:get_scrollable_size() return 0 end
function DebuggerWatchVariableView:get_gutter_width() return 0 end
function DebuggerWatchVariableView:draw_line_gutter(idx, x, y) end

--  common.draw_text(style.code_font, style.text, "Watch Values", "left", ox + style.padding.x, oy, self.size.x, h)
function DebuggerWatchVariableView:get_content_offset(...)
  local x, y = DebuggerWatchVariableView.super.get_content_offset(self, ...)
  return x, y + self:get_line_height()
end
function DebuggerWatchVariableView:get_line_screen_position(idx)
  local x, y = self:get_content_offset()
  return x + self:get_gutter_width() + style.padding.x, y + (idx-1)
end
function DebuggerWatchVariableView:draw_line_body(idx, x, y)
  DebuggerWatchVariableView.super.draw_line_body(self, idx, x, y)
  if idx == 1 then
    renderer.draw_rect(x - self:get_gutter_width() - style.padding.x, y, self.size.x, 1, style.divider)
  end
  renderer.draw_rect(x - self:get_gutter_width() - style.padding.x, y + self:get_line_height(), self.size.x, 1, style.divider)
end
function DebuggerWatchVariableView:draw()
  DebuggerWatchVariableView.super.draw(self)
  local ox, oy = self:get_content_offset()
  common.draw_text(style.font, style.text, "Watch Expressions", "left", ox + style.padding.x, oy - self:get_line_height(), self.size.x, self:get_line_height())
end
function DebuggerWatchVariableView:draw_background(color)
  DebuggerWatchVariableView.super.draw_background(self, style.background3)
end


local DebuggerStackView = View:extend()
debugger.DebuggerStackView = DebuggerStackView
function DebuggerStackView:new()
  DebuggerStackView.super.new(self)
  self.stack = { }
  self.target_size = config.plugins.debugger.drawer_size
  self.scrollable = true
  self.init_size = true
  self.hovered_frame = nil
  self.active_frame = nil
end
function DebuggerStackView:update()
  local dest = debugger.drawer_visible and self.target_size or 0
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
function DebuggerStackView:set_stack(stack)
  self.stack = stack
  self.hovered_frame = nil
  self.active_frame = 1
  core.redraw = true
end
function DebuggerStackView:get_item_height()
  return style.code_font:get_height() + style.padding.y*2
end
function DebuggerStackView:get_scrollable_size()
  return #self.stack and self:get_item_height() * (#self.stack + 1)
end
function DebuggerStackView:on_mouse_moved(px, py, ...)
  DebuggerStackView.super.on_mouse_moved(self, px, py, ...)
  if self.dragging_scrollbar then return end
  local ox, oy = self:get_content_offset()
  local offset = math.floor((py - oy) / self:get_item_height())
  self.hovered_frame = offset >= 1 and offset <= #self.stack and offset
end

function DebuggerStackView:on_mouse_pressed(button, x, y, clicks)
  local caught = DebuggerStackView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then
    return caught
  end
  if self.hovered_frame then
    if clicks >= 2 then
      debugger.frame(self.hovered_frame - 1)
      self.active_frame = self.hovered_frame
      debugger.set_instruction(self.stack[self.hovered_frame][3], self.stack[self.hovered_frame][4])
    end
    jump_to_file(self.stack[self.hovered_frame][3], self.stack[self.hovered_frame][4])
    return true;
  end
end

function DebuggerStackView:draw()
  self:draw_background(style.background3)
  local h = style.code_font:get_height()
  local item_height = self:get_item_height()
  local ox, oy = self:get_content_offset()
  common.draw_text(style.font, style.text, "Stack Trace", "left", ox + style.padding.x, oy, 0, h)
  for i,v in ipairs(self.stack) do
    local yoffset = style.padding.y + (i - 1)*item_height + style.padding.y + h
    if self.hovered_frame == i or self.active_frame == i then
      renderer.draw_rect(ox, oy + yoffset - style.padding.y, self.size.x, h + style.padding.y*2, style.line_highlight)
    end
    common.draw_text(style.code_font, style.text, "#" .. i .. " " .. v[1] .. " " .. v[2] .. " " .. v[3] .. (v[4] and (" line " .. v[4]) or ""), "left", ox + style.padding.x, oy + yoffset, 0, h)
  end
  self:draw_scrollbar()
end
function DebuggerStackView:refresh(on_finish)
  model:stacktrace(function(stack)
    self:set_stack(stack)
    if on_finish then
      on_finish(stack)
    end
  end)
end

debugger.stack_view = DebuggerStackView()
debugger.watch_variable_view = DebuggerWatchVariableView()
debugger.watch_result_view = DebuggerWatchResultView()

local node = core.root_view:get_active_node()
debugger.stack_view_node = node:split("down", debugger.stack_view, { y = true }, true)
debugger.watch_variable_view_node = debugger.stack_view_node:split("right", debugger.watch_variable_view, { y = true }, true)
debugger.watch_result_view_node = debugger.watch_variable_view_node:split("right", debugger.watch_result_view, { y = true }, true)

core.status_view:add_item({
  predicate = function() return config.target_binary end,
  name = "debugger:binary",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local dv = core.active_view
    return {
      style.text, config.target_binary .. (config.target_binary_arguments and "*" or "")
    }
  end,
  command = function()
     core.command_view:enter("Set Target Binary", {
      text = config.target_binary .. (config.target_binary_arguments and (" " .. config.target_binary_arguments) or ""),
      submit = function(text)
        local i = text:find(" ")
        if i then
          config.target_binary = text:sub(1, i-1)
          config.target_binary_arguments = text:sub(i+1)
        else
          config.target_binary = text
          config.target_binary_arguments = nil
        end
      end
    })
  end
})

core.status_view:add_item({
  predicate = function() return config.target_binary end,
  name = "debugger:status",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local dv = core.active_view
    return {
      style.text, model.state
    }
  end
})

command.add(function()
  return config.target_binary and system.get_file_info(config.target_binary) and (model.state == "stopped" or model.state == "inactive")
end, {
  ["debugger:start-or-continue"] = function()
    if model.state == "stopped" then
      model:continue()
    elseif config.target_binary then
      model:start(config.target_binary, config.target_binary_arguments, function()
        debugger:paused()
      end, function() 
        debugger:exited()
      end)
    end
  end
})

command.add(function()
  return core.active_view and core.active_view.doc and (model.state == "stopped" or model.state == "inactive")
end, {
  ["debugger:toggle-breakpoint"] = function()
    local line1, col1, line2, col2, swap = core.active_view.doc:get_selection(true)
    if line1 then
      if model:has_breakpoint(core.active_view.doc.abs_filename, line1) then
        model:add_breakpoint(core.active_view.doc.abs_filename, line1)
      else
        model:remove_breakpoint(core.active_view.doc.abs_filename, line1)
      end
    end
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

command.add(function()
  return model.state == "running"
end, {
  ["debugger:halt"] =      function() model:halt() end,
})

command.add(function()
  return model.state == "stopped"
end, {
  ["debugger:step-over"] = function() model:step_over() end,
  ["debugger:step-into"] = function() model:step_into() end,
  ["debugger:step-out"] =  function() model:step_out() end,
})

keymap.add { 
  ["f7"]                 = "debugger:step-over",
  ["shift+f7"]           = "debugger:step-into",
  ["ctrl+f7"]            = "debugger:step-out",
  ["f8"]                 = "debugger:start-or-continue", 
  ["ctrl+f8"]            = "debugger:halt",
  ["shift+f8"]           = "debugger:terminate",
  ["f9"]                 = "debugger:toggle-breakpoint",
  ["f12"]                = "debugger:toggle-drawer",
}


local has_build, build = core.try(require, 'plugins.build')
if has_build then
  -- overwrite the build plugins' "play" toolbar button to activate the debugger, if this is a debug build.
  build.build_bar_view.toolbar_commands[2] = { symbol = '"', command = "debugger:start-or-continue"}
  build.build_bar_view.toolbar_commands[4] = { symbol = '$', command = "debugger:terminate"}
end


return debugger
