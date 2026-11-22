local state_machine = require("codewars.state_machine")

--- Kata-authoring states. Data only — the step/is_editable/
--- is_locked/label engine lives in codewars.state_machine, shared with the
--- kumite machine so a fix to it cannot miss one of them.
---
---   draft ──save──▶ saving ──save_done──▶ REVERT (back to draft)
---     │
---  publish
---     ▼
---  publishing ──publish_done──▶ published
---                                  │
---                              unpublish
---                                  ▼
---  draft ◀──unpublish_done── unpublishing ──unpublish_failed──▶ REVERT
---
---  draft / published ──delete──▶ deleting ──delete_done──▶ deleted (terminal)
---                                         └─delete_failed─▶ REVERT
---
--- Saving never changes publication, so `saving` reverts to whichever state
--- entered it — that is why save_done is REVERT and not a fixed state.
---
--- Unpublishing and deleting refuse every other action until the reply lands; a
--- failure reverts. `deleted` is terminal, so a pending prompt cannot act on a gone kata.
local REVERT = state_machine.REVERT

local SAVING_LOCKED = "Saving in progress — wait for it to finish."
local PUBLISHING_LOCKED = "Publishing in progress — wait for it to finish."
local UNPUBLISHING_LOCKED = "Unpublishing in progress — wait for it to finish."
local DELETING_LOCKED = "Deleting in progress — wait for it to finish."
local DELETED = "This kata was deleted — there is nothing left to do with it."

--- transitions[state][action] = next-state string, or { err = message }.
local transitions = {
    draft = {
        edit = "draft",
        validate = "draft",
        save = "saving",
        publish = "publishing",
        delete = "deleting",
        unpublish = { err = "This kata isn't published yet — nothing to unpublish." },
    },
    published = {
        edit = "published",
        validate = "published",
        save = "saving",
        delete = "deleting",
        unpublish = "unpublishing",
        publish = { err = "Already published — :CW kata unpublish to take it back to a draft." },
    },
    saving = {
        edit = { err = SAVING_LOCKED },
        validate = { err = SAVING_LOCKED },
        save = { err = "Already saving." },
        publish = { err = SAVING_LOCKED },
        unpublish = { err = SAVING_LOCKED },
        delete = { err = SAVING_LOCKED },
        save_done = REVERT,
        save_failed = REVERT,
    },
    publishing = {
        edit = { err = PUBLISHING_LOCKED },
        validate = { err = PUBLISHING_LOCKED },
        save = { err = PUBLISHING_LOCKED },
        publish = { err = "Already publishing." },
        unpublish = { err = PUBLISHING_LOCKED },
        delete = { err = PUBLISHING_LOCKED },
        publish_done = "published",
        publish_failed = REVERT,
    },
    unpublishing = {
        edit = { err = UNPUBLISHING_LOCKED },
        validate = { err = UNPUBLISHING_LOCKED },
        save = { err = UNPUBLISHING_LOCKED },
        publish = { err = UNPUBLISHING_LOCKED },
        unpublish = { err = "Already unpublishing." },
        delete = { err = UNPUBLISHING_LOCKED },
        unpublish_done = "draft",
        unpublish_failed = REVERT,
    },
    deleting = {
        edit = { err = DELETING_LOCKED },
        validate = { err = DELETING_LOCKED },
        save = { err = DELETING_LOCKED },
        publish = { err = DELETING_LOCKED },
        unpublish = { err = DELETING_LOCKED },
        delete = { err = "Already deleting." },
        delete_done = "deleted",
        delete_failed = REVERT,
    },
    deleted = {
        edit = { err = DELETED },
        validate = { err = DELETED },
        save = { err = DELETED },
        publish = { err = DELETED },
        unpublish = { err = DELETED },
        delete = { err = DELETED },
    },
}

---@class cw.kata.State
local state = state_machine.new({
    transitions = transitions,
    editable = { draft = true, published = true },
    locked = { saving = true, publishing = true, unpublishing = true, deleting = true, deleted = true },
    labels = {
        draft = "Draft",
        saving = "Saving…",
        publishing = "Publishing…",
        published = "Published",
        unpublishing = "Unpublishing…",
        deleting = "Deleting…",
        deleted = "Deleted",
    },
    kind = "kata",
})

--- The state a freshly-loaded model starts in.
---@param published boolean
---@return string
function state.of(published)
    return published and "published" or "draft"
end

return state
