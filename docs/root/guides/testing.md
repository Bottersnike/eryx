# Testing your code

When writing any code, it is always best practice to [unit test](https://en.wikipedia.org/wiki/Unit_testing) it. Unit testing provides a means to validate that the code functioned as expected, and to detect regressions later if it stops functioning properly.

Eryx provides a built-in framework for writing unit tests.

To write a test, first create a `.test.luau` file (eg `foobar.test.luau`) and `require("@eryx/test")` from within it.

Tests are grouped into "suites", and we can create a new suite using `test.Suite.new("Suite Name")`.

Within a suite, we need to build tests. Each test is defined with:

```luau
suite:Test("that our test does something", function()
    ...
end)
```

Within an individual test, we build expectations using `test.expect`. Expectations are similar to assertions, but provide substantially more utility, and allow the testing framework to present more informative errors when a specific expectation is not met.

As a complete example:

```luau
const test = require("@eryx/test")
const suite = test.Suite.new("Demo test")

suite:Test("that addition works", function()
    test.expect(1 + 1):ToBe(2)
end)

return suite
```

To run a single test file, use:

```sh
eryx test <name>.test.luau
```

Alternatively, to test an entire folder, use:

```sh
eryx test <folder>
```

Running the rest shows that `1 + 1` does indeed evaluate to `2`:

```
  > Demo test
    + that addition works 0.04ms
```

The complete reference for how to use the testing library can be found in [[test|the API reference]].
