package.path = debug.getinfo(1, "S").source:match("^@?(.*/)") .. "?.lua;" .. package.path

local mp = require("mp")
local options = require("mp.options")
local util = require("util")
local cache = require("cache")
local providers = require("providers")
local layout = require("layout")
local render = require("render")
local timeline = require("timeline")

local opts = {
	key_cycle_mode = "Alt+t",
	key_show_translation = "Ctrl+y",
	mode_on_start = "off",
	provider = "mymemory",
	lang_from = "en",
	lang_to = "tr",

	position = "top-center",
	margin_y = 24,
	font = "sans-serif",
	color_text = "ffffff",
	color_outline = "101010",
	outline_width = 1,
	color_bg = "101010",
	bg_opacity = 55,
	max_width_percent = 80,
	translation_background = false,
	panel_font_scale = 0.85,

	hover_backend = "replica",
	replica_font_size = 38,
	replica_outline = 3,
	hovered_color = "ff5555",
	dict_url_template = "https://tureng.com/en/turkish-english/{word}",
	word_provider = "tureng",

	mirror_font = "monospace",
	mirror_font_size = 30,
	mirror_margin_y = 56,
	color_mirror = "ffffff",

	dict_max_groups = 4,
	dict_max_terms = 6,
	dict_max_lines = 6,
	popup_offset = 18,
	popup_font_size = 32,
	popup_padding_x = 0.35,
	popup_padding_y = 0.12,
	timeout = 10,
	prefetch = true,
	prefetch_all = true,
	prefetch_concurrency = 4,
	prefetch_ahead = 20,
	verbose = false,
	show_hitboxes = false,

	deepl_api_key = "",
	deepl_free = true,
	libretranslate_url = "https://libretranslate.com",
	libretranslate_api_key = "",
	lingva_instance = "https://lingva.ml",
	mymemory_email = "",
}

options.read_options(opts, "subtitle-translate")

cache.init(opts)
providers.init(opts)
layout.init(opts)
render.init(opts)
timeline.init(opts)

local MODES = { "off", "dict", "ondemand", "always" }
local MODE_LABEL = {
	off = "translation off",
	dict = "mode 1: hover a word - wheel scrolls, click opens dictionary",
	ondemand = "mode 2: hover the subtitle area or press " .. opts.key_show_translation,
	always = "mode 3: translation always on",
}

local state = "off"
local mode_index = 1

local line_ui = {
	seq = 0,
	text = nil,
	display = nil,
	translated = nil,
	error = nil,
	pending = false,
	pinned_line = nil,
	shown = false,
	rendered_key = nil,
}

local hover = {
	sub = nil,
	layout = nil,
	idx = nil,
	seq = 0,
	last_diag = nil,
	osd_w = nil,
	osd_h = nil,
	built_at = nil,
}

local saved_sub_props = nil

local function log(text)
	util.log(text)
end

local function notify(text, duration)
	mp.osd_message("[subtitle-translate] " .. text, duration or 2)
	if opts.verbose then
		log(text)
	end
end

local function current_sub()
	local text = mp.get_property("sub-text")
	if not text or text == "" then
		return nil
	end
	return text
end

local function get_replica_style()
	return {
		playres_y = 720,
		font = mp.get_property("sub-font") or "sans-serif",
		fontsize = opts.replica_font_size,
		bold = 0,
		italic = 0,
		spacing = 0,
		align = 2,
		margin_l = 0,
		margin_r = 0,
		margin_v = opts.mirror_margin_y,
		sub_pos = mp.get_property_number("sub-pos") or 100,
		source = "options",
		primary = "&HFFFFFF",
		primary_a = 0,
		outline_c = "&H101010",
		outline_a = 0,
		back_c = "&H101010",
		back_a = 0,
		outline = 3,
		shadow = 0,
	}
end

