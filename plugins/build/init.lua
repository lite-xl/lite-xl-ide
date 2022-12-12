-- mod-version:3 -- lite-xl 2.1
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local StatusView = require "core.statusview"
local TreeView = require "plugins.treeview"
local ToolbarView = require "plugins.toolbarview"

local build = common.merge({
  targets = { },
  current_target = 1,
  thread = nil,
  interval = 0.01,
  running_bundles = {},
  -- Config variables
  threads = 8,
  error_pattern = "^%s*([^:]+):(%d+):(%d*):? %[?(%w*)%]?:? (.+)",
  file_pattern = "^%s*([^:]+):(%d+):(%d*):? (.+)",
  error_color = style.error,
  warning_color = style.warn,
  good_color = style.good,
  drawer_size = 100,
  close_drawer_on_success = true,
  terminal = "xterm",
  shell = "bash -c"
}, config.plugins.build)


local function get_plugin_directory() 
  local paths = { 
    USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "build",
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "build"
  }
  for i, v in ipairs(paths) do if system.get_file_info(v) then return v end end
  return nil
end

local function jump_to_file(file, line, col)
  if not core.active_view or not core.active_view.doc or core.active_view.doc.abs_filename ~= file then
    -- Check to see if the file is in the project. If it is, open it, and go to the line.
    for i = 1, #core.project_directories do
      if common.path_belongs_to(file, core.project_dir) then
        local view = core.root_view:open_doc(core.open_doc(file))
        if line then
          view:scroll_to_line(math.max(1, line - 20), true)
          view.doc:set_selection(line, col or 1, line, col or 1)
        end
        break
      end
    end
  end
end


function build.parse_compile_line(line)
  local _, _, file, line_number, column, type, message = line:find(build.error_pattern)
  if file and (type == "warning" or type == "error") then
    return { type, file, line_number, column, message }
  end
  local _, _, file, line_number, column, message = line:find(build.file_pattern)
  return file and { "info", file, line_number, (column or 1), message } or line
end


local function default_on_line(line)
  build.message_view:add_message(build.parse_compile_line(line))
end

-- accept a table of commands. Run as many as we have threads. 
function build.run_tasks(tasks, on_done, on_line)
  if #tasks == 0 then
    if on_done then on_done(0) end
    return
  end
  local bundle = { tasks = {}, on_done = on_done, on_line = (on_line or default_on_line)  }
  for i, task in ipairs(tasks) do
    table.insert(bundle.tasks, { cmd = task, program = nil, done = false })
  end
  table.insert(build.running_bundles, bundle)

  if build.thread and core.threads[build.thread] and coroutine.status(core.threads[build.thread].cr) == "dead" then build.thread = nil end
  if not build.thread then
    build.thread = core.add_thread(function()
      local function handle_output(bundle, output)
        if output ~= nil then
          local offset = 1
          while offset < #output do
            local newline = output:find("\n", offset) or #output
            if bundle.on_line then
              bundle.on_line(output:sub(offset, newline-1))
            end
            offset = newline + 1
          end
        end
      end

      while #build.running_bundles > 0 do
        local total_running = 0
        local yield_time = build.interval
        local status, err = pcall(function()
          for i, bundle in ipairs(build.running_bundles) do
            local has_unfinished, bundle_finished
            for _, task in ipairs(bundle.tasks) do
              if not task.done then
                has_unfinished = true
                if task.program then
                  handle_output(bundle, task.program:read_stdout())
                  if task.program:running() then
                    total_running = total_running + 1
                  else
                    task.done = true
                    local status = task.program:returncode()
                    if status ~= 0 then
                      for _, killing_task in ipairs(bundle.tasks) do
                        if killing_task.program then 
                          killing_task.program:terminate() 
                          total_running = total_running - 1
                         end
                      end
                      bundle_finished = status
                      break
                    end
                  end
                end
              end
            end
            if not has_unfinished and bundle_finished == nil then bundle_finished = 0 end
            if bundle_finished ~= nil then 
              if bundle.on_done then bundle.on_done(bundle_finished) end
              table.remove(build.running_bundles, i)
              yield_time = 0
              break 
            end
          end
          for i, bundle in ipairs(build.running_bundles) do
            if total_running < build.threads then
              for i,task in ipairs(bundle.tasks) do
                if total_running >= build.threads then break end
                if not task.done and not task.program then
                  task.program = process.start(task.cmd, { ["stderr"] = process.REDIRECT_STDOUT })
                  build.message_view:add_message(table.concat(task.cmd, " "))
                  total_running = total_running + 1
                end
              end
              if total_running >= build.threads then break end
            end
          end
        end)
        if not status then build.message_view:add_message({ "error", err }) end
        coroutine.yield(yield_time)
      end
      build.thread = nil
    end, "build-thread")
  end
