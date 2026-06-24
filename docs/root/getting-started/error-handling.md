# Error Handling

Like normal Luau, Eryx raises errors with `error()` and traps them with `pcall()`. There is one important difference you'll run into almost immediately, so it's worth covering up front.

## Errors are `Exception`s

In normal Luau, whatever value you pass to `error()` is exactly what `pcall()` hands back:

```luau
-- Normal Luau
local ok, err = pcall(function()
    error("something went wrong")
end)
print(err) -- "main:2: something went wrong" (the raw string)
```

In Eryx, the value you pass to `error()` is not "the error" itself. Instead it becomes the *message* attached to a richer `Exception` object, and that `Exception` is what `pcall()` returns:

```luau
local ok, err = pcall(function()
    error("something went wrong")
end)

if not ok then
    print(err.message)    -- "something went wrong"
    print(err.type)       -- "thrown"
    print(err.traceback)  -- the captured traceback
end
```

So the key thing to remember: **after a failed `pcall`, `err` is an `Exception`, not the string you threw.** Reach for `err.message` to get the text back.

## Printing a readable error

The [[exception]] library can format an `Exception` into a complete, human-readable report (message plus traceback):

```luau
local exception = require("@eryx/exception")

local ok, err = pcall(function()
    error("something went wrong")
end)

if not ok then
    print(exception.format(err))
end
```

## Checking what went wrong

Because the error is a structured object, you can inspect it instead of pattern-matching on a string. Every `Exception` carries a `type`, and you can recognise one with `typeof`:

```luau
local ok, err = pcall(risky)
if not ok and typeof(err) == "Exception" then
    -- handle the failure using err.type, err.message, etc.
end
```

This is also the guard to use if you're writing code that needs to run on both Eryx and stock Luau, where `err` would be a bare value.

:::note
This is a behavioural change from standard Luau: any code that inspects the raw value returned by `pcall` will behave differently under Eryx. If you're porting existing Luau code, this is the first thing to check.
:::

For the full picture (how tracebacks survive re-raising across `pcall` boundaries, exception *causes* such as the `interrupt` raised on Ctrl+C, and the design behind all of this) see [[writing-code/exceptions|Exceptions]] under Writing Code with Eryx, and the [[exception]] API reference.
