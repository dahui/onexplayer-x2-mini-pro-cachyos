-- ONEXPLAYER X2Mini PRO internal OLED — Samsung AMS881KB01-0.
--
-- gamescope only advertises HDR for panels it recognises: `--hdr-enabled` alone
-- is not enough, the display must also match an entry in
-- gamescope.config.known_displays. Without one, Steam shows no HDR toggle even
-- though the panel and the kernel are both ready.
--
-- This is the same panel used in the Lenovo Legion Go 2, which gamescope 3.16
-- does not ship an entry for either — the bundled lenovo.legiongo*.lua scripts
-- cover only the LCD models and set supported = false.
--
-- Installed to /etc/gamescope/scripts/, which gamescope scans after its own
-- bundled directory, so this survives gamescope updates.
--
-- Every value below is read from the panel's own EDID rather than a datasheet:
--
--   Manufacturer: SDC          Model: 17153 (0x4301)
--   Product name: AMS881KB01-0
--   Display Device Technology: Organic LED, native 12 bpc
--   Colorimetry Data Block: BT2020RGB
--   HDR Static Metadata: SMPTE ST2084, static metadata type 1
--     Desired content max luminance:           1107.128 cd/m^2
--     Desired content max frame-average:        475.683 cd/m^2
--     Desired content min luminance:              0.001 cd/m^2

-- Chromaticity from the EDID Color Characteristics block.
local x2mini_oled_colorimetry = {
	r = { x = 0.6835, y = 0.3154 },
	g = { x = 0.2402, y = 0.7138 },
	b = { x = 0.1396, y = 0.0439 },
	w = { x = 0.3134, y = 0.3291 },
}

gamescope.config.known_displays.oxp_x2mini_oled = {
	pretty_name = "AMS881KB01-0 OLED",
	hdr = {
		supported = true,
		force_enabled = true,
		-- Describes the panel's native SDR transfer function, not the HDR
		-- output encoding — matching every other OLED entry shipped with
		-- gamescope (Steam Deck OLED, Zotac AMOLED, OneXPlayer F1 OLED).
		eotf = gamescope.eotf.gamma22,
		max_content_light_level = 1107,
		max_frame_average_luminance = 476,
		min_content_light_level = 0.001,
	},
	colorimetry = x2mini_oled_colorimetry,

	-- Deliberately no dynamic_refresh_rates / dynamic_modegen. Those drive
	-- refresh-rate switching and need per-panel timings verified against a
	-- datasheet; guessing them risks an unusable mode. The panel's native
	-- 1920x1200@144 and its VRR range (30-144 Hz, advertised in the EDID's
	-- Adaptive Sync Data Block) are unaffected by their absence.

	matches = function(display)
		if display.vendor == "SDC" and display.product == 0x4301 then
			debug("[oxp_x2mini_oled] Matched vendor: " .. display.vendor ..
				" product: " .. display.product)
			return 5000
		end
		return -1
	end,
}
debug("Registered AMS881KB01-0 OLED as a known display")