end

function build.is_running() return build.thread ~= nil end
function build.output(line) core.log(line) end

function build.set_target(target)
  build.current_target = target
  config.target_binary = build.targets[target].binary
end

function build.set_targets(targets, type)
  build.targets = targets
  for i,v in ipairs(targets) do v.backend = require("plugins.build." .. (type or "internal")) end
  config.target_binary = build.targets[1].binary
end


function build.build(callback)
  if build.is_running() then return false end
  build.message_view:clear_messages()
  build.message_view.visible = true
  local target = build.current_target
  build.message_view:add_message("Building " .. (build.targets[target].binary or "target") .. "...")
  local status, err = pcall(function() 
    if not build.targets[target] then error("Can't find target " .. target) end
    if not build.targets[target].backend then error("Can't find target " .. target .. " backend.") end
    build.targets[target].backend.build(build.targets[target], function (status)
      local line = "Completed building " .. (build.targets[target].binary or "target") .. ". " .. status .. " Errors/Warnings."
      build.message_view:add_message({ status == 0 and "good" or "error", line })
      build.message_view.visible = #build.message_view.messages > 0 or not build.close_drawer_on_success
      build.output(line)
      build.message_view.scroll.to.y = 0
    end)
  end)
  if not status then build.message_view:add_message({ "error", err }) end
end

function build.run()
  if build.is_running() then return false end
  build.message_view:clear_messages()
  local target = build.current_target
  local command = build.targets[target].run or build.targets[target].binary
  if type(command) == "function" then
    command = command(build.targets[target])
  elseif type(command) == "string" then
    command = { build.terminal, "-e", build.shell .. " 'cd " .. core.project_dir .. "; ./" .. command .. "; echo \"\nProgram exited with error code $?.\n\nPress any key to exit...\"; read'" }
  end
  build.run_tasks({ command })
end

function build.clean(callback)
  if build.is_running() then return false end
  build.message_view:clear_messages()
  local target = build.current_target
  build.message_view.visible = true
  build.message_view:add_message("Started clean " .. (build.targets[build.current_target].binary or "target") .. ".")
  build.targets[build.current_target].backend.clean(build.targets[build.current_target], function(...)
    build.message_view:add_message("Completed cleaning " .. (build.targets[build.current_target].binary or "target") .. ".")
    if callback then callback(...) end
  end)
end

function build.terminate(callback)
  if not build.is_running() then return false end
  for i, bundle in ipairs(build.running_bundles) do
    for j, task in ipairs(bundle.tasks) do 
      if task.program and not task.done then 
        task.program:terminate() 
        task.done = true
      end
    end
    bundle.on_done(1)
  end
  build.running_bundles = {}
  build.message_view:add_message({ "warning", "Terminated running build." })
  if callback then callback() end
end

function build.kill(callback)
  if not build.is_running() then return false end
  for i, bundle in ipairs(build.running_bundles) do
    for j, task in ipairs(bundle.tasks) do 
      if task.program then task.program:kill() end
    end
  end
  build.message_view:add_message({ "error", "Killed running build." })
  if callback then callback() end
end


------------------ UI Elements
core.status_view:add_item({
  predicate = function() return build.current_target and build.targets[build.current_target] end,
  name = "build:target",
  alignemnt = StatusView.Item.RIGHT,
  get_item = function()
    local dv = core.active_view
    return {
      style.text, "target: " .. build.targets[build.current_target].name
    }
  end,
  command = function()
     core.command_view:enter("Select Build Target", {
      text = build.targets[build.current_target].name,
      submit = function(text)
        local has = false
        for i,v in ipairs(build.targets) do
          if text == v.name then
            set_build_target(i)
            has = true
          end
        end
        if not has then core.error("Can't find target " .. text) end
      end,
      suggest = function()
        local names = {}
        for i,v in ipairs(build.targets) do
          table.insert(names, v.name)
        end
        return names
      end
    })
  end
})

