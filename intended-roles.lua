-- WirePlumber
--
-- Copyright © 2021 Asymptotic
--    @author Arun Raghavan <arun@asymptotic.io>
--
-- SPDX-License-Identifier: MIT
--
-- Route streams of a given role (media.role property) to devices that are
-- intended for that role (device.intended-roles property)

metadata_om = ObjectManager {
  Interest {
    type = "metadata",
    Constraint { "metadata.name", "=", "default" },
  }
}

devices_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "matches", "Audio/*", type = "pw-global" },
    Constraint { "device.intended-roles", "is-present", type = "pw" },
  }
}

streams_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "matches", "Stream/*/Audio", type = "pw-global" },
    Constraint { "media.role", "is-present", type = "pw-global" }
  }
}

local function routeUsingIntendedRole(stream, dev)
  -- [本地补丁 2026-11-08] Q38-1（无麦蓝牙音箱）的 HFP 输入节点是"假麦克风"，
  -- 不参与 intended-roles 的"通信"抢流；其余设备行为与原版完全一致。
  -- 回滚：删除本文件（~/.config/wireplumber/scripts/intended-roles.lua）后重启 wireplumber。
  if dev.properties["media.class"] == "Audio/Source"
      and (dev.properties["node.name"] or ""):find("23_CF_F0_21_FD_2A") then
    return
  end
  local stream_role = stream.properties["media.role"]
  local is_input = stream.properties["media.class"]:find("Input") ~= nil

  local is_source = dev.properties["media.class"]:find("Source") ~= nil
  local dev_roles = dev.properties["device.intended-roles"]

  -- Make sure the stream and device direction match
  if is_input ~= is_source then
    return
  end

  for role in dev_roles:gmatch("(%a+)") do
    if role == stream_role then
      Log.info(stream,
        string.format("Routing stream '%s' (%d) with role '%s' to '%s' (%d)",
          stream.properties["node.name"], stream["bound-id"], stream_role,
          dev.properties["node.name"], dev["bound-id"])
      )

      local metadata = metadata_om:lookup()
      metadata:set(stream["bound-id"], "target.node", "Spa:Id", dev["bound-id"])
    end
  end
end

streams_om:connect("object-added", function (streams_om, stream)
  for dev in devices_om:iterate() do
    routeUsingIntendedRole(stream, dev)
  end
end)

devices_om:connect("object-added", function (devices_om, dev)
  for stream in streams_om:iterate() do
    routeUsingIntendedRole(stream, dev)
  end
end)

metadata_om:activate()
devices_om:activate()
streams_om:activate()
