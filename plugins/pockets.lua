-- mod-version:3 -- lite-xl 2.1 -- priority:0

local core = require "core"
local Node = require "core.node"
local config = require "core.config"
local common = require "core.common"
local View = require "core.view"
local RootView = require "core.rootview"
local EmptyView = require "core.emptyview"

config.plugins.pockets = common.merge({
  pockets = {
    { name = "top", direction = "up", preference = "hsplit" },
    { name = "bottom", direction = "down", preference = "hsplit" },
    { name = "left", direction = "left", preference = "tab" },
    { name = "right", direction = "right", preference = "tab" },
    { name = "drawer", direction = "down", preference = "hsplit" }
  }
}, config.plugins.pockets)


-- A pocket is a special kind of node that is always present, but if it has no contents, is hidden.
-- Pockets can be either tabbable, h-splittable, or v-splittable
core.root_view.pockets = {}
for i,v in ipairs(config.plugins.pockets.pockets) do
  local lock = ((v.direction == "left" or v.direction == "right") and { x = true } or { y = true })
  core.root_view.pockets[v.name] = core.root_view:get_active_node():split(v.direction, nil, lock, true)
  core.root_view.pockets[v.name].preference = v.preference
end


function RootView:add_view(view)
  local node = self.root_node:get_node_for_view(core.active_view)
  local parent = self.root_node:get_node_for_view(core.active_view)
  while parent and parent.preference == nil do parent = node:get_parent_node(self.root_node) end
  if parent and parent.preference == "tab" then
    node:add_view(view)
  else
    core.root_view:get_active_node_default():add_view(view)
  end
end


local old_add_view = Node.add_view
function Node:add_view(view, preference)
  local leaf = self
  if (preference or self.preference) == "tab" then
    while leaf.type ~= "leaf" do leaf = leaf.a end
  else
    while leaf.type ~= "leaf" do leaf = leaf.b end
  end
  local view_count = #leaf.views - (#leaf.views > 0 and leaf.views[1]:is(EmptyView) and 1 or 0)

  if view_count > 0 and (preference or self.preference) == "hsplit" then
    leaf:split("right", view, self.preference == "tab" and { y = true, x = true }, true)
  elseif view_count > 0 and (preference or self.preference) == "vsplit" then
    leaf:split("down", view, self.preference == "tab" and { x = true, y = true }, true)
  else
    while leaf.type ~= "leaf" do leaf = leaf.a end
    -- Specifically override locked, to handle the case where a view has no underlying views.
    local old_locked = leaf.locked
    assert(not leaf.locked or view_count == 0, "Tried to add view to locked node")
    leaf.locked = false
    old_add_view(leaf, view)
    leaf.locked = old_locked
  end
  return view
end
