local first_ts = nil
local second_ts = nil

local function msg(text)
	mp.osd_message(text, 2)
	print("[submarkdiff] " .. text)
end

local function get_sub_start()
	local v = mp.get_property_number("sub-start")
	if v == nil then
		msg("No subtitle is currently displayed.")
		return nil
	end
	return v
end

mp.add_key_binding("Ctrl+1", "mark_first_sub", function()
	local t = get_sub_start()
	if not t then
		return
	end

	first_ts = t
	msg(string.format("First subtitle start time: %.3f seconds", t))
end)

mp.add_key_binding("Ctrl+2", "mark_second_sub", function()
	local t = get_sub_start()
	if not t then
		return
	end

	second_ts = t
	msg(string.format("Second subtitle start time: %.3f seconds", t))
end)

mp.add_key_binding("Ctrl+3", "calculate_difference", function()
	if not first_ts or not second_ts then
		msg("Mark both subtitles first with Ctrl+1 and Ctrl+2.")
		return
	end

	local diff = second_ts - first_ts
	local sign = diff >= 0 and "+" or "-"

	msg(
		string.format(
			"Subtitle difference:\n"
				.. "First start:  %.3f sec\n"
				.. "Second start: %.3f sec\n\n"
				.. "Difference: %s%.3f sec",
			first_ts,
			second_ts,
			sign,
			math.abs(diff)
		)
	)
end)
