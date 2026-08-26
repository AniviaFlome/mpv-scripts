local mp = require("mp")
local util = require("util")
local layout = require("layout")

local M = {}

local opts = nil
local line_ov = nil
local popup_ov = nil
local debug_ov = nil
local popup_paging = { lines = nil, offset = 0, header = nil, word = nil, mx = 0, my = 0 }
local panel_rect = nil

local POS_TR = {
	noun = "isim",
	verb = "fiil",
	adjective = "sıfat",
	adverb = "zarf",
	preposition = "edat",
	conjunction = "bağlaç",
	pronoun = "zamir",
	interjection = "ünlem",
	numeral = "sayı",
	exclamation = "ünlem",
}

function M.init(o)
	opts = o
	line_ov = mp.create_osd_overlay("ass-events")
	popup_ov = mp.create_osd_overlay("ass-events")
	debug_ov = mp.create_osd_overlay("ass-events")
end

function M.remove_all()
	line_ov:remove()
	popup_ov:remove()
	debug_ov:remove()
end

function M.remove_line()
	line_ov:remove()
end

function M.remove_debug()
	debug_ov:remove()
end

local function build_bg_content(an, x, y, bw, bh, color, alpha, bord, bord_color)
	return string.format(
		"{\\an%d\\pos(%d,%d)\\bord%s\\shad0\\3c%s\\1c%s\\alpha%s\\p1}m 0 0 l %.0f 0 %.0f %.0f 0 %.0f{\\p0}",
		an,
		x,
		y,
		string.format("%.1f", bord or 0),
		util.ass_color(bord_color or "000000"),
		util.ass_color(color),
		alpha,
		bw,
		bw,
		bh,
		bh
	)
end

local function build_text_content(an, x, y, content)
	return "{\\an" .. an .. "\\pos(" .. x .. "," .. y .. ")}" .. content
end

function M.get_anchor()
	local POSITIONS = {
		["top-left"] = { an = 7, fx = 0, fy = 0 },
		["top-center"] = { an = 8, fx = 0.5, fy = 0 },
		["top-right"] = { an = 9, fx = 1, fy = 0 },
		["bottom-left"] = { an = 1, fx = 0, fy = 1 },
		["bottom-center"] = { an = 2, fx = 0.5, fy = 1 },
		["bottom-right"] = { an = 3, fx = 1, fy = 1 },
	}
	return POSITIONS[opts.position] or POSITIONS["top-center"]
end

local function anchor_xy(pos, w, h)
	local x = pos.fx * w
	local y = pos.fy * h
	if pos.fx == 0 then
		x = 40
	elseif pos.fx == 1 then
		x = w - 40
	end
	if pos.fy == 0 then
		y = opts.margin_y
	elseif pos.fy == 1 then
		y = h - opts.margin_y
	end
	return math.floor(x), math.floor(y)
end

function M.popup_line_limit()
	return math.max(1, tonumber(opts.dict_max_lines) or 8)
end

