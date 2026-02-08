-- mpv-cheatsheet
-- dynamically displays active keybindings in an OSD overlay

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local function script_config()
    return opts
end

local opts = {
    font = "monospace",
    font_size = 20,
    activation_key = "?"
}

(require 'mp.options').read_options(opts, "cheatsheet")

local active = false
local overlay = mp.create_osd_overlay("ass-events")
local display_list = {}
local current_scroll_idx = 1
local max_key_lens = {} -- Store max key length per category

-- Usage hints (Static data moved out of draw loop)
local usage = {
    "ESC / ? : close",
    "j / DOWN : scroll down",
    "k / UP : scroll up",
    "l / RIGHT : next section",
    "h / LEFT : prev section",
    "+ / - : zoom"
}

-- Category definitions with patterns for easier maintenance
local categories = {
    { name = "Scripts", patterns = { "script", "^script_" } },
    { name = "Navigation", patterns = { "seek" } },
    { name = "Audio", patterns = { "volume", "mute", "audio" } },
    { name = "Subtitles", patterns = { "sub" } },
    { name = "Video", patterns = { "video", "contrast", "gamma", "brightness" } },
    { name = "General", patterns = { "quit", "screenshot", "playlist" } },
    { name = "Ignored", patterns = { "ignore" } }
}

-- Simplified category detection
local function detect_category(cmd, comment)
    if not cmd then return "Other" end
    local lower_cmd = cmd:lower()
    local lower_comment = (comment or ""):lower()

    for _, cat in ipairs(categories) do
        for _, pattern in ipairs(cat.patterns) do
            if lower_cmd:find(pattern) or lower_comment:find(pattern) then
                return cat.name
            end
        end
    end
    
    return "Other"
end

