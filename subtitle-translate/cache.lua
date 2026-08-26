local util = require("util")

local M = {}

local opts = nil
local cache = {}
local cache_count = 0
local CACHE_MAX = 5000

function M.init(o)
	opts = o
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
	return cache[M.lookup_cache_key(kind, text, provider_name)]
end

function M.get_by_key(key)
	return cache[key]
end

function M.store(key, value)
	if cache[key] == nil then
		if cache_count >= CACHE_MAX then
			return
		end
		cache_count = cache_count + 1
	end
	cache[key] = value
end

function M.store_by_key(key, value)
	M.store(key, value)
end

function M.purge(kind, text)
	local key = M.lookup_cache_key(kind, text)
	if cache[key] ~= nil then
		cache[key] = nil
		cache_count = cache_count - 1
	end
end

function M.purge_by_key(key)
	if cache[key] ~= nil then
		cache[key] = nil
		cache_count = cache_count - 1
	end
end

function M.count()
	return cache_count
end

return M
