--[[--
Ask Claude: a reading companion for KOReader.

Select text and tap "Ask Claude…" (or open the menu with a gesture) to get help
from Claude Code running on your computer, using your Claude subscription.

The plugin talks to the computer over SSH with KOReader's bundled dbclient. On
the computer the key is locked to the kindle_ask.py script (a forced command),
which keeps the book, cuts it at your reading position so there are no
spoilers, and runs `claude -p`. The menu actions come from that script's
pluggable modules, so they can be added or removed without touching this plugin.

@module koplugin.askclaude
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local SETTINGS_DIR = DataStorage:getSettingsDir()

-- install-kindle.sh writes the computer's address and user to askclaude/computer.lua;
-- the "Computer" menu item overrides them.
local DEFAULTS = {
    host = "",
    port = 22,
    user = "",
    key = SETTINGS_DIR .. "/SSH/id_laptop",
}
do
    local ok, computer = pcall(dofile, SETTINGS_DIR .. "/askclaude/computer.lua")
    if ok and type(computer) == "table" then
        for k, v in pairs(computer) do DEFAULTS[k] = v end
    end
end

-- Used until the computer has sent its module list (after the first answer,
-- or via "Refresh menu from computer").
local FALLBACK_ACTIONS = {
    { id = "20-how-did-i-get-here", label = "How did I get here?", scope = "any" },
    { id = "21-explain-passage", label = "Explain", scope = "selection" },
}

local AskClaude = WidgetContainer:extend{
    name = "askclaude",
    is_doc_only = true,
}

-- helpers -------------------------------------------------------------------

local function shq(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Shorten to at most `max` bytes without splitting a UTF-8 character.
local function excerpt(s, max)
    s = trim(s):gsub("%s+", " ")
    if #s <= max then return s end
    local cut = max
    while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and (s:byte(cut + 1) or 0) < 0xC0 do
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

local function str(v)
    -- rapidjson decodes JSON null to a sentinel, not nil
    return type(v) == "string" and v or nil
end

-- setup ---------------------------------------------------------------------

function AskClaude:init()
    self.settings = LuaSettings:open(SETTINGS_DIR .. "/askclaude.lua")
    -- dbclient keeps its known_hosts under $HOME/.ssh, so give it a home of its own.
    self.home = SETTINGS_DIR .. "/askclaude"
    lfs.mkdir(self.home)
    lfs.mkdir(self.home .. "/.ssh")
    self.checked_books = {}

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("13_ask_claude", function(this)
            return {
                text = _("Ask Claude…"),
                callback = function()
                    local text = this.selected_text and this.selected_text.text
                    this:onClose()
                    self:showMenu(text)
                end,
            }
        end)
    end
end

function AskClaude:onDispatcherRegisterActions()
    Dispatcher:registerAction("askclaude_menu", {
        category = "none",
        event = "AskClaudeMenu",
        title = _("Ask Claude"),
        reader = true,
    })
end

function AskClaude:onAskClaudeMenu()
    self:showMenu(nil)
    return true
end

function AskClaude:get(key)
    local v = self.settings:readSetting(key)
    if v == nil then v = DEFAULTS[key] end
    return v
end

function AskClaude:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

-- book context ----------------------------------------------------------------

function AskClaude:bookId()
    local doc_settings = self.ui.doc_settings
    return (doc_settings and doc_settings:readSetting("partial_md5_checksum"))
        or util.partialMD5(self.ui.document.file)
end

-- Text of the page on screen, so the computer can cut the book exactly there.
-- Only available for reflowable books (EPUB, FB2, MOBI…); PDFs fall back to %.
function AskClaude:getPageText(page)
    local doc = self.ui.document
    if not self.ui.rolling or not doc.getPageXPointer or not doc.getTextFromXPointers then
        return nil
    end
    local ok, text = pcall(function()
        if page >= doc:getPageCount() then return nil end
        return doc:getTextFromXPointers(doc:getPageXPointer(page), doc:getPageXPointer(page + 1))
    end)
    return ok and str(text) or nil
end

-- Table of contents up to the current page only (later titles can be spoilers).
function AskClaude:getTocSoFar(page, total)
    local toc = self.ui.toc
    if not toc then return nil end
    pcall(function() toc:fillToc() end)
    local list = {}
    for _i, item in ipairs(toc.toc or {}) do
        if type(item.page) == "number" and item.page <= page then
            local ok, title = pcall(function() return toc:cleanUpTocTitle(item.title or "") end)
            table.insert(list, {
                title = ok and title or item.title,
                depth = item.depth,
                percent = total > 0 and item.page / total or nil,
            })
            if #list >= 500 then break end
        end
    end
    return list
end

function AskClaude:getContext()
    local ui, doc = self.ui, self.ui.document
    local props = ui.doc_props or {}
    local page = ui:getCurrentPage() or 1
    local total = doc:getPageCount() or 0
    local chapter
    if ui.toc then
        local ok, t = pcall(function() return ui.toc:getTocTitleByPage(page) end)
        chapter = ok and str(t) or nil
    end
    return {
        file = doc.file,
        ext = (util.getFileNameSuffix(doc.file) or ""):lower(),
        book_id = self:bookId(),
        title = str(props.display_title) or str(props.title),
        authors = str(props.authors),
        percent = total > 0 and page / total or nil,
        chapter = chapter,
        page_text = self:getPageText(page),
        toc = self:getTocSoFar(page, total),
    }
end

-- talking to the computer ---------------------------------------------------

function AskClaude:dbclient()
    for _i, p in ipairs({ "./dbclient", DataStorage:getDataDir() .. "/dbclient", "/mnt/us/koreader/dbclient" }) do
        if lfs.attributes(p, "mode") == "file" then return p end
    end
end

-- Runs one request in a dismissable subprocess (tap the message to cancel).
-- Returns the decoded reply, or nil plus an error message (nil if cancelled).
function AskClaude:remote(verb, stdin_file, message)
    if self:get("host") == "" or self:get("user") == "" then
        return nil, _("No computer set. Run install-kindle.sh, or set it in the menu: Ask Claude → Computer.")
    end
    local dbclient = self:dbclient()
    if not dbclient then
        return nil, _("KOReader's SSH client (dbclient) was not found.")
    end
    local errfile = self.home .. "/last_error.txt"
    local target = self:get("user") .. "@" .. self:get("host")
    local cmd = string.format("HOME=%s %s -y -T -i %s -p %d %s %s < %s 2> %s",
        shq(self.home), shq(dbclient), shq(self:get("key")), tonumber(self:get("port")) or 22,
        shq(target), shq(verb), shq(stdin_file or "/dev/null"), shq(errfile))
    local completed, out = Trapper:dismissableRunInSubprocess(function()
        local p = io.popen(cmd, "r")
        if not p then return "" end
        local s = p:read("*a") or ""
        p:close()
        return s
    end, message, true)
    if not completed then return nil, nil end

    local ok, res = pcall(rapidjson.decode, out or "")
    if ok and type(res) == "table" then
        if res.ok then return res end
        return nil, str(res.error) or _("Unknown error from the computer.")
    end
    local err = ""
    local f = io.open(errfile, "r")
    if f then
        err = trim(f:read("*a"))
        f:close()
    end
    logger.warn("AskClaude: request failed:", verb, err, out)
    local hint = ""
    if err:find("Connection refused") or err:find("No route") or err:find("timed out")
            or err:find("Network is unreachable") then
        hint = "\n\n" .. T(_("Check that the computer (%1) is awake, on the same Wi-Fi, and running its SSH server."),
            self:get("host"))
    end
    return nil, (err ~= "" and err or _("No reply from the computer.")) .. hint
end

function AskClaude:showError(err)
    if err then  -- nil means the user cancelled
        UIManager:show(InfoMessage:new{ text = T(_("Ask Claude: %1"), err) })
    end
end

-- Runs fn once Wi-Fi is up, inside the coroutine that self:remote() needs.
function AskClaude:withConnection(fn)
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(fn)
    end)
end

-- Writes a JSON request body for self:remote(); returns its path.
function AskClaude:writeRequest(name, tbl)
    local path = self.home .. "/" .. name .. ".json"
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(rapidjson.encode(tbl))
    f:close()
    return path
end

-- The computer keeps a copy of each book (sent once) so Claude can search it.
function AskClaude:ensureBook(ctx, force)
    if self.checked_books[ctx.book_id] and not force then return true end
    if not force then
        local res, err = self:remote("has-book " .. ctx.book_id, nil, _("Connecting to your computer…"))
        if not res then return false, err end
        if res.present then
            self.checked_books[ctx.book_id] = true
            return true
        end
    end
    if not ctx.ext:match("^[a-z0-9]+$") then
        return false, _("This file type can't be sent.")
    end
    local res, err = self:remote(string.format("put-book %s %s", ctx.book_id, ctx.ext), ctx.file,
        _("Sending this book to your computer (first time only)…"))
    if not res then return false, err end
    self.checked_books[ctx.book_id] = true
    return true
end

-- actions and sessions ------------------------------------------------------

function AskClaude:getActions()
    local actions = self.settings:readSetting("actions")
    return (type(actions) == "table" and #actions > 0) and actions or FALLBACK_ACTIONS
end

function AskClaude:saveActions(actions)
    local clean = {}
    for _i, a in ipairs(actions) do
        if str(a.id) and str(a.label) then
            table.insert(clean, { id = a.id, label = a.label, scope = str(a.scope) or "any" })
        end
    end
    self:set("actions", clean)
end

function AskClaude:lastSession(book_id)
    local sessions = self.settings:readSetting("sessions") or {}
    return sessions[book_id or self:bookId()]
end

-- Remembers the conversation "Continue" picks up, with what it holds
-- (`info` = {first = its first question, answers = count}); nil forgets it.
function AskClaude:saveSession(book_id, session_id, info)
    local sessions = self.settings:readSetting("sessions") or {}
    sessions[book_id] = session_id
    self:set("sessions", sessions)
    local conversations = self.settings:readSetting("conversations") or {}
    conversations[book_id] = (session_id and type(info) == "table" and str(info.first))
        and { first = info.first, answers = tonumber(info.answers) or 1 } or nil
    self:set("conversations", conversations)
end

function AskClaude:continueLabel(book_id)
    local c = (self.settings:readSetting("conversations") or {})[book_id or self:bookId()]
    if not c then return _("Continue last conversation…") end
    local answers = c.answers == 1 and _("1 answer") or T(_("%1 answers"), c.answers)
    return T(_("Continue: “%1” (%2)"), excerpt(c.first, 24), answers)
end

-- "Spoilers OK": Claude gets the whole book, and the no-spoilers rule is off.
function AskClaude:spoilersOk(book_id)
    local books = self.settings:readSetting("spoilers_ok") or {}
    return books[book_id or self:bookId()] == true
end

function AskClaude:toggleSpoilersOk()
    local book_id = self:bookId()
    local on = not self:spoilersOk(book_id)
    local books = self.settings:readSetting("spoilers_ok") or {}
    books[book_id] = on or nil
    self:set("spoilers_ok", books)
    -- The current conversation was had under the other setting.
    self:saveSession(book_id, nil)
    UIManager:show(InfoMessage:new{
        text = on and _("Spoilers OK: Claude can now read the whole book and discuss anything in it. The next question starts a new conversation.")
            or _("No spoilers again. The next question starts a new conversation."),
        timeout = 4,
    })
end

-- UI --------------------------------------------------------------------------
--
-- Navigation: every screen opened from another screen gets a `back` function
-- that reopens its parent, shown as a "‹ Back" button. Tapping outside a pop-up
-- (or the X of a text view) still closes everything and returns to the book.

local BACK = "‹ " .. _("Back")

-- The floating menu: module buttons that fit the situation, plus free-text questions.
function AskClaude:showMenu(selection)
    if selection and trim(selection) == "" then selection = nil end
    local menu
    local function back() self:showMenu(selection) end
    local function go(fn)
        return function()
            UIManager:close(menu)
            fn()
        end
    end
    local buttons, row = {}, {}
    for _i, a in ipairs(self:getActions()) do
        local fits = a.scope == "any"
            or (selection and a.scope == "selection")
            or (not selection and a.scope == "page")
        if fits then
            table.insert(row, {
                text = a.label,
                callback = go(function()
                    self:ask{ selection = selection, action = a.id, label = a.label, back = back }
                end),
            })
            if #row == 2 then
                table.insert(buttons, row)
                row = {}
            end
        end
    end
    if #row > 0 then table.insert(buttons, row) end
    table.insert(buttons, {{
        text = _("Ask a question…"),
        callback = go(function() self:promptQuestion(selection, nil, back) end),
    }})
    local last = self:lastSession()
    if last then
        table.insert(buttons, {{
            text = self:continueLabel(),
            callback = go(function() self:promptQuestion(selection, last, back) end),
        }})
    end
    table.insert(buttons, {
        { text = _("History"), callback = go(function() self:showHistory(back) end) },
        { text = _("Modules"), callback = go(function() self:showModules(selection, back) end) },
    })
    menu = ButtonDialog:new{
        title = selection and ("“" .. excerpt(selection, 180) .. "”")
            or (self:spoilersOk() and _("Ask Claude about this book (spoilers OK)"))
            or _("Ask Claude about this book"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(menu)
end

-- `back` (optional) reopens the screen the question box was opened from.
function AskClaude:promptQuestion(selection, session_id, back)
    local dialog
    dialog = InputDialog:new{
        title = session_id and _("Follow-up question") or _("Ask Claude"),
        description = selection and excerpt(selection, 240) or nil,
        input_hint = _("Your question"),
        buttons = {{
            {
                text = back and BACK or _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if back then back() end
                end,
            },
            {
                text = _("Ask"),
                is_enter_default = true,
                callback = function()
                    local q = trim(dialog:getInputText())
                    if q == "" then return end
                    UIManager:close(dialog)
                    self:ask{ selection = selection, question = q, session_id = session_id, back = back }
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AskClaude:showAnswer(opts, answer, session_id)
    local heading = opts.question or opts.label
    local text = heading and (heading .. "\n\n" .. answer) or answer
    local viewer
    local function reshow() self:showAnswer(opts, answer, session_id) end
    local row = {}
    if opts.back then
        table.insert(row, {
            text = BACK,
            callback = function()
                UIManager:close(viewer)
                opts.back()
            end,
        })
    end
    table.insert(row, {
        text = _("Follow up…"),
        enabled = session_id ~= nil,
        callback = function()
            UIManager:close(viewer)
            self:promptQuestion(nil, session_id, reshow)
        end,
    })
    table.insert(row, {
        text = _("Close"),
        callback = function() UIManager:close(viewer) end,
    })
    viewer = TextViewer:new{
        title = _("Claude"),
        text = text,
        buttons_table = { row },
    }
    UIManager:show(viewer)
end

function AskClaude:ask(opts)
    self:withConnection(function() self:doAsk(opts) end)
end

-- A pop-up list: a top row with "‹ Back" (if `back`) plus any `top` buttons,
-- then one full-width button per row. Rows with `header = true` are section
-- titles. Scrolls when long.
function AskClaude:showList(title, rows, back, top)
    local dialog
    local function go(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local buttons, first = {}, {}
    if back then table.insert(first, { text = BACK, callback = go(back) }) end
    for _i, b in ipairs(top or {}) do
        table.insert(first, { text = b.text, callback = go(b.callback) })
    end
    if #first > 0 then table.insert(buttons, first) end
    for _i, r in ipairs(rows) do
        if r.header then
            table.insert(buttons, {{ text = r.text, enabled = false, callback = function() end }})
        else
            table.insert(buttons, {{ text = r.text, align = "left", callback = go(r.callback) }})
        end
    end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- history (kept per book on the computer) ----------------------------------

function AskClaude:showHistory(back)
    local book_id = self:bookId()
    self:withConnection(function()
        local res, err = self:remote("history " .. book_id, nil, _("Loading this book's history…"))
        if not res then return self:showError(err) end
        local entries = type(res.entries) == "table" and res.entries or {}
        if #entries == 0 then
            UIManager:show(InfoMessage:new{ text = _("No questions about this book yet."), timeout = 3 })
            return
        end
        self:renderHistory(book_id, entries, back)
    end)
end

-- Entries arrive newest first. They are grouped by conversation (newest
-- conversation first), each in order with its follow-ups indented; ● marks
-- the conversation "Continue" picks up.
function AskClaude:renderHistory(book_id, entries, back)
    local function again() self:renderHistory(book_id, entries, back) end
    local last = self:lastSession(book_id)
    local groups, by_session = {}, {}
    for _i, e in ipairs(entries) do
        local key = str(e.session_id) or ("entry " .. tostring(e.id))
        if not by_session[key] then
            by_session[key] = { session_id = str(e.session_id), entries = {} }
            table.insert(groups, by_session[key])
        end
        table.insert(by_session[key].entries, 1, e)
    end
    local rows = {}
    for _i, group in ipairs(groups) do
        local is_last = last ~= nil and group.session_id == last
        for j, e in ipairs(group.entries) do
            local where = str(e.where)
            table.insert(rows, {
                text = (is_last and "● " or "") .. (j > 1 and "   ↳ " or "")
                    .. (where and where ~= "" and (excerpt(where, 28) .. " · ") or "")
                    .. excerpt(str(e.question) or "", 60),
                callback = function() self:showHistoryEntry(book_id, e, again, back) end,
            })
        end
    end
    if last then
        -- Keep the Continue button's summary in step with deleted entries.
        local group = by_session[last]
        self:saveSession(book_id, last, group
            and { first = str(group.entries[1].question) or "", answers = #group.entries })
    end
    table.insert(rows, {
        text = _("Clear this book's history…"),
        callback = function() self:confirmClearHistory(book_id, again, back) end,
    })
    self:showList(T(_("This book: %1 questions"), #entries), rows, back)
end

-- `to_list` reopens the history list; `list_back` is where the list goes back to.
function AskClaude:showHistoryEntry(book_id, e, to_list, list_back)
    local parts = { table.concat({ str(e.when) or "", str(e.where) or "" }, " · ") }
    if str(e.selection) then table.insert(parts, "“" .. e.selection .. "”") end
    table.insert(parts, str(e.question) or "")
    table.insert(parts, str(e.answer) or "")
    local session_id = str(e.session_id)
    local viewer
    local function reshow() self:showHistoryEntry(book_id, e, to_list, list_back) end
    viewer = TextViewer:new{
        title = _("Earlier question"),
        text = table.concat(parts, "\n\n"),
        buttons_table = {{
            {
                text = BACK,
                callback = function()
                    UIManager:close(viewer)
                    to_list()
                end,
            },
            {
                text = _("Continue…"),
                enabled = session_id ~= nil,
                callback = function()
                    UIManager:close(viewer)
                    self:promptQuestion(nil, session_id, reshow)
                end,
            },
            {
                text = _("Delete"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete this question and its answer from the history?"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            UIManager:close(viewer)
                            self:withConnection(function()
                                local res, err = self:remote(string.format("history-delete %s %s", book_id, e.id),
                                    nil, _("Deleting…"))
                                if not res then return self:showError(err) end
                                UIManager:nextTick(function() self:showHistory(list_back) end)
                            end)
                        end,
                    })
                end,
            },
        }},
    }
    UIManager:show(viewer)
end

function AskClaude:confirmClearHistory(book_id, to_list, back)
    UIManager:show(ConfirmBox:new{
        text = _("Delete all questions and answers about this book? Claude will no longer remember them."),
        ok_text = _("Clear"),
        cancel_callback = to_list,
        ok_callback = function()
            self:withConnection(function()
                local res, err = self:remote("history-clear " .. book_id, nil, _("Clearing…"))
                if not res then return self:showError(err) end
                self:saveSession(book_id, nil)
                UIManager:show(InfoMessage:new{ text = _("History cleared."), timeout = 2 })
                if back then UIManager:nextTick(back) end
            end)
        end,
    })
end

-- help modules (live on the computer) ----------------------------------------

-- A module with a prompt is a button; one with only guidance is a rule that
-- shapes every answer.
local function isButton(m)
    return (str(m.kind) or ""):find("action") ~= nil
end

function AskClaude:showModules(selection, back)
    self:withConnection(function()
        local res, err = self:remote("modules", nil, _("Loading modules…"))
        if not res then return self:showError(err) end
        self:renderModules(type(res.modules) == "table" and res.modules or {}, selection, back)
    end)
end

function AskClaude:renderModules(modules, selection, back)
    local function again() self:renderModules(modules, selection, back) end
    local button_rows, rule_rows = {}, {}
    for _i, m in ipairs(modules) do
        table.insert(isButton(m) and button_rows or rule_rows, {
            text = (m.enabled == true and "● " or "○ ") .. (str(m.label) or str(m.id) or "?"),
            callback = function() self:showModule(m, selection, again, back) end,
        })
    end
    local rows = {}
    for _i, section in ipairs({ { _("Buttons"), button_rows }, { _("Rules"), rule_rows } }) do
        if #section[2] > 0 then
            table.insert(rows, { header = true, text = section[1] })
            for _j, r in ipairs(section[2]) do table.insert(rows, r) end
        end
    end
    self:showList(_("Modules (● on, ○ off)"), rows, back, {{
        text = _("+ New module"),
        callback = function() self:promptNewModule(selection, again, back) end,
    }})
end

-- Runs a module-changing request, updates the cached menu, reopens the list.
function AskClaude:moduleCommand(verb, id, message, selection, back)
    self:withConnection(function()
        local res, err = self:remote(verb .. " " .. id, nil, message)
        if not res then return self:showError(err) end
        if type(res.actions) == "table" then self:saveActions(res.actions) end
        UIManager:nextTick(function() self:showModules(selection, back) end)
    end)
end

-- `to_list` reopens the module list; `list_back` is where the list goes back to.
function AskClaude:showModule(m, selection, to_list, list_back)
    local enabled = m.enabled == true
    local button = isButton(m)
    -- Buttons made for highlighted text need a selection to make sense.
    local can_ask = button and enabled and (selection ~= nil or m.scope ~= "selection")
    local note
    if not button then
        note = _("A rule: it shapes every answer, so there's nothing to tap.")
    elseif not enabled then
        note = _("This button is turned off.")
    elseif not can_ask then
        note = _("Works on highlighted text: select a passage first.")
    end
    local viewer
    local function reshow() self:showModule(m, selection, to_list, list_back) end
    local function close_then(fn)
        return function()
            UIManager:close(viewer)
            fn()
        end
    end
    local first_row = {}
    if button then
        table.insert(first_row, {
            text = _("Ask now"),
            enabled = can_ask,
            callback = close_then(function()
                self:ask{ selection = selection, action = m.id, label = str(m.label), back = reshow }
            end),
        })
    end
    table.insert(first_row, {
        text = enabled and _("Turn off") or _("Turn on"),
        callback = close_then(function()
            self:moduleCommand(enabled and "module-disable" or "module-enable", m.id, _("Saving…"),
                selection, list_back)
        end),
    })
    viewer = TextViewer:new{
        title = str(m.label) or str(m.id) or _("Module"),
        text = (note and (note .. "\n\n") or "") .. (str(m.content) or ""),
        buttons_table = {
            first_row,
            {
                { text = BACK, callback = close_then(to_list) },
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Delete the module “%1”? It is moved to the trash folder on your computer."),
                                str(m.label) or m.id),
                            ok_text = _("Delete"),
                            ok_callback = close_then(function()
                                self:moduleCommand("module-delete", m.id, _("Deleting…"), selection, list_back)
                            end),
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

function AskClaude:promptNewModule(selection, to_list, list_back)
    local dialog
    dialog = InputDialog:new{
        title = _("Create a module"),
        description = _("Describe what would help, e.g. “a button listing unresolved mysteries and their clues” or “always say which chapter an event happened in”. Claude also sees your recent questions about this book, to tailor the module to what you've needed. The module will work for any book."),
        input_hint = _("What should the module do?"),
        allow_newline = true,
        buttons = {{
            {
                text = to_list and BACK or _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if to_list then to_list() end
                end,
            },
            {
                text = _("Create"),
                is_enter_default = true,
                callback = function()
                    local description = trim(dialog:getInputText())
                    if description == "" then return end
                    UIManager:close(dialog)
                    self:createModule(description, selection, list_back)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AskClaude:createModule(description, selection, list_back)
    local book_id = self:bookId()
    self:withConnection(function()
        local reqfile = self:writeRequest("module_request", { description = description, book_id = book_id })
        if not reqfile then return self:showError(_("Couldn't write the request file.")) end
        local res, err = self:remote("module-new", reqfile, _("Claude is writing the module…\n\nTap to cancel."))
        os.remove(reqfile)
        if not res then return self:showError(err) end
        local id = str(res.id)
        if not id then return self:showError(_("No module came back.")) end
        local viewer
        viewer = TextViewer:new{
            title = T(_("New module: %1"), str(res.label) or id),
            text = str(res.content) or "",
            buttons_table = {{
                {
                    text = _("Discard"),
                    callback = function()
                        UIManager:close(viewer)
                        self:withConnection(function()
                            self:remote("module-discard " .. id, nil, _("Discarding…"))
                            UIManager:nextTick(function() self:showModules(selection, list_back) end)
                        end)
                    end,
                },
                {
                    text = _("Add"),
                    callback = function()
                        UIManager:close(viewer)
                        self:moduleCommand("module-add", id, _("Adding the module…"), selection, list_back)
                    end,
                },
            }},
        }
        UIManager:show(viewer)
    end)
end

function AskClaude:doAsk(opts)
    local ctx = self:getContext()
    if not ctx.book_id then
        return self:showError(_("Couldn't identify this book."))
    end
    local ok, err = self:ensureBook(ctx)
    if not ok then return self:showError(err) end

    local req = {
        book_id = ctx.book_id,
        title = ctx.title,
        authors = ctx.authors,
        chapter = ctx.chapter,
        percent = ctx.percent,
        page_text = ctx.page_text,
        toc = ctx.toc,
        selection = opts.selection,
        action = opts.action,
        question = opts.question,
        session_id = opts.session_id,
        spoilers_ok = self:spoilersOk(ctx.book_id),
    }
    local reqfile = self:writeRequest("request", req)
    if not reqfile then return self:showError(_("Couldn't write the request file.")) end

    local res
    res, err = self:remote("ask", reqfile, _("Claude is reading…\n\nThis usually takes 10–40 seconds. Tap to cancel."))
    os.remove(reqfile)
    if not res then return self:showError(err) end
    if type(res.actions) == "table" then self:saveActions(res.actions) end
    local session_id = str(res.session_id)
    if session_id then self:saveSession(ctx.book_id, session_id, res.conversation) end
    self:showAnswer(opts, str(res.answer) or "", session_id)
end

-- main menu -----------------------------------------------------------------

function AskClaude:refreshActions()
    self:withConnection(function()
        local res, err = self:remote("actions", nil, _("Fetching the menu from your computer…"))
        if not res then return self:showError(err) end
        self:saveActions(res.actions or {})
        UIManager:show(InfoMessage:new{
            text = T(_("Menu updated: %1 actions."), #self:getActions()),
            timeout = 3,
        })
    end)
end

function AskClaude:testConnection()
    self:withConnection(function()
        local res, err = self:remote("ping", nil, _("Connecting to your computer…"))
        if not res then return self:showError(err) end
        UIManager:show(InfoMessage:new{ text = _("Connected to your computer."), timeout = 3 })
    end)
end

function AskClaude:resendBook()
    self:withConnection(function()
        local ok, err = self:ensureBook(self:getContext(), true)
        if not ok then return self:showError(err) end
        UIManager:show(InfoMessage:new{ text = _("Book sent."), timeout = 3 })
    end)
end

function AskClaude:editServer(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Computer running Claude Code"),
        description = _("Format: user@address:port"),
        input = self:get("host") ~= ""
            and string.format("%s@%s:%s", self:get("user"), self:get("host"), self:get("port")) or "",
        input_hint = "user@192.168.1.10:22",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local user, host, port = trim(dialog:getInputText()):match("^([^@%s]+)@([^:%s]+):?(%d*)$")
                    if not user then
                        UIManager:show(InfoMessage:new{ text = _("Use the form user@address:port") })
                        return
                    end
                    self:set("user", user)
                    self:set("host", host)
                    self:set("port", tonumber(port) or 22)
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AskClaude:addToMainMenu(menu_items)
    menu_items.ask_claude = {
        text = _("Ask Claude"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open Ask Claude menu"),
                callback = function() self:showMenu(nil) end,
            },
            {
                text = _("History for this book"),
                callback = function() self:showHistory() end,
            },
            {
                text = _("Help modules"),
                callback = function() self:showModules() end,
            },
            {
                text = _("Spoilers OK for this book"),
                checked_func = function() return self:spoilersOk() end,
                callback = function() self:toggleSpoilersOk() end,
            },
            {
                text = _("Refresh menu from computer"),
                callback = function() self:refreshActions() end,
            },
            {
                text = _("Re-send this book"),
                callback = function() self:resendBook() end,
            },
            {
                text = _("Test connection"),
                callback = function() self:testConnection() end,
            },
            {
                text_func = function()
                    if self:get("host") == "" then return _("Computer: not set") end
                    return T(_("Computer: %1@%2:%3"), self:get("user"), self:get("host"), self:get("port"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:editServer(touchmenu_instance) end,
            },
        },
    }
end

return AskClaude
