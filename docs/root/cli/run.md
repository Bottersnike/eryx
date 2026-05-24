# run

`eryx run` resolves and launches a script by file path, project script name, or direct dependency script name.

## Usage

```sh
eryx run [runtime-options] [--help|--help-scripts] <script> [args...]
```

Runtime options:

```sh
-O0 | -O1 | -O2
--native
--no-native
--native-only-specified
```

## What it resolves

`eryx run` checks, in order:

1. A direct file path such as `scripts/dev.luau`
2. A project script from `eryx.toml`
3. A script exported by a direct dependency

If multiple direct dependencies export the same script name, `eryx run` fails and asks you to disambiguate.

## Help

```sh
eryx run --help
```

Prints command usage and supported flags.

```sh
eryx run --help-scripts
```

Lists:

- scripts declared by the current project
- scripts exported by direct dependencies

## Examples

Run a file directly:

```sh
eryx run scripts/build.luau --watch
```

Run a named project script:

```sh
eryx run dev --port 8080
```

Run a dependency-provided script:

```sh
eryx run doc
```

Override runtime behaviour for the launched script:

```sh
eryx run -O0 --no-native dev
```

Combine top-level and `run`-local runtime flags:

```sh
eryx -O2 run --native-only-specified bench
```
