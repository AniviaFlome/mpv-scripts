local mp = require("mp")
local utils = require("mp.utils")
local util = require("util")
local cache = require("cache")

local M = {}

local opts = nil
local req_seq = 0
local NEUTRAL_UA = "mpv-subtitle-translate/1.0"
local BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0"
local TURENG_MAX_LINES = 8

function M.init(o)
	opts = o
end

function M.cancel_requests() end

local function http_request(def, cb)
	req_seq = req_seq + 1
	local seq = req_seq
	local args = { "curl", "-sS", "--compressed", "--max-time", "10", "-A", def.ua or NEUTRAL_UA }
	if def.headers then
		for _, header in ipairs(def.headers) do
			args[#args + 1] = "-H"
			args[#args + 1] = header
		end
	end
	if def.body then
		args[#args + 1] = "--data-binary"
		args[#args + 1] = def.body
	end
	args[#args + 1] = def.url
	if opts.verbose then
		util.log("request [" .. seq .. "] " .. (def.method_label or def.url))
	end
	mp.command_native_async({
		name = "subprocess",
		args = args,
		capture_stdout = true,
		capture_stderr = true,
		playback_only = false,
	}, function(success, result, err)
		if not success or not result or result.status ~= 0 then
			local detail = err
				or (result and result.stderr and util.trim(result.stderr))
				or (result and result.status and ("curl exited with status " .. tostring(result.status)))
				or "request failed"
			cb(nil, detail)
			return
		end
		cb(result.stdout)
	end)
end

local providers = {}

local function parse_google(body)
	local data = utils.parse_json(body)
	if not data then
		return nil, "invalid response from google"
	end
	local parts = {}
	if data.sentences then
		for _, s in ipairs(data.sentences) do
			if type(s.trans) == "string" then
				parts[#parts + 1] = s.trans
			end
		end
	end
	local sentence = table.concat(parts)
	local groups
	if data.dict then
		groups = {}
		for _, g in ipairs(data.dict) do
			if type(g.pos) == "string" and type(g.terms) == "table" then
				local terms = {}
				for _, t in ipairs(g.terms) do
					if type(t) == "string" and t ~= "" then
						terms[#terms + 1] = t
					end
				end
				groups[#groups + 1] = { pos = g.pos, terms = terms }
			end
		end
		if #groups == 0 then
			groups = nil
		end
	end
	if sentence == "" and not groups then
		return nil, "google returned no translation"
	end
	return { main = sentence ~= "" and sentence or nil, groups = groups }
end

local function google_url(text, dict)
	return "https://translate.googleapis.com/translate_a/single?client=gtx&sl="
		.. util.url_encode(opts.lang_from)
		.. "&tl="
		.. util.url_encode(opts.lang_to)
		.. "&dj=1&dt=t"
		.. (dict and "&dt=bd" or "")
		.. "&q="
		.. util.url_encode(text)
end

providers.google = {
	sentence = function(text, cb)
		http_request({ url = google_url(text, false) }, function(body, err)
			if not body then
				cb(nil, err)
				return
			end
			local res, perr = parse_google(body)
			cb(res and res.main, perr or err)
		end)
	end,
	word = function(word, cb)
		http_request({ url = google_url(word, true) }, function(body, err)
			if not body then
				cb(nil, err)
				return
			end
			local res, perr = parse_google(body)
			cb(res, perr or err)
		end)
	end,
}

local function parse_lingva(body)
	local data = utils.parse_json(body)
	if not data then
		return nil, "invalid response from lingva"
	end
	if data.error or type(data.translation) ~= "string" then
		return nil, "lingva instance failed — try another via lingva_instance"
	end
	return data.translation
end

providers.lingva = {
	sentence = function(text, cb)
		local inst = opts.lingva_instance:gsub("/+$", "")
		local url = inst
			.. "/api/v1/"
			.. util.url_encode(opts.lang_from)
			.. "/"
			.. util.url_encode(opts.lang_to)
			.. "/"
			.. util.url_encode(text)
		http_request({ url = url }, function(body, err)
			if not body then
				cb(nil, err)
				return
			end
			local res, perr = parse_lingva(body)
			cb(res, perr or err)
		end)
	end,
}

local function parse_mymemory(body)
	local data = utils.parse_json(body)
	if not data then
		return nil, "invalid response from mymemory"
	end
	local text = data.responseData and data.responseData.translatedText
	if type(text) ~= "string" or text == "" then
		return nil, "mymemory returned no translation"
	end
	if text:find("MYMEMORY WARNING") or text:find("QUERY LENGTH LIMIT") then
		return nil, "mymemory quota exceeded"
	end
	if data.responseStatus ~= 200 then
		return nil, "mymemory error " .. tostring(data.responseStatus)
	end
	return text
end

providers.mymemory = {
	sentence = function(text, cb)
		local q = text:len() > 480 and text:sub(1, 480) or text
		local url = "https://api.mymemory.translated.net/get?q="
			.. util.url_encode(q)
			.. "&langpair="
			.. util.url_encode(opts.lang_from .. "|" .. opts.lang_to)
		if opts.mymemory_email ~= "" then
			url = url .. "&de=" .. util.url_encode(opts.mymemory_email)
		end
		http_request({ url = url }, function(body, err)
			if not body then
				cb(nil, err)
				return
			end
			local res, perr = parse_mymemory(body)
			cb(res, perr or err)
		end)
	end,
}

local function parse_libretranslate(body)
	local data = utils.parse_json(body)
	if not data then
		return nil, "invalid response from libretranslate"
	end
	if data.error then
		return nil,
			"libretranslate: "
				.. tostring(data.error)
				.. " (public instances need a key — set libretranslate_url to a self-hosted instance)"
	end
	if type(data.translatedText) ~= "string" then
		return nil, "libretranslate returned no translation"
	end
	return data.translatedText
end

providers.libretranslate = {
	sentence = function(text, cb)
		local url = opts.libretranslate_url:gsub("/+$", "") .. "/translate"
		local body = "q="
			.. util.url_encode(text)
			.. "&source="
			.. util.url_encode(opts.lang_from)
			.. "&target="
			.. util.url_encode(opts.lang_to)
			.. "&format=text"
		if opts.libretranslate_api_key ~= "" then
			body = body .. "&apikey=" .. util.url_encode(opts.libretranslate_api_key)
		end
		http_request({
			url = url,
			method_label = "POST libretranslate",
			headers = { "Content-Type: application/x-www-form-urlencoded" },
			body = body,
		}, function(resp, err)
			if not resp then
				cb(nil, err)
				return
			end
			cb(parse_libretranslate(resp))
		end)
	end,
}

local function parse_deepl(body)
	local data = utils.parse_json(body)
	if not data then
		return nil, "invalid response from deepl"
	end
	if data.message then
		return nil, "deepl: " .. tostring(data.message)
	end
	if not data.translations or not data.translations[1] or type(data.translations[1].text) ~= "string" then
		return nil, "deepl returned no translation"
	end
	return data.translations[1].text
end

local function json_quote(s)
	return util.json_quote(s)
end

providers.deepl = {
	sentence = function(text, cb)
		if opts.deepl_api_key == "" then
			cb(nil, "deepl needs a free API key (deepl.com/pro-api) — set deepl_api_key")
			return
		end
		local host = opts.deepl_free and "https://api-free.deepl.com" or "https://api.deepl.com"
		local body = '{"text":[' .. json_quote(text) .. '],"target_lang":"' .. opts.lang_to:upper() .. '"'
		if opts.lang_from ~= "" and opts.lang_from ~= "auto" then
			body = body .. ',"source_lang":"' .. opts.lang_from:upper() .. '"'
		end
		body = body .. "}"
		http_request({
			url = host .. "/v2/translate",
			method_label = "POST deepl",
			headers = {
				"Authorization: DeepL-Auth-Key " .. opts.deepl_api_key,
				"Content-Type: application/json",
			},
			body = body,
		}, function(resp, err)
			if not resp then
				cb(nil, err)
				return
			end
			cb(parse_deepl(resp))
		end)
	end,
}

local function parse_tureng(body)
	local entries = {}
	local seen = {}
	for row in body:gmatch("<tr[^>]->(.-)</tr>") do
		local raw_cells = {}
		for cell in row:gmatch("<td[^>]->(.-)</td>") do
			raw_cells[#raw_cells + 1] = cell
		end
		if #raw_cells >= 4 then
			local cat = util.html_unescape(util.html_unescape(util.strip_tags(raw_cells[2])))
			local typ = raw_cells[3]:match("<i[^>]*>(.-)</i>")
			typ = typ and util.trim(util.html_unescape(util.html_unescape(util.strip_tags(typ)))) or ""
			local term_src = raw_cells[4]:match("<a[^>]->(.-)</a>") or raw_cells[4]
			local term = util.html_unescape(util.html_unescape(util.strip_tags(term_src)))
			local key = term .. "|" .. typ .. "|" .. cat
			if term ~= "" and not seen[key] and not term:match("^[%d%s.,%-]+$") then
				seen[key] = true
				entries[#entries + 1] = { cat = cat, typ = typ, term = term }
				if #entries >= 24 then
					break
				end
			end
		end
	end
	if #entries == 0 then
		return nil, "tureng returned no results"
	end
	return { entries = entries }
end

providers.tureng = {
	word = function(word, cb)
		local url = "https://tureng.com/en/turkish-english/" .. util.url_encode(word)
		http_request({ url = url, ua = BROWSER_UA }, function(body, err)
			if not body then
				cb(nil, err)
				return
			end
			local res, perr = parse_tureng(body)
			if not res then
				cb(nil, perr)
				return
			end
			local lines = {}
			for i, entry in ipairs(res.entries) do
				local suffix = ""
				if entry.typ ~= "" then
					suffix = " (" .. entry.typ .. ")"
				end
				if entry.cat ~= "" then
					suffix = suffix .. " " .. entry.cat
				end
				lines[i] = entry.term .. suffix
			end
			cb({ lines = lines })
		end)
	end,
}

function M.get(name)
	return providers[name]
end

local lookup_word_via
lookup_word_via = function(source, word, cb)
	local wp = providers[source]
	if not wp or not wp.word then
		cb(source, nil, source .. " has no word dictionary")
		return
	end
	local key = "wordprov|" .. source .. "|" .. opts.lang_from .. ">" .. opts.lang_to .. "|" .. word
	local cached = cache.get_by_key(key)
	if cached ~= nil then
		if opts.verbose then
			util.log("cache hit: wordprov " .. source)
		end
		mp.add_timeout(0, function()
			cb(source, cached)
		end)
		return
	end
	wp.word(word, function(res, err)
		if res then
			cache.store_by_key(key, res)
		end
		cb(source, res, err)
	end)
end

function M.lookup_word(word, cb)
	local source = util.trim(opts.word_provider or "")
	if source == "" then
		cb(nil, nil, "word_provider is empty")
		return
	end
	if source:find(",", 1, true) then
		cb(nil, nil, "word_provider must name exactly one dictionary")
		return
	end
	lookup_word_via(source, word, cb)
end

function M.lookup(kind, text, cb)
	local provider = providers[opts.provider]
	if not provider then
		cb(nil, "unknown provider '" .. tostring(opts.provider) .. "'")
		return
	end
	local key = cache.lookup_cache_key(kind, text)
	local cached = cache.get(kind, text)
	if cached ~= nil then
		if opts.verbose then
			util.log("cache hit: " .. kind)
		end
		mp.add_timeout(0, function()
			cb(cached)
		end)
		return
	end
	if kind == "word" and not provider.word then
		provider.sentence(text, function(res, err)
			if res then
				res = { main = res }
				cache.store(key, res)
				cb(res)
			else
				cb(nil, err)
			end
		end)
		return
	end
	local fn = kind == "word" and provider.word or provider.sentence
	fn(text, function(res, err)
		if res then
			cache.store(key, res)
			cb(res)
		else
			cb(nil, err)
		end
	end)
end

M.parse = {
	google = parse_google,
	lingva = parse_lingva,
	mymemory = parse_mymemory,
	libretranslate = parse_libretranslate,
	deepl = parse_deepl,
	tureng = parse_tureng,
}

-- word backends: cambridge / wiktionary / reverso -----------------------------

local CAMBRIDGE_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0"

local function strip_ws(s)
	return util.trim((s:gsub("%s+", " ")))
end

local function parse_cambridge(html)
	local groups = {}
	local cur = nil
	for pos, tr in
		html:gmatch('<span class="pos dpos[^"]*"[^>]*>([^<]+)</span>.-<span class="trans dtrans[^"]*"[^>]*>(.-)</span>')
	do
		pos = util.trim(util.strip_tags(pos))
		tr = util.strip_tags(tr)
		if cur and cur.pos == pos then
			cur.terms[#cur.terms + 1] = tr
		else
			cur = { pos = pos, terms = { tr } }
			groups[#groups + 1] = cur
		end
	end
	local ipa = html:match('<span class="ipa dipa[^"]*"[^>]*>([^<]+)</span>')
	if #groups == 0 and not ipa then
		return nil
	end
	return { groups = groups, ipa = ipa }
end

local function parse_wiktionary(body)
	local data = utils.parse_json(body)
	if type(data) ~= "table" then
		return nil
	end
	local lines = {}
	for lang_key, entries in pairs(data) do
		if lang_key == opts.lang_from then
			for _, entry in ipairs(entries) do
				for _, def in ipairs(entry.definitions or {}) do
					local d = util.strip_tags(def.definition or "")
					if d ~= "" then
						lines[#lines + 1] = d
					end
				end
			end
		end
	end
	if #lines == 0 then
		return nil
	end
	return { lines = lines }
end

local function parse_reverso(html)
	local pairs_out = {}
	for src, trg in html:gmatch('<div class="src ltr">(.-)</div>.-<div class="trg ltr">(.-)</div>') do
		src = util.strip_tags(src)
		trg = util.strip_tags(trg)
		if src ~= "" and trg ~= "" then
			pairs_out[#pairs_out + 1] = src .. " — " .. trg
		end
		if #pairs_out >= 6 then
			break
		end
	end
	if #pairs_out == 0 then
		return nil
	end
	return { lines = pairs_out }
end

local function cambridge_dir(lang)
	if lang == "tr" then
		return "turkish-english"
	end
	return "english-turkish"
end

local function cambridge_word(word, cb)
	local lang = opts.lang_from
	local dir = (lang == "tr") and "turkish-english" or "english-turkish"
	local url = "https://dictionary.cambridge.org/dictionary/" .. dir .. "/" .. util.url_encode(word)
	http_request({
		url = url,
		ua = CAMBRIDGE_UA,
	}, function(body, err)
		if not body then
			cb(nil, err)
			return
		end
		local res = parse_cambridge(body)
		if not res then
			cb(nil, "cambridge: no entry for '" .. word .. "'")
			return
		end
		local groups = {}
		for _, g in ipairs(res.groups) do
			groups[#groups + 1] = { pos = g.pos, terms = g.terms }
		end
		cb({ main = nil, groups = groups, ipa = res.ipa })
	end)
end

local function wiktionary_word(word, cb)
	local url = "https://en.wiktionary.org/api/rest_v1/page/definition/" .. util.url_encode(word)
	http_request({ url = url }, function(body, err)
		if not body then
			cb(nil, err)
			return
		end
		local res = parse_wiktionary(body)
		if not res then
			cb(nil, "wiktionary: no entry for '" .. word .. "'")
			return
		end
		cb(res)
	end)
end

local function reverso_word(word, cb)
	local pair = opts.lang_from .. "-" .. opts.lang_to
	local url = "https://context.reverso.net/translation/" .. pair .. "/" .. util.url_encode(word)
	http_request({
		url = url,
		ua = CAMBRIDGE_UA,
	}, function(body, err)
		if not body then
			cb(nil, err)
			return
		end
		local pairs_out = {}
		for src, trg in body:gmatch('<div class="src ltr">(.-)</div>.-<div class="trg ltr">(.-)</div>') do
			src = util.strip_tags(src)
			trg = util.strip_tags(trg)
			if src ~= "" and trg ~= "" then
				pairs_out[#pairs_out + 1] = src .. " — " .. trg
			end
			if #pairs_out >= 6 then
				break
			end
		end
		if #pairs_out == 0 then
			cb(nil, "reverso: no results for '" .. word .. "'")
			return
		end
		cb({ lines = pairs_out })
	end)
end

providers.cambridge = { word = cambridge_word }
providers.wiktionary = { word = wiktionary_word }
providers.reverso = { word = reverso_word }

M.parse.cambridge = parse_cambridge
M.parse.wiktionary = parse_wiktionary
M.parse.reverso = parse_reverso

return M
