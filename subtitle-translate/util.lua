local M = {}

function M.log(text)
	print("[subtitle-translate] " .. text)
end

function M.trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.url_encode(s)
	return (s:gsub("[^%w%-_.~]", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

function M.json_quote(s)
	return '"'
		.. s:gsub('[%c"\\]', function(c)
			if c == '"' then
				return '\\"'
			elseif c == "\\" then
				return "\\\\"
			elseif c == "\n" then
				return "\\n"
			elseif c == "\r" then
				return "\\r"
			elseif c == "\t" then
				return "\\t"
			else
				return string.format("\\u%04x", c:byte())
			end
		end)
		.. '"'
end

function M.json_serialize(v)
	local t = type(v)
	if t == "string" then
		return M.json_quote(v)
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local parts = {}
		if #v > 0 then
			for _, item in ipairs(v) do
				parts[#parts + 1] = M.json_serialize(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, item in pairs(v) do
			parts[#parts + 1] = M.json_quote(tostring(k)) .. ":" .. M.json_serialize(item)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return '""'
end

function M.utf8_chr(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
	end
	return string.char(
		0xF0 + math.floor(cp / 262144),
		0x80 + math.floor(cp / 4096) % 64,
		0x80 + math.floor(cp / 64) % 64,
		0x80 + cp % 64
	)
end

M.ENTITIES = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apost = "'",
	nbsp = " ",
	copy = M.utf8_chr(0xA9),
	reg = M.utf8_chr(0xAE),
	hellip = M.utf8_chr(0x2026),
	mdash = M.utf8_chr(0x2014),
	ndash = M.utf8_chr(0x2013),
	lsquo = M.utf8_chr(0x2018),
	rsquo = M.utf8_chr(0x2019),
	ldquo = M.utf8_chr(0x201C),
	rdquo = M.utf8_chr(0x201D),
	middot = M.utf8_chr(0xB7),
	eacute = M.utf8_chr(0xE9),
	egrave = M.utf8_chr(0xE8),
	ccedil = M.utf8_chr(0xE7),
}

function M.html_unescape(s)
	local out = s:gsub("&(#x?)(%x+);", function(prefix, digits)
		local cp = tonumber(digits, prefix == "#x" and 16 or 10)
		if cp and cp >= 32 and cp <= 1114111 then
			return M.utf8_chr(cp)
		end
		return "&" .. prefix .. digits .. ";"
	end)
	out = out:gsub("&(%w+);", function(name)
		return M.ENTITIES[name] or ("&" .. name .. ";")
	end)
	return out
end

function M.strip_tags(s)
	return M.trim((s:gsub("<[^>]*>", "")):gsub("%s+", " "))
end

function M.clean_subtitle_text(text)
	text = text:gsub("%{[^}]*%}", " ")
	text = text:gsub("\\[Nnh]", " ")
	return M.trim(M.strip_tags(M.html_unescape(text)))
end

function M.ass_escape(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub("{", "\\{"):gsub("}", "\\}")
	s = s:gsub("\n", "\\N")
	return s
end

function M.ass_color(rgb)
	if type(rgb) ~= "string" or rgb:len() ~= 6 or not rgb:match("^%x+$") then
		rgb = "ffffff"
	end
	local r = tonumber(rgb:sub(1, 2), 16)
	local g = tonumber(rgb:sub(3, 4), 16)
	local b = tonumber(rgb:sub(5, 6), 16)
	return string.format("&H%02X%02X%02X", b, g, r)
end

function M.ass_alpha(opacity_percent)
	local alpha = math.floor(255 * (100 - opacity_percent) / 100 + 0.5)
	if alpha < 0 then
		alpha = 0
	elseif alpha > 255 then
		alpha = 255
	end
	return string.format("&H%02X", alpha)
end

function M.scaled_font(size, h)
	return math.max(8, math.floor(size * h / 1080 + 0.5))
end

function M.parse_mpv_color(value, fallback)
	if type(value) ~= "string" then
		return fallback, 0
	end
	local hex = value:match("^#(%x+)$")
	if not hex then
		return fallback, 0
	end
	local r, g, b, a
	if hex:len() == 8 then
		a = tonumber(hex:sub(1, 2), 16)
		r = tonumber(hex:sub(3, 4), 16)
		g = tonumber(hex:sub(5, 6), 16)
		b = tonumber(hex:sub(7, 8), 16)
	elseif hex:len() == 6 then
		a = 255
		r = tonumber(hex:sub(1, 2), 16)
		g = tonumber(hex:sub(3, 4), 16)
		b = tonumber(hex:sub(5, 6), 16)
	else
		return fallback, 0
	end
	return string.format("&H%02X%02X%02X", b, g, r), 255 - a
end

function M.split_csv(s)
	local out = {}
	local rest = s
	while true do
		local pos = rest:find(",")
		if not pos then
			out[#out + 1] = M.trim(rest)
			break
		end
		out[#out + 1] = M.trim(rest:sub(1, pos - 1))
		rest = rest:sub(pos + 1)
	end
	return out
end

local LATIN5_MAP = {
	[0xD0] = "\xC4\x9E",
	[0xDD] = "\xC4\xB0",
	[0xDE] = "\xC5\x9E",
	[0xF0] = "\xC4\x9F",
	[0xFD] = "\xC4\xB1",
	[0xFE] = "\xC5\x9F",
}

local function latin5_standalone(s, i)
	local b = s:byte(i)
	if not LATIN5_MAP[b] then
		return false
	end
	local nxt = s:byte(i + 1)
	return not nxt or nxt < 0x80 or nxt > 0xBF
end

function M.latin5_to_utf8(s)
	local out = {}
	local i = 1
	local n = #s
	while i <= n do
		if latin5_standalone(s, i) then
			out[#out + 1] = LATIN5_MAP[s:byte(i)]
			i = i + 1
		else
			out[#out + 1] = s:sub(i, i)
			i = i + 1
		end
	end
	return table.concat(out)
end

function M.normalize_sub(text)
	return M.trim((text:gsub("%s*\n%s*", " ")))
end

return M
