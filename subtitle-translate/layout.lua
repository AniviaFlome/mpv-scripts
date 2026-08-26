local mp = require("mp")
local util = require("util")

local M = {}

local opts = nil
local probe = nil
local probe_ok = true
local probe_cache = {}
local LINE_H = 1.3
local MONO_ASPECT = 0.6

function M.init(o)
	opts = o
end

local function probe_text(text, style, w, h, fs_px)
	if not probe_ok or not text or text == "" or type(style) ~= "table" then
		return nil
	end
	local key = string.format(
		"%s|%s|%d|%d|%s|%s|%d|%d|%s",
		style.font,
		math.floor(fs_px * 10),
		style.bold or 0,
		style.italic or 0,
		style.spacing or 0,
		style.playres_y or 0,
		w,
		h,
		text
	)
	local cached = probe_cache[key]
	if cached ~= nil then
		if type(cached) == "table" then
			return cached
		end
		return nil
	end
	if not probe then
		probe = mp.create_osd_overlay("ass-events")
	end
	local tags = "{\\an7\\pos(1,1)\\fn" .. style.font .. "\\fs" .. string.format("%.2f", fs_px) .. "\\bord0\\shad0"
	if (style.bold or 0) ~= 0 then
		tags = tags .. "\\b1"
	end
	if (style.italic or 0) ~= 0 then
		tags = tags .. "\\i1"
	end
	if (style.spacing or 0) ~= 0 then
		tags = tags .. string.format("\\fsp%.2f", (style.spacing or 0) * (h / (style.playres_y or 720)))
	end
	tags = tags .. "}"
	probe.hidden = true
	probe.compute_bounds = true
	probe.res_x = w
	probe.res_y = h
	probe.data = tags .. util.ass_escape(text)
	local ok, rc = pcall(function()
		return probe:update()
	end)
	if not ok or type(rc) ~= "table" or rc.x0 == nil or rc.x1 == nil then
		probe_ok = false
		if opts.verbose then
			util.log("hidden text measuring unavailable, using width estimation")
		end
		probe_cache[key] = false
		return nil
	end
	probe_cache[key] = rc
	local count = 0
	for _ in pairs(probe_cache) do
		count = count + 1
	end
	if count > 2000 then
		probe_cache = {}
	end
	return rc
end

function M.probe_text(text, style, w, h, fs_px)
	return probe_text(text, style, w, h, fs_px)
end

function M.measure_width(text, style, w, h, fs_px)
	local rc = probe_text(text, style, w, h, fs_px)
	if rc then
		return rc.x1 - rc.x0
	end
	return nil
end

function M.measure_height(text, style, w, h, fs_px)
	local rc = probe_text(text, style, w, h, fs_px)
	if rc then
		return rc.y1 - rc.y0
	end
	return nil
end