local doc_view_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(idx, x, y, width)
  if build.message_view and self.doc.abs_filename == build.message_view.active_file
    and build.message_view.active_message
    and idx == build.message_view.active_line
  then
    renderer.draw_rect(x, y, self:get_gutter_width(), self:get_line_height(), build.error_color)
  end
  doc_view_draw_line_gutter(self, idx, x, y, width)
end

local BuildMessageView = View:extend()
function BuildMessageView:new()
  BuildMessageView.super.new(self)
  self.messages = { }
  self.target_size = build.drawer_size
  self.scrollable = true
  self.init_size = true
  self.hovered_message = nil
  self.visible = false
  self.active_message = nil
  self.active_file = nil
  self.active_line = nil
end

function BuildMessageView:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.y = dest
    self.init_size = false
  else
    self:move_towards(self.size, "y", dest)
  end
  BuildMessageView.super.update(self)
end

function BuildMessageView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end

function BuildMessageView:clear_messages()
  self.messages = {}
  self.hovered_message = nil
  self.active_message = nil
  self.active_file = nil
  self.active_line = nil
end

function BuildMessageView:add_message(message)
  local should_scroll = self:get_scrollable_size() <= self.size.y or self.scroll.to.y == self:get_scrollable_size() - self.size.y
  table.insert(self.messages, message)
  if should_scroll then
    self.scroll.to.y = self:get_scrollable_size() - self.size.y
  end
end

function BuildMessageView:get_item_height()
  return style.code_font:get_height() + style.padding.y*2
end

function BuildMessageView:get_scrollable_size()
  return #self.messages and self:get_item_height() * (#self.messages + 1)
end

function BuildMessageView:on_mouse_moved(px, py, ...)
  BuildMessageView.super.on_mouse_moved(self, px, py, ...)
  if self.dragging_scrollbar then return end
  local ox, oy = self:get_content_offset()
  if px > self.position.x and py > self.position.y and px < self.position.x + self.size.x and py < self.position.y + self.size.y then
    local offset = math.floor((py - oy) / self:get_item_height())
    self.hovered_message = offset >= 1 and offset <= #self.messages and offset
  else
    self.hovered_message = nil
  end
end