local function refresh_bindings()
    local bindings = mp.get_property_native("input-bindings", {})
    local grouped = {}
    local cats = {}
    local cat_set = {}
    max_key_lens = {}

    for _, bind in ipairs(bindings) do
        if bind.cmd and not bind.cmd:find("ignore") then
            local key = bind.key
            local comment = bind.comment or bind.cmd
            local cat = detect_category(bind.cmd, comment)

            if cat == "Scripts" then
                -- Combined gsub for efficiency
                comment = comment:gsub("^script[%-_]binding ", ""):gsub("^script[%-_]message ", "")
            end

            if not grouped[cat] then
                grouped[cat] = {}
                max_key_lens[cat] = 0
                if not cat_set[cat] then
                    table.insert(cats, cat)
                    cat_set[cat] = true
                end
            end
            
            local key_len = #key
            if key_len > max_key_lens[cat] then
                max_key_lens[cat] = key_len
            end
            
            table.insert(grouped[cat], {key = key, cmd = bind.cmd, comment = comment})
        end
    end
    
    -- Custom sort order
    local sort_order = {
        ["General"] = 1,
        ["Navigation"] = 2,
        ["Audio"] = 3,
        ["Video"] = 4,
        ["Subtitles"] = 5,
        ["Scripts"] = 6,
        ["Other"] = 99
    }
    
    table.sort(cats, function(a, b)
        local oa = sort_order[a] or 50
        local ob = sort_order[b] or 50
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    
    -- Flatten into display list with types
    display_list = {}
    for _, cat in ipairs(cats) do
        table.insert(display_list, {type = "header", text = cat})
        
        table.sort(grouped[cat], function(a, b) return a.key < b.key end)
        
        for _, item in ipairs(grouped[cat]) do
            table.insert(display_list, {type = "item", key = item.key, comment = item.comment, category = cat})
        end
        
        -- Add an empty line between cats
        table.insert(display_list, {type = "spacer"})
    end
end

local function draw_menu()
    if not active then
        overlay:remove()
        return
    end

    local success, err = xpcall(function()
        local ass = {}
        
        local style = string.format("{\\an7\\pos(10,10)\\bord1\\shad1\\xshad0\\yshad1\\1a&H00&\\3a&H00&\\4a&H99&\\1c&Heeeeee&\\3c&H111111&\\4c&H000000&\\fn%s\\fs%d\\fsp0\\q2}", 
            opts.font, opts.font_size)
            
        table.insert(ass, style)
        
        -- Loop
        local start = current_scroll_idx
        local max_lines = 40 -- Rough limit to prevent overflow offscreen if too many lines
        
        local lines_rendered = 0
        local idx = start
        
        while idx <= #display_list do
            if lines_rendered > max_lines then break end
            
            local item = display_list[idx]
            
            if item.type == "header" then
               table.insert(ass, "{\\b1}" .. (item.text or "") .. "{\\b0}")
            elseif item.type == "item" then
                local max_len = max_key_lens[item.category] or 10
                local key_len = #(item.key or "")
                local padding = string.rep(" ", max_len - key_len + 2) -- +2 for gap
                
                -- Escape special chars (assdraw.escape)
                local key = (item.key or ""):gsub("[{}\\]", "")
                local comment = (item.comment or ""):gsub("[{}\\]", "")
                
                table.insert(ass, key .. padding .. comment)
            elseif item.type == "spacer" then
                table.insert(ass, " ")
            end
            
            table.insert(ass, "\\N")
            
            idx = idx + 1
            lines_rendered = lines_rendered + 1
        end
        
        local w, h = mp.get_osd_size()
        if w and h then
             -- \an9 pos(w-10, 10)
             local usage_style = string.format("{\\an9\\pos(%d,10)\\fs%d\\bord1\\shad1\\1c&Heeeeee&\\4a&H99&}", w - 10, opts.font_size - 2)
             table.insert(ass, usage_style)
             table.insert(ass, "USAGE:\\N")
             for _, u in ipairs(usage) do
                 table.insert(ass, u .. "\\N")
             end
        end

        overlay.data = table.concat(ass)
        overlay:update()
    end, debug.traceback)
    
     if not success then
        msg.error("Cheatsheet draw error: " .. tostring(err))
    end
end

local function scroll_down()
    if current_scroll_idx < #display_list then
        current_scroll_idx = current_scroll_idx + 1
        draw_menu()
    end
end

local function scroll_up()
    if current_scroll_idx > 1 then
        current_scroll_idx = current_scroll_idx - 1
        draw_menu()
    end
end

local function increase_font_size()
    opts.font_size = opts.font_size + 2
    draw_menu()
end

local function decrease_font_size()
    if opts.font_size > 4 then
        opts.font_size = opts.font_size - 2
        draw_menu()
    end
end

-- Section jump (find next header)
local function next_section()
    for i = current_scroll_idx + 1, #display_list do
        if display_list[i].type == "header" then
            current_scroll_idx = i
            draw_menu()
            return
        end
    end
end

local function prev_section()
    local last_header_idx = 1
    for i = current_scroll_idx - 1, 1, -1 do
        if display_list[i].type == "header" then
            last_header_idx = i
            break
        end
    end
    current_scroll_idx = last_header_idx
    draw_menu()
end

-- Key bindings config
local key_bindings = {
    { key = "ESC", name = "cheatsheet-close", fn = function() toggle_menu() end },
    { key = "q", name = "cheatsheet-quit", fn = function() toggle_menu() end },
    { key = "j", name = "cheatsheet-down", fn = scroll_down, repeatable = true },
    { key = "DOWN", name = "cheatsheet-down-arrow", fn = scroll_down, repeatable = true },
    { key = "s", name = "cheatsheet-down-s", fn = scroll_down, repeatable = true },
    { key = "k", name = "cheatsheet-up", fn = scroll_up, repeatable = true },
    { key = "UP", name = "cheatsheet-up-arrow", fn = scroll_up, repeatable = true },
    { key = "w", name = "cheatsheet-up-w", fn = scroll_up, repeatable = true },
    { key = "l", name = "cheatsheet-next", fn = next_section, repeatable = true },
    { key = "RIGHT", name = "cheatsheet-next-arrow", fn = next_section, repeatable = true },
    { key = "d", name = "cheatsheet-next-d", fn = next_section, repeatable = true },
    { key = "h", name = "cheatsheet-prev", fn = prev_section, repeatable = true },
    { key = "LEFT", name = "cheatsheet-prev-arrow", fn = prev_section, repeatable = true },
    { key = "a", name = "cheatsheet-prev-a", fn = prev_section, repeatable = true },
    { key = "+", name = "cheatsheet-zoom-in", fn = increase_font_size, repeatable = true },
    { key = "=", name = "cheatsheet-zoom-in-eq", fn = increase_font_size, repeatable = true },
    { key = "-", name = "cheatsheet-zoom-out", fn = decrease_font_size, repeatable = true },
}

function toggle_menu()
    active = not active
    if active then
        local success, err = xpcall(refresh_bindings, debug.traceback)
        if not success then
            msg.error("Cheatsheet refresh error: " .. tostring(err))
            active = false
            return
        end
        
        for _, bind in ipairs(key_bindings) do
            local flags = bind.repeatable and "repeatable" or ""
            mp.add_forced_key_binding(bind.key, bind.name, bind.fn, flags)
        end
        
        draw_menu()
    else
        for _, bind in ipairs(key_bindings) do
            mp.remove_key_binding(bind.name)
        end
        
        overlay:remove()
    end
end

mp.add_key_binding(opts.activation_key, "display-cheatsheet", toggle_menu)
