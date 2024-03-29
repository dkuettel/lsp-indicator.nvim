---global settings
--@type nil | { on_updates: function, interval_ms: number, log: boolean }
local settings = nil

---Is the lsp_progress_handler already registered with vim.lsp.handlers["$/progress"]?
--@type boolean
local handler_is_registered = false

---Is the DiagnosticChanged event hanlder registered?
--@type boolean
local event_is_registered = false

---access like progress[client_id][token]
--.busy for general idle vs busy, .percentage with percentage IF the lsp reports it
---@type table<integer, table<string, { busy: boolean, percentage: number? }>>
local client_progress = {}

---last on_update call from lsp_progress_handler
local last_update = nil

---scheduled update from vim.defer_fn -> vim.loop.new_timer()
local scheduled_update = nil

---log buffer id
---@type nil | integer
local log_buffer = nil

---cached diagnostics string
--@type nil | str
local last_diagnostics = nil

---last update ofr last_diagnostics
local last_diagnostics_update = nil

local function log_lsp_progress_reply(err, result, ctx, config)
    if log_buffer == nil then
        log_buffer = vim.api.nvim_create_buf(true, true)
    end
    vim.fn.appendbufline(log_buffer, "$", vim.inspect(err))
    vim.fn.appendbufline(log_buffer, "$", vim.inspect(result))
    vim.fn.appendbufline(log_buffer, "$", vim.inspect(ctx))
    vim.fn.appendbufline(log_buffer, "$", vim.inspect(config))
    vim.fn.appendbufline(log_buffer, "$", "")
end

local function update_progress(ctx, result)
    local client_id = ctx.client_id
    if client_progress[client_id] == nil then
        client_progress[client_id] = {}
    end
    local token = result.token
    if client_progress[client_id][token] == nil then
        client_progress[client_id][token] = { busy = false, percentage = nil }
    end
    local kind = result.value.kind
    if kind == "begin" or kind == "report" then
        local percentage = result.value.percentage -- can be nil
        client_progress[client_id][token].busy = true
        client_progress[client_id][token].percentage = percentage
    elseif kind == "end" then
        client_progress[client_id][token] = nil
    else
        -- NOTE that's unexpected :)
        client_progress[client_id][token] = nil
    end
end

local function maybe_callback()
    if settings.on_update == nil then
        return
    end
    if scheduled_update ~= nil then
        return
    end
    local wait_ms = settings.interval_ms - vim.fn.reltimefloat(vim.fn.reltime(last_update)) * 1000
    if wait_ms <= 0 then
        settings.on_update()
        last_update = vim.fn.reltime()
        return
    end
    scheduled_update = vim.defer_fn(function()
        settings.on_update()
        last_update = vim.fn.reltime()
        scheduled_update = nil
    end, settings.interval_ms)
end

---callback to update client_progress according to the lsp's reply
---see https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#progress
---@diagnostic disable-next-line: unused-local
local function lsp_progress_handler(err, result, ctx, config)
    if settings.log then
        log_lsp_progress_reply(err, result, ctx, config)
    end
    update_progress(ctx, result)
    maybe_callback()
    if config.chain ~= nil then
        -- NOTE I think this is messed up with vims lsp handler handling
        -- is config part of the signature? then what I'm supposed to pass on?
        -- when I chain, I cannot know what was the intention
        -- plus vim.lsp.with seems to wrap anyway so why have it part of
        -- the signature to begin with?
        config.chain(err, result, ctx, {})
    end
end

---from all parallel progress, get the lowest one
--percentage or true when busy, nil when done
---@param progress nil | table<string, { busy: boolean, percentage: number? }>
---@return { busy: boolean, percentage: number? }
local function get_representative_state(progress)
    if progress == nil then
        return { busy = false, percentage = nil }
    end
    local agg = { busy = false, percentage = nil }
    for _, state in pairs(progress) do
        agg.busy = agg.busy or state.busy
        if state.percentage ~= nil then
            agg.percentage = math.min(agg.percentage, state.percentage)
        end
    end
    return agg
end

---nerdfont-style indicator of progress percentage
---@param percentage number
---@param icons string
---@return string
local function get_progress_icon(percentage, icons)
    local n = vim.fn.strcharlen(icons)
    local index = math.floor(0.5 + percentage / 100 * (n - 1))
    return vim.fn.strcharpart(icons, index, 1)
end

