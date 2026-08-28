-- Safe Omarchy default used while the iMac display mode is forced at boot.
-- Native 5K requires two-tile stitching that the current Aquamarine path does
-- not expose as one Hyprland output.

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

