-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 2

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
-- cm = "edid": manage color against this panel's own EDID-reported gamut
-- (wide/P3) instead of assuming generic sRGB, to fix oversaturation.
-- Bit depth: this is a 10-bit wide-gamut panel. NB: depth has nothing to do
-- with the sheared tile seam -- genlock is lost intermittently per modeset at
-- any depth, and any fresh modeset re-rolls it. Left at whatever last locked.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale, cm = "dp3", bitdepth = 8 })

-- Configure a specific monitor.
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })
