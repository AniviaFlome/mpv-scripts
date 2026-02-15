-- mpv-cheatsheet
-- dynamically displays active keybindings in an OSD overlay
-- features: single-category view, section navigation, live search

local mp = require 'mp'
local msg = require 'mp.msg'

local opts = {
    font = "monospace",
    font_size = 20,
    activation_key = "?"
}

(require 'mp.options').read_options(opts, "cheatsheet")

local active = false
local overlay = mp.create_osd_overlay("ass-events")

-- Data: populated by refresh_bindings
local sorted_cats = {}   -- ordered category names
local grouped = {}        -- cat_name -> list of {key, cmd, comment}
local max_key_lens = {}   -- cat_name -> max key string length

-- View state
local current_cat_idx = 1
local current_scroll_idx = 1
local search_query = ""
local search_mode = false

-- Usage hints
local usage = {
    "ESC / ? : close",
    "j / DOWN : scroll down",
    "k / UP : scroll up",
    "l / RIGHT : next section",
    "h / LEFT : prev section",
    "+ / - : zoom",
    "/ : search",
}

-- Category definitions with patterns
local categories = {
    { name = "Scripts", patterns = { "script", "^script_" } },
    { name = "Navigation", patterns = { "seek" } },
    { name = "Audio", patterns = { "volume", "mute", "audio" } },
    { name = "Subtitles", patterns = { "sub" } },
    { name = "Video", patterns = { "video", "contrast", "gamma", "brightness" } },
    { name = "General", patterns = { "quit", "screenshot", "playlist" } },
}

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
    grouped = {}
    sorted_cats = {}
    max_key_lens = {}

    for _, bind in ipairs(bindings) do
        if bind.cmd and not bind.cmd:find("ignore") then
            local key = bind.key
            local comment = bind.comment or bind.cmd
            local cat = detect_category(bind.cmd, comment)

            -- Strip noisy command prefixes from display text
            comment = comment
                :gsub("^no%-osd ", "")
                :gsub("^nonscalable ", "")
                :gsub("^osd%-[%w%-]+ ", "")
                :gsub("^repeatable ", "")
                :gsub("^script[%-_]binding ", "")
                :gsub("^script[%-_]message[%-to]* ", "")

            if not grouped[cat] then
                grouped[cat] = {}
                max_key_lens[cat] = 0
                table.insert(sorted_cats, cat)
            end

            local key_len = #key
            if key_len > max_key_lens[cat] then
                max_key_lens[cat] = key_len
            end

            table.insert(grouped[cat], { key = key, cmd = bind.cmd, comment = comment })
        end
    end

    -- Custom sort order
    local sort_order = {
        ["General"] = 1, ["Navigation"] = 2, ["Audio"] = 3,
        ["Video"] = 4, ["Subtitles"] = 5, ["Scripts"] = 6,
        ["Other"] = 99
    }

    table.sort(sorted_cats, function(a, b)
        local oa = sort_order[a] or 50
        local ob = sort_order[b] or 50
        if oa ~= ob then return oa < ob end
        return a < b
    end)

    -- Sort items within each category
    for _, cat in ipairs(sorted_cats) do
        table.sort(grouped[cat], function(a, b) return a.key < b.key end)
    end
end

-- Get items to display based on current mode (category view or search)
local function get_visible_items()
    if search_mode and search_query ~= "" then
        -- Search across all categories
        local results = {}
        local query = search_query:lower()
        local search_max_key_len = 0

        for _, cat in ipairs(sorted_cats) do
            for _, item in ipairs(grouped[cat] or {}) do
                if item.key:lower():find(query, 1, true) or item.comment:lower():find(query, 1, true) then
                    table.insert(results, { key = item.key, comment = item.comment, category = cat })
                    if #item.key > search_max_key_len then
                        search_max_key_len = #item.key
                    end
                end
            end
        end

        return results, "Search: " .. search_query, search_max_key_len
    end

    -- Single category view
    if #sorted_cats == 0 then return {}, "No bindings", 10 end

    local cat = sorted_cats[current_cat_idx] or sorted_cats[1]
    local items = grouped[cat] or {}
    local mkl = max_key_lens[cat] or 10

    return items, cat, mkl
end

