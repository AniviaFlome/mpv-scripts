local mp = require("mp")
local utils = require("mp.utils")
local util = require("util")

local M = {}

local opts = nil

M.backends = {}

function M.register_backend(name, def)
	if type(name) ~= "string" or name == "" then
		util.log("ocr: register_backend needs a name")
		return false
	end
	if type(def) ~= "table" or type(def.recognize) ~= "function" then
		util.log("ocr: backend '" .. name .. "' needs a recognize(image_path, cb) function")
		return false
	end
	def.name = name
	if not def.label then
		def.label = name
	end
	M.backends[name] = def
	return true
end

function M.get_backend(name)
	return M.backends[name or (opts and opts.ocr_backend)]
end

function M.list_backends()
	local out = {}
	for name in pairs(M.backends) do
		out[#out + 1] = name
	end
	table.sort(out)
	return out
end

local function log(text)
	if opts and opts.verbose then
		util.log(text)
	end
end

-- cached PATH lookups
local bin_cache = {}

local function bin_available(bin)
	if bin_cache[bin] ~= nil then
		return bin_cache[bin]
	end
	local res = mp.command_native({
		name = "subprocess",
		args = { "sh", "-c", "command -v " .. bin },
		capture_stdout = true,
		playback_only = false,
	})
	local ok = res and res.status == 0 and util.trim(res.stdout or "") ~= ""
	bin_cache[bin] = ok
	return ok
end

local function tesseract_bin()
	local bin = opts and util.trim(opts.ocr_tesseract_bin or "") or ""
	if bin == "" then
		bin = "tesseract"
	end
	return bin
end

local function ffmpeg_bin()
	local bin = opts and util.trim(opts.ocr_ffmpeg_bin or "") or ""
	if bin == "" then
		bin = "ffmpeg"
	end
	return bin
end

local st = {
	busy = false,
	seq = 0,
	last_run = 0,
	ffmpeg = nil, -- nil=unknown, false=missing, string=path
	tmp_seq = 0,
}

function M.init(o)
	opts = o
end

function M.reset()
	st.seq = st.seq + 1
	st.busy = false
	st.last_run = 0
end

function M.is_busy()
	return st.busy
end

local TESS_LANGS = {
	en = "eng",
	tr = "tur",
	de = "deu",
	fr = "fra",
	es = "spa",
	it = "ita",
	pt = "por",
	ru = "rus",
	uk = "ukr",
	ja = "jpn",
	zh = "chi_sim",
	ko = "kor",
	ar = "ara",
	fa = "fas",
	hi = "hin",
	nl = "nld",
	pl = "pol",
	vi = "vie",
	th = "tha",
	id = "ind",
	el = "ell",
	he = "heb",
}

local function ocr_lang_tesseract()
	if opts.ocr_lang and util.trim(opts.ocr_lang) ~= "" then
		return util.trim(opts.ocr_lang)
	end
	local from = util.trim(opts.lang_from or "en")
	if not TESS_LANGS[from] then
		log("ocr: no tesseract mapping for '" .. from .. "', passing through — set ocr_lang if tesseract rejects it")
	end
	return TESS_LANGS[from] or from
end

local function tmp_path(suffix)
	st.tmp_seq = st.tmp_seq + 1
	local dir = os.getenv("TMPDIR")
	if type(dir) ~= "string" or dir == "" then
		dir = "/tmp"
	end
	dir = dir:gsub("/+$", "")
	return string.format("%s/mpv-ocr-%d-%d%s", dir, math.floor(mp.get_time() * 1000) % 1000000, st.tmp_seq, suffix)
end

local function find_ffmpeg()
	if st.ffmpeg ~= nil then
		return st.ffmpeg or nil
	end
	local bin = ffmpeg_bin()
	if not bin_available(bin) then
		log("ocr: ffmpeg binary '" .. bin .. "' not in PATH, using full frame (set ocr_ffmpeg_bin)")
		st.ffmpeg = false
		return nil
	end
	st.ffmpeg = bin
	return bin
end

local function has_video()
	local path = mp.get_property("path")
	if not path or path == "" then
		return false
	end
	return true
end

local function capture_frame(out_path)
	if not has_video() then
		return false, "no video loaded"
	end
	local ok, err = pcall(function()
		mp.commandv("screenshot-to-file", out_path, "video")
	end)
	if not ok then
		return false, "screenshot failed: " .. tostring(err)
	end
	local f = io.open(out_path, "r")
	if not f then
		return false, "screenshot produced no file (vo may not support it)"
	end
	f:close()
	return true
end

local function preprocess(full_path, cb)
	local ffmpeg = find_ffmpeg()
	if not ffmpeg then
		log("ocr: ffmpeg not found, using full frame")
		cb(full_path)
		return
	end
	local crop_h = tonumber(opts.ocr_crop_h) or 0.25
	if crop_h <= 0 or crop_h > 1 then
		crop_h = 0.25
	end
	local scale = tonumber(opts.ocr_scale) or 2
	if scale < 1 or scale > 4 then
		scale = 2
	end
	local out = tmp_path("-crop.png")
	local vf = string.format("crop=iw:ih*%f:0:ih*(1-%f),scale=iw*%d:ih*%d,format=gray", crop_h, crop_h, scale, scale)
	if opts.ocr_sharpen ~= false then
		vf = vf .. ",unsharp=5:5:1.0:5:5:0.0"
	end
	mp.command_native_async({
		name = "subprocess",
		args = { ffmpeg, "-y", "-v", "error", "-i", full_path, "-vf", vf, out },
		capture_stdout = true,
		capture_stderr = true,
		playback_only = false,
	}, function(success, result)
		if success and result and result.status == 0 then
			local f = io.open(out, "r")
			if f then
				f:close()
				os.remove(full_path)
				cb(out)
				return
			end
		end
		log("ocr: ffmpeg crop failed, using full frame")
		cb(full_path)
	end)
end

local function cleanup(path)
	if path and path:match("^/tmp/mpv%-ocr%-") or (path and path:match("mpv%-ocr%-")) then
		os.remove(path)
	end
end

function M.cleanup_file(path)
	cleanup(path)
end

-- CJK punctuation excluded from the letter count
local NON_LETTER_MB = {
	["。"] = true,
	["、"] = true,
	["！"] = true,
	["？"] = true,
	["「"] = true,
	["」"] = true,
	["『"] = true,
	["』"] = true,
	["（"] = true,
	["）"] = true,
	["："] = true,
	["；"] = true,
	["，"] = true,
	["．"] = true,
	["・"] = true,
	["…"] = true,
	["—"] = true,
	["–"] = true,
	["〈"] = true,
	["〉"] = true,
	["《"] = true,
	["》"] = true,
	["　"] = true,
}

local function alpha_ratio(text)
	local total, alpha = 0, 0
	local i, n = 1, #text
	while i <= n do
		local b = text:byte(i)
		local len = 1
		if b >= 0xF0 then
			len = 4
		elseif b >= 0xE0 then
			len = 3
		elseif b >= 0xC2 then
			len = 2
		end
		if not (len == 1 and (b <= 0x20 or b == 0x7F)) then
			total = total + 1
			local ch = text:sub(i, i + len - 1)
			if len > 1 then
				if not NON_LETTER_MB[ch] then
					alpha = alpha + 1
				end
			elseif ch:match("[%w]") then
				alpha = alpha + 1
			end
		end
		i = i + len
	end
	if total == 0 then
		return 0
	end
	return alpha / total
end

function M.normalize_text(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local text = util.clean_subtitle_text(raw)
	text = text:gsub("%s+", " ")
	text = util.trim(text)
	if text == "" then
		return nil
	end
	local min_chars = tonumber(opts.ocr_min_chars) or 2
	local max_chars = tonumber(opts.ocr_max_chars) or 200
	if #text < min_chars or #text > max_chars then
		return nil
	end
	if text:match("^[%d%p%s]+$") then
		return nil
	end
	local min_alpha = tonumber(opts.ocr_min_alpha_ratio)
	if min_alpha == nil then
		min_alpha = 0.5
	end
	if min_alpha > 0 and alpha_ratio(text) < min_alpha then
		return nil
	end
	return text
end

-- backends

M.register_backend("tesseract", {
	label = "Tesseract (CLI)",
	recognize = function(image_path, cb)
		local bin = tesseract_bin()
		if not bin_available(bin) then
			cb(
				nil,
				"tesseract binary '"
					.. bin
					.. "' not found in PATH — run mpv from nix-shell (tesseract is in shell.nix) "
					.. "or set ocr_tesseract_bin to its absolute path"
			)
			return
		end
		local lang = ocr_lang_tesseract()
		local psm = tonumber(opts.ocr_psm) or 6
		local oem = tonumber(opts.ocr_oem) or 1
		local args = { bin, image_path, "stdout", "-l", lang, "--oem", tostring(oem), "--psm", tostring(psm) }
		for item in (opts.ocr_tessconfig or ""):gmatch("%S+") do
			args[#args + 1] = "-c"
			args[#args + 1] = item
		end
		if opts.ocr_blacklist and util.trim(opts.ocr_blacklist) ~= "" then
			args[#args + 1] = "-c"
			args[#args + 1] = "tessedit_char_blacklist=" .. util.trim(opts.ocr_blacklist)
		end
		mp.command_native_async({
			name = "subprocess",
			args = args,
			capture_stdout = true,
			capture_stderr = true,
			playback_only = false,
		}, function(success, result, err)
			if not success or not result or result.status ~= 0 then
				local detail = util.trim((result and result.stderr) or err or "")
				if detail == "" then
					detail = "could not start '"
						.. bin
						.. "' (removed from PATH after startup?) — run mpv from nix-shell or set ocr_tesseract_bin"
				elseif detail:find("Error opening data file", 1, true) then
					detail = "tesseract language data missing for '" .. lang .. "' (tesseract --list-langs)"
				end
				cb(nil, detail)
				return
			end
			cb(M.normalize_text(result.stdout or ""))
		end)
	end,
	check = function()
		return bin_available(tesseract_bin())
	end,
})

M.register_backend("custom", {
	label = "Custom command (opts.ocr_command)",
	recognize = function(image_path, cb)
		local tpl = util.trim(opts.ocr_command or "")
		if tpl == "" then
			cb(nil, "ocr_command is empty (set it to use backend=custom)")
			return
		end
		local cmd = tpl:gsub("{image}", image_path):gsub("{lang}", ocr_lang_tesseract())
		mp.command_native_async({
			name = "subprocess",
			args = { "sh", "-c", cmd },
			capture_stdout = true,
			capture_stderr = true,
			playback_only = false,
		}, function(success, result, err)
			if not success or not result or result.status ~= 0 then
				local detail = util.trim((result and result.stderr) or err or "")
				if detail == "" then
					detail = "custom ocr command failed to start (check ocr_command)"
				end
				cb(nil, detail)
				return
			end
			cb(M.normalize_text(result.stdout or ""))
		end)
	end,
})

local function python_one_shot(python_code, image_path, missing_hint, cb)
	local bin = "python3" -- on PATH: nix-shell env python, venv, or system
	if not bin_available(bin) then
		cb(nil, "python3 not found in PATH")
		return
	end
	mp.command_native_async({
		name = "subprocess",
		args = { bin, "-c", python_code, image_path },
		capture_stdout = true,
		capture_stderr = true,
		playback_only = false,
	}, function(success, result, err)
		if not success or not result or result.status ~= 0 then
			local detail = (result and result.stderr and util.trim(result.stderr) or err or "")
			if detail:find("ModuleNotFoundError", 1, true) or detail:find("No module named", 1, true) then
				cb(nil, missing_hint)
				return
			end
			if detail == "" then
				detail = "could not start 'python3' (removed from PATH after startup?)"
			elseif #detail > 300 then
				-- frameworks warn noisily first; the real error is last
				detail = "…" .. detail:sub(-300)
			end
			cb(nil, detail)
			return
		end
		cb(M.normalize_text(result.stdout or ""))
	end)
end

local EASYOCR_LANGS = {
	zh = "ch_sim",
}

local PADDLE_LANGS = {
	zh = "ch",
	ja = "japan",
	ko = "korean",
}

local BAIDU_LANGS = {
	en = "ENG",
	zh = "CHN_ENG",
	ja = "JAP",
	ko = "KOR",
	ru = "RUS",
	de = "GER",
	fr = "FRE",
	es = "SPA",
	it = "ITA",
	pt = "POR",
	-- Baidu general OCR has no Turkish model; latin script reads as English
	tr = "ENG",
}

local function ocr_lang_for(map, label)
	if opts.ocr_lang and util.trim(opts.ocr_lang) ~= "" then
		return util.trim(opts.ocr_lang)
	end
	local from = util.trim(opts.lang_from or "en")
	if map[from] then
		return map[from]
	end
	log(
		"ocr: no "
			.. tostring(label or "backend")
			.. " mapping for '"
			.. from
			.. "', passing it through — set ocr_lang if the engine rejects it"
	)
	return from
end

-- engine language for a backend; nil means auto
function M.backend_lang(name)
	name = name or (opts and opts.ocr_backend)
	if name == "tesseract" or name == "custom" then
		return ocr_lang_tesseract()
	elseif name == "easyocr" then
		return ocr_lang_for(EASYOCR_LANGS, "easyocr")
	elseif name == "paddleocr" then
		return ocr_lang_for(PADDLE_LANGS, "paddleocr")
	elseif name == "baiduocr" then
		return ocr_lang_for(BAIDU_LANGS, "baiduocr"):upper()
	end
	return nil
end

M.register_backend("rapidocr", {
	label = "RapidOCR",
	recognize = function(image_path, cb)
		python_one_shot(
			"import sys;from rapidocr_onnxruntime import RapidOCR;e=RapidOCR();r,_=e(sys.argv[1]);"
				.. "print(' '.join([t[1] for t in (r or []) if len(t)>1 and t[1]]))",
			image_path,
			"rapidocr not installed (needs python package 'rapidocr_onnxruntime')",
			cb
		)
	end,
})

M.register_backend("easyocr", {
	label = "EasyOCR",
	recognize = function(image_path, cb)
		local lang = ocr_lang_for(EASYOCR_LANGS, "easyocr")
		local gpu = opts.ocr_cuda and "True" or "False"
		python_one_shot(
			"import sys;import easyocr;r=easyocr.Reader(['"
				.. lang
				.. "'],gpu="
				.. gpu
				.. ",quantize=True);"
				.. "print(' '.join(r.readtext(sys.argv[1],detail=0)))",
			image_path,
			"easyocr not installed (needs python package 'easyocr' plus torch, ~500MB+)",
			cb
		)
	end,
})

M.register_backend("paddleocr", {
	label = "PaddleOCR",
	recognize = function(image_path, cb)
		local lang = ocr_lang_for(PADDLE_LANGS, "paddleocr")
		python_one_shot(
			"import sys;from paddleocr import PaddleOCR;e=PaddleOCR(lang='"
				.. lang
				.. "',use_doc_orientation_classify=False,use_doc_unwarping=False,use_textline_orientation=False);"
				.. "r=e.predict(sys.argv[1]);"
				.. "print(' '.join([t for res in (r or []) for t in res.get('rec_texts',[])]))",
			image_path,
			"paddleocr not installed (needs python packages 'paddleocr' + 'paddlepaddle'; "
				.. "lang codes vary by version — override with ocr_lang)",
			function(text, err)
				if err then
					local low = err:lower()
					if low:find("onednn", 1, true) or low:find("convertpirattribute", 1, true) then
						err = err
							.. " [CPU oneDNN bug in this paddlepaddle build — use ocr_backend=rapidocr on CPU, "
							.. "or a GPU build for paddleocr]"
					end
					cb(nil, err)
					return
				end
				cb(text)
			end
		)
	end,
})

-- Baidu AI Cloud general OCR. Needs an account + app keys
local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		b = b or 0
		c = c or 0
		local n = a * 65536 + b * 256 + c
		local remain = #data - i + 1
		out[#out + 1] = B64CHARS:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
			.. B64CHARS:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
			.. (remain > 1 and B64CHARS:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
			.. (remain > 2 and B64CHARS:sub(n % 64 + 1, n % 64 + 1) or "=")
	end
	return table.concat(out)
end

local baidu_token = { value = nil, exp = 0 }

local function baidu_get_token(cb)
	if baidu_token.value and mp.get_time() < baidu_token.exp - 60 then
		cb(baidu_token.value)
		return
	end
	local ak = util.trim(opts.baiduocr_api_key or "")
	local sk = util.trim(opts.baiduocr_secret_key or "")
	if ak == "" or sk == "" then
		cb(nil, "baiduocr needs an API Key and Secret Key — set baiduocr_api_key / baiduocr_secret_key")
		return
	end
	local url = "https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id="
		.. util.url_encode(ak)
		.. "&client_secret="
		.. util.url_encode(sk)
	mp.command_native_async({
		name = "subprocess",
		args = { "curl", "-sS", "-L", "--compressed", "--max-time", "10", url },
		capture_stdout = true,
		capture_stderr = true,
		playback_only = false,
	}, function(success, result, err)
		if not success or not result or result.status ~= 0 then
			cb(nil, util.trim((result and result.stderr) or err or "baidu token request failed"))
			return
		end
		local data = utils.parse_json(result.stdout or "")
		if not data or type(data.access_token) ~= "string" then
			local msg = data and (data.error_description or data.error) or "invalid token response"
			cb(nil, "baidu token failed: " .. tostring(msg))
			return
		end
		baidu_token.value = data.access_token
		baidu_token.exp = mp.get_time() + (tonumber(data.expires_in) or 2592000)
		cb(baidu_token.value)
	end)
end

-- returns text, err, bad_token
local function baidu_parse_ocr(body)
	local data = utils.parse_json(body or "")
	if not data then
		return nil, "invalid response from baiduocr", false
	end
	if data.error_code then
		local code = tonumber(data.error_code) or 0
		local msg = tostring(data.error_msg or "unknown error")
		if code == 110 or code == 111 then
			return nil, "baiduocr: invalid access token (" .. msg .. ")", true
		end
		if code == 18 or code == 19 then
			return nil, "baiduocr quota exceeded (rate limit, code " .. code .. ")", false
		end
		return nil, "baiduocr: " .. msg .. " (code " .. code .. ")", false
	end
	if type(data.words_result) ~= "table" or #data.words_result == 0 then
		return nil, nil, false
	end
	local lines = {}
	for _, w in ipairs(data.words_result) do
		if type(w) == "table" and type(w.words) == "string" and w.words ~= "" then
			lines[#lines + 1] = w.words
		end
	end
	if #lines == 0 then
		return nil, nil, false
	end
	return table.concat(lines, "\n"), nil, false
end

M.register_backend("baiduocr", {
	label = "Baidu OCR",
	recognize = function(image_path, cb)
		local f = io.open(image_path, "rb")
		if not f then
			cb(nil, "baiduocr: cannot read capture")
			return
		end
		local raw = f:read("*a")
		f:close()
		if not raw or raw == "" then
			cb(nil, "baiduocr: empty capture")
			return
		end
		local b64 = base64_encode(raw)
		local lang = ocr_lang_for(BAIDU_LANGS, "baiduocr"):upper()
		local attempted = 0
		local function attempt()
			attempted = attempted + 1
			baidu_get_token(function(token, terr)
				if not token then
					cb(nil, terr)
					return
				end
				local body = "image=" .. util.url_encode(b64) .. "&language_type=" .. util.url_encode(lang)
				mp.command_native_async({
					name = "subprocess",
					args = {
						"curl",
						"-sS",
						"-L",
						"--compressed",
						"--max-time",
						"15",
						"-H",
						"Content-Type: application/x-www-form-urlencoded",
						"--data-raw",
						body,
						"https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic?access_token="
							.. util.url_encode(token),
					},
					capture_stdout = true,
					capture_stderr = true,
					playback_only = false,
				}, function(success, result, err)
					if not success or not result or result.status ~= 0 then
						cb(nil, util.trim((result and result.stderr) or err or "baidu ocr request failed"))
						return
					end
					local text, perr, bad_token = baidu_parse_ocr(result.stdout or "")
					if bad_token and attempted < 2 then
						baidu_token.value = nil
						baidu_token.exp = 0
						attempt()
						return
					end
					if perr then
						cb(nil, perr)
						return
					end
					cb(M.normalize_text(text or ""))
				end)
			end)
		end
		attempt()
	end,
})

-- capture pipeline shared by all backends

-- single capture, preprocess, recognize; nil text means no text found
function M.recognize_now(cb)
	if st.busy then
		cb(nil, nil, "ocr busy")
		return
	end
	local backend = M.get_backend()
	if not backend then
		cb(
			nil,
			nil,
			"unknown ocr_backend '"
				.. tostring(opts.ocr_backend)
				.. "' (available: "
				.. table.concat(M.list_backends(), ", ")
				.. ")"
		)
		return
	end
	st.busy = true
	st.seq = st.seq + 1
	local seq = st.seq
	local full = tmp_path("-full.png")
	local ok, cerr = capture_frame(full)
	if not ok then
		st.busy = false
		cb(nil, nil, cerr)
		return
	end
	preprocess(full, function(cropped)
		if seq ~= st.seq then
			cleanup(full)
			cleanup(cropped)
			return
		end
		log("ocr: recognizing with backend=" .. (backend.name or "?") .. " image=" .. cropped)
		local done = false
		backend.recognize(cropped, function(text, err)
			if done then
				return
			end
			done = true
			if seq ~= st.seq then
				cleanup(full)
				cleanup(cropped)
				return
			end
			st.busy = false
			st.last_run = mp.get_time()
			if err then
				log("ocr: backend error: " .. tostring(err))
				cleanup(full)
				cleanup(cropped)
				cb(nil, { backend = backend.name }, err)
				return
			end
			cleanup(full)
			cleanup(cropped)
			cb(text and text ~= "" and text or nil, { backend = backend.name })
		end)
	end)
end

function M.cancel()
	st.seq = st.seq + 1
	st.busy = false
end

return M
