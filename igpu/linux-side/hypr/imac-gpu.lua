-- Pin Hyprland to the Radeon when the Intel iGPU is visible (omarchy-imac18-3 igpu/linux-side).
-- Load it from ~/.config/hypr/hyprland.lua next to the other personal modules
-- (after require("default.hypr.omarchy"), e.g. just before require("hypr.monitors")):
--     require("hypr.imac-gpu")
-- hl.env() takes effect "before the display server initializes" (wiki), so the
-- position among the user requires should not matter; AQ_DRM_DEVICES is read
-- once at startup, a config reload does not re-pick GPUs.
-- (mirror the same change into ~/Projects/dotfiles, which carries copies.)
--
-- Pin Hyprland/aquamarine to the Radeon. AQ_DRM_DEVICES is a ':'-separated
-- list; aquamarine canonicalises each entry (std::filesystem::canonical, so a
-- udev symlink is fine) and then uses ONLY the listed devices, first = primary
-- (aquamarine v0.15.0 src/backend/drm/DRM.cpp, scanGPUs()). Without it,
-- aquamarine opens every KMS device: boot_vga first, but a GPU with more
-- *connected* eDP/LVDS/DSI panels is promoted to primary, and every other card
-- is opened as a secondary GPU. hl.env() is applied before the display server
-- initialises (Hyprland wiki, configuring/core/environment-variables).
--
-- Guarded, because an AQ_DRM_DEVICES entry that does not exist leaves
-- aquamarine with no GPU at all (black screen at login):
--   * only when the Intel function exists (set_os boots) -- default boots,
--     where the iGPU is hidden, keep today's behaviour exactly;
--   * only when the udev link from 61-imac-dri-names.rules is already there.
-- Never add the Intel card to this list: it has no outputs and must not
-- become a (secondary) renderer for the compositor.
--
-- Aquamarine ignores GPUs that appear after it started (the session emits
-- addDrmCard, nothing consumes it), so an i915 that binds late cannot be
-- picked up either way.
--
-- Deliberately NOT set here: LIBVA_DRIVER_NAME. libva applies it to every VA
-- display regardless of which device it was opened on (va.c: drivers[0] =
-- LIBVA_DRIVER_NAME), so "iHD" globally would break VA-API on the Radeon.
-- libva already maps i915 -> iHD and amdgpu -> radeonsi by itself.

require("default.hypr.helpers") -- defines o.shell_succeeds (idempotent)

if o.shell_succeeds("test -e /sys/bus/pci/devices/0000:00:02.0 && test -e /dev/dri/amd-card") then
  hl.env("AQ_DRM_DEVICES", "/dev/dri/amd-card")
end
