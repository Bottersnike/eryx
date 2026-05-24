# pkg

`eryx pkg` is the built-in package manager.

## Usage

```sh
eryx pkg <subcommand> [options]
```

If no subcommand is provided, Eryx prints the package manager help text.

## Subcommands

### `install`

Install all packages from the current project.

```sh
eryx pkg install [--dev]
```

### `update`

Re-resolve and update all packages, or only selected dependencies.

```sh
eryx pkg update [--dev] [package...]
```

### `upgrade`

Update repository dependencies and rewrite the version ranges in `eryx.toml`.

```sh
eryx pkg upgrade [--dev] [package...]
```

### `tree`

Show the resolved dependency tree.

```sh
eryx pkg tree [--dev]
```

### `ls`

List top-level dependencies.

```sh
eryx pkg ls [--dev]
```

### `add`

Add a dependency to the project manifest.

```sh
eryx pkg add [--dev] [--dry] [--path] [--sha256 <hash>] [--rev <rev>] [--tag <tag>] [--branch <branch>] [--subdir <dir>] <package>
```

Notes:

- `--dev` writes to `dev-dependencies`
- `--dry` updates the manifest without running install
- `--path` records the dependency as a path dependency
- `--sha256` is used for URL package verification
- `--rev`, `--tag`, and `--branch` control git dependency selection
- `--subdir` selects a package subdirectory inside a git repository

### `remove`

Remove a dependency from the project manifest.

```sh
eryx pkg remove [--dev] [--dry] <package>
```

## Examples

Install dependencies:

```sh
eryx pkg install
```

Add a dev dependency:

```sh
eryx pkg add --dev eryx:testlib
```

Add a git dependency pinned to a tag:

```sh
eryx pkg add --tag v1.2.0 git+https://example.com/repo.git
```

Inspect the tree including dev dependencies:

```sh
eryx pkg tree --dev
```