local function replica_activate()
	if saved_sub_props then
		return
	end
	saved_sub_props = {
		color = mp.get_property("sub-color"),
		border_color = mp.get_property("sub-border-color"),
		shadow_color = mp.get_property("sub-shadow-color"),
		ass_override = mp.get_property("sub-ass-override"),
	}
	mp.set_property("sub-color", "0/0/0/0")
	mp.set_property("sub-border-color", "0/0/0/0")
	mp.set_property("sub-shadow-color", "0/0/0/0")
	mp.set_property("sub-ass-override", "force")
	if opts.verbose then
		log("replica: native subtitles transparent, sub-* config styling active")
	end
end

local function replica_deactivate()
	if not saved_sub_props then
		return
	end
	local saved = saved_sub_props
	saved_sub_props = nil
	render.remove_line()
	if saved.color then
		mp.set_property("sub-color", saved.color)
	end
	if saved.border_color then
		mp.set_property("sub-border-color", saved.border_color)
	end
	if saved.shadow_color then
		mp.set_property("sub-shadow-color", saved.shadow_color)
	end
	if saved.ass_override then
		mp.set_property("sub-ass-override", saved.ass_override)
	end
	if opts.verbose then
		log("replica: native subtitles restored")
	end
end

local function ensure_hover_layout()
	local raw = current_sub()
	if not raw then
		hover.sub = nil
		hover.layout = nil
		return nil
	end
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return nil
	end
	if raw == hover.sub and hover.layout and hover.osd_w == w and hover.osd_h == h then
		if hover.built_at and mp.get_time() - hover.built_at < 1.5 then
			return hover.layout
		end
	end
	local style
	hover.sub = raw
	hover.idx = nil
	if opts.hover_backend == "mirror" then
		hover.layout = layout.build_mirror_layout(raw, w, h)
	elseif opts.hover_backend == "replica" then
		style = get_replica_style(saved_sub_props)
		local fs = style.fontsize * (h / 720)
		local meas = {
			width = function(t)
				return layout.measure_width(t, style, w, h, fs)
			end,
			height = function()
				return layout.measure_height("X", style, w, h, fs)
			end,
			row_rect = function(t)
				return layout.probe_text(t, style, w, h, fs)
			end,
		}
		hover.layout = layout.build_native_layout(raw, w, h, style, meas)
	else
		style = timeline.get_native_style()
		local scale = (style.playres_y or 288) > 0 and (h / style.playres_y) or 1
		local fs = style.fontsize * scale
		local meas = {
			width = function(t)
				return layout.measure_width(t, style, w, h, fs)
			end,
			height = function()
				return layout.measure_height("X", style, w, h, fs)
			end,
			row_rect = function(t)
				return layout.probe_text(t, style, w, h, fs)
			end,
		}
		hover.layout = layout.build_native_layout(raw, w, h, style, meas)
	end
	hover.layout.style = style
	hover.osd_w = w
	hover.osd_h = h
	hover.built_at = mp.get_time()
	local mouse = mp.get_property_native("mouse-pos")
	if mouse then
		hover.idx = layout.hit_test(hover.layout, mouse.x, mouse.y)
	else
		hover.idx = nil
	end
	hover.rebuilt = true
	if opts.hover_backend == "replica" then
		render.render_replica_line(hover.layout, hover.idx)
	end
	render.render_hitboxes(hover.layout)
	if opts.verbose then
		log(
			string.format(
				"hover layout built: backend=%s words=%d bbox=(%d,%d)-(%d,%d) measured=%s",
				opts.hover_backend,
				hover.layout.words and #hover.layout.words or 0,
				hover.layout.x0,
				hover.layout.y0,
				hover.layout.x1,
				hover.layout.y1,
				tostring(not hover.layout.approximate)
			)
		)
	end
	return hover.layout
end

local function region_contains_mouse(layout, mx, my)
	if not layout then
		return false
	end
	local pad = (layout.line_h or layout.lh or 24) / 2
	return mx >= layout.x0 - pad and mx <= layout.x1 + pad and my >= layout.y0 - pad and my <= layout.y1 + pad
end