function M.build_popup_lines(res)
	local lines_out = {}
	if res.lines then
		for _, l in ipairs(res.lines) do
			lines_out[#lines_out + 1] = { text = l }
		end
		if #lines_out == 0 then
			lines_out[1] = { text = "(no results)" }
		end
		return lines_out
	end
	if res.main and res.main ~= "" then
		lines_out[#lines_out + 1] = { text = res.main }
	end
	if res.groups then
		for gi, group in ipairs(res.groups) do
			if gi > opts.dict_max_groups then
				break
			end
			local label = POS_TR[group.pos] or group.pos
			if label ~= "" then
				lines_out[#lines_out + 1] = { text = label, kind = "group" }
			end
			for ti, term in ipairs(group.terms) do
				if ti > opts.dict_max_terms then
					break
				end
				lines_out[#lines_out + 1] = { text = "\xE2\x80\xA2 " .. term }
			end
		end
	end
	if #lines_out == 0 then
		lines_out[1] = { text = "(no dictionary results)" }
	end
	return lines_out
end

function M.hide_line_translation()
	line_ov:remove()
end

function M.get_panel_rect()
	return panel_rect
end

local function render_line_translation(translated, error_text)
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return
	end
	local pos = M.get_anchor()
	local x, y = anchor_xy(pos, w, h)
	local sub_font = mp.get_property("sub-font") or opts.font
	local fs = (mp.get_property_number("sub-font-size") or 38) * (h / 720) * (opts.panel_font_scale or 1)
	local text_c = util.parse_mpv_color(mp.get_property("sub-color"), util.ass_color(opts.color_text))
	local bord_c = util.parse_mpv_color(mp.get_property("sub-border-color"), util.ass_color(opts.color_outline))
	local bord_px = (mp.get_property_number("sub-border-size") or 3) * (h / 720)
	local max_chars = math.max(10, math.floor((w * opts.max_width_percent / 100 - 2 * 40) / (fs * 0.58)))

	local main_lines = {}
	if translated then
		for _, row in ipairs(layout.wrap_words(translated, max_chars)) do
			main_lines[#main_lines + 1] = table.concat(row.words, " ")
		end
	elseif error_text then
		main_lines[1] = "(" .. error_text .. ")"
	end
	if #main_lines == 0 then
		return
	end

	local content = "{\\fn"
		.. sub_font
		.. "\\fs"
		.. string.format("%.1f", fs)
		.. "\\1c"
		.. text_c
		.. "\\3c"
		.. bord_c
		.. "\\bord"
		.. string.format("%.1f", bord_px)
		.. "\\shad0}"
	for i, l in ipairs(main_lines) do
		if i > 1 then
			content = content .. "\\N"
		end
		content = content .. util.ass_escape(l)
	end

	local pad = math.floor(fs * 0.25)
	line_ov.res_x = w
	line_ov.res_y = h
	line_ov.compute_bounds = true
	line_ov.data = build_text_content(pos.an, x, y, content)
	local ok_rc, rc = pcall(line_ov.update, line_ov)
	line_ov.compute_bounds = false

	local bg_data = ""
	if ok_rc and rc and rc.x0 and rc.y0 and rc.x1 and rc.y1 then
		local bx = math.floor(rc.x0 - pad)
		local by = math.floor(rc.y0 - pad)
		local bw = math.ceil(rc.x1 - rc.x0 + 2 * pad)
		local bh = math.ceil(rc.y1 - rc.y0 + 2 * pad)
		panel_rect = { x = bx, y = by, w = bw, h = bh }
		if opts.translation_background then
			bg_data = build_bg_content(
				7,
				bx,
				by,
				bw,
				bh,
				opts.color_bg,
				util.ass_alpha(math.min(100, opts.bg_opacity + 15)),
				math.max(1.5, math.floor(fs * 0.06)),
				"5a5a5a"
			)
		end
	end
	local text_data = build_text_content(pos.an, x, y, content)
	line_ov.data = bg_data ~= "" and (bg_data .. "\n" .. text_data) or text_data
	line_ov:update()
end
function M.show_line_translation(translated, error_text)
	render_line_translation(translated, error_text)
end

local function render_popup_panel(display, header, anchor)
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return
	end
	local fs = util.scaled_font(opts.popup_font_size, h)
	local header_fs = math.floor(fs * 1.15)
	local dim_fs = math.floor(fs * 0.72)
	local group_fs = math.floor(fs * 0.85)
	local pad_x = math.floor(fs * (opts.popup_padding_x or 0.35))
	local pad_y = math.floor(fs * (opts.popup_padding_y or 0.12))
	local gap = math.floor(fs * 0.4)

	local plain = {}
	if header and header ~= "" then
		plain[#plain + 1] = header
	end
	for _, d in ipairs(display) do
		plain[#plain + 1] = d.text
	end
	if #plain == 0 then
		return
	end

	local probe_style = {
		font = opts.font,
		bold = 0,
		italic = 0,
		spacing = 0,
		playres_y = 720,
	}
	local ok_rc, rc = pcall(layout.probe_text, table.concat(plain, "\n"), probe_style, w, h, fs)
	if not ok_rc then
		rc = nil
	end
	local box_w, box_h
	if rc and rc.x1 and rc.x0 and rc.y1 and rc.y0 then
		local header_extra = (header and header ~= "") and math.ceil((header_fs - fs) * 0.58 * header:len()) or 0
		box_w = math.floor(rc.x1 - rc.x0 + 2 * pad_x + header_extra)
		box_h = math.floor(rc.y1 - rc.y0 + 2 * pad_y)
	else
		local est_max = 0
		if header and header ~= "" then
			local est = header:len() * header_fs * 0.58
			if est > est_max then
				est_max = est
			end
		end
		for _, d in ipairs(display) do
			local est = d.text:len() * fs * 0.58
			if est > est_max then
				est_max = est
			end
		end
		box_w = math.floor(est_max + 2 * pad_x)
		box_h = math.floor(#display * fs * 1.2 + 2 * pad_y)
	end
	if box_w > w - 8 then
		box_w = w - 8
	end

	local an, px, py
	if anchor and anchor.w and anchor.h and anchor.x then
		local cx = anchor.x + anchor.w / 2
		local half = box_w / 2 + 4
		if cx < half then
			cx = half
		elseif cx > w - half then
			cx = w - half
		end
		local by = anchor.y - gap
		if by - box_h < 4 then
			an = 8
			by = anchor.y + anchor.h + gap
		else
			an = 2
		end
		px, py = math.floor(cx), math.floor(by)
	else
		local mx = (anchor and anchor.cursor_x) or 0
		local my = (anchor and anchor.cursor_y) or 0
		px = mx + opts.popup_offset
		py = my + opts.popup_offset
		if px + box_w > w - 4 then
			px = mx - opts.popup_offset - box_w
		end
		if py + box_h > h - 4 then
			py = my - opts.popup_offset - box_h
		end
		if px < 4 then
			px = 4
		end
		if py < 4 then
			py = 4
		end
		an = 7
	end

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
	local parts = {}
	for _, d in ipairs(display) do
		if d.kind == "header" then
			parts[#parts + 1] = "{\\fs"
				.. header_fs
				.. "\\1c"
				.. util.ass_color(opts.hovered_color)
				.. "\\b1\\bord0}"
				.. util.ass_escape(d.text)
				.. "{\\fs"
				.. fs
				.. "\\b0\\bord"
				.. math.max(1, math.floor(opts.outline_width * h / 1080 + 0.5))
				.. "}"
		elseif d.kind == "group" then
			parts[#parts + 1] = "{\\fs"
				.. group_fs
				.. "\\1c&H999999&\\b1\\bord0}"
				.. util.ass_escape(d.text)
				.. "{\\fs"
				.. fs
				.. "\\b0\\1c"
				.. util.ass_color(opts.color_text)
				.. "\\bord"
				.. math.max(1, math.floor(opts.outline_width * h / 1080 + 0.5))
				.. "}"
		elseif d.kind == "dim" then
			parts[#parts + 1] = "{\\fs"
				.. dim_fs
				.. "\\1c&H999999&\\bord0}"
				.. util.ass_escape(d.text)
				.. "{\\fs"
				.. fs
				.. "\\1c"
				.. util.ass_color(opts.color_text)
				.. "\\bord"
				.. math.max(1, math.floor(opts.outline_width * h / 1080 + 0.5))
				.. "}"
		else
			parts[#parts + 1] = util.ass_escape(d.text)
		end
	end

	popup_ov.res_x = w
	popup_ov.res_y = h
	popup_ov.compute_bounds = true
	popup_ov.data = build_text_content(an, px, py, base .. table.concat(parts, "\\N"))
	local ok_rc, rc = pcall(popup_ov.update, popup_ov)
	local bg_data = ""
	if ok_rc and rc and rc.x0 and rc.y0 and rc.x1 and rc.y1 then
		bg_data = build_bg_content(
			7,
			math.floor(rc.x0 - pad_x),
			math.floor(rc.y0 - pad_y),
			math.ceil(rc.x1 - rc.x0 + 2 * pad_x),
			math.ceil(rc.y1 - rc.y0 + 2 * pad_y),
			opts.color_bg,
			util.ass_alpha(math.min(100, opts.bg_opacity + 25)),
			math.max(1, math.floor(fs * 0.06)),
			"5a5a5a"
		)
		popup_ov.compute_bounds = false
		popup_ov.data = bg_data .. "\n" .. build_text_content(an, px, py, base .. table.concat(parts, "\\N"))
		popup_ov:update()
	end
end

function M.clear_popup()
	popup_ov:remove()
	popup_paging.lines = nil
	popup_paging.offset = 0
end

local function popup_render_page()
	local lines = popup_paging.lines
	if not lines then
		return
	end
	local limit = M.popup_line_limit()
	local max_offset = math.max(0, #lines - limit)
	local off = math.max(0, math.min(popup_paging.offset, max_offset))
	popup_paging.offset = off
	local display = {}
	for i = off + 1, math.min(#lines, off + limit) do
		display[#display + 1] = lines[i]
	end
	if #lines > limit then
		display[#display + 1] = {
			text = string.format("%d-%d / %d", off + 1, math.min(#lines, off + limit), #lines),
			kind = "dim",
		}
	end
	local anchor
	if popup_paging.word then
		anchor = popup_paging.word
	else
		anchor = { cursor_x = popup_paging.mx, cursor_y = popup_paging.my }
	end
	render_popup_panel(display, popup_paging.header, anchor)
end

function M.popup_set(lines, header, word, mx, my)
	popup_paging.lines = lines
	popup_paging.offset = 0
	popup_paging.header = header
	popup_paging.word = word
	popup_paging.mx = mx
	popup_paging.my = my
	popup_render_page()
end

function M.popup_scroll(dir)
	if not popup_paging.lines then
		return
	end
	popup_paging.offset = popup_paging.offset + dir
	popup_render_page()
end

local function render_mirror_line(layout, highlight_idx)
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return
	end
	local pad = math.floor(layout.lh * 0.15)
	local base_style = "{\\fn"
		.. opts.mirror_font
		.. "\\fs"
		.. layout.font_size
		.. "\\1c"
		.. util.ass_color(opts.color_mirror)
		.. "\\bord0\\shad0\\q2}"
	local hl_style = "{\\1c" .. util.ass_color(opts.hovered_color) .. "}"
	local norm_style = "{\\1c" .. util.ass_color(opts.color_mirror) .. "}"
	local max_cols = 0
	local row_lines = {}
	for r, row in ipairs(layout.rows) do
		if row.cols > max_cols then
			max_cols = row.cols
		end
		local parts = {}
		local pos_now = 0
		for wi, wd in ipairs(layout.words) do
			if wd.row == r then
				local g = wd.col - pos_now
				if g > 0 then
					parts[#parts + 1] = string.rep(" ", g)
					pos_now = pos_now + g
				end
				local piece = wd.text
				if wi == highlight_idx then
					piece = hl_style .. piece .. norm_style
				end
				parts[#parts + 1] = piece
				pos_now = pos_now + wd.len
			end
		end
		row_lines[r] = table.concat(parts)
	end
	local nrows = #layout.rows
	local block_w = max_cols * layout.cw
	local block_h = nrows * layout.lh
	local base_y = h - opts.mirror_margin_y
	local bg_data = build_bg_content(
		2,
		math.floor(w / 2),
		math.floor(base_y),
		math.floor(block_w + 2 * pad),
		math.floor(block_h + 2 * pad),
		opts.color_bg,
		util.ass_alpha(math.min(100, opts.bg_opacity + 20))
	)
	local content = base_style
		.. "{\\an2\\pos("
		.. math.floor(w / 2)
		.. ","
		.. math.floor(base_y)
		.. ")}"
		.. table.concat(row_lines, "\\N")
	line_ov.res_x = w
	line_ov.res_y = h
	line_ov.data = bg_data .. "\n" .. content
	line_ov:update()
end

local function render_replica_line(layout, highlight_idx)
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return
	end
	local fs = layout.font_size
	local s = layout.style or {}
	local scale = h / (s.playres_y or 720)

	local text_a = s.primary_a or 0
	local bord_a = s.outline_a or 0
	local shad_a = s.back_a or 0
	local base = "{\\fn"
		.. (s.font or layout.font or "sans-serif")
		.. "\\fs"
		.. string.format("%.1f", fs)
		.. "\\1c"
		.. (s.primary or "&HFFFFFF")
		.. "\\3c"
		.. (s.outline_c or "&H101010")
		.. "\\bord"
		.. string.format("%.1f", (opts.replica_outline or 3) * scale)
		.. "\\4c"
		.. (s.back_c or "&H101010")
		.. "\\shad"
		.. string.format("%.1f", (s.shadow or 0) * scale)
	if text_a > 0 then
		base = base .. string.format("\\1a&H%02X", text_a)
	end
	if bord_a > 0 then
		base = base .. string.format("\\3a&H%02X", bord_a)
	end
	if shad_a > 0 then
		base = base .. string.format("\\4a&H%02X", shad_a)
	end
	if (s.bold or 0) ~= 0 then
		base = base .. "\\b1"
	end
	if (s.italic or 0) ~= 0 then
		base = base .. "\\i1"
	end
	if (s.spacing or 0) ~= 0 then
		base = base .. string.format("\\fsp%.2f", s.spacing * scale)
	end
	base = base .. "}"
	local hl = "{\\1c" .. util.ass_color(opts.hovered_color) .. "\\u1}"
	local norm = "{\\1c" .. (s.primary or "&HFFFFFF") .. "\\u0}"

	local lines = {}
	local parts = {}
	local current_row = 0
	local row_x0, row_x1, row_y = 0, 0, 0
	local function flush_row()
		if #parts > 0 then
			local a = s.align or 2
			local col = a % 3
			local ax
			if col == 1 then
				ax = row_x0
			elseif col == 0 then
				ax = row_x1
			else
				ax = (row_x0 + row_x1) / 2
			end
			local an = col == 1 and 7 or col == 0 and 9 or 8
			lines[#lines + 1] = "{\\an"
				.. an
				.. "\\pos("
				.. math.floor(ax)
				.. ","
				.. math.floor(row_y)
				.. ")}"
				.. base
				.. table.concat(parts)
		end
		parts = {}
	end
	for wi, wd in ipairs(layout.words) do
		if wd.row ~= current_row then
			flush_row()
			current_row = wd.row
			row_x0 = wd.x
			row_x1 = wd.x + wd.w
			row_y = wd.y
		end
		if wd.x < row_x0 then
			row_x0 = wd.x
		end
		if wd.x + wd.w > row_x1 then
			row_x1 = wd.x + wd.w
		end
		if #parts > 0 then
			parts[#parts + 1] = " "
		end
		local piece = wd.text
		if wi == highlight_idx then
			piece = hl .. piece .. norm
		end
		parts[#parts + 1] = piece
	end
	flush_row()

	line_ov.res_x = w
	line_ov.res_y = h
	line_ov.data = table.concat(lines, "\n")
	line_ov:update()
end

local function render_hitboxes(layout)
	if not opts.show_hitboxes then
		return
	end
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		return
	end
	if not layout or not layout.words or #layout.words == 0 then
		return
	end
	local default_h = layout.line_h or layout.lh or 24
	local events = {}
	for _, wd in ipairs(layout.words) do
		if wd.x and wd.y and wd.w then
			local wh = wd.h or default_h
			events[#events + 1] = build_bg_content(
				7,
				math.floor(wd.x),
				math.floor(wd.y),
				math.ceil(wd.w),
				math.ceil(wh),
				"204060",
				util.ass_alpha(65),
				1,
				"ff3333"
			)
		end
	end
	events[#events + 1] = build_bg_content(
		7,
		math.floor(layout.x0),
		math.floor(layout.y0),
		math.ceil(layout.x1 - layout.x0),
		math.ceil(layout.y1 - layout.y0),
		"000000",
		"&HFF",
		1,
		"4466ff"
	)
	debug_ov.res_x = w
	debug_ov.res_y = h
	debug_ov.data = table.concat(events, "\n")
	debug_ov:update()
	if opts.verbose then
		util.log(
			string.format(
				"hitboxes drawn: %d words, bbox=(%d,%d)-(%d,%d)",
				#layout.words,
				layout.x0,
				layout.y0,
				layout.x1,
				layout.y1
			)
		)
	end
end

M.render_mirror_line = render_mirror_line
M.render_replica_line = render_replica_line
M.render_hitboxes = render_hitboxes

return M
