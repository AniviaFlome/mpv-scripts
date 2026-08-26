local mp = require("mp")
local options = require("mp.options")

local opts = {
	key_mark_first = "Alt+1",
	key_mark_second = "Alt+2",
	key_calculate = "Alt+3",
}

options.read_options(opts, "subtitle-sync")

local first_ts = nil
local second_ts = nil

local function notify(text)
	mp.osd_message(text, 2)
	print("[subtitle-sync] " .. text)
end

local function get_sub_start()
	local v = mp.get_property_number("sub-start")
	if v == nil then
		notify("No subtitle is currently displayed.")
		return nil
	end
	return v
end

local function mark_sub(which)
	local t = get_sub_start()
	if not t then
		return
	end

	if which == 1 then
		first_ts = t
		notify(string.format("First subtitle start time: %.3f seconds", t))
	elseif which == 2 then
		second_ts = t
		notify(string.format("Second subtitle start time: %.3f seconds", t))
	end
end

mp.add_key_binding(opts.key_mark_first, "mark_first_sub", function()
	mark_sub(1)
end)
mp.add_key_binding(opts.key_mark_second, "mark_second_sub", function()
	mark_sub(2)
end)

mp.add_key_binding(opts.key_calculate, "calculate_difference", function()
	if not first_ts or not second_ts then
		notify(string.format("Mark both subtitles first with %s and %s.", opts.key_mark_first, opts.key_mark_second))
		return
	end

	local diff = second_ts - first_ts

	local report = string.format(
		"Subtitle difference:\n"
			.. "First start:  %.3f sec\n"
			.. "Second start: %.3f sec\n\n"
			.. "Difference: %+.3f sec",
		first_ts,
		second_ts,
		diff
	)
	notify(report)
end)
