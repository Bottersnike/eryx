# compile

`eryx compile` bundles a project into a standalone executable using Eryx's VFS builder.

## Usage

```sh
eryx compile <root> <output> <entrypoint> [options]
```

## Arguments

### `<root>`

Project root directory to bundle.

### `<output>`

Path to the output executable.

### `<entrypoint>`

Entrypoint script, relative to `<root>`.

## Options

### `-s`, `--source-exe <path>`

Executable to clone as the base runtime. If omitted, Eryx uses the current executable.

## Example

```sh
eryx compile . dist/my-app.exe src/main.luau
```
