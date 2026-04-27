# Package Management

Eryx has its own package manager, which can be used to install dependencies into a project. Dependencies are defined in `eryx.toml`, in the `[eryx.dependencies]` section.

Packages are installed into `eryx_packages` at the root of the project. This folder should never be tracked with source control, and is automatically populated when using `eryx pkg`. When using git, add `eryx_packages/` to `.gitignore`. Both `eryx.toml` and `eryx.lock` should however be tacked with source control.

Cyclic dependencies are not permitted. Multiple versions of the same package may be installed when required. When repository packages are used, Eryx prefers valid solutions that minimise duplicate package versions.

Within `[eryx.dependencies]`, the table key is the dependency name used by Eryx. By default, this is also the Luau alias.

## The lockfile

Eryx emits an `eryx.lock` file whenever one or more packages is installed or removed.

The lock file is currently informational only, but future versions of Eryx will use it to provide deterministic installs, faster resolution, and package removal tracking.

## Command line

The package manager is accessed through `eryx pkg`. The following commands are available:

- `eryx pkg install`: Installs all packages as defined in `eryx.toml`, updating `.luaurc` as appropriate.
- `eryx pkg add [...]`: Adds a new dependency. The following sections outline the specific formats for each dependency type.
- `eryx pkg remove <dep>`: Removes an existing dependency, using the key in `eryx.toml` as the dependency name.
- `eryx pkg tree`: Resolve all dependencies, as if performing an install, then display the dependency graph.
- `eryx pkg ls`: List all dependencies defined in `eryx.toml`

## Dependency types

### Path dependencies

A path dependency represents a Luau alias. This dependency will emit an alias into `.luaurc`, but copies no files. The path is not investigated to discover child dependencies.

Relative paths are resolved relative to the `eryx.toml` file.

:::note
Path dependencies exist exclusively to configure Luau aliases. As such,
any `eryx.toml` files within a path dependency are ignored. Critically, this means `sourceRoot` is ignored.
:::

```toml
[eryx.dependencies]
package1 = { path = "./foo/bar" }
package2 = { path = "./foo/bar" }
```

Install a new path dependency with:

```sh
# Infers the name as "bar"
eryx pkg add --path ./foo/bar
# Explicit "package" name
eryx pkg add --path package=./foo/bar
```

### Local dependencies

A local dependency links to a folder available on the local filesystem. The folder is installed by copying its contents into `eryx_packages`, and an `eryx.toml` inside the folder will be used to discover child dependencies.

Local dependencies should be used when the path truly represents a dependency, as opposed to just a Luau alias (which are represented as path dependencies).

Relative paths are resolved relative to the `eryx.toml` file.

```toml
[eryx.dependencies]
package1 = { local = "/opt/foo/bar" }
package2 = { local = "/opt/foo/bar" }
```

Install a new local dependency with:

```sh
# Infers the name as "bar"
eryx pkg add ./foo/bar
# Explicit "package" name
eryx pkg add package=./foo/bar
```

### URL dependencies

A URL dependency represents an archive available as an HTTP resource. Currently only ZIP files are supported. An `eryx.toml` present inside the archive is explored to discover child dependencies.

Optionally, a `sha256` hash can be provided for file integrity. This is strongly recommended. If the downloaded file does not match the provided hash, installation is aborted.

Only `http://` and `https://` URL schemes are supported, with `https://` being preferred.

If the archive contains a single top-level folder, this folder is treated as the archive root.

```toml
[eryx.dependencies]
package1 = { url = "https://cdn.eryx.local/package.zip" }
package2 = { url = "https://cdn.eryx.local/package.zip", sha256 = "b94d27..." }
```

Install a new URL dependency with:

```sh
# Infers the package name as "package"
eryx pkg add https://cdn.eryx.local/package.zip
eryx pkg add https://cdn.eryx.local/package.zip --sha256 b94d27...
# Explicit "foo" name
eryx pkg add foo=https://cdn.eryx.local/package.zip --sha256 b94d27...
```

### Git dependencies

A Git dependency represents a package available on a Git server. The requested version must be specified with exactly one of a branch name, a tag, or a revision (commit hash).

An `eryx.toml` present at the repository root is used for discovery of child dependencies.

```toml
[eryx.dependencies]
package1 = { git = "ssh://git@git.eryx.local/package.git", rev = "f771f5..." }
package2 = { git = "ssh://git@git.eryx.local/package.git", tag = "v1.0.0" }
package3 = { git = "ssh://git@git.eryx.local/package.git", branch = "master" }
```

Install a new Git dependency with:

```sh
# Infers the name as package
eryx pkg add git+ssh://git@git.eryx.local/package.git --rev f771f5
eryx pkg add git+ssh://git@git.eryx.local/package.git --tag v1.0.0
eryx pkg add git+ssh://git@git.eryx.local/package.git --branch master
# Explicit "foo" name
eryx pkg add foo=git+ssh://git@git.eryx.local/package.git --tag v1.0.0
```

### Repository dependencies

A repository dependency represents a package available on a package repository. Semantic versions are supported here to permit a range of versions.

If no version is specified, the latest version (defined as the highest available stable semantic version) is used unless constrained by other dependencies.

:::warning
TODO: We need to support passing the package name as an argument to the dep, so we can have duplicates with different versions!
:::

```toml
[eryx.repositories]
eryx = "https://packages.eryx.local/"

[eryx.dependencies]
package1 = { repo = "eryx", version = "^1.0.0" }
package2 = { repo = "eryx", version = "~1.5.0" }
package3 = { repo = "eryx", version = "1.1.0 || 1.2.0" }
```

If `repo` contains `://`, is it treated as a repository URL directly. Otherwise, it must match a key present in `[eryx.repositories]`.

Install a new repository dependency with:

```sh
# Accept any version, defaulting to the "eryx" repository
eryx pkg add foo
# Accept specific versions, defaulting to the "eryx" repository
eryx pkg add foo@^1.0.0
eryx pkg add foo@~1.5.0
eryx pkg add foo@"1.1.0 || 1.2.0"
# Accept specific versions, from a specified repository
eryx pkg add repository:foo@^1.0.0
```
