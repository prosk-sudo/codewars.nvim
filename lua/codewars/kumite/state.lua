--- Pure kumite workspace state machine (design §3.4, eng review D3/D16).
--- No UI access: the workspace holds the current state value and calls
--- step(); every transition and every wrong-state message lives here so
--- the full matrix is spec-able without a buffer existing.
---
---   published_view ──fork──▶ local_fork ──save──▶ saving ──save_done──▶ server_draft
---        │                       │                   │
---       run                   publish            save_failed ▶ REVERT (caller restores)
---        ▼                       ▼
---   published_view          publishing ──publish_done──▶ published
---
---@class cw.kumite.State
local state = {}

--- Sentinel: caller restores the state it saved before entering
--- saving/publishing (the machine itself is memoryless).
state.REVERT = "revert"

local EDITABLE = { local_new = true, local_fork = true, server_draft = true }
local LOCKED = { saving = true, publishing = true }

local LABELS = {
    published_view = "Published (read-only)",
    local_new = "New (unsaved)",
    local_fork = "Local fork (unsaved)",
    server_draft = "Draft",
    saving = "Saving…",
    publishing = "Publishing…",
    published = "Published",
}

local READ_ONLY_EDIT = "This kumite is read-only — :CW kumite fork to edit a copy."
local ALREADY_EDITABLE = "Already an editable local copy."
local SAVING_LOCKED = "Saving in progress — wait for it to finish."
local PUBLISHING_LOCKED = "Publishing in progress — wait for it to finish."

--- transitions[state][action] = next-state string, or { err = message }.
--- Unlisted (state, action) pairs are programming errors, not user errors.
local transitions = {
    published_view = {
        run = "published_view",
        fork = "local_fork",
        edit = { err = READ_ONLY_EDIT },
        save = { err = "Nothing to save — this is someone else's kumite. Fork it first." },
        publish = { err = "Publish is only available for an editable draft." },
    },
    local_new = {
        edit = "local_new",
        run = "local_new",
        save = "saving",
        publish = "publishing",
        fork = { err = ALREADY_EDITABLE },
    },
    local_fork = {
        edit = "local_fork",
        run = "local_fork",
        save = "saving",
        publish = "publishing",
        fork = { err = ALREADY_EDITABLE },
    },
    server_draft = {
        edit = "server_draft",
        run = "server_draft",
        save = "saving",
        publish = "publishing",
        fork = { err = ALREADY_EDITABLE },
    },
    saving = {
        edit = { err = SAVING_LOCKED },
        run = { err = SAVING_LOCKED },
        save = { err = "Already saving." },
        publish = { err = SAVING_LOCKED },
        fork = { err = SAVING_LOCKED },
        save_done = "server_draft",
        save_failed = state.REVERT,
    },
    publishing = {
        edit = { err = PUBLISHING_LOCKED },
        run = { err = PUBLISHING_LOCKED },
        save = { err = PUBLISHING_LOCKED },
        publish = { err = "Already publishing." },
        fork = { err = PUBLISHING_LOCKED },
        publish_done = "published",
        publish_failed = state.REVERT,
    },
    published = {
        run = "published",
        fork = "local_fork",
        edit = { err = "This kumite is published — fork it to keep iterating." },
        save = { err = "Already published." },
        publish = { err = "Already published." },
    },
}

state.transitions = transitions

---@param current string
---@param action string
---@return string? next_state # nil when rejected; may be state.REVERT
---@return string? err # user-facing, state-aware message when rejected
function state.step(current, action)
    local row = transitions[current]
    assert(row, "unknown kumite state: " .. tostring(current))
    local cell = row[action]
    if cell == nil then
        return nil, ("Action '%s' is not available in state '%s'."):format(action, current)
    end
    if type(cell) == "table" then
        return nil, cell.err
    end
    return cell, nil
end

---@param s string
---@return boolean
function state.is_editable(s)
    return EDITABLE[s] == true
end

---@param s string
---@return boolean
function state.is_locked(s)
    return LOCKED[s] == true
end

--- Display label for the workspace title:
--- `Kumite · {title} · {lang} · {label}[ +]`
---@param s string
---@return string
function state.label(s)
    return LABELS[s] or s
end

return state
