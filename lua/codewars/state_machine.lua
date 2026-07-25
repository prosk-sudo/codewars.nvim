--- Generic transition-table state machine.
---
--- The kumite and kata workspaces each had a byte-identical
--- step/is_editable/is_locked/label engine; only their transition tables
--- genuinely differ (kumite has `fork` across 7 states, kata has
--- `validate`/`delete` across 4). The engine lives here so a fix to it cannot
--- land in one copy and silently miss the other.
---@class cw.StateMachine
local M = {}

--- Sentinel: the caller restores the state it saved before entering an
--- in-flight state (the machine itself is memoryless).
M.REVERT = "revert"

---@class cw.StateMachine.Spec
---@field transitions table<string, table<string, string|{ err: string }>>
---@field editable table<string, boolean>?
---@field locked table<string, boolean>?
---@field labels table<string, string>?
---@field kind string? used in the assert message for an unknown state

--- Build a machine from its data tables.
---@param spec cw.StateMachine.Spec
---@return table
function M.new(spec)
    local transitions = spec.transitions
    local editable = spec.editable or {}
    local locked = spec.locked or {}
    local labels = spec.labels or {}
    local kind = spec.kind or "workspace"

    local sm = { REVERT = M.REVERT, transitions = transitions }

    --- Take `action` from `current`.
    ---@param current string
    ---@param action string
    ---@return string? next_state # nil when rejected; may be REVERT
    ---@return string? err # user-facing, state-aware message when rejected
    function sm.step(current, action)
        local row = transitions[current]
        assert(row, ("unknown %s state: %s"):format(kind, tostring(current)))
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
    function sm.is_editable(s)
        return editable[s] == true
    end

    ---@param s string
    ---@return boolean
    function sm.is_locked(s)
        return locked[s] == true
    end

    --- Display label for the workspace title.
    ---@param s string
    ---@return string
    function sm.label(s)
        return labels[s] or s
    end

    return sm
end

return M
