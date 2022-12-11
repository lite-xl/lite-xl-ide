local core = require "core"
local build = require "plugins.build"

local make = {
  threads = build.threads,
  running_program = nil,
  interval = 0.1
}


local function run_command(cmd, on_line, on_done)
  core.add_thread(function()
    make.running_program = process.start(cmd, { ["stderr"] = process.REDIRECT_STDOUT })    
    
    local function handle_output(output)
      if output ~= nil then
        local offset = 1
        while offset < #output do
          local newline = output:find("\n", offset) or #output
          if on_line then
            on_line(output:sub(offset, newline-1))
          end
          offset = newline + 1
        end
      end
    end
    
    while make.running_program:running() do
      handle_output(make.running_program:read_stdout())
      coroutine.yield(make.interval)
    end
    handle_output(make.running_program:read_stdout())
    if on_done then
      on_done(make.running_program:returncode())
    end
  end)
end


function make.terminate(callback)
  make.running_program:terminate()
  if callback then callback() end
end

function make.is_running()
  return make.running_program and make.running_program:running()
end


local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end
function make.build(target, callback)
  run_command({ "make", target.name, "-j", build.threads }, function(line)
    local _, _, file, line_number, column, type, message = line:find(build.error_pattern)
    if file and (type == "warning" or type == "error") then
      build.message_view:add_message({ type, file, line_number, column, message })
    else
      local _, _, file, line_number, column, message = line:find(build.file_pattern)
      if file then
        build.message_view:add_message({ "info", file, line_number, (column or 1), message } )
      else
        build.message_view:add_message(line)
      end
    end
  end, function(status)
    local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
    if callback then callback(status == 0 and #filtered_messages or 1) end
  end)
end


function make.clean(target, callback)
  run_command({ "make", "clean" }, function() end, function()
    if callback then callback() end
  end)
end


return make
