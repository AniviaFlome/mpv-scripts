package.path = debug.getinfo(1, "S").source:match("^@?(.*/)") .. "?.lua;" .. package.path

local mp = require("mp")
local options = require("mp.options")
local util = require("util")
local cache = require("cache")
local providers = require("providers")
local layout = require("layout")
local render = require("render")
local timeline = require("timeline")
local menu = require("menu")
local search = require("search")
local translate = require("translate")
local ocr = require("ocr")

local opts = {
	-- keys, all rebindable, empty unbinds
	key_cycle_mode = "Alt+t",
	key_show_translation = "Ctrl+y",
	key_settings_menu = "Alt+m",
	key_dict_box = "Alt+k",
	key_translate_box = "Alt+K",
	key_search_word = "", -- deprecated alias of key_dict_box
	key_ocr = "Alt+y",

	-- translation
	mode_on_start = "off", -- off / dict / ondemand / always
	provider = "mymemory", -- mymemory / google / duckduckgo / lingva / libretranslate / deepl
	word_provider = "cambridge", -- tureng / cambridge / wiktionary / reverso
	lang_from = "en",
	lang_to = "tr",

	-- panel
	position = "top-center",
	margin_y = 24,
	font = "sans-serif",
	color_text = "#ffffff",
	color_outline = "#101010",
	outline_width = 1,
	color_bg = "#101010",
	bg_opacity = 55,
	max_width_percent = 80,
	panel_font_scale = 0.85,

	-- hover dictionary, mode 1
	hover_backend = "replica", -- replica / native / mirror
	replica_font_size = 38,
	replica_outline = 3,
	accent = "#ff5555",
	dict_url_template = "https://tureng.com/en/turkish-english/{word}",
	mirror_font = "monospace",
	mirror_font_size = 30,
	mirror_margin_y = 56,
	color_mirror = "#ffffff",

	-- dictionary popup
	dict_max_groups = 4,
	dict_max_terms = 6,
	dict_max_lines = 6,
	popup_offset = 18,
	popup_font_size = 32,
	popup_padding_x = 0.35,
	popup_padding_y = 0.12,

	-- prefetch + cache
	prefetch = true,
	prefetch_all = false,
	prefetch_concurrency = 2,
	prefetch_ahead = 20,
	disk_cache = true,
	cache_dir = "",
	cache_max_entries = 5000,

	-- debugging
	verbose = false,
	show_hitboxes = false,

	-- OCR hardsubs: one-shot capture -> recognize -> translate -> panel
	ocr_enabled = true,
	ocr_backend = "tesseract", -- tesseract / custom / rapidocr / easyocr / paddleocr
	-- capture and filtering, all backends
	ocr_ffmpeg_bin = "ffmpeg",
	ocr_crop_h = 0.25,
	ocr_scale = 2,
	ocr_sharpen = true,
	ocr_lang = "",
	ocr_min_chars = 2,
	ocr_max_chars = 200,
	ocr_min_alpha_ratio = 0.5,
	ocr_display_seconds = 5,
	-- tesseract only
	ocr_tesseract_bin = "tesseract",
	ocr_psm = 6,
	ocr_oem = 1,
	ocr_tessconfig = "",
	ocr_blacklist = "|\\@#¥§©®™°^~\\",
	-- python backends: rapidocr, easyocr, paddleocr
	ocr_cuda = false,
	-- custom backend
	ocr_command = "",

	-- provider credentials
	deepl_api_key = "",
	-- deprecated, ignored: host is auto-detected from key suffix
	deepl_free = true,
	libretranslate_url = "https://libretranslate.com",
	libretranslate_api_key = "",
	lingva_instance = "https://lingva.ml",
	mymemory_email = "",
	yandex_api_key = "",
	yandex_folder_id = "",

	-- baidu ocr credentials: cloud account and app keys
	baiduocr_api_key = "",
	baiduocr_secret_key = "",

	-- secret files: each holds just that value (e.g. a sops-nix secret).
	-- when set and readable, the file wins over the inline option above.
	deepl_api_path = "",
	libretranslate_api_path = "",
	mymemory_email_path = "",
	yandex_api_path = "",
	yandex_folder_id_path = "",
	baiduocr_api_path = "",
	baiduocr_secret_path = "",
}

