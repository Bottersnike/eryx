local argparse = require("@eryx/argparse")
local test = require("@eryx/test")

local suite = test.Suite.new("argparse")

suite:test("parse: supports flags options and positionals", function()
	local parser = argparse.Parser.new("tool", "desc")
	parser:addPositional("file", "string", nil, true, "Input file")
	parser:addFlag("verbose", "v", "Verbose")
	parser:addOption("port", "p", "number", 8080, nil, "Port")

	local result = parser:parse({ "input.txt", "--verbose", "--port=9000" })
	test.expect(result.file):toBe("input.txt")
	test.expect(result.verbose):toBeTrue()
	test.expect(result.port):toBe(9000)
end)

suite:test("parse: supports merged short flags and options", function()
	local parser = argparse.Parser.new("tool")
	parser:addFlag("verbose", "v")
	parser:addOption("port", "p", "number", nil, true)

	local result = parser:parse({ "-vp8080" })
	test.expect(result.verbose):toBeTrue()
	test.expect(result.port):toBe(8080)
end)

suite:test("parse: delegates to subcommands", function()
	local parser = argparse.Parser.new("tool")
	local run = parser:addSubCommand("run", "Run things")
	run:addPositional("script", "string", nil, true, "Script")

	local result = parser:parse({ "run", "main.luau" })
	test.expect(result.run):toNotBeNil()
	test.expect(result.run.script):toBe("main.luau")
end)

suite:test("parse: help handler short-circuits validation", function()
	local parser = argparse.Parser.new("tool")
	parser:addPositional("file", "string", nil, true, "Input file")

	local called = false
	parser:setHelpHandler(function()
		called = true
	end)

	test.expect(function()
		parser:parse({ "--help" })
	end):toNotError()
	test.expect(called):toBeTrue()
end)

suite:test("parse: missing required option errors", function()
	local parser = argparse.Parser.new("tool")
	parser:addOption("port", "p", "number", nil, true, "Port")

	test.expect(function()
		parser:parse({})
	end):toError("Missing required option")
end)

suite:test("disableHelp: frees the help flag names", function()
	local parser = argparse.Parser.new("tool")
	parser:disableHelp()
	parser:addFlag("help", "h", "Custom help")

	local result = parser:parse({ "-h" })
	test.expect(result.help):toBeTrue()
end)

suite:test("generateHelp: includes commands and options", function()
	local parser = argparse.Parser.new("tool", "Useful tool", "bye")
	parser:addOption("port", "p", "number", 8080, nil, "Port")
	parser:addSubCommand("run", "Run it")

	local output = parser:generateHelp()
	test.expect(output):toContain("Usage: tool")
	test.expect(output):toContain("Commands:")
	test.expect(output):toContain("--port <number>")
	test.expect(output):toContain("bye")
end)

suite:test("parse: supports variadic positionals", function()
	local parser = argparse.Parser.new("tool")
	parser:addPositional("files", "string", nil, false, "Files", true)

	local result = parser:parse({ "a.txt", "b.txt", "c.txt" })
	test.expect(#result.files):toBe(3)
	test.expect(result.files[1]):toBe("a.txt")
	test.expect(result.files[3]):toBe("c.txt")
end)

suite:test("parse: supports multi-value options", function()
	local parser = argparse.Parser.new("tool")
	parser:addOption("include", "I", "string", nil, false, "Include paths", {
		multiple = true,
	})

	local result = parser:parse({ "-Ia", "--include", "b" })
	test.expect(#result.include):toBe(2)
	test.expect(result.include[1]):toBe("a")
	test.expect(result.include[2]):toBe("b")
end)

suite:test("parse: supports fixed-arity options", function()
	local parser = argparse.Parser.new("tool")
	parser:addOption("range", nil, "number", nil, true, "Numeric range", {
		arity = 2,
	})

	local result = parser:parse({ "--range", "10", "20" })
	test.expect(#result.range):toBe(2)
	test.expect(result.range[1]):toBe(10)
	test.expect(result.range[2]):toBe(20)
end)

suite:test("parse: treats values after -- as positional arguments", function()
	local parser = argparse.Parser.new("tool")
	parser:addFlag("verbose", "v")
	parser:addPositional("file", "string", nil, true, "Input file")

	local result = parser:parse({ "--", "--verbose" })
	test.expect(result.verbose):toBeFalse()
	test.expect(result.file):toBe("--verbose")
end)

suite:test("parse: enforces mutually exclusive groups", function()
	local parser = argparse.Parser.new("tool")
	parser:addFlag("json", nil, "JSON output")
	parser:addFlag("yaml", nil, "YAML output")
	parser:addMutuallyExclusive({ "json", "yaml" })

	test.expect(function()
		parser:parse({ "--json", "--yaml" })
	end):toError("mutually exclusive")
end)

suite:test("generateCompletion: emits bash completions", function()
	local parser = argparse.Parser.new("tool")
	parser:addFlag("verbose", "v", "Verbose")
	parser:addSubCommand("run", "Run it")

	local output = parser:generateCompletion("bash")
	test.expect(output):toContain("complete -F _tool_completions tool")
	test.expect(output):toContain("--verbose")
	test.expect(output):toContain("run")
end)

suite:test("getCompletionCandidates: suggests subcommand-local options", function()
	local parser = argparse.Parser.new("tool")
	local run = parser:addSubCommand("run", "Run it")
	run:addFlag("watch", "w", "Watch for changes")

	local output = run:getCompletionCandidates({})
	test.expect(table.find(output, "--watch")):toNotBeNil()
	test.expect(table.find(output, "-w")):toNotBeNil()
end)

suite:test("getCompletionCandidates: hides one-shot flags that are already present", function()
	local parser = argparse.Parser.new("tool")
	parser:addFlag("verbose", "v", "Verbose")

	local output = parser:getCompletionCandidates({ "--verbose" })
	test.expect(table.find(output, "--verbose")):toBeNil()
	test.expect(table.find(output, "-v")):toBeNil()
end)

suite:test("getCompletionCandidates: keeps repeatable options available", function()
	local parser = argparse.Parser.new("tool")
	parser:addOption("include", "I", "string", nil, false, "Include", {
		multiple = true,
	})

	local output = parser:getCompletionCandidates({ "--include", "src" })
	test.expect(table.find(output, "--include")):toNotBeNil()
	test.expect(table.find(output, "-I")):toNotBeNil()
end)

suite:test("getCompletionCandidates: stops suggesting options after --", function()
	local parser = argparse.Parser.new("tool")
	parser:addFlag("verbose", "v", "Verbose")

	local output = parser:getCompletionCandidates({ "--" })
	test.expect(#output):toBe(0)
end)

return suite