function M.split_lines(s)
	local lines = {}
	for line in (s .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end
	return lines
end

function M.wrap_words(text, max_cols)
	local rows = {}
	for _, hard in ipairs(M.split_lines(text)) do
		local row_words = {}
		local cols = 0
		if hard:match("^%s*$") then
			rows[#rows + 1] = row_words
		else
			for word in hard:gmatch("%S+") do
				local pieces = {}
				if word:len() <= max_cols then
					pieces[1] = word
				else
					local rest = word
					while rest:len() > max_cols do
						pieces[#pieces + 1] = rest:sub(1, max_cols)
						rest = rest:sub(max_cols + 1)
					end
					if rest ~= "" then
						pieces[#pieces + 1] = rest
					end
				end
				for _, piece in ipairs(pieces) do
					local plen = piece:len()
					local sep = cols > 0 and 1 or 0
					if cols > 0 and cols + sep + plen > max_cols then
						rows[#rows + 1] = row_words
						row_words = {}
						cols = 0
						sep = 0
					end
					row_words[#row_words + 1] = piece
					cols = cols + sep + plen
				end
			end
			rows[#rows + 1] = row_words
		end
	end
	local words = {}
	for r, row_words in ipairs(rows) do
		local col = 0
		for _, piece in ipairs(row_words) do
			words[#words + 1] = { text = piece, row = r, col = col, len = piece:len() }
			col = col + piece:len() + 1
		end
		rows[r] = { words = row_words, cols = col > 0 and col - 1 or 0 }
	end
	return rows, words
end

local function layout_rows_bottom(rows, w, h, cw, lh, margin_y)
	local nrows = #rows
	local base_y = h - margin_y
	local minx, maxx, miny = w, 0, base_y
	for r, row in ipairs(rows) do
		local rw = row.cols * cw
		row.w = rw
		row.x = math.floor((w - rw) / 2)
		row.y = math.floor(base_y - (nrows - r + 1) * lh)
		row.h = lh
		if rw > 0 then
			if row.x < minx then
				minx = row.x
			end
			if row.x + rw > maxx then
				maxx = row.x + rw
			end
			if row.y < miny then
				miny = row.y
			end
		end
	end
	return {
		rows = rows,
		base_y = base_y,
		cw = cw,
		lh = lh,
		nrows = nrows,
		x0 = minx,
		x1 = maxx,
		y0 = miny,
		y1 = base_y,
	}
end

function M.build_mirror_layout(text, w, h)
	local fs = util.scaled_font(opts.mirror_font_size, h)
	local cw = fs * MONO_ASPECT
	local lh = math.floor(fs * LINE_H)
	local max_cols = math.max(8, math.floor((w * 0.94) / cw))
	local rows, words = M.wrap_words(text, max_cols)
	local layout = layout_rows_bottom(rows, w, h, cw, lh, opts.mirror_margin_y)
	for _, wd in ipairs(words) do
		local row = layout.rows[wd.row]
		wd.x = row.x + wd.col * cw
		wd.y = row.y
		wd.w = wd.len * cw
		wd.h = lh
	end
	layout.words = words
	layout.font_size = fs
	layout.line_h = lh
	layout.approximate = false
	return layout
end

function M.build_native_layout(text, w, h, style, meas)
	local scale = (style.playres_y or 720) > 0 and (h / style.playres_y) or 1
	local fs = style.fontsize * scale
	local ml = (style.margin_l or 0) * scale
	local mr = (style.margin_r or 0) * scale
	local mv = (style.margin_v or 0) * scale

	local line_h = nil
	if meas and meas.height then
		line_h = meas.height()
	end
	if not line_h or line_h <= 0 then
		line_h = fs * 1.25
	end

	local measured = false
	local function word_width(word)
		if meas and meas.width then
			local mw = meas.width(word)
			if mw then
				measured = true
				return mw
			end
		end
		return word:len() * fs * 0.53
	end
	local space_w = nil
	if meas and meas.width then
		local with_gap = meas.width("n n")
		local without = meas.width("nn")
		if with_gap and without and with_gap > without then
			space_w = with_gap - without
		end
	end
	if not space_w or space_w <= 0 then
		space_w = word_width(" ")
	end
	if not space_w or space_w <= 0 then
		space_w = fs * 0.3
	end

	local max_w = math.max(w - ml - mr, fs * 4)
	local rows, cur, cur_w = {}, {}, 0
	for word in text:gmatch("%S+") do
		local ww = word_width(word)
		local sep = #cur > 0 and space_w or 0
		if #cur > 0 and cur_w + sep + ww > max_w then
			rows[#rows + 1] = cur
			cur, cur_w, sep = {}, 0, 0
		end
		cur[#cur + 1] = { text = word, w = ww }
		cur_w = cur_w + sep + ww
	end
	rows[#rows + 1] = cur

	local nrows = #rows
	local words = {}
	local a = style.align or 2
	local vrow = 3 - math.floor((a - 1) / 3)
	local col = a % 3

	local row_hs = {}
	local bearings = {}
	local true_ws = {}
	local est_ws = {}
	local block_h = 0
	for r, row in ipairs(rows) do
		local texts = {}
		local est_w = 0
		for i, item in ipairs(row) do
			texts[i] = item.text
			est_w = est_w + item.w + (i > 1 and space_w or 0)
		end
		est_ws[r] = est_w
		row_hs[r] = line_h
		bearings[r] = 0
		true_ws[r] = nil
		if meas and meas.row_rect then
			local rc = meas.row_rect(table.concat(texts, " "))
			if rc and rc.x0 and rc.x1 and rc.y0 and rc.y1 and rc.x1 > rc.x0 and rc.y1 > rc.y0 then
				true_ws[r] = rc.x1 - rc.x0
				bearings[r] = rc.x0 - 1
				row_hs[r] = rc.y1 - rc.y0
				measured = true
			end
		end
		block_h = block_h + row_hs[r]
	end

	local anchor_y = h * ((style.sub_pos or 100) / 100)
	local top
	if vrow == 1 then
		top = anchor_y + mv
	elseif vrow == 2 then
		top = anchor_y - block_h / 2
	else
		top = anchor_y - mv - block_h
	end

	local minx, maxx, miny, maxy = w, 0, h, 0
	local wi = 0
	local y = top
	for r, row in ipairs(rows) do
		local row_w = true_ws[r] or est_ws[r]
		local space_row = space_w
		local words_sum = 0
		for _, item in ipairs(row) do
			words_sum = words_sum + item.w
		end
		if true_ws[r] and #row > 1 then
			local derived = (true_ws[r] - words_sum) / (#row - 1)
			if derived > 0 and derived < fs * 2 then
				space_row = derived
			end
		end
		local x0
		if col == 1 then
			x0 = ml + bearings[r]
		elseif col == 0 then
			x0 = w - mr - row_w + bearings[r]
		else
			x0 = (w - row_w) / 2 + bearings[r]
		end
		local cx = x0
		for _, item in ipairs(row) do
			local ww = item.w
			wi = wi + 1
			words[wi] = { text = item.text, row = r, x = cx, y = y, w = ww, h = row_hs[r] }
			if cx < minx then
				minx = cx
			end
			if cx + ww > maxx then
				maxx = cx + ww
			end
			if y < miny then
				miny = y
			end
			if y + row_hs[r] > maxy then
				maxy = y + row_hs[r]
			end
			cx = cx + ww + space_row
		end
		y = y + row_hs[r]
	end

	return {
		words = words,
		line_h = line_h,
		font_size = fs,
		approximate = not measured,
		x0 = minx,
		x1 = maxx,
		y0 = miny,
		y1 = maxy,
		base_y = maxy,
	}
end

function M.hit_test(layout, mx, my)
	if not layout.words or #layout.words == 0 then
		return nil
	end
	local default_h = layout.line_h or layout.lh or 24
	local tol = math.max(6, default_h / 4)
	local best, best_d
	for wi, wd in ipairs(layout.words) do
		if wd.x and wd.y and wd.w then
			local wh = wd.h or default_h
			if mx >= wd.x - tol and mx <= wd.x + wd.w + tol and my >= wd.y - tol and my <= wd.y + wh + tol then
				local dx = mx - (wd.x + wd.w / 2)
				local dy = my - (wd.y + wh / 2)
				local d = math.abs(dy) * 2 + math.abs(dx)
				if best == nil or d < best_d then
					best = wi
					best_d = d
				end
			end
		end
	end
	return best
end

function M.clean_word(word)
	local w = word:gsub("^[%p%s]+", ""):gsub("[%p%s]+$", "")
	if w == "" or w:match("^[%d%p%s]+$") then
		return nil
	end
	return w
end

return M