options.read_options(opts, "subtitle-translate")

-- sensitive keys only: secret files override the inline value
local SECRET_PATHS = {
	deepl_api_key = "deepl_api_path",
	libretranslate_api_key = "libretranslate_api_path",
	mymemory_email = "mymemory_email_path",
	yandex_api_key = "yandex_api_path",
	yandex_folder_id = "yandex_folder_id_path",
	baiduocr_api_key = "baiduocr_api_path",
	baiduocr_secret_key = "baiduocr_secret_path",
}

for key, path_opt in pairs(SECRET_PATHS) do
	local path = util.trim(opts[path_opt] or "")
	if path ~= "" then
		local value, err = util.read_secret_file(path)
		if value then
			opts[key] = value
			if opts.verbose then
				util.log(key .. " loaded from file (" .. value:len() .. " chars): " .. path)
			end
		else
			util.log("warning: " .. path_opt .. " unreadable (" .. tostring(err) .. "): " .. path)
		end
	end
end

-- deprecated alias: key_search_word -> key_dict_box
if opts.key_search_word ~= "" and opts.key_dict_box == "Alt+k" then
	opts.key_dict_box = opts.key_search_word
end

cache.init(opts)
providers.init(opts)
layout.init(opts)
render.init(opts)
timeline.init(opts)
ocr.init(opts)

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

local hover_mute_until = 0
local HOVER_MUTE_SECS = 1.2

-- close-stickiness: manual close mutes hover popups briefly
local function mute_hover()
	hover_mute_until = mp.get_time() + HOVER_MUTE_SECS
end

local saved_sub_props = nil

-- generic backend error text
local BACKEND_ERROR = "translation backend not working"

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

local search_history = {}
local SEARCH_HISTORY_MAX = 50

local function record_search(word)
	if not word or word == "" then
		return
	end
	for i, w in ipairs(search_history) do
		if w == word then
			table.remove(search_history, i)
			break
		end
	end
	table.insert(search_history, 1, word)
	while #search_history > SEARCH_HISTORY_MAX do
		search_history[#search_history] = nil
	end
end

-- keep ASS codes as word separators
local function sub_tokens()
	local raw = current_sub()
	if not raw then
		return {}
	end
	raw = raw:gsub("%b{}", " ")
	raw = raw:gsub("\\[Nnh]", " ")
	raw = util.strip_tags(raw)
	local out = {}
	for token in raw:gmatch("%S+") do
		local w = layout.clean_word(token)
		if w then
			out[#out + 1] = w
		end
	end
	return out
end

local function subtitle_words()
	local out, seen = {}, {}
	for _, w in ipairs(sub_tokens()) do
		if not seen[w] then
			seen[w] = true
			out[#out + 1] = w
		end
	end
	return out
end

local function subtitle_phrases()
	local tokens = sub_tokens()
	local out, seen = {}, {}
	for i = 1, #tokens - 1 do
		local phrase = tokens[i] .. " " .. tokens[i + 1]
		if not seen[phrase] then
			seen[phrase] = true
			out[#out + 1] = phrase
		end
	end
	return out
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
	-- strip ASS codes to avoid fake words
	local plain = util.clean_subtitle_text(raw)
	if opts.hover_backend == "mirror" then
		hover.layout = layout.build_mirror_layout(plain, w, h)
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
		hover.layout = layout.build_native_layout(plain, w, h, style, meas)
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
		hover.layout = layout.build_native_layout(plain, w, h, style, meas)
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
local present_lookup
local trbox = nil
local open_search_menu
local open_search_box
local open_translate_box

local function tick_hover()
	if trbox then
		return
	end
	if mp.get_time() < hover_mute_until then
		return
	end
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
		if search.is_pinned() then
			return
		end
		local word = layout.clean_word(lay.words[idx].text)
		if word then
			show_word_popup(word, mouse.x, mouse.y)
		else
			render.clear_popup()
		end
	else
		if not search.is_pinned() then
			render.clear_popup()
		end
		if opts.hover_backend == "mirror" then
			render.render_mirror_line(lay, nil)
		elseif opts.hover_backend == "replica" then
			render.render_replica_line(lay, nil)
		end
	end
end

show_word_popup = function(word, mx, my)
	if mp.get_time() < hover_mute_until then
		return
	end
	local wd = hover.layout and hover.layout.words and hover.layout.words[hover.idx]
	local rect = nil
	if wd and wd.x and wd.w and wd.h and opts.hover_backend ~= "native" then
		rect = { x = wd.x, y = wd.y, w = wd.w, h = wd.h }
	end
	hover.seq = hover.seq + 1
	local seq = hover.seq
	render.clear_popup()
	record_search(word)

	providers.lookup_word(word, function(source, res, err)
		if seq ~= hover.seq or hover.idx == nil or not source then
			return
		end
		present_lookup(source, res, err, word, rect, mx, my)
	end)
end

present_lookup = function(source, res, err, word, rect, mx, my, fixed)
	local lines
	if res then
		lines = render.build_popup_lines(res)
	else
		if opts.verbose then
			log("lookup failed: " .. tostring(err))
		end
		lines = { { text = "(" .. BACKEND_ERROR .. ")", kind = "dim" } }
	end
	local dictionary_name = source:sub(1, 1):upper() .. source:sub(2)
	local header = dictionary_name .. " — " .. word
	if fixed then
		render.popup_set_fixed(lines, header)
	else
		render.popup_set(lines, header, rect, mx, my)
	end
end

local search_seq = 0

local function lookup_searched_word(text)
	local word = layout.clean_word(text)
	if not word then
		notify("nothing to look up")
		return
	end
	search_seq = search_seq + 1
	local seq = search_seq
	record_search(word)
	providers.lookup_word(word, function(source, res, err)
		if seq ~= search_seq or not source then
			return
		end
		present_lookup(source, res, err, word, nil, 0, 0, true)
	end)
end

local trbox_seq = 0
local preview_seq = 0
local translate_history = {}
local TRANSLATE_HISTORY_MAX = 50

local function clear_trbox_ui()
	trbox = nil
	trbox_seq = trbox_seq + 1
	preview_seq = preview_seq + 1
	render.hide_line_translation()
	hover.sub = nil
	hover.layout = nil
	hover.idx = nil
end

local function record_translate(text)
	if not text or text == "" then
		return
	end
	for i, w in ipairs(translate_history) do
		if w == text then
			table.remove(translate_history, i)
			break
		end
	end
	table.insert(translate_history, 1, text)
	while #translate_history > TRANSLATE_HISTORY_MAX do
		translate_history[#translate_history] = nil
	end
end

local function paused_error()
	return "translation paused (quota:" .. opts.provider .. ") — retry in ~" .. timeline.quota_eta_min() .. " min"
end

local function lookup_sentence_box(text)
	text = util.trim(text or ""):gsub("%s+", " ")
	if text == "" then
		notify("nothing to translate")
		return
	end
	if timeline.quota_active() then
		trbox = { input = text, translated = nil, error = paused_error() }
		render.show_line_translation(nil, trbox.error)
		return
	end
	trbox_seq = trbox_seq + 1
	local seq = trbox_seq
	record_translate(text)
	providers.lookup("sentence", text, function(res, err)
		if seq ~= trbox_seq or not translate.is_pinned() then
			return
		end
		if err then
			timeline.report_quota(err)
		end
		hover.seq = hover.seq + 1
		render.clear_popup()
		if err then
			if opts.verbose then
				log("lookup failed: " .. tostring(err))
			end
			err = BACKEND_ERROR
		end
		local translated = type(res) == "string" and res or (type(res) == "table" and res.main)
		trbox = { input = text, translated = translated, error = err }
		render.show_line_translation(translated, err)
	end)
end

-- provisional preview, not pinned
local function preview_sentence(text)
	text = util.trim(text or ""):gsub("%s+", " ")
	if text == "" or timeline.quota_active() then
		return
	end
	preview_seq = preview_seq + 1
	local seq = preview_seq
	providers.lookup("sentence", text, function(res, err)
		if seq ~= preview_seq or translate.is_pinned() then
			return
		end
		if err then
			if opts.verbose then
				log("preview failed: " .. tostring(err))
			end
			return
		end
		local translated = type(res) == "string" and res or (type(res) == "table" and res.main)
		if not translated then
			return
		end
		hover.seq = hover.seq + 1
		render.clear_popup()
		trbox = { input = text, translated = translated, error = nil, provisional = true }
		render.show_line_translation(translated, nil)
	end)
end

-- clear provisional, keep pinned
local function clear_provisional()
	preview_seq = preview_seq + 1
	if trbox and not translate.is_pinned() then
		clear_trbox_ui()
	end
end

-- pinned popups dismiss on any key / click; mpv lacks single any-key hook
-- any_unicode covers all text keys in one bind; small tables cover special keys + mouse
local dismiss_armed = false
local dismiss_names = {}
local DISMISS_KEYS = {
	"ESC",
	"ENTER",
	"KP_ENTER",
	"BS",
	"DEL",
	"SPACE",
	"TAB",
	"UP",
	"DOWN",
	"LEFT",
	"RIGHT",
	"PGUP",
	"PGDWN",
	"HOME",
	"END",
}
local DISMISS_MOUSE = { "MBTN_LEFT", "MBTN_MID", "MBTN_RIGHT" }

local function dismiss_deactivate()
	if not dismiss_armed then
		return
	end
	dismiss_armed = false
	for _, name in ipairs(dismiss_names) do
		pcall(function()
			mp.remove_key_binding(name)
		end)
	end
	dismiss_names = {}
end

local function dismiss_popup()
	render.clear_popup()
	if trbox then
		clear_trbox_ui()
	end
	search.disarm()
	translate.disarm()
	dismiss_deactivate()
end

local function sync_dismiss()
	local want = search.is_pinned() or translate.is_pinned()
	if want and not dismiss_armed then
		dismiss_armed = true
		dismiss_names = {}
		for _, key in ipairs(DISMISS_KEYS) do
			local name = "st_dismiss_" .. key
			dismiss_names[#dismiss_names + 1] = name
			pcall(function()
				mp.add_forced_key_binding(key, name, dismiss_popup)
			end)
		end
		dismiss_names[#dismiss_names + 1] = "st_dismiss_unicode"
		mp.add_forced_key_binding("any_unicode", "st_dismiss_unicode", function(ev)
			if ev and (ev.event == "press" or ev.event == "down" or ev.event == "repeat") then
				dismiss_popup()
			end
		end, { complex = true })
		for _, key in ipairs(DISMISS_MOUSE) do
			-- dict LEFT handled inside word_click via early dismiss
			if key ~= "MBTN_LEFT" or state ~= "dict" then
				local name = "st_dismiss_" .. key
				dismiss_names[#dismiss_names + 1] = name
				pcall(function()
					mp.add_forced_key_binding(key, name, dismiss_popup)
				end)
			end
		end
	elseif not want and dismiss_armed then
		dismiss_deactivate()
	end
end

local function word_click()
	if search.is_pinned() or translate.is_pinned() then
		dismiss_popup()
		return
	end
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
		mp.remove_key_binding("st_word_click")
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
	if trbox then
		return
	end
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
		if opts.verbose then
			log("lookup failed: " .. tostring(err))
		end
		line_ui.error = BACKEND_ERROR
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
	-- strip ASS codes for translator/cache
	local text = util.normalize_sub(util.clean_subtitle_text(raw))
	if line_ui.text == text and (line_ui.pending or line_ui.translated ~= nil or line_ui.error ~= nil) then
		-- same line: skip fetch, recheck visibility
		render_panel()
		return
	end
	line_ui.text = text
	line_ui.display = display
	line_ui.ocr = false
	line_ui.translated = nil
	line_ui.error = nil
	if timeline.quota_active() then
		line_ui.pending = false
		line_ui.error = paused_error()
		render_panel()
		return
	end
	line_ui.pending = true
	line_ui.seq = line_ui.seq + 1
	local seq = line_ui.seq
	providers.lookup("sentence", text, function(res, err)
		if seq ~= line_ui.seq or line_ui.text ~= text then
			return
		end
		line_ui.pending = false
		if err then
			timeline.report_quota(err)
		end
		apply_line_result(res, err)
		render_panel()
	end)
	render_panel()
end

local function tick_ondemand()
	render_panel()
end

-- OCR glue: OCR text feeds the sentence pipeline.
-- One-shot only, no auto-poll: engines are slower than realtime.

-- explicit keypress force-shows the panel even in mode off and dict
local function render_ocr_panel()
	if line_ui.translated ~= nil or line_ui.error ~= nil then
		line_ui.shown = true
		render.show_line_translation(line_ui.translated, line_ui.error)
		return
	end
	render_panel()
end

local ocr_hide_timer = nil

local function clear_ocr_panel()
	line_ui.seq = line_ui.seq + 1
	line_ui.text = nil
	line_ui.display = nil
	line_ui.translated = nil
	line_ui.error = nil
	line_ui.pending = false
	line_ui.ocr = false
	line_ui.shown = false
	line_ui.rendered_key = nil
	line_ui.pinned_line = nil
	render.hide_line_translation()
end

-- OCR results never expire on their own: hide after ocr_display_seconds
-- unless replaced. 0 disables.
local function schedule_ocr_hide(text)
	if ocr_hide_timer then
		ocr_hide_timer:kill()
		ocr_hide_timer = nil
	end
	local secs = tonumber(opts.ocr_display_seconds) or 0
	if secs <= 0 or text == "" then
		return
	end
	ocr_hide_timer = mp.add_timeout(secs, function()
		ocr_hide_timer = nil
		if not line_ui.ocr or line_ui.text ~= text then
			return
		end
		clear_ocr_panel()
		if opts.verbose then
			log("ocr: panel auto-hidden after " .. secs .. "s")
		end
	end)
end

local function translate_ocr_text(text, backend)
	text = util.normalize_sub(util.clean_subtitle_text(text or ""))
	if text == "" then
		return
	end
	if line_ui.text == text and (line_ui.pending or line_ui.translated ~= nil or line_ui.error ~= nil) then
		render_ocr_panel()
		schedule_ocr_hide(text)
		return
	end
	line_ui.text = text
	line_ui.display = "[OCR] " .. text
	line_ui.ocr = true
	line_ui.translated = nil
	line_ui.error = nil
	if timeline.quota_active() then
		line_ui.pending = false
		line_ui.error = paused_error()
		render_ocr_panel()
		schedule_ocr_hide(text)
		return
	end
	line_ui.pending = true
	line_ui.seq = line_ui.seq + 1
	local seq = line_ui.seq
	if opts.verbose then
		log("ocr: translating (" .. tostring(backend or opts.ocr_backend) .. "): " .. text:sub(1, 80))
	end
	providers.lookup("sentence", text, function(res, err)
		if seq ~= line_ui.seq or line_ui.text ~= text then
			return
		end
		line_ui.pending = false
		if err then
			timeline.report_quota(err)
		end
		apply_line_result(res, err)
		render_ocr_panel()
		schedule_ocr_hide(text)
	end)
	render_ocr_panel()
end

local function ocr_now()
	if not opts.ocr_enabled then
		notify("OCR disabled (ocr_enabled=no)")
		return
	end
	-- hide instead of re-running when a result shows
	if line_ui.ocr and not line_ui.pending and (line_ui.translated ~= nil or line_ui.error ~= nil) then
		if ocr_hide_timer then
			ocr_hide_timer:kill()
			ocr_hide_timer = nil
		end
		clear_ocr_panel()
		notify("OCR hidden")
		return
	end
	if timeline.quota_active() then
		notify(paused_error())
		return
	end
	notify("OCR (" .. tostring(opts.ocr_backend) .. ")…")
	ocr.recognize_now(function(text, info, err)
		if err then
			if err == "ocr busy" then
				notify("OCR still running")
			else
				notify("OCR failed: " .. tostring(err))
			end
			return
		end
		if not text or text == "" then
			notify("OCR: no text found")
			return
		end
		if state == "ondemand" then
			line_ui.pinned_line = util.normalize_sub(util.clean_subtitle_text(text))
		end
		translate_ocr_text(text, info and info.backend)
	end)
end

local function ocr_check()
	local names = ocr.list_backends()
	local parts = {}
	for _, name in ipairs(names) do
		local b = ocr.get_backend(name)
		local ok = true
		if b and type(b.check) == "function" then
			ok = b.check()
		end
		parts[#parts + 1] = name .. (ok and "" or " (missing)")
	end
	notify("OCR backends: " .. table.concat(parts, ", ") .. " | active: " .. tostring(opts.ocr_backend))
end

local function on_sub_change_inner(_name, text)
	if opts.verbose then
		log("sub-text changed: " .. (text and util.trim(text):sub(1, 40) or "nil"))
	end
	hover.sub = nil
	hover.layout = nil
	hover.idx = nil
	if not search.is_pinned() then
		render.clear_popup()
	end
	if state == "always" or state == "ondemand" then
		line_ui.pinned_line = nil
		update_line_translation()
	elseif state == "dict" and not trbox then
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
	ocr.cancel()
	if ocr_hide_timer then
		ocr_hide_timer:kill()
		ocr_hide_timer = nil
	end
	line_ui.seq = line_ui.seq + 1
	line_ui.text = nil
	line_ui.translated = nil
	line_ui.error = nil
	line_ui.pending = false
	line_ui.ocr = false
	line_ui.pinned_line = nil
	line_ui.shown = false
	line_ui.rendered_key = nil
	hover.sub = nil
	hover.layout = nil
	hover.idx = nil
	hover.seq = hover.seq + 1
	search.disarm()
	translate.disarm()
	trbox = nil
	dismiss_deactivate()
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
		line_ui.pinned_line = util.normalize_sub(util.clean_subtitle_text(raw))
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
mp.register_script_message("ocr-now", ocr_now)
mp.register_script_message("ocr-check", ocr_check)

-- forced: stale twin (HM-bundled copy) binds same keys normally; forced wins
-- so worktree owns keys; empty opt still unbinds
local function bind_action(key, name, fn)
	if not key or key == "" then
		return
	end
	pcall(function()
		-- complex + repeat/up dropped: held hotkey never strobes toggle
		mp.add_forced_key_binding(key, name, function(ev)
			if ev and (ev.event == "repeat" or ev.event == "up") then
				return
			end
			fn()
		end, { complex = true })
	end)
end

bind_action(opts.key_cycle_mode, "cycle_mode", cycle_mode)
bind_action(opts.key_show_translation, "show_translation", manual_show)
bind_action(opts.key_ocr, "ocr_now", ocr_now)

menu.init(opts, {
	notify = notify,
	retranslate = function()
		providers.cancel_requests()
		line_ui.seq = line_ui.seq + 1
		line_ui.text = nil
		line_ui.translated = nil
		line_ui.error = nil
		line_ui.pending = false
		if state == "always" or state == "ondemand" then
			update_line_translation()
		end
	end,
	refresh_panel = function()
		render_panel()
	end,
	rebuild_hover = function()
		hover.sub = nil
		hover.layout = nil
		hover.idx = nil
		hover.seq = hover.seq + 1
		search.disarm()
		translate.disarm()
		dismiss_deactivate()
		render.clear_popup()
		if state == "dict" and opts.hover_backend == "replica" then
			replica_activate()
		else
			replica_deactivate()
		end
	end,
})

search.init(opts, {
	notify = notify,
	lookup = function(word)
		translate.disarm()
		if trbox then
			clear_trbox_ui()
		end
		lookup_searched_word(word)
	end,
	suggest = function(prefix, cb)
		providers.suggest(prefix, cb)
	end,
	close_popup = render.clear_popup,
	pin_changed = sync_dismiss,
	hover_mute = mute_hover,
	subtitle_words = subtitle_words,
	subtitle_phrases = subtitle_phrases,
	history_words = function()
		return search_history
	end,
})

translate.init(opts, {
	notify = notify,
	lookup = function(text)
		search.disarm()
		render.clear_popup()
		lookup_sentence_box(text)
	end,
	preview = preview_sentence,
	clear_result = clear_provisional,
	close_popup = function()
		if trbox then
			clear_trbox_ui()
		end
	end,
	pin_changed = sync_dismiss,
	translate_history = function()
		return translate_history
	end,
})

-- sloppy Alt-chords can flash bare key through mpv (e.g. d toggles
-- deinterlace) just before box opens; snapshot + restore neutralizes it
local function guard_deinterlace(still_open)
	local ok_before, before = pcall(mp.get_property, "deinterlace")
	if not ok_before then
		return
	end
	local function restore_if_flipped()
		if not still_open() then
			return
		end
		local ok_now, now = pcall(mp.get_property, "deinterlace")
		if ok_now and now ~= before then
			pcall(mp.set_property, "deinterlace", before)
		end
	end
	mp.add_timeout(0.12, restore_if_flipped)
	mp.add_timeout(0.6, restore_if_flipped)
end

-- tail of chord feeds echo guard (Alt+k -> k); non-text binds yield nil
local function base_key(binding)
	if type(binding) ~= "string" then
		return nil
	end
	local tail = util.trim(binding:match("[^+]+$") or "")
	if #tail == 1 then
		return tail
	end
	return nil
end

open_search_menu = function()
	search.close()
	menu.open()
end

open_search_box = function()
	menu.close()
	translate.close()
	render.clear_popup()
	search.open(base_key(opts.key_dict_box))
	guard_deinterlace(function()
		return search.is_open()
	end)
end

open_translate_box = function()
	menu.close()
	search.close()
	if trbox then
		clear_trbox_ui()
	end
	translate.open(base_key(opts.key_translate_box))
	guard_deinterlace(function()
		return translate.is_open()
	end)
end

bind_action(opts.key_settings_menu, "open_settings", open_search_menu)
bind_action(opts.key_dict_box, "open_search", open_search_box)
bind_action(opts.key_translate_box, "open_translate", open_translate_box)
mp.register_script_message("open-settings", open_search_menu)
mp.register_script_message("open-search", open_search_box)
mp.register_script_message("open-translate", open_translate_box)

if not set_mode_from_name(opts.mode_on_start, true) then
	state = "off"
	mode_index = 1
end

mp.observe_property("sub-text", "string", on_sub_change)
mp.observe_property("sid", "number", function()
	ocr.reset()
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
	ocr.reset()
	timeline.on_file_loaded()
end)
mp.add_periodic_timer(0.05, on_tick)
mp.register_event("shutdown", function()
	providers.cancel_requests()
	ocr.cancel()
	if ocr_hide_timer then
		ocr_hide_timer:kill()
		ocr_hide_timer = nil
	end
	cache.save_now()
	timeline.reset()
	dict_bindings_deactivate()
	replica_deactivate()
	render.remove_all()
	render.clear_popup()
end)

local VERSION = "0.15.2"

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
		.. " settings="
		.. opts.key_settings_menu
		.. " dict="
		.. opts.key_dict_box
		.. " translate="
		.. opts.key_translate_box
		.. " ocr="
		.. opts.key_ocr
		.. " ocr_backend="
		.. opts.ocr_backend
		.. ")"
)

return {
	opts = opts,
	panel_should_show = panel_should_show,
	apply_line_result = apply_line_result,
	set_mode_from_name = set_mode_from_name,
}
