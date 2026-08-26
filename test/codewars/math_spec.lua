local math_ = require("codewars-ui.math")
local markdown = require("codewars-ui.markdown")

describe("math.to_text", function()
    it("renders fractions, roots and scripts as readable text", function()
        assert.equals("(x_A + x_B + x_C)/3", math_.to_text("\\frac{x_A + x_B + x_C}{3}"))
        assert.equals("1/2", math_.to_text("\\frac{1}{2}"))
        assert.equals("x² + y²", math_.to_text("x^2 + y^2"))
        assert.equals("aᵢ₊₁", math_.to_text("a_{i+1}"))
        assert.equals("2ⁿ⁺¹", math_.to_text("2^{n+1}"))
        assert.equals("x^(y+Q)", math_.to_text("x^{y+Q}"))
        assert.equals("√(n+1)", math_.to_text("\\sqrt{n+1}"))
        assert.equals("³√8", math_.to_text("\\sqrt[3]{8}"))
    end)

    it("maps symbols and keeps unknown commands readable", function()
        assert.equals("α ≤ β · ∞", math_.to_text("\\alpha \\le \\beta \\cdot \\infty"))
        assert.equals("∑ᵢ₌₁ⁿ i", math_.to_text("\\sum_{i=1}^{n} i"))
        assert.equals("ℕ → ℝ", math_.to_text("\\mathbb{N} \\to \\mathbb{R}"))
        assert.equals("(a + b)", math_.to_text("\\left( a + b \\right)"))
        assert.equals("foo(x)", math_.to_text("\\foo(x)"))
        assert.equals("gcd(a, b) mod n", math_.to_text("\\gcd(a,\\,b) \\bmod n"))
    end)

    it("turns \\\\ into line breaks", function()
        assert.equals("a = 1\nb = 2", math_.to_text("a = 1 \\\\ b = 2"))
    end)
end)

describe("markdown.from_html math", function()
    it("renders a $$ block with line breaks as a fenced block", function()
        local out = markdown.from_html("Centroid:\n$$\nx_O = \\frac{x_A + x_B + x_C}{3}\n\\\\\ny_O = \\frac{y_A + y_B + y_C}{3}\n$$\nDone.")
        assert.truthy(out:find("```\nx_O = (x_A + x_B + x_C)/3\ny_O = (y_A + y_B + y_C)/3\n```", 1, true))
        assert.truthy(out:find("Centroid:", 1, true) and out:find("Done.", 1, true))
    end)

    it("renders a ```math fence the same way and leaves other fences alone", function()
        local out = markdown.from_html("```math\nn^2 \\le m\n```\n```python\nprice = \"$5\"\n```")
        assert.truthy(out:find("```\nn² ≤ m\n```", 1, true))
        assert.truthy(out:find('price = "$5"', 1, true))
    end)

    it("renders inline math as a code span and leaves prices alone", function()
        assert.equals("Area is `π · r²` here.", markdown.from_html("Area is $\\pi \\cdot r^2$ here."))
        assert.equals("It costs $5 and $10.", markdown.from_html("It costs $5 and $10."))
        assert.equals("Use `$HOME`.", markdown.from_html("Use `$HOME`."))
    end)

    it("renders math written inside a code span, as Codewars does", function()
        local out = markdown.from_html(table.concat({
            "* `$\\text{Min} = \\dfrac{ \\text{Age} } {2} + 7$`",
            "* `$\\text{Max} = 2 \\cdot (\\text{Age - 7})$`",
            "* `$\\text{Minimum age} \\le \\text{Your age} \\le \\text{Maximum age}$`",
        }, "\n"))
        assert.equals(table.concat({
            "* `Min = Age/2 + 7`",
            "* `Max = 2 · (Age - 7)`",
            "* `Minimum age ≤ Your age ≤ Maximum age`",
        }, "\n"), out)
        assert.equals("`x²`", markdown.from_html("`$x^2$`"))
    end)
end)
