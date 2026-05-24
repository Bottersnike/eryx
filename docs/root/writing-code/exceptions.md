# Exceptions

In Luau, errors can be thrown either from internal C functions, or by calling the `error()` function. The argument passed to `error()` is considered "the error". That argument could be a string, a table, or something else entirely.

As the error unwinds, any wrapping `pcall()` will trap the error, and returns the exact value passed into the `error()` function. If the error unwinds all the way to the top level of the script, it is printed to the console if the argument was a string.

Eryx does not do this. Instead, Eryx introduces the concept of an `Exception`. The use of `error()` remains the same, however the argument passed to `error()` is now not considered "the error". Instead, it is considered metadata to be attached to a more complex error object: an `Exception`.

This brings some immediate benefits: `Exception`s track their traceback within the object, allowing introspection. Importantly, if an `Exception` is re-raised (passing it on to `error()`) the traceback is retained, allowing introspection to cross `pcall` boundaries.

The exception "cause" is also tracked, such as an `interrupt` exception which is thrown when the user presses Ctrl+C. This allows trapping of specific exception classes without requiring string manipulation to identify the cause.

This does, however, mean any code using `pcall` is **incompatible** between normal Luau and Eryx. In Eryx, `pcall` will always return an `Exception` type, rather than the bare value passed to `error()`.

Full type interfaces for exceptions can be found in the [[exception]] reference.

To present a brief example, in normal Luau we might write:

```luau
local function erroringFn()
    error("Hello errors")
end
local ok, err = pcall(erroringFn)
if not ok then
    print(err)  -- Outputs "main:2: Hello errors"
end
```

In Eryx, this pattern changes slightly:

```luau
local function erroringFn()
    error("Hello errors")
end
local ok, err = pcall(erroringFn)
if not ok then
    -- err is an Exception, not the string we originally errored with
    print(err.type)  -- Outputs "thrown"
    print(err.message)  -- Outputs "Hello errors"
    print(err.traceback)  -- Outputs the traceback table
    print(require("@eryx/exception").format(err))
end
```

This obviously provides additional flexibility, though comes at the code of incompatibility. `typeof(err) == "Exception"` can be used as a guard when aiming to write runtime-agnostic code.