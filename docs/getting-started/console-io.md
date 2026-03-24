# Console Input and Output

Luau provides the `print` function, which can be used to output one or more lines of information to the console.

In Eryx, this function is augmented to print more types. Printing tables will print a literal version of the table, rather than `table: 0x....`.

For more complex console interaction, [[stdio|@eryx/stdio]] is provided.

Using `stdio`, we can treat the console more like a file that we can read and write to. To read from the console, we can use `stdio.readline()`. `stdio.write()` allows us to write to the console without appending a new line at the end. As an example:

```luau
const stdio = require("@eryx/stdio")

stdio.write("What is 5+5: ")
local answer = stdio.readline()
if answer == "10" then
    print("Correct!")
end
```

We can see in this example that `readline` waited until a line terminator (`\n` or `\r\n`) was entered at the console, but that said line terminator was not included in the returned string.
