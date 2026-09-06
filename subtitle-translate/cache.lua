local mp = require("mp")
local utils = require("mp.utils")
local util = require("util")

local M = {}

local opts = nil
local cache = {}
local touched = {}
local persist = {}
local use_seq = 0
local cache_count = 0
local CACHE_VERSION = 1
local SAVE_DEBOUNCE = 10

local cache_file = nil
local cache_dir = nil
local dirty = false
local save_timer = nil

local function log(text)
	if opts and opts.verbose then
		util.log(text)
	end
end

local function max_entries()
	local n = opts and tonumber(opts.cache_max_entries) or 5000
	if not n then
		return 5000
	end
	return math.max(1, math.floor(n))
end

local function disk_enabled()
	return opts and opts.disk_cache and cache_file ~= nil
end

-- disk cache: XDG_CACHE_HOME only, else memory-only
local function resolve_cache_file()
	local dir = nil
	if opts and type(opts.cache_dir) == "string" and opts.cache_dir ~= "" then
		dir = opts.cache_dir
	else
		local xdg = os.getenv("XDG_CACHE_HOME")
		if type(xdg) == "string" and xdg:match("^/") then
			xdg = xdg:gsub("/+$", "")
			if xdg ~= "" and xdg ~= "/" then
				dir = xdg .. "/subtitle-translate"
			end
		end
	end
	if not dir or dir == "" then
		return nil, nil
	end
	return dir .. "/cache.json", dir
end

local function touch(key)
	use_seq = use_seq + 1
	touched[key] = use_seq
end

local function evict_lru(limit)
	while cache_count > limit do
		local oldest, oldest_seq = nil, nil
		for key, seq in pairs(touched) do
			if oldest_seq == nil or seq < oldest_seq then
				oldest, oldest_seq = key, seq
			end
		end
		if oldest == nil then
			break
		end
		cache[oldest] = nil
		touched[oldest] = nil
		persist[oldest] = nil
		cache_count = cache_count - 1
	end
end

local function schedule_save()
	if not disk_enabled() or not dirty or save_timer then
		return
	end
	save_timer = mp.add_timeout(SAVE_DEBOUNCE, function()
		save_timer = nil
		M.save_now()
	end)
end

-- single JSON file, atomic write; disk errors stay memory-only
function M.save_now()
	if not disk_enabled() or not dirty then
		return false
	end
	local limit = max_entries()
	local entries = {}
	for key in pairs(persist) do
		if cache[key] ~= nil then
			entries[#entries + 1] = { key = key, value = cache[key], used = touched[key] or 0 }
		end
	end
	table.sort(entries, function(a, b)
		return a.used > b.used
	end)
	while #entries > limit do
		entries[#entries] = nil
	end
	local json = utils.format_json({ version = CACHE_VERSION, entries = entries })
	if type(json) ~= "string" or json == "" then
		log("disk cache: serialize failed, skipping save")
		return false
	end
	pcall(function()
		mp.command_native({
			name = "subprocess",
			args = { "mkdir", "-p", cache_dir },
			playback_only = false,
		})
	end)
	local tmp = cache_file .. ".tmp"
	local f, ferr = io.open(tmp, "w")
	if not f then
		log("disk cache: cannot write " .. tmp .. ": " .. tostring(ferr))
		return false
	end
	f:write(json)
	local ok_close, cerr = f:close()
	if not ok_close then
		log("disk cache: close failed: " .. tostring(cerr))
		return false
	end
	local ok_ren, rerr = os.rename(tmp, cache_file)
	if not ok_ren then
		log("disk cache: rename failed: " .. tostring(rerr))
		return false
	end
	dirty = false
	log("disk cache: saved " .. #entries .. " entries to " .. cache_file)
	return true
end

local function load()
	if not disk_enabled() then
		if opts and opts.disk_cache then
			log("disk cache: XDG_CACHE_HOME unset, disk persistence disabled (memory-only)")
		end
		return
	end
	local f = io.open(cache_file, "r")
	if not f then
		log("disk cache: no existing file, starting cold")
		return
	end
	local content = f:read("*a")
	f:close()
	if type(content) ~= "string" or content == "" then
		return
	end
	local ok, data = pcall(utils.parse_json, content)
	if not ok or type(data) ~= "table" or data.version ~= CACHE_VERSION or type(data.entries) ~= "table" then
		log("disk cache: unreadable file, starting cold")
		return
	end
	table.sort(data.entries, function(a, b)
		return (tonumber(a.used) or 0) < (tonumber(b.used) or 0)
	end)
	local limit = max_entries()
	local loaded = 0
	for _, e in ipairs(data.entries) do
		if cache_count >= limit then
			break
		end
		if type(e) == "table" and type(e.key) == "string" and e.value ~= nil and cache[e.key] == nil then
			cache[e.key] = e.value
			persist[e.key] = true
			touch(e.key)
			cache_count = cache_count + 1
			loaded = loaded + 1
		end
	end
	log("disk cache: loaded " .. loaded .. " entries from " .. cache_file)
end

function M.init(o)
	opts = o
	cache_file, cache_dir = resolve_cache_file()
	load()
end

function M.lookup_cache_key(kind, text, provider_name)
	return (provider_name or opts.provider)
		.. "|"
		.. kind
		.. "|"
		.. opts.lang_from
		.. ">"
		.. opts.lang_to
		.. "|"
		.. text
end

function M.has_cached(kind, text)
	return cache[M.lookup_cache_key(kind, text)] ~= nil
end

function M.get(kind, text, provider_name)
	local key = M.lookup_cache_key(kind, text, provider_name)
	local v = cache[key]
	if v ~= nil then
		touch(key)
	end
	return v
end

function M.get_by_key(key)
	local v = cache[key]
	if v ~= nil then
		touch(key)
	end
	return v
end

-- persistent=true: sentence entries go to disk
function M.store(key, value, persistent)
	if cache[key] == nil then
		cache_count = cache_count + 1
	end
	cache[key] = value
	touch(key)
	if persistent then
		persist[key] = true
		dirty = true
		schedule_save()
	else
		persist[key] = nil
	end
	evict_lru(max_entries())
end

function M.store_by_key(key, value, persistent)
	M.store(key, value, persistent)
end

function M.purge(kind, text)
	M.purge_by_key(M.lookup_cache_key(kind, text))
end

function M.purge_by_key(key)
	if cache[key] ~= nil then
		local was_persistent = persist[key] ~= nil
		cache[key] = nil
		touched[key] = nil
		persist[key] = nil
		cache_count = cache_count - 1
		if was_persistent then
			dirty = true
			schedule_save()
		end
	end
end

function M.count()
	return cache_count
end

return M