---turn progress percentage into an icon
---@param client_id integer
---@param theme table
---@return string
local function format_progress(client_id, theme)
    -- TODO not clear if client.id is unique and never reused
    local progress = client_progress[client_id]
    local state = get_representative_state(progress)
    if not state.busy then
        return theme.idle
    end
    if state.percentage == nil then
        return theme.busy
    end
    return get_progress_icon(state.percentage, theme.progress)
end

---to sort by client name, increasing
local function compare_client_names(a, b)
    return a.name < b.name
end

---format all clients
---@param bufnr nil | integer
---@param theme table
---@return string
local function format(bufnr, theme)
    local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
    table.sort(clients, compare_client_names)
    local function format_client(client)
        if theme.name then
            return format_progress(client.id, theme) .. " " .. client.name
        else
            return format_progress(client.id, theme)
        end
    end
    local formatted = vim.tbl_map(format_client, clients)
    if theme.name then
        return vim.fn.join(formatted, " ")
    else
        return vim.fn.join(formatted, "")
    end
end

-- NOTE there is also vim.lsp.buf.server_ready()
-- it only indicates if the current buffer's lsps are responsive
-- it doesnt mean they are not busy scanning or with other background tasks
-- that means completion or diagnostic can still be out of date

-- NOTE there is also vim.lsp.util.get_progress_messages
-- but it's marked as private and not documented
-- it seems to give messages since last call, so it's difficult to manage the side-effects
-- plus it doesnt correctly aggregate and multiplex on the progress token from the lsp

---setup lsp-progress, can be called more than once to change settings
---the on_updates callback will be called when progress changes
---this callback is rate limited by interval_ms
---log is only for debugging the lsp messages, they will be written to a scratch buffer
---@param config { on_updates: function, interval_ms: number, log: boolean }
local function setup(config)
    settings = vim.tbl_extend("keep", config or {}, { on_update = nil, interval_ms = 500, log = false })
    if not handler_is_registered then
        vim.lsp.handlers["$/progress"] = vim.lsp.with(lsp_progress_handler, { chain = vim.lsp.handlers["$/progress"] })
        handler_is_registered = true
    end
    if not event_is_registered then
        vim.api.nvim_create_autocmd("DiagnosticChanged", {
            callback = maybe_callback,
            desc = "lsp-indicator",
        })
        event_is_registered = true
    end
end

---return something like " rust 󰄳 lua" showing all lsp's progresses
---@param bufnr nil | integer
---@return string
local function get_named_progress(bufnr)
    local theme = {
        name = true,
        busy = "",
        progress = "",
        idle = "󰄳",
    }
    return format(bufnr, theme)
end

---return same as get_named_progress but without the names
---@param bufnr nil | integer
---@return string
local function get_progress(bufnr)
    local theme = {
        name = false,
        busy = "",
        progress = "",
        idle = "󰄳",
    }
    return format(bufnr, theme)
end

---return something like "󰁙 rust 󰄳 lua" showing all lsp's states
---@param bufnr nil | integer
---@return string
local function get_named_state(bufnr)
    local theme = { name = true, busy = "", progress = "", idle = "󰄳" }
    return format(bufnr, theme)
end

---return same as get_named_state but without the names
---@param bufnr nil | integer
---@return string
local function get_state(bufnr)
    local theme = { name = false, busy = "", progress = "", idle = "󰄳" }
    return format(bufnr, theme)
end

---@param bufnr nil | integer
local function compute_diagnostics(bufnr)
    local icons = { "󰅚", "", "󰋽", "󰛩" }
    local show = {}
    for s = 1, 4 do
        local c = #vim.diagnostic.get(bufnr, { severity = s })
        if c > 0 then
            table.insert(show, icons[s] .. " " .. c)
        end
    end

    last_diagnostics = vim.fn.join(show, "  ")
    last_diagnostics_update = vim.fn.reltime()

    return last_diagnostics
end

---return something like "󰅚 5   3  󰋽 1  󰛩 3"
--cached based on setup's interval_ms setting
--calling often will not slow down nvim
---@param bufnr nil | integer
---@return string
local function get_diagnostics(bufnr)
    if last_diagnostics_update == nil or last_diagnostics == nil then
        return compute_diagnostics(bufnr)
    end

    local wait_ms = settings.interval_ms - vim.fn.reltimefloat(vim.fn.reltime(last_diagnostics_update)) * 1000

    if wait_ms > 0 then
        return last_diagnostics
    end

    return compute_diagnostics(bufnr)
end

return {
    setup = setup,
    get_named_progress = get_named_progress,
    get_progress = get_progress,
    get_named_state = get_named_state,
    get_state = get_state,
    get_diagnostics = get_diagnostics,
}
