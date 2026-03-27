describe("solutions.parse_html", function()
    local solutions = require("codewars.api.solutions")

    it("extracts code from valid HTML", function()
        local html = [[
<div>
  <pre><code>def multiply(a, b):
    return a * b</code></pre>
  <pre><code>def solution(a, b):
    return a * b</code></pre>
</div>
]]
        local result = solutions.parse_html(html, "python")
        -- First block is skipped (test fixture) when multiple exist
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("def solution"))
    end)

    it("keeps single code block (no fixture skip)", function()
        local html = '<pre><code>def solution(a, b):\n    return a * b</code></pre>'
        local result = solutions.parse_html(html, "python")
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("def solution"))
    end)

    it("unescapes HTML entities", function()
        local html = '<pre><code>if a &lt; b &amp;&amp; c &gt; d:\n    return &quot;hello&quot;</code></pre>'
        local result = solutions.parse_html(html, "python")
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("if a < b"))
        assert.truthy(result[1]:find('return "hello"'))
    end)

    it("unescapes &#39; and &#x27; to single quote", function()
        local html = "<pre><code>s = &#39;hello&#x27;</code></pre>"
        local result = solutions.parse_html(html, "python")
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("s = 'hello'"))
    end)

    it("returns empty for no code blocks", function()
        local html = "<div>No code here</div>"
        local result = solutions.parse_html(html, "python")
        assert.are.equal(0, #result)
    end)

    it("filters out short code blocks (<= 10 chars)", function()
        local html = '<pre><code>short</code></pre>'
        local result = solutions.parse_html(html, "python")
        assert.are.equal(0, #result)
    end)

    it("handles empty HTML", function()
        local result = solutions.parse_html("", "python")
        assert.are.equal(0, #result)
    end)

    it("skips first block when multiple exist", function()
        local html = [[
<pre><code>import Test from "test-framework"</code></pre>
<pre><code>function solution_one(a, b) { return a * b; }</code></pre>
<pre><code>function solution_two(a, b) { return a + b; }</code></pre>
]]
        local result = solutions.parse_html(html, "javascript")
        assert.are.equal(2, #result)
        assert.truthy(result[1]:find("solution_one"))
        assert.truthy(result[2]:find("solution_two"))
    end)
end)
