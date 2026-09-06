-- session-only settings menu
local mp = require("mp")
local util = require("util")

local M = {}

local opts = nil
local actions = {}
local input = nil

local PROVIDERS = { "mymemory", "google", "duckduckgo", "lingva", "libretranslate", "deepl" }
local WORD_PROVIDERS = { "tureng", "cambridge", "wiktionary", "reverso" }
local LANGS_FROM = { "en", "tr", "de", "fr", "es", "it", "ru", "ja", "zh", "ar", "auto" }
local LANGS_TO = { "en", "tr", "de", "fr", "es", "it", "ru", "ja", "zh", "ar" }
local POSITIONS = { "top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right" }
local HOVER_BACKENDS = { "replica", "native", "mirror" }
local CUSTOM_ITEM = "custom… (type it)"

local function notify(text, duration)
	if actions.notify then
		actions.notify(text, duration)
	else
		mp.osd_message("[subtitle-translate] " .. text, duration or 2)
	end
end

local function bool_label(v)
	return v and "yes" or "no"
end

local function index_of(list, value)
	for i, v in ipairs(list) do
		if v == value then
			return i
		end
	end
	return nil
end

local function apply(key, value, effect)
	opts[key] = value
	if effect and actions[effect] then
		actions[effect]()
	end
	notify(key .. " → " .. tostring(value))
	if opts.verbose then
		util.log("settings: " .. key .. " = " .. tostring(value) .. " (session-only)")
	end
end

local function open_choice(prompt, choices, current, on_pick)
	input.select({
		prompt = prompt,
		items = choices,
		default_item = index_of(choices, current) or 1,
		keep_open = true,
		submit = function(id)
			if choices[id] then
				on_pick(choices[id])
			else
				M.open()
			end
		end,
	})
end

local function toggle_bool(key, effect)
	apply(key, not opts[key], effect)
	M.open()
end

local function open_lang(prompt, key, presets)
	local choices = {}
	for _, lang in ipairs(presets) do
		choices[#choices + 1] = lang
	end
	choices[#choices + 1] = CUSTOM_ITEM
	open_choice(prompt, choices, tostring(opts[key]), function(pick)
		if pick == CUSTOM_ITEM then
			input.get({
				prompt = prompt,
				default_text = tostring(opts[key]),
				keep_open = true,
				submit = function(text)
					text = util.trim(text or "")
					if text ~= "" then
						apply(key, text, "retranslate")
					end
					M.open()
				end,
			})
		else
			apply(key, pick, "retranslate")
			M.open()
		end
	end)
end

local function open_section(id)
	if id == 1 then
		open_choice("Sentence provider:", PROVIDERS, opts.provider, function(pick)
			apply("provider", pick, "retranslate")
			M.open()
		end)
	elseif id == 2 then
		open_choice("Dictionary provider:", WORD_PROVIDERS, opts.word_provider, function(pick)
			apply("word_provider", pick, "rebuild_hover")
			M.open()
		end)
	elseif id == 3 then
		open_lang("Source language:", "lang_from", LANGS_FROM)
	elseif id == 4 then
		open_lang("Target language:", "lang_to", LANGS_TO)
	elseif id == 5 then
		open_choice("Panel position:", POSITIONS, opts.position, function(pick)
			apply("position", pick, "refresh_panel")
			M.open()
		end)
	elseif id == 6 then
		open_choice("Hover backend:", HOVER_BACKENDS, opts.hover_backend, function(pick)
			apply("hover_backend", pick, "rebuild_hover")
			M.open()
		end)
	elseif id == 7 then
		toggle_bool("prefetch", nil)
	elseif id == 8 then
		toggle_bool("prefetch_all", nil)
	else
		M.open()
	end
end

local function root_items()
	return {
		"Sentence provider: " .. tostring(opts.provider),
		"Dictionary provider: " .. tostring(opts.word_provider),
		"Source language: " .. tostring(opts.lang_from),
		"Target language: " .. tostring(opts.lang_to),
		"Panel position: " .. tostring(opts.position),
		"Hover backend: " .. tostring(opts.hover_backend),
		"Prefetch subtitles: " .. bool_label(opts.prefetch),
		"Prefetch whole file: " .. bool_label(opts.prefetch_all),
	}
end

function M.open()
	if not input then
		notify("settings menu needs mpv with mp.input support (0.37+)")
		return
	end
	input.select({
		prompt = "subtitle-translate settings:",
		items = root_items(),
		keep_open = true,
		submit = function(id)
			open_section(id)
		end,
	})
end

function M.close()
	if input and input.terminate then
		input.terminate()
	end
end

function M.init(o, a)
	opts = o
	actions = a or {}
	local ok, mod = pcall(require, "mp.input")
	if ok and type(mod) == "table" and type(mod.select) == "function" then
		input = mod
	else
		input = nil
	end
	mp.register_script_message("open-settings", M.open)
end

return M
