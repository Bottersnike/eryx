# check

`eryx check` type-checks and lints Luau source files.

## Usage

```sh
eryx check <path> [options]
```

## Arguments

### `<path>`

A file or directory to check.

## Options

### `-d`, `--defs <path>`

Add a definition file (`.d.luau`). This option can be passed multiple times.

### `-e`, `--exclude <pattern>`

Exclude files or directories by name substring. This option can be passed multiple times.

## Examples

Check a single file:

```sh
eryx check src/main.luau
```

Check a directory with shared definitions:

```sh
eryx check src --defs types/global.d.luau --defs types/http.d.luau
```

Exclude generated code:

```sh
eryx check src --exclude generated --exclude vendor
```