local function draw_menu()
    if not active then
        overlay:remove()
        return
    end

    local success, err = xpcall(function()
        local ass = {}

        local style = string.format(
            "{\\an7\\pos(10,10)\\bord1\\shad1\\xshad0\\yshad1"
            .. "\\1a&H00&\\3a&H00&\\4a&H99&"
            .. "\\1c&Heeeeee&\\3c&H111111&\\4c&H000000&"
            .. "\\fn%s\\fs%d\\fsp0\\q2}",
            opts.font, opts.font_size
        )

        table.insert(ass, style)

        local items, title, mkl = get_visible_items()

        -- Header: category name [idx/total] or search prompt
        local header
        if search_mode then
            header = title
        else
            header = string.format("%s  [%d/%d]", title, current_cat_idx, #sorted_cats)
        end
        table.insert(ass, "{\\b1}" .. header .. "{\\b0}\\N")
        table.insert(ass, "\\N") -- blank line after header

        -- Render items with scrolling
        local max_lines = 38
        local total = #items
        local start = current_scroll_idx
        local lines_rendered = 0

        for i = start, total do
            if lines_rendered >= max_lines then break end

            local item = items[i]
            local key_len = #(item.key or "")
            local padding = string.rep(" ", mkl - key_len + 2)

            local key = (item.key or ""):gsub("[{}\\]", "")
            local comment = (item.comment or ""):gsub("[{}\\]", "")

            table.insert(ass, key .. padding .. comment .. "\\N")
            lines_rendered = lines_rendered + 1
        end

        if total == 0 then
            table.insert(ass, "(no results)\\N")
        end

        -- Usage panel (top-right)
        local w, h = mp.get_osd_size()
        if w and h then
            local usage_style = string.format(
                "{\\an9\\pos(%d,10)\\fs%d\\bord1\\shad1\\1c&Heeeeee&\\4a&H99&}",
                w - 10, opts.font_size - 2
            )
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

-- Navigation
local function scroll_down()
    local items = get_visible_items()
    if current_scroll_idx < #items then
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

local function next_section()
    if search_mode then return end
    if current_cat_idx < #sorted_cats then
        current_cat_idx = current_cat_idx + 1
        current_scroll_idx = 1
        draw_menu()
    end
end

local function prev_section()
    if search_mode then return end
    if current_cat_idx > 1 then
        current_cat_idx = current_cat_idx - 1
        current_scroll_idx = 1
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

-- Search
local function exit_search()
    search_mode = false
    search_query = ""
    current_scroll_idx = 1
    draw_menu()
end

local function handle_search_input(event)
    if not event or not event.event then return end

    if event.event == "press" then
        local key = event.key_name

        if key == "ESC" or key == "ENTER" or key == "KP_ENTER" then
            -- ESC exits search, ENTER "locks in" results (stays in search view)
            if key == "ESC" then
                exit_search()
            else
                -- Keep results visible, exit search input mode
                -- Remove text input, keep search_mode true to show results
                mp.set_osd_ass(0, 0, "")
            end
            mp.remove_key_binding("cheatsheet-search-input")
            return
        elseif key == "BS" or key == "DEL" then
            if #search_query > 0 then
                search_query = search_query:sub(1, -2)
            end
            if #search_query == 0 then
                exit_search()
                mp.remove_key_binding("cheatsheet-search-input")
                return
            end
        elseif #key == 1 then
            -- Single printable character
            search_query = search_query .. key
        elseif key == "SPACE" then
            search_query = search_query .. " "
        else
            return -- ignore non-printable keys
        end

        current_scroll_idx = 1
        draw_menu()
    end
end

local function start_search()
    search_mode = true
    search_query = ""
    current_scroll_idx = 1
    draw_menu()

    mp.add_forced_key_binding("any_unicode", "cheatsheet-search-input", handle_search_input, { complex = true })
end

-- Toggle
local toggle_menu -- forward declaration

local function toggle()
    active = not active
    if active then
        local success, err = xpcall(refresh_bindings, debug.traceback)
        if not success then
            msg.error("Cheatsheet refresh error: " .. tostring(err))
            active = false
            return
        end

        -- Reset state
        current_cat_idx = 1
        current_scroll_idx = 1
        search_mode = false
        search_query = ""

        for _, bind in ipairs(key_bindings) do
            local flags = bind.repeatable and "repeatable" or ""
            mp.add_forced_key_binding(bind.key, bind.name, bind.fn, flags)
        end

        draw_menu()
    else
        -- Clean up search binding if active
        mp.remove_key_binding("cheatsheet-search-input")

        for _, bind in ipairs(key_bindings) do
            mp.remove_key_binding(bind.name)
        end

        overlay:remove()
    end
end

toggle_menu = toggle

-- Key bindings config
key_bindings = {
    { key = "ESC", name = "cheatsheet-close", fn = toggle },
    { key = "q", name = "cheatsheet-quit", fn = toggle },
    { key = "j", name = "cheatsheet-down", fn = scroll_down, repeatable = true },
    { key = "DOWN", name = "cheatsheet-down-arrow", fn = scroll_down, repeatable = true },
    { key = "k", name = "cheatsheet-up", fn = scroll_up, repeatable = true },
    { key = "UP", name = "cheatsheet-up-arrow", fn = scroll_up, repeatable = true },
    { key = "l", name = "cheatsheet-next", fn = next_section, repeatable = true },
    { key = "RIGHT", name = "cheatsheet-next-arrow", fn = next_section, repeatable = true },
    { key = "h", name = "cheatsheet-prev", fn = prev_section, repeatable = true },
    { key = "LEFT", name = "cheatsheet-prev-arrow", fn = prev_section, repeatable = true },
    { key = "+", name = "cheatsheet-zoom-in", fn = increase_font_size, repeatable = true },
    { key = "=", name = "cheatsheet-zoom-in-eq", fn = increase_font_size, repeatable = true },
    { key = "-", name = "cheatsheet-zoom-out", fn = decrease_font_size, repeatable = true },
    { key = "/", name = "cheatsheet-search", fn = start_search },
}

mp.add_key_binding(opts.activation_key, "display-cheatsheet", toggle_menu)