local show_word_popup

local function tick_hover()
	local had_ui = hover.layout ~= nil or hover.idx ~= nil
	local lay = ensure_hover_layout()
	if not lay then
		if had_ui then
			render.clear_popup()
			render.remove_line()
			render.remove_debug()
			hover.idx = nil
		end
		return
	end
	if hover.rebuilt then
		hover.rebuilt = false
		if opts.hover_backend == "mirror" then
			render.render_mirror_line(lay, hover.idx)
		elseif opts.hover_backend == "replica" then
			render.render_replica_line(lay, hover.idx)
		end
	end
	local mouse = mp.get_property_native("mouse-pos")
	if not mouse then
		return
	end
	local idx = layout.hit_test(lay, mouse.x, mouse.y)
	if opts.verbose and (not hover.last_diag or mp.get_time() - hover.last_diag > 0.4) then
		hover.last_diag = mp.get_time()
		log(
			string.format(
				"hover: mouse=(%d,%d) word=%s",
				mouse.x,
				mouse.y,
				idx and ("'" .. lay.words[idx].text .. "'") or "none"
			)
		)
	end
	if idx == hover.idx then
		return
	end
	hover.idx = idx
	if idx then
		if opts.hover_backend == "mirror" then
			render.render_mirror_line(lay, idx)
		elseif opts.hover_backend == "replica" then
			render.render_replica_line(lay, idx)
		end
		local word = layout.clean_word(lay.words[idx].text)
		if word then
			show_word_popup(word, mouse.x, mouse.y)
		else
			render.clear_popup()
		end
	else
		render.clear_popup()
		if opts.hover_backend == "mirror" then
			render.render_mirror_line(lay, nil)
		elseif opts.hover_backend == "replica" then
			render.render_replica_line(lay, nil)
		end
	end
end

show_word_popup = function(word, mx, my)
	local wd = hover.layout and hover.layout.words and hover.layout.words[hover.idx]
	local rect = nil
	if wd and wd.x and wd.w and wd.h and opts.hover_backend ~= "native" then
		rect = { x = wd.x, y = wd.y, w = wd.w, h = wd.h }
	end
	hover.seq = hover.seq + 1
	local seq = hover.seq
	render.clear_popup()

	providers.lookup_word(word, function(source, res, err)
		if seq ~= hover.seq or hover.idx == nil or not source then
			return
		end
		local lines
		if res then
			lines = render.build_popup_lines(res)
		else
			lines = { { text = "(" .. tostring(err) .. ")", kind = "dim" } }
		end
		render.popup_set(lines, word, rect, mx, my)
	end)
end

local function word_click()
	if state ~= "dict" or not hover.idx or not hover.layout or not hover.layout.words then
		return
	end
	local wd = hover.layout.words[hover.idx]
	if not wd or not wd.text then
		return
	end
	local word = layout.clean_word(wd.text)
	if not word then
		return
	end
	local url = opts.dict_url_template:gsub("{word}", util.url_encode(word))
	mp.command_native_async({
		name = "subprocess",
		args = { "xdg-open", url },
		playback_only = false,
	}, function() end)
	if opts.verbose then
		log("opened dictionary: " .. url)
	end
end

local function dict_bindings_activate()
	mp.add_key_binding("WHEEL_UP", "st_wheel_up", function()
		render.popup_scroll(-1)
	end)
	mp.add_key_binding("WHEEL_DOWN", "st_wheel_down", function()
		render.popup_scroll(1)
	end)
	mp.add_key_binding("MBTN_LEFT", "st_word_click", word_click)
end

local function dict_bindings_deactivate()
	pcall(function()
		mp.remove_key_binding("st_wheel_up")
	end)
	pcall(function()
		mp.remove_key_binding("st_wheel_down")
	end)
	pcall(function()
		mp.remove_key_binding("st_word_click")
	end)
end

