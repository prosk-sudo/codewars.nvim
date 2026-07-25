--- Pure kata-authoring state machine (design KP2), same shape as
--- codewars.kumite.state: no UI access, so the whole matrix is spec-able
--- without a buffer existing. The workspace holds the current value and
--- calls step(); every wrong-state message lives here.
---
---   draft ──save──▶ saving ──save_done──▶ REVERT (back to draft)
---     │
---  publish
---     ▼
---  publishing ──publish_done──▶ published ──unpublish──▶ draft
---
--- Saving never changes publication, so `saving` reverts to whichever state
--- entered it — that is why save_done is REVERT and not a fixed state.
---@class cw.kata.State
local state = {}

--- Sentinel: the caller restores the state it saved before entering
--- saving/publishing (the machine itself is memoryless).
state.REVERT = "revert"

local EDITABLE = { draft = true, published = true }
local LOCKED = { saving = true, publishing = true }

local LABELS = {
    draft = "Draft",
    saving = "Saving…",
    publishing = "Publishing…",
    published = "Published",
}

local SAVING_LOCKED = "Saving in progress — wait for it to finish."
local PUBLISHING_LOCKED = "Publishing in progress — wait for it to finish."

--- transitions[state][action] = next-state string, or { err = message }.
local transitions = {
    draft = {
        edit = "draft",
        validate = "draft",
        save = "saving",
        publish = "publishing",
        delete = "draft",
        unpublish = { err = "This kata isn't published yet — nothing to unpublish." },
    },
    published = {
        edit = "published",
        validate = "published",
        save = "saving",
        delete = "published",
        unpublish = "draft",
        publish = { err = "Already published — :CW kata unpublish to take it back to a draft." },
    },
    saving = {
        edit = { err = SAVING_LOCKED },
        validate = { err = SAVING_LOCKED },
        save = { err = "Already saving." },
        publish = { err = SAVING_LOCKED },
        unpublish = { err = SAVING_LOCKED },
        delete = { err = SAVING_LOCKED },
        save_done = state.REVERT,
        save_failed = state.REVERT,
    },
    publishing = {
        edit = { err = PUBLISHING_LOCKED },
        validate = { err = PUBLISHING_LOCKED },
        save = { err = PUBLISHING_LOCKED },
        publish = { err = "Already publishing." },
        unpublish = { err = PUBLISHING_LOCKED },
        delete = { err = PUBLISHING_LOCKED },
        publish_done = "published",
        publish_failed = state.REVERT,
    },
}

state.transitions = transitions

---@param current string
---@param action string
---@return string? next_state # nil when rejected; may be state.REVERT
---@return string? err # user-facing, state-aware message when rejected
function state.step(current, action)
    local row = transitions[current]
    assert(row, "unknown kata state: " .. tostring(current))
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

--- The state a freshly-loaded model starts in.
---@param published boolean
---@return string
function state.of(published)
    return published and "published" or "draft"
end

--- Display label for the workspace title.
---@param s string
---@return string
function state.label(s)
    return LABELS[s] or s
end

return state
