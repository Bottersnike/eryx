# Writing Code with Eryx

Eryx is a runtime for the [Luau language](https://luau.org/). For the most part, it behaves exactly as Luau is expected to.

All of Luau's [built in library](https://luau.org/library) is available for use. All of Eryx's additions are available through `require("@eryx/...")`.

Code written for Luau will generally, but not always, run fine within Eryx, though code that depends on functionality provided by other runtimes will **not** work. Eryx's runtime is incompatible with other third party runtimes.

The most important change made in Eryx is the handling of `error`s. This change fundamentally alters how error handling works in Luau, and can cause compatibility issues with code written in Luau.
