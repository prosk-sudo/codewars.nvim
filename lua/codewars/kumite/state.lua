local state_machine = require("codewars.state_machine")

--- Kumite workspace states. Data only — the
--- step/is_editable/is_locked/label engine lives in codewars.state_machine,
--- shared with the kata machine so a fix to it cannot miss one of them.
---
---   published_view ──fork──▶ local_fork ──save──▶ saving ──save_done──▶ server_draft
---        │                       │                   │
---       run                   publish            save_failed ▶ REVERT (caller restores)
---        ▼                       ▼
---   published_view          publishing ──publish_done──▶ published
local REVERT = state_machine.REVERT

local EDITABLE = { local_new = true, local_fork = true, server_draft = true }

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
    saving = {
        edit = { err = SAVING_LOCKED },
        run = { err = SAVING_LOCKED },
        save = { err = "Already saving." },
        publish = { err = SAVING_LOCKED },
        fork = { err = SAVING_LOCKED },
        save_done = "server_draft",
        save_failed = REVERT,
    },
    publishing = {
        edit = { err = PUBLISHING_LOCKED },
        run = { err = PUBLISHING_LOCKED },
        save = { err = PUBLISHING_LOCKED },
        publish = { err = "Already publishing." },
        fork = { err = PUBLISHING_LOCKED },
        publish_done = "published",
        publish_failed = REVERT,
    },
    published = {
        run = "published",
        fork = "local_fork",
        edit = { err = "This kumite is published — fork it to keep iterating." },
        save = { err = "Already published." },
        publish = { err = "Already published." },
    },
}

-- The three editable states share one shape: stay put on edit/run, hand
-- off to the in-flight states on save/publish.
for editable_state in pairs(EDITABLE) do
    transitions[editable_state] = {
        edit = editable_state,
        run = editable_state,
        save = "saving",
        publish = "publishing",
        fork = { err = ALREADY_EDITABLE },
    }
end

---@class cw.kumite.State
return state_machine.new({
    transitions = transitions,
    editable = EDITABLE,
    locked = { saving = true, publishing = true },
    labels = {
        published_view = "Published (read-only)",
        local_new = "New (unsaved)",
        local_fork = "Local fork (unsaved)",
        server_draft = "Draft",
        saving = "Saving…",
        publishing = "Publishing…",
        published = "Published",
    },
    kind = "kumite",
})
