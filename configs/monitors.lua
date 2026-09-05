-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 2

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
-- cm = "edid": manage color against this panel's own EDID-reported gamut
-- (wide/P3) instead of assuming generic sRGB, to fix oversaturation.
-- bitdepth = 10: the dual-tile panel keeps genlock (sync_enabled=1 on both
-- tile streams) at 10-bpc, but the compositor's default 8-bpc modeset drops
-- the slave tile out of sync, which shows up as a skewed/sheared seam.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale, cm = "dp3", bitdepth = 10 })

-- Configure a specific monitor.
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })
