-- free-text translation box
local mp = require("mp")
local util = require("util")

local M = {}

local opts = nil
local actions = {}
local overlay = nil

local PREVIEW_DEBOUNCE = 0.4
local MAX_ITEMS = 12

local pinned = false
local is_open = false
local query = ""
local selected = 1
local preview_timer = nil
local last_layout = nil

local PREVIEW_DEBOUNCE = 0.4

local close_ui

local function pin_changed()
	if actions.pin_changed then
		actions.pin_changed()
	end
end

local function notify(text, duration)
	if actions.notify then
		actions.notify(text, duration)
	else
		mp.osd_message("[subtitle-translate] " .. text, duration or 2)
	end
end

local function do_lookup(text)
	close_ui()
	pinned = true
	if actions.lookup then
		actions.lookup(text)
	end
	pin_changed()
end

local function display_items()
	local seen = {}
	local out = {}
	local function add(word)
		if not word or word == "" or seen[word] then
			return
		end
		seen[word] = true
		out[#out + 1] = word
	end
	local hist = {}
	if actions.translate_history then
		hist = actions.translate_history() or {}
	end
	local q = util.trim(query or ""):lower()
	if query ~= "" then
		add(util.trim(query))
	end
	for _, w in ipairs(hist) do
		if q == "" or w:lower():sub(1, #q) == q then
			add(w)
		end
	end
	while #out > MAX_ITEMS do
		out[#out] = nil
	end
	return out
end

local function clamp_selection(items)
	if selected < 1 then
		selected = 1
	end
	if selected > #items and #items > 0 then
		selected = #items
	end
end

-- row 1 is prompt echo, hidden
local function first_visible()
	if util.trim(query or "") ~= "" then
		return 2
	end
	return 1
end

local function render()
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return
	end
	local items = display_items()
	clamp_selection(items)
	local fs = util.scaled_font(opts.popup_font_size or 32, h)
	local fx = math.floor(w / 2)
	local fy = math.floor(h * 0.30)
	local base = "{\\fn"
		.. (opts.font or "sans-serif")
		.. "\\fs"
		.. fs
		.. "\\1c"
		.. util.ass_color(opts.color_text)
		.. "\\3c"
		.. util.ass_color(opts.color_outline)
		.. "\\bord"
		.. math.max(1, math.floor(opts.outline_width * h / 1080 + 0.5))
		.. "\\shad0}"
	local hl = "{\\1c" .. util.ass_color(opts.hovered_color) .. "\\b1}"
	local norm = "{\\1c" .. util.ass_color(opts.color_text) .. "\\b0}"
	local dim = "{\\1c&H999999&\\bord0}"
	local lines = {}
	lines[#lines + 1] = "{\\b1}translate:{\\b0} " .. util.ass_escape(query) .. "_"
	local start = first_visible()
	for i = start, #items do
		local item = items[i]
		local marker = (i == selected) and "> " or "  "
		local piece = util.ass_escape(item)
		if i == selected then
			piece = hl .. piece .. norm
		end
		lines[#lines + 1] = marker .. piece
	end
	if #items == 0 then
		lines[#lines + 1] = dim .. "type text to translate — ESC to close"
	end
	local text_data = "{\\an8\\pos(" .. fx .. "," .. fy .. ")}" .. base .. table.concat(lines, "\\N")
	overlay.res_x = w
	overlay.res_y = h
	overlay.compute_bounds = true
	overlay.data = text_data
	local ok, rc = pcall(overlay.update, overlay)
	overlay.compute_bounds = false
	last_layout = nil
	if ok and rc and rc.x0 and rc.y0 and rc.x1 and rc.y1 and rc.x1 > rc.x0 and rc.y1 > rc.y0 then
		local pad = math.floor(fs * 0.3)
		local bx = math.floor(rc.x0 - pad)
		local by = math.floor(rc.y0 - pad)
		local bw = math.ceil(rc.x1 - rc.x0 + 2 * pad)
		local bh = math.ceil(rc.y1 - rc.y0 + 2 * pad)
		local nlines = #lines
		last_layout = { y0 = rc.y0, lh = (rc.y1 - rc.y0) / nlines, nlines = nlines }
		local bord = string.format("%.1f", math.max(1, math.floor(fs * 0.06)))
		local bg = string.format(
			"{\\an7\\pos(%d,%d)\\bord%s\\shad0\\3c%s\\1c%s\\alpha%s\\p1}m 0 0 l %.0f 0 %.0f %.0f 0 %.0f{\\p0}",
			bx,
			by,
			bord,
			util.ass_color("5a5a5a"),
			util.ass_color(opts.color_bg),
			util.ass_alpha(math.min(100, opts.bg_opacity + 25)),
			bw,
			bw,
			bh,
			bh
		)
		overlay.data = bg .. "\n" .. text_data
	else
		overlay.data = text_data
	end
	overlay:update()
end

local function current_item()
	local items = display_items()
	return items[selected]
end

-- preview only, Enter pins
local function schedule_preview()
	if preview_timer then
		preview_timer:kill()
		preview_timer = nil
	end
	if not actions.preview then
		return
	end
	preview_timer = mp.add_timeout(PREVIEW_DEBOUNCE, function()
		preview_timer = nil
		if not is_open then
			return
		end
		local item = current_item()
		if not item and actions.clear_result then
			actions.clear_result()
			return
		end
		if item then
			actions.preview(item)
		end
	end)
end

local function on_text(c)
	query = query .. c
	selected = 1
	render()
	schedule_preview()
end

local function on_backspace()
	if #query > 0 then
		local pos = #query
		while pos > 1 and query:byte(pos) >= 0x80 and query:byte(pos) < 0xC0 do
			pos = pos - 1
		end
		query = query:sub(1, pos - 1)
		selected = 1
		render()
		schedule_preview()
	end
end

local function on_move(dir)
	local items = display_items()
	if #items == 0 then
		return
	end
	selected = selected + dir
	if selected < 1 then
		selected = #items
	elseif selected > #items then
		selected = 1
	end
	render()
	schedule_preview()
end

local function on_enter()
	local items = display_items()
	if items[selected] then
		do_lookup(items[selected])
	end
end

local function on_click()
	local mouse = mp.get_property_native("mouse-pos")
	if not mouse or not last_layout then
		close_ui()
		return
	end
	local row = math.floor((mouse.y - last_layout.y0) / last_layout.lh)
	if row < 1 then
		close_ui()
		return
	end
	local items = display_items()
	local idx = row + first_visible() - 1
	if row < 1 or idx > #items then
		close_ui()
		return
	end
	selected = idx
	do_lookup(items[idx])
end

local BINDINGS = {
	"st_translate_text",
	"st_translate_bs",
	"st_translate_enter",
	"st_translate_kpenter",
	"st_translate_esc",
	"st_translate_up",
	"st_translate_down",
	"st_translate_click",
}

close_ui = function()
	if preview_timer then
		preview_timer:kill()
		preview_timer = nil
	end
	for _, name in ipairs(BINDINGS) do
		pcall(function()
			mp.remove_key_binding(name)
		end)
	end
	if overlay then
		overlay:remove()
	end
	is_open = false
	if actions.clear_result then
		actions.clear_result()
	end
end

local function open_ui()
	query = ""
	selected = 1
	is_open = true
	mp.add_forced_key_binding("any_unicode", "st_translate_text", function(ev)
		if ev and (ev.event == "press" or ev.event == "down" or ev.event == "repeat") and ev.key_text then
			on_text(ev.key_text)
		end
	end, { complex = true })
	mp.add_forced_key_binding("BS", "st_translate_bs", on_backspace, { repeatable = true })
	mp.add_forced_key_binding("ENTER", "st_translate_enter", on_enter)
	mp.add_forced_key_binding("KP_ENTER", "st_translate_kpenter", on_enter)
	mp.add_forced_key_binding("ESC", "st_translate_esc", close_ui)
	mp.add_forced_key_binding("UP", "st_translate_up", function()
		on_move(-1)
	end, { repeatable = true })
	mp.add_forced_key_binding("DOWN", "st_translate_down", function()
		on_move(1)
	end, { repeatable = true })
	-- shadow dict clicks while open
	mp.add_forced_key_binding("MBTN_LEFT", "st_translate_click", on_click)
	render()
end

function M.open()
	if not overlay then
		notify("translate box unavailable")
		return
	end
	if pinned then
		pinned = false
		if actions.close_popup then
			actions.close_popup()
		end
		pin_changed()
		return
	end
	if is_open then
		close_ui()
		return
	end
	open_ui()
end

function M.close()
	if is_open then
		close_ui()
	end
end

function M.is_pinned()
	return pinned
end

function M.disarm()
	pinned = false
end

function M.init(o, a)
	opts = o
	actions = a or {}
	overlay = mp.create_osd_overlay("ass-events")
	mp.register_script_message("open-translate", M.open)
end

return M