local function panel_should_show(text)
	if state == "always" then
		return true
	end
	if state ~= "ondemand" then
		return false
	end
	if line_ui.pinned_line ~= nil and line_ui.pinned_line == text then
		return true
	end
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return false
	end
	local mouse = mp.get_property_native("mouse-pos")
	if not mouse then
		return false
	end
	local rect = render.get_panel_rect()
	local pad = line_ui.shown and 30 or 12
	if rect then
		return mouse.x >= rect.x - pad
			and mouse.x <= rect.x + rect.w + pad
			and mouse.y >= rect.y - pad
			and mouse.y <= rect.y + rect.h + pad
	end
	local band_h = math.floor(h * 0.15)
	return mouse.x >= w * 0.15
		and mouse.x <= w * 0.85
		and mouse.y >= opts.margin_y - 10
		and mouse.y <= opts.margin_y + band_h
end

local function render_panel()
	local text = line_ui.text
	local show = text ~= nil and panel_should_show(text) and (line_ui.translated ~= nil or line_ui.error ~= nil)
	local key = show and (text .. "|" .. tostring(line_ui.translated) .. "|" .. tostring(line_ui.error)) or nil
	if not show then
		if line_ui.shown then
			render.hide_line_translation()
			if opts.verbose then
				log("panel hidden")
			end
		end
		line_ui.shown = false
		line_ui.rendered_key = nil
		return
	end
	if line_ui.shown and line_ui.rendered_key == key then
		return
	end
	line_ui.rendered_key = key
	line_ui.shown = true
	if opts.verbose then
		log("panel shown")
	end
	render.show_line_translation(line_ui.translated, line_ui.error)
end

local function apply_line_result(res, err)
	if err then
		line_ui.error = err
		return
	end
	local translated = nil
	if type(res) == "string" then
		translated = res
	elseif type(res) == "table" and res.main then
		translated = res.main
	end
	if translated and util.normalize_sub(translated) == line_ui.text then
		cache.purge("sentence", line_ui.text)
		line_ui.translated = nil
		return
	end
	line_ui.translated = translated
end

local function update_line_translation()
	local raw = current_sub()
	if not raw then
		line_ui.text = nil
		render_panel()
		return
	end
	local display = util.trim(raw)
	local text = util.normalize_sub(raw)
	if line_ui.text == text and (line_ui.pending or line_ui.translated ~= nil or line_ui.error ~= nil) then
		return
	end
	line_ui.text = text
	line_ui.display = display
	line_ui.translated = nil
	line_ui.error = nil
	line_ui.pending = true
	line_ui.seq = line_ui.seq + 1
	local seq = line_ui.seq
	providers.lookup("sentence", text, function(res, err)
		if seq ~= line_ui.seq or line_ui.text ~= text then
			return
		end
		line_ui.pending = false
		apply_line_result(res, err)
		render_panel()
	end)
	render_panel()
end

local function tick_ondemand()
	render_panel()
end

local function on_sub_change_inner(_name, text)
	if opts.verbose then
		log("sub-text changed: " .. (text and util.trim(text):sub(1, 40) or "nil"))
	end
	hover.sub = nil
	hover.layout = nil
	hover.idx = nil
	render.clear_popup()
	if state == "always" or state == "ondemand" then
		line_ui.pinned_line = nil
		update_line_translation()
	elseif state == "dict" then
		if not text or text == "" then
			render.remove_line()
		elseif opts.hover_backend == "replica" or opts.hover_backend == "mirror" then
			local lay = ensure_hover_layout()
			if lay then
				if opts.hover_backend == "replica" then
					render.render_replica_line(lay, nil)
				else
					render.render_mirror_line(lay, nil)
				end
			end
		end
	end
end

local function on_tick()
	if state == "dict" then
		tick_hover()
	elseif state == "ondemand" then
		tick_ondemand()
	end
end

