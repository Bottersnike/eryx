local test = require("@eryx/test")
local text = require("@eryx/text")

local suite = test.Suite.new("text")

suite:test("startsWith and endsWith handle normal empty and oversized affixes", function()
	test.expect(text.startsWith("prefix-value", "prefix")):toBeTrue()
	test.expect(text.startsWith("prefix-value", "")):toBeTrue()
	test.expect(text.startsWith("abc", "abcd")):toBeFalse()

	test.expect(text.endsWith("value-suffix", "suffix")):toBeTrue()
	test.expect(text.endsWith("value-suffix", "")):toBeTrue()
	test.expect(text.endsWith("abc", "zabc")):toBeFalse()
end)

suite:test("removeStart and removeEnd strip matching affixes and otherwise return the input", function()
	test.expect(text.removeStart("foobar", "foo")):toBe("bar")
	test.expect(text.removeStart("foobar", "bar")):toBe("foobar")
	test.expect(text.removeStart("foobar", "")):toBe("foobar")

	test.expect(text.removeEnd("foobar", "bar")):toBe("foo")
	test.expect(text.removeEnd("foobar", "foo")):toBe("foobar")
	test.expect(text.removeEnd("foobar", "")):toBe("foobar")
end)

suite:test("count performs literal non-overlapping matches", function()
	test.expect(text.count("banana", "an")):toBe(2)
	test.expect(text.count("aaaa", "aa")):toBe(2)
	test.expect(text.count("a.b.a.b", ".")):toBe(3)
	test.expect(text.count("abc", "z")):toBe(0)
end)

suite:test("count rejects an empty needle", function()
	test.expect(function()
		text.count("abc", "")
	end):toError("needle must not be empty")
end)

suite:test("trim defaults to both sides and uses whitespace characters by default", function()
	test.expect(text.trim(" \t hello \r\n")):toBe("hello")
	test.expect(text.trim("")):toBe("")
	test.expect(text.trim("no-change")):toBe("no-change")
end)

suite:test("trim can target only one side and accept custom trim characters", function()
	test.expect(text.trim("--hello--", "start", { "-" })):toBe("hello--")
	test.expect(text.trim("--hello--", "end", { "-" })):toBe("--hello")
	test.expect(text.trim("--hello--", "both", { "-" })):toBe("hello")
	test.expect(text.trim("xyxhelloxy", "both", { "x", "y" })):toBe("hello")
end)

suite:test("trim validates side and trim character inputs", function()
	test.expect(function()
		text.trim("abc", "middle" :: any)
	end):toError("side must be 'start', 'end', or 'both'")

	test.expect(function()
		text.trim("abc", "both", { "" })
	end):toError("trim characters must not contain empty strings")
end)

suite:test("indent prefixes every line and supports zero columns", function()
	test.expect(text.indent("a\n\nb", 2)):toBe("  a\n  \n  b")
	test.expect(text.indent("abc", 0)):toBe("abc")
	test.expect(text.indent("", 3)):toBe("   ")
end)

suite:test("indent validates column counts", function()
	test.expect(function()
		text.indent("abc", -1)
	end):toError("columns must be a non%-negative integer")

	test.expect(function()
		text.indent("abc", 1.5)
	end):toError("columns must be a non%-negative integer")
end)

suite:test("unindent removes the common indentation while ignoring blank lines", function()
	local value = "    alpha\n\n        beta\n    gamma"
	test.expect(text.unindent(value)):toBe("alpha\n\n    beta\ngamma")
end)

suite:test("unindent can remove an explicit number of leading columns", function()
	test.expect(text.unindent("    alpha\n  beta\n\tgamma", 2)):toBe("  alpha\nbeta\ngamma")
	test.expect(text.unindent("alpha\n beta", 10)):toBe("alpha\nbeta")
	test.expect(text.unindent("alpha", 0)):toBe("alpha")
end)

suite:test("unindent normalizes CRLF line endings and validates column counts", function()
	test.expect(text.unindent("  a\r\n  b")):toBe("a\nb")

	test.expect(function()
		text.unindent("abc", -1)
	end):toError("columns must be a non%-negative integer")

	test.expect(function()
		text.unindent("abc", 2.5)
	end):toError("columns must be a non%-negative integer")
end)

suite:test("wrap prefers whitespace boundaries and preserves blank lines", function()
	test.expect(text.wrap("alpha beta gamma", 8)):toBe("alpha\nbeta\ngamma")
	test.expect(text.wrap("alpha\n\nbeta gamma", 6)):toBe("alpha\n\nbeta\ngamma")
end)

