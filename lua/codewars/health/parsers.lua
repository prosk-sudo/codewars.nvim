--- Parser drift self-check for `:CW doctor`.
---
--- Codewars publishes no API for most of what this plugin reads, so the
--- parsers match against HTML shapes. When Codewars changes that markup the
--- patterns stop matching SILENTLY: the kata editor opens with blank metadata,
--- and saving that blank metadata back erases the kata's name and tags.
---
--- Each fixture below is the shape last verified against the live site. Running
--- the real parser over it proves the parser still extracts what we expect.
--- It does NOT prove Codewars still serves that shape — refreshing a fixture is
--- how you check that — but it turns a silent parser regression into a
--- diagnostic the user can run.
---@class cw.health.Parsers
local M = {}

local KATA_EDIT = table.concat({
    [[<html><body><script>App.setup({ data: JSON.parse("]],
    [[{\"controllerName\":\"code_challenges\",\"language\":\"python\",]],
    [[\"languages\":{\"python\":{\"id\":\"aaaaaaaaaaaaaaaaaaaaaaaa\",\"name\":\"python\",]],
    [[\"answer\":\"def%20hi%28%29%3A%0A%20%20%20%20pass\",\"setup\":\"\",]],
    [[\"fixture\":\"test\",\"example_fixture\":\"\",\"package\":\"\"}},]],
    [[\"published\":false,\"id\":\"bbbbbbbbbbbbbbbbbbbbbbbb\",]],
    [[\"testFrameworks\":{\"python\":\"cw-2\"},]],
    [[\"versionInfo\":{\"python\":[{\"id\":\"3.11\",\"label\":\"3.11\",\"default\":true}]}}]],
    [[") });</script>]],
    [[<input class="string optional" type="text" value="Sample&#39;s Kata" ]],
    [[name="code_challenge[name]" id="code_challenge_name" />]],
    [[<input autocomplete="off" type="hidden" value="algorithms" ]],
    [[name="code_challenge[category]" id="code_challenge_category" />]],
    [[<select name="code_challenge[estimated_rank]" id="code_challenge_estimated_rank">]],
    [[<option value=""></option><option selected="selected" value="-6">6 kyu</option></select>]],
    [[<input type="text" value="Strings" name="code_challenge[tags_text]" id="code_challenge_tags_text" />]],
    [[<input checked="checked" id="code_challenge_coauthors_wanted" ]],
    [[name="code_challenge[coauthors_wanted]" type="checkbox" value="true" />]],
    [[<textarea name="code_challenge[description]" id="code_challenge_description">]],
    "\nDescribe it.",
    [[</textarea></body></html>]],
})

local KUMITE_LIST = table.concat({
    [[<div class="code-snippet-list-item foo">]],
    [[<a href="/kumite/new?parent=cccccccccccccccccccccccc">Fork</a>]],
    [[<h3 class="m-0"><a class="is-alt" href="/kumite/cccccccccccccccccccccccc">Sample &amp; Co</a></h3>]],
    [[<i class="icon-moon-user "></i><a href="/users/someone">someone</a>]],
    [[<pre lang="python"><code>print(1)</code></pre>]],
    [[</div>]],
})

local SOLUTIONS = table.concat({
    [[<div id="solutions_list">]],
    [[<div class="js-result-group" data-controller="solution-group" ]],
    [[data-solution-group-group-id-value="dddddddddddddddddddddddd" ]],
    [[data-solution-group-review-id-value="eeeeeeeeeeeeeeeeeeeeeeee" id="dddddddddddddddddddddddd">]],
    [[<h6 class="solution-group-users-list my-4"><i class="icon-moon-users "></i>]],
    [[<a class="font-semibold" href="/users/someone">someone</a><span> (+ 3)</span></h6>]],
    [[<pre class="p-2"><code data-language="python">def f(x): return x</code></pre>]],
    [[<ul class="vote-labels" data-vote-name="solution-solution_group" data-vote-ref-id="dddddddddddddddddddddddd">]],
    [[<li><a class="vote-label" data-label="best_practice"><i class="icon-moon-up "></i>Best Practices<span>487</span></a></li>]],
    [[<li><a class="vote-label is-voted" data-label="clever"><i class="icon-moon-up "></i>Clever<span>168</span></a></li></ul>]],
    [[<div class="comments-list-component" v-scope data-view-data="{&quot;comments&quot;:[{&quot;id&quot;:&quot;c1&quot;,]],
    [[&quot;markdown&quot;:&quot;hi&quot;,&quot;nest_level&quot;:0,&quot;votes_score&quot;:1,]],
    [[&quot;created_at_datetime&quot;:&quot;2026-08-01T00:00:00.000+0000&quot;,]],
    [[&quot;user&quot;:{&quot;username&quot;:&quot;alice&quot;,&quot;rank_name&quot;:&quot;2 kyu&quot;},&quot;comments&quot;:[]}],]],
    [[&quot;totalComments&quot;:1}"></div></div></div>]],
})

--- Each check returns ok, detail.
M.checks = {
    {
        name = "kata edit page parser",
        verified = "2026-07-25",
        run = function()
            local model = require("codewars.api.kata_page").parse_edit_page(KATA_EDIT)
            if not model then
                return false, "parse_edit_page returned nil — the embedded App.setup blob no longer matches"
            end
            local py = (model.languages or {}).python or {}
            local cc = model.code_challenge or {}
            local missing = {}
            if py.answer ~= "def hi():\n    pass" then missing[#missing + 1] = "answer (percent-decode)" end
            if cc.name ~= "Sample's Kata" then missing[#missing + 1] = "name" end
            if cc.category ~= "algorithms" then missing[#missing + 1] = "category" end
            if cc.estimated_rank ~= "-6" then missing[#missing + 1] = "estimated_rank" end
            if cc.tags_text ~= "Strings" then missing[#missing + 1] = "tags_text" end
            if cc.coauthors_wanted ~= true then missing[#missing + 1] = "coauthors_wanted" end
            if cc.description ~= "Describe it." then missing[#missing + 1] = "description" end
            if ((model.version_info or {}).python or {})[1] == nil then missing[#missing + 1] = "versionInfo" end
            if #missing > 0 then
                return false, "fields not extracted: " .. table.concat(missing, ", ")
            end
            return true, "8/8 fields"
        end,
    },
    {
        name = "kumite list parser",
        verified = "2026-07-24",
        run = function()
            local result = require("codewars.api.kumite").parse_list_html(KUMITE_LIST)
            local entry = (result.entries or {})[1]
            if not entry then
                return false, "no entries parsed — the code-snippet-list-item markup changed"
            end
            if entry.title ~= "Sample & Co" then
                return false, "title not HTML-unescaped"
            end
            if entry.code ~= "print(1)" then
                return false, "code block not extracted"
            end
            return true, "1 entry, all fields"
        end,
    },
    {
        name = "solutions page parser",
        verified = "2026-08-23",
        run = function()
            local result = require("codewars.api.solutions").parse(SOLUTIONS, "python")
            local s = result[1]
            if not s or #result ~= 1 then
                return false, "no solution group parsed — the data-solution-group-group-id-value wrapper changed"
            end
            if s.code ~= "def f(x): return x" then
                return false, "code block not extracted from the group"
            end
            if s.votes.best_practice ~= 487 or s.votes.clever ~= 168 then
                return false, "vote counts not read — the vote-labels markup changed"
            end
            -- Voting needs the group and review ids and the user's own vote;
            -- without asserting them the check stayed green while voting
            -- was broken.
            if s.id ~= "dddddddddddddddddddddddd" or s.review_id ~= "eeeeeeeeeeeeeeeeeeeeeeee" then
                return false, "group/review ids not read — the data-solution-group-*-id-value attributes changed (voting breaks)"
            end
            if s.voted.clever ~= true or s.voted.best_practice ~= false then
                return false, "own vote not read — the is-voted class changed"
            end
            if s.authors[1] ~= "someone" or s.extra_authors ~= 3 then
                return false, "author list not read — the solution-group-users-list markup changed"
            end
            if s.total_comments ~= 1 or (s.comments[1] or {}).author ~= "alice" then
                return false, "comments not decoded — the data-view-data JSON changed"
            end
            return true, "1 group: code, votes, authors, 1 comment"
        end,
    },
}

return M