local function apply_state(new_state, quiet)
	state = new_state
	providers.cancel_requests()
	line_ui.seq = line_ui.seq + 1
	line_ui.text = nil
	line_ui.translated = nil
	line_ui.error = nil
	line_ui.pending = false
	line_ui.pinned_line = nil
	line_ui.shown = false
	line_ui.rendered_key = nil
	hover.sub = nil
	hover.layout = nil
	hover.idx = nil
	hover.seq = hover.seq + 1
	render.remove_line()
	render.clear_popup()
	render.remove_debug()
	if state == "dict" and opts.hover_backend == "replica" then
		replica_activate()
	else
		replica_deactivate()
	end
	if state == "dict" then
		dict_bindings_activate()
	else
		dict_bindings_deactivate()
	end
	if state == "always" or state == "ondemand" then
		update_line_translation()
	end
	if not quiet then
		notify(MODE_LABEL[state])
	end
end

local function cycle_mode()
	mode_index = mode_index % #MODES + 1
	apply_state(MODES[mode_index])
end

local function set_mode_from_name(name, quiet)
	for i, m in ipairs(MODES) do
		if m == name then
			mode_index = i
			apply_state(m, quiet)
			return true
		end
	end
	return false
end

local function manual_show()
	local raw = current_sub()
	if not raw then
		notify("no subtitle is currently displayed")
		return
	end
	if state == "ondemand" then
		line_ui.pinned_line = util.normalize_sub(raw)
		update_line_translation()
		render_panel()
	end
end

local function on_sub_change(_name, text)
	local ok, err = pcall(function()
		on_sub_change_inner(_name, text)
	end)
	if not ok then
		log("sub-change error: " .. tostring(err))
	end
end

mp.register_script_message("cycle-mode", cycle_mode)
mp.register_script_message("set-mode", function(name)
	set_mode_from_name(name)
end)
mp.register_script_message("show-translation", manual_show)

mp.add_key_binding(opts.key_cycle_mode, "cycle_mode", cycle_mode)
mp.add_key_binding(opts.key_show_translation, "show_translation", manual_show)

if not set_mode_from_name(opts.mode_on_start, true) then
	state = "off"
	mode_index = 1
end

mp.observe_property("sub-text", "string", on_sub_change)
mp.observe_property("sid", "number", function()
	timeline.schedule_reload(0.4)
end)
for _, prop in ipairs({ "sub-pos", "sub-margin-x", "sub-margin-y", "sub-align-x", "sub-align-y", "sub-use-margins" }) do
	mp.observe_property(prop, "native", function()
		if state == "dict" then
			hover.sub = nil
			hover.layout = nil
			hover.idx = nil
			local raw = current_sub()
			if raw and (opts.hover_backend == "replica" or opts.hover_backend == "mirror") then
				local lay = ensure_hover_layout()
				if lay then
					if opts.hover_backend == "replica" then
						render.render_replica_line(lay, nil)
					else
						render.render_mirror_line(lay, nil)
					end
				end
			end
		end
	end)
end
mp.register_event("file-loaded", function()
	timeline.on_file_loaded()
end)
mp.add_periodic_timer(0.05, on_tick)
mp.add_periodic_timer(15, function()
	mp.add_key_binding(opts.key_cycle_mode, "cycle_mode", cycle_mode)
	mp.add_key_binding(opts.key_show_translation, "show_translation", manual_show)
end)
mp.register_event("shutdown", function()
	providers.cancel_requests()
	timeline.reset()
	dict_bindings_deactivate()
	replica_deactivate()
	render.remove_all()
	render.clear_popup()
end)

local VERSION = "0.9.2"

log("subtitle-translate v" .. VERSION)
log(
	"loaded (mode: "
		.. state
		.. ", provider: "
		.. opts.provider
		.. ", "
		.. opts.lang_from
		.. "->"
		.. opts.lang_to
		.. ", keys: cycle="
		.. opts.key_cycle_mode
		.. " show="
		.. opts.key_show_translation
		.. ")"
)

return {
	opts = opts,
	panel_should_show = panel_should_show,
	apply_line_result = apply_line_result,
	set_mode_from_name = set_mode_from_name,
}