suite:test("wrap does not hyphenate when a word fits exactly before a boundary space", function()
	test.expect(text.wrap("foo bar", 3, 1)):toBe("foo\nbar")
	test.expect(text.wrap("foo bar baz", 7, 10)):toBe("foo bar\nbaz")
end)

suite:test("wrap leaves oversized words intact by default", function()
	test.expect(text.wrap("abcdef ghi", 3)):toBe("abcdef\nghi")
	test.expect(text.wrap("abcdefgh", 3)):toBe("abcdefgh")
end)

suite:test("wrap with threshold one breaks oversized words using the default marker", function()
	test.expect(text.wrap("abcdef", 3, 1)):toBe("ab-\ncd-\nef")
	test.expect(text.wrap("abcdefgh", 4, 1)):toBe("abc-\ndef-\ngh")
end)

suite:test("wrap can break oversized words without a marker", function()
	test.expect(text.wrap("abcdefgh", 4, 1, "")):toBe("abcd\nefgh")
	test.expect(text.wrap("abcdefghij", 3, 1, "")):toBe("abc\ndef\nghi\nj")
end)

suite:test("wrap thresholds one and two behave the same for ordinary whitespace wrapping", function()
	local value = "foo abcdef"
	test.expect(text.wrap(value, 7, 1)):toBe("foo\nabcdef")
	test.expect(text.wrap(value, 7, 2)):toBe("foo\nabcdef")
end)

suite:test("wrap threshold three or higher can prefer breaking the next word to avoid a short line", function()
	local value = "foo abcdef"
	test.expect(text.wrap(value, 7, 2)):toBe("foo\nabcdef")
	test.expect(text.wrap(value, 7, 3)):toBe("foo ab-\ncdef")
	test.expect(text.wrap(value, 7, 4)):toBe("foo ab-\ncdef")
end)

suite:test("wrap accounts for the full width of a custom break marker", function()
	test.expect(text.wrap("abcdefghij", 8, 1, "...")):toBe("abcde...\nfghij")
	test.expect(text.wrap("foo abcdef", 9, 3, "...")):toBe("foo ab...\ncdef")
end)

suite:test("wrap disables word breaking when the marker is too wide for the line", function()
	test.expect(text.wrap("abcdefgh", 3, 1, "---")):toBe("abcdefgh")
	test.expect(text.wrap("foo abcdef", 7, 3, "-------")):toBe("foo\nabcdef")
end)

suite:test("wrap trims whitespace around chosen break points", function()
	test.expect(text.wrap("foo   bar", 6)):toBe("foo\nbar")
	test.expect(text.wrap("foo \t  bar baz", 7)):toBe("foo\nbar baz")
end)

suite:test("wrap validates width and threshold inputs", function()
	test.expect(function()
		text.wrap("abc", 0)
	end):toError("width must be a positive integer")

	test.expect(function()
		text.wrap("abc", 2.5)
	end):toError("width must be a positive integer")

	test.expect(function()
		text.wrap("abc", 3, -1)
	end):toError("breakWordThreshold must be a non%-negative integer")

	test.expect(function()
		text.wrap("abc", 3, 1.5)
	end):toError("breakWordThreshold must be a non%-negative integer")
end)

suite:test("truncate returns the original string when it already fits", function()
	test.expect(text.truncate("abc", 3)):toBe("abc")
	test.expect(text.truncate("abc", 5, "...")):toBe("abc")
end)

suite:test("truncate accounts for the marker width when trimming", function()
	test.expect(text.truncate("abcdef", 5, "...")):toBe("ab...")
	test.expect(text.truncate("abcdef", 4, "")):toBe("abcd")
	test.expect(text.truncate("abcdef", 1, "")):toBe("a")
end)

suite:test("truncate returns the marker directly when it is wider than the limit", function()
	test.expect(text.truncate("abcdef", 2, "...")):toBe("...")
	test.expect(text.truncate("abcdef", 0, "!")):toBe("!")
	test.expect(text.truncate("abcdef", 0)):toBe("")
end)

suite:test("truncate validates width", function()
	test.expect(function()
		text.truncate("abc", -1)
	end):toError("width must be a non%-negative integer")

	test.expect(function()
		text.truncate("abc", 1.5)
	end):toError("width must be a non%-negative integer")
end)

return suite