function BuildMessageView:draw()
  self:draw_background(style.background3)
  local h = style.code_font:get_height()
  local item_height = self:get_item_height()
  local ox, oy = self:get_content_offset()
  local title = "Build Messages"
  local subtitle = { }
  if build.is_running() then
    local t = { "|", "/", "-", "\\", "|", "/", "-", "\\" }
    title = title .. " " .. t[(math.floor(system.get_time()*8) % #t) + 1]
    core.redraw = true
  elseif type(self.messages[#self.messages]) == "table" and #self.messages[#self.messages] == 2 then
    subtitle = self.messages[#self.messages]
  end
  local colors = {
    error = build.error_color,
    warning = build.warning_color,
    good = build.good_color
  }
  local x = common.draw_text(style.code_font, style.accent, title, "left", ox + style.padding.x, self.position.y + style.padding.y, 0, h)
  if subtitle and #subtitle == 2 then
    common.draw_text(style.code_font, colors[subtitle[1]] or style.accent, subtitle[2], "left", x + style.padding.x, self.position.y + style.padding.y, 0, h)
  end
  core.push_clip_rect(self.position.x, self.position.y + h + style.padding.y * 2, self.size.x, self.size.y - h - style.padding.y * 2)
  for i,v in ipairs(self.messages) do
    local yoffset = style.padding.y * 2 + (i - 1)*item_height + style.padding.y + h
    if self.hovered_message == i or self.active_message == i then
      renderer.draw_rect(ox, oy + yoffset - style.padding.y * 0.5, self.size.x, h + style.padding.y, style.line_highlight)
    end
    if type(v) == "table" then
      if #v > 2 then
        common.draw_text(style.code_font, colors[v[1]] or style.text, v[2] .. ":" .. v[3] .. " [" .. v[1] .. "]: " .. v[5], "left", ox + style.padding.x, oy + yoffset, 0, h)
      else
        common.draw_text(style.code_font, colors[v[1]] or style.text, v[2], "left", ox + style.padding.x, oy + yoffset, 0, h)
      end
    else
      common.draw_text(style.code_font, style.text, v, "left", ox + style.padding.x, oy + yoffset, 0, h)
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end



local BuildBarView = ToolbarView:extend()

function BuildBarView:new()
  BuildBarView.super.new(self)
  self.toolbar_font = renderer.font.load(get_plugin_directory() .. PATHSEP .. "build.ttf", style.icon_big_font:get_size())
  self.toolbar_commands = {
    {symbol = "!", command = "build:build"},
    {symbol = '"', command = "build:run-or-term-or-kill"},
    {symbol = "#", command = "build:rebuild"},
    {symbol = "$", command = "build:terminate"},
    {symbol = "&", command = "build:next-target"},
    {symbol = "%", command = "build:toggle-drawer"},
  }
end

build.build_bar_view = BuildBarView()
build.message_view = BuildMessageView()
local node = core.root_view:get_active_node()
build.message_view_node = node:split("down", build.message_view, { y = true }, true)
build.build_bar_node = TreeView.node.b:split("up", build.build_bar_view, {y = true})

command.add(function()
  local mv = build.message_view
  return mv.hovered_message and type(mv.messages[mv.hovered_message]) == "table" and #mv.messages[mv.hovered_message] > 2
end, {
  ["build:jump-to-hovered"] = function() 
    local mv = build.message_view
    mv.active_message = mv.hovered_message
    mv.active_file = system.absolute_path(common.home_expand(mv.messages[mv.hovered_message][2]))
    mv.active_line = tonumber(mv.messages[mv.hovered_message][3])
    jump_to_file(mv.active_file, tonumber(mv.messages[mv.hovered_message][3]), tonumber(mv.messages[mv.hovered_message][4]))
  end
})

local tried_term = false
command.add(function()
  return not build.is_running()
end, {
  ["build:build"] = function()
    if #build.targets > 0 then
      build.build()
    end
  end,
  ["build:rebuild"] = function()
    build.clean(function()
      if #build.targets > 0 then
        build.build()
      end
    end)
  end,
  ["build:clean"] = function()
    build.clean()
  end,
  ["build:next-target"] = function()
    if #build.targets > 0 then
      build.set_target((build.current_target % #build.targets) + 1)
    end
  end
})

command.add(function()
  return build.is_running()
end, {
  ["build:terminate"] = function()
    build.terminate()
  end
})


command.add(function()
  return config.target_binary and system.get_file_info(config.target_binary)
end, {
  ["build:run-or-term-or-kill"] = function()
    if build.is_running() then
      if tried_term then
        build.kill()
      else
        build.terminate()
        tried_term = true
      end
    else
      tried_term = false
      build.run()
    end
  end
})

command.add(nil, {
  ["build:toggle-drawer"] = function()
    build.message_view.visible = not build.message_view.visible
  end
})

keymap.add {
  ["lclick"]             = "build:jump-to-hovered",
  ["ctrl+b"]             = { "build:build", "build:terminate" },
  ["ctrl+alt+b"]         = "build:rebuild",
  ["ctrl+e"]             = "build:run-or-term-or-kill",
  ["ctrl+t"]             = "build:next-target",
  ["ctrl+shift+b"]       = "build:clean",
  ["f6"]                 = "build:toggle-drawer"
}

core.add_thread(function()
  if config.plugins.build.targets then
    build.set_targets(config.plugins.build.targets, config.plugins.build.type)
  else
    build.set_targets({
      { name = "debug", binary = common.basename(core.project_dir) .. "-debug", cflags = "-g", cxxflags = "-g" },
      { name = "release", binary = common.basename(core.project_dir) .. "-release", cflags = "-O3", cxxflags = "-O3" },
    })
  end
end)

return build

