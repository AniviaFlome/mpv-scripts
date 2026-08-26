local mp = require("mp")
local util = require("util")
local cache = require("cache")
local providers = require("providers")

local M = {}

local opts = nil
local tl = {
	entries = {},
	cur = 1,
	queue = {},
	head = 1,
	active = 0,
	gen = 0,
	ffmpeg_path = false,
	debounce = nil,
	raw_content = nil,
	raw_ext = nil,
	style = nil,
	style_gen = nil,
}

function M.init(o)
	opts = o
end

local function parse_timestamp(s)
	local h, m, rest = s:match("(%d+):(%d+):([%d.,]+)")
	if not h then
		m, rest = s:match("^(%d+):([%d.,]+)$")
		if not m then
			return nil
		end
		h = 0
	end
	local sec, frac = rest:match("^(%d+)[.,]?(%d*)$")
	return (tonumber(h) or 0) * 3600
		+ (tonumber(m) or 0) * 60
		+ (tonumber(sec) or 0)
		+ (tonumber(frac) or 0) / (10 ^ #frac)
end

local function clean_subtitle_text(text)
	text = text:gsub("%{[^}]*%}", "")
	text = text:gsub("\\[Nnh]", " ")
	return util.trim(util.strip_tags(util.html_unescape(text)))
end

local function parse_ass_content(content)
	local entries = {}
	for line in content:gmatch("[^\r\n]+") do
		local start_s, tail = line:match("^Dialogue:%s*[^,]*,(%d+:%d%d:[%d.,]+),(.*)$")
		if start_s then
			for _ = 1, 7 do
				tail = tail:match("^[^,]*,(.*)$") or ""
			end
			entries[#entries + 1] = { start = parse_timestamp(start_s) or 0, text = clean_subtitle_text(tail) }
		end
	end
	return entries
end

local function parse_srt_content(content)
	content = content:gsub("^﻿", "")
	local entries = {}
	local pending_start, buf = nil, {}
	local function flush()
		if pending_start and #buf > 0 then
			entries[#entries + 1] = { start = pending_start, text = clean_subtitle_text(table.concat(buf, " ")) }
		end
		pending_start, buf = nil, {}
	end
	for line in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local start_s = line:match("(%d+:%d%d:[%d.,]+)%s*-->") or line:match("(%d+:[%d.,]+)%s*-->")
		if start_s then
			flush()
			pending_start = parse_timestamp(start_s) or 0
		elseif line:match("^%s*$") then
			flush()
		elseif pending_start then
			buf[#buf + 1] = line
		end
	end
	flush()
	return entries
end

function M.parse_subtitle_content(content, ext)
	ext = (ext or ""):lower()
	if ext == "ass" or ext == "ssa" then
		return parse_ass_content(content)
	end
	return parse_srt_content(content)
end

function M.finalize_entries(entries)
	table.sort(entries, function(a, b)
		return a.start < b.start
	end)
	local out, last = {}, nil
	for _, e in ipairs(entries) do
		if e.text ~= "" and e.text ~= last and not e.text:match("^[%d%p%s]+$") then
			out[#out + 1] = e
			last = e.text
		end
	end
	return out
end

function M.parse_ass_style(content)
	local playres_y, playres_x
	local section = nil
	local format_fields = nil
	local styles = {}
	local style_counts = {}
	for line in content:gmatch("[^\r\n]+") do
		local l = util.trim(line)
		local sec = l:match("^%[([^%]]*)%]$")
		if sec then
			section = sec:lower()
			format_fields = nil
		elseif section == "script info" then
			local k, v = l:match("^([^:;]+):%s*(.-)$")
			if k then
				k = k:lower():gsub("%s", "")
				if k == "playresy" then
					playres_y = tonumber(v)
				elseif k == "playresx" then
					playres_x = tonumber(v)
				end
			end
		elseif section == "v4+ styles" or section == "v4 styles" then
			if l:match("^Format:") then
				format_fields = util.split_csv(l:sub(8))
				for i, f in ipairs(format_fields) do
					format_fields[i] = f:lower():gsub("%s", "")
				end
			elseif l:match("^Style:") and format_fields then
				local vals = util.split_csv(l:sub(7))
				local m = {}
				for i, f in ipairs(format_fields) do
					m[f] = vals[i]
				end
				if m.name and m.name ~= "" then
					styles[m.name:lower()] = {
						font = m.fontname or "sans-serif",
						fontsize = tonumber(m.fontsize) or 48,
						bold = tonumber(m.bold) or 0,
						italic = tonumber(m.italic) or 0,
						spacing = tonumber(m.spacing) or 0,
						align = tonumber(m.alignment) or 2,
						margin_l = tonumber(m.marginl) or 10,
						margin_r = tonumber(m.marginr) or 10,
						margin_v = tonumber(m.marginv) or 10,
						color_primary = m.primarycolour,
						color_outline = m.outlinecolour,
						color_back = m.backcolour,
						outline = tonumber(m.outline) or 2,
						shadow = tonumber(m.shadow) or 0,
					}
				end
			end
		elseif section == "events" then
			local st = l:match("^Dialogue:%s*[^,]*,[^,]*,[^,]*,([^,]*)")
			if st then
				st = util.trim(st):lower()
				style_counts[st] = (style_counts[st] or 0) + 1
			end
		end
	end
	local best_name, best_n = nil, -1
	for name, n in pairs(style_counts) do
		if styles[name] then
			local better = false
			if best_name == nil or n > best_n then
				better = true
			elseif n == best_n then
				if name == "default" and best_name ~= "default" then
					better = true
				elseif best_name ~= "default" and name < best_name then
					better = true
				end
			end
			if better then
				best_name, best_n = name, n
			end
		end
	end
	local s = (best_name and styles[best_name]) or styles["default"]
	if not s then
		s = {
			font = "sans-serif",
			fontsize = 48,
			bold = 0,
			italic = 0,
			spacing = 0,
			align = 2,
			margin_l = 10,
			margin_r = 10,
			margin_v = 10,
		}
	end
	s.playres_y = playres_y or 288
	s.playres_x = playres_x
	s.source = "ass"
	local function ass_alpha_color(v, def_color, def_alpha)
		local hex = type(v) == "string" and v:match("^&H([%x]+)$")
		if not hex then
			return def_color, def_alpha
		end
		hex = hex:upper()
		if hex:len() < 8 then
			hex = string.rep("0", 8 - hex:len()) .. hex
		end
		local a = tonumber(hex:sub(1, 2), 16)
		local b = hex:sub(3, 4)
		local g = hex:sub(5, 6)
		local r = hex:sub(7, 8)
		return "&H" .. b .. g .. r, a
	end
	s.primary, s.primary_a = ass_alpha_color(s.color_primary, "&HFFFFFF", 0)
	s.outline_c, s.outline_a = ass_alpha_color(s.color_outline, "&H101010", 0)
	s.back_c, s.back_a = ass_alpha_color(s.color_back, "&H101010", 0)
	return s
end

function M.srt_native_style()
	local ax = mp.get_property("sub-align-x") or "center"
	local ay = mp.get_property("sub-align-y") or "bottom"
	local align = 2
	if ay == "top" then
		align = ax == "left" and 7 or ax == "right" and 9 or 8
	elseif ay == "center" then
		align = ax == "left" and 4 or ax == "right" and 6 or 5
	else
		align = ax == "left" and 1 or ax == "right" and 3 or 2
	end
	return {
		playres_y = 288,
		font = mp.get_property("sub-font") or "sans-serif",
		fontsize = mp.get_property_number("sub-font-size") or 55,
		bold = mp.get_property_number("sub-bold") or 0,
		italic = mp.get_property_number("sub-italic") or 0,
		spacing = mp.get_property_number("sub-spacing") or 0,
		align = align,
		margin_l = mp.get_property_number("sub-margin-x") or 0,
		margin_r = mp.get_property_number("sub-margin-x") or 0,
		margin_v = mp.get_property_number("sub-margin-y") or 0,
		sub_pos = mp.get_property_number("sub-pos") or 100,
		source = "options",
	}
end

local function tl_reset()
	tl.gen = tl.gen + 1
	tl.entries = {}
	tl.cur = 1
	tl.queue = {}
	tl.head = 1
	tl.active = 0
	tl.raw_content = nil
	tl.raw_ext = nil
	tl.style = nil
end

local function find_ffmpeg()
	if tl.ffmpeg_path ~= false then
		return tl.ffmpeg_path
	end
	local res = mp.command_native({
		name = "subprocess",
		args = { "sh", "-c", "command -v ffmpeg" },
		capture_stdout = true,
		playback_only = false,
	})
	tl.ffmpeg_path = (res and res.status == 0 and util.trim(res.stdout) ~= "") and util.trim(res.stdout) or nil
	if not tl.ffmpeg_path then
		mp.osd_message("[subtitle-translate] prefetch disabled: ffmpeg not found in PATH", 4)
	end
	return tl.ffmpeg_path
end

local function selected_sub_track()
	local tracks = mp.get_property_native("track-list")
	if not tracks then
		return nil
	end
	for _, t in ipairs(tracks) do
		if t.type == "sub" and t.selected then
			return t
		end
	end
	return nil
end

local function prefetch_step()
	if not opts.prefetch or #tl.entries == 0 then
		return
	end
	if tl.active >= (opts.prefetch_concurrency or 4) then
		return
	end
	local now = mp.get_property_number("playback-time") or mp.get_property_number("time-pos") or 0
	while tl.cur <= #tl.entries and tl.entries[tl.cur].start <= now do
		tl.cur = tl.cur + 1
	end
	local order = {}
	if opts.prefetch_all then
		for i = tl.cur, #tl.entries do
			order[#order + 1] = i
		end
		for i = 1, tl.cur - 1 do
			order[#order + 1] = i
		end
	else
		for i = tl.cur, math.min(#tl.entries, tl.cur + opts.prefetch_ahead - 1) do
			order[#order + 1] = i
		end
	end
	for _, i in ipairs(order) do
		local entry = tl.entries[i]
		if not cache.has_cached("sentence", entry.text) then
			tl.active = tl.active + 1
			if opts.verbose then
				util.log("prefetch: translating line " .. i .. "/" .. #tl.entries)
			end
			providers.lookup("sentence", entry.text, function(_, err)
				tl.active = tl.active - 1
				if err and opts.verbose then
					util.log("prefetch failed: " .. err)
				end
				mp.add_timeout(0.3, prefetch_step)
			end)
			return
		end
	end
end

local function load_timeline()
	tl_reset()
	local track = selected_sub_track()
	if not track then
		return
	end
	local gen = tl.gen
	if track.external and track["external-filename"] then
		local path = track["external-filename"]
		if path:match("^%a+:") then
			return
		end
		local f = io.open(path, "r")
		if not f then
			return
		end
		local content = f:read("*a")
		f:close()
		local ext = (path:match("%.([%w]+)$") or ""):lower()
		tl.raw_content = content
		tl.raw_ext = ext
		tl.entries = M.finalize_entries(M.parse_subtitle_content(content, ext))
		if opts.verbose then
			util.log("prefetch timeline ready: " .. #tl.entries .. " lines from external subtitle file")
		end
		for _ = 1, (opts.prefetch_concurrency or 4) do
			prefetch_step()
		end
		return
	end
	local media_path = mp.get_property("path")
	local ff_index = track["ff-index"]
	local ffmpeg = find_ffmpeg()
	if not media_path or media_path:match("^%a+:") or ff_index == nil or not ffmpeg then
		return
	end
	mp.command_native_async({
		name = "subprocess",
		args = {
			ffmpeg,
			"-nostdin",
			"-v",
			"error",
			"-i",
			media_path,
			"-map",
			"0:" .. tostring(ff_index),
			"-f",
			"ass",
			"-",
		},
		capture_stdout = true,
		capture_stderr = true,
		playback_only = false,
	}, function(success, result)
		if gen ~= tl.gen then
			return
		end
		if not success or not result or result.status ~= 0 or not result.stdout or result.stdout == "" then
			if opts.verbose then
				util.log("prefetch: ffmpeg extraction failed for embedded subtitle track")
			end
			return
		end
		tl.raw_content = result.stdout
		tl.raw_ext = "ass"
		tl.entries = M.finalize_entries(M.parse_subtitle_content(result.stdout, "ass"))
		if opts.verbose then
			util.log("prefetch timeline ready: " .. #tl.entries .. " lines from embedded subtitle track")
		end
		for _ = 1, (opts.prefetch_concurrency or 4) do
			prefetch_step()
		end
	end)
end

local function schedule_timeline_reload(delay)
	if tl.debounce then
		tl.debounce:kill()
	end
	tl.debounce = mp.add_timeout(delay or 0.5, load_timeline)
end

function M.reset()
	tl_reset()
end

function M.schedule_reload(delay)
	schedule_timeline_reload(delay)
end

function M.get_native_style()
	if tl.style and tl.style_gen == tl.gen then
		return tl.style
	end
	local style = nil
	if tl.raw_content and (tl.raw_ext == "ass" or tl.raw_ext == "ssa") then
		style = M.parse_ass_style(tl.raw_content)
	end
	if not style then
		style = M.srt_native_style()
	end
	tl.style = style
	tl.style_gen = tl.gen
	if opts.verbose then
		util.log(
			string.format(
				"native subtitle style: font=%s size=%s align=%d playres_y=%d source=%s",
				style.font,
				style.fontsize,
				style.align,
				style.playres_y,
				style.source
			)
		)
	end
	return style
end

function M.on_file_loaded()
	schedule_timeline_reload(0.6)
end

function M.on_sid_change()
	schedule_timeline_reload(0.4)
end

return M
