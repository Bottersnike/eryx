---
title: Welcome to Eryx
summary: Getting starting with Eryx
---

Welcome to the Eryx documentation. This site contains a collection of high level tutorials and guides, along with a complete API reference for all libraries provided with Eryx.

Eryx's standard library covers a vast array of functions and utilities you are likely to need when writing code. The search bar at the top of this site can be used to quickly find what you are looking for.

## Installing Eryx

Currently, Eryx is distributed via GitHub. At the time of writing, no official releases are available. "Nighly" builds can be found by visiting the [Actions Page](https://github.com/Bottersnike/eryx/actions) on GitHub and downloading build artifacts.

For normal use, the "Standard" build should be used.

For convenience, is it recommended to modify your `PATH` variable to include the folder that contains `eryx` (or `eryx.exe` on Windows). A packaged installer is planned for the future.

## Using Eryx

Eryx is intended to be used from the command line.

Running `eryx` with no command line arguments enters a [REPL](https://en.wikipedia.org/wiki/Read%E2%80%93eval%E2%80%93print_loop). Note that every line is run within a new scope, so a `local` defined on one line is not available on the next. Globals are shared across all lines.

To run a script, simply use:

```sh
eryx script.luau
```

The `run` command (`eryx run script.luau`) is provided as an alias.

Two other commands exist, `eryx compile` and `eryx test`. These will be explored in subsequent sections.
