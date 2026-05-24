# CLI overview

Eryx can be used in three main ways:

```sh
eryx [options] [script.luau [args...]]
eryx [options] run [options] <script> [args...]
eryx completion <bash|zsh|fish|powershell>
```

It also supports:

```sh
eryx --help
eryx --version
```

## Runtime options

These options affect how Luau code is compiled and executed. They can appear before a direct script path, and they can also appear after `run` when you want them to apply while resolving and launching a named script.

```sh
-O0
-O1
-O2
--native
--no-native
--native-only-specified
```

### `-O0`, `-O1`, `-O2`

Set the Luau optimisation level for the current run.

### `--native`

Enable native code generation for all eligible chunks.

### `--no-native`

Disable native code generation.

### `--native-only-specified`

Only native-compile chunks that explicitly opt in with `--!native`.

## Script arguments

Eryx presents scripts with a synthetic argv:

- `os.cliargs()[1]` is the invoked script name or path
- the remaining entries are the arguments passed to that script

That means:

```sh
eryx -O2 foo.luau alpha beta
```

produces:

```luau
{ "foo.luau", "alpha", "beta" }
```

The runtime flags are not exposed to the script.

## Passing names that begin with `-`

Use `--` to stop Eryx's own option parsing:

```sh
eryx -- -literal-file-name.luau
eryx run -- -script-name
```
