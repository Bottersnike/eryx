# Package Management

Eryx has its own package manager, which can be used to install dependencies into a project. Top-level dependencies are defined in `eryx.toml`, using `[eryx.dependencies]` for normal dependencies and `[eryx."dev-dependencies"]` for development-only dependencies.

Packages are usually installed into `eryx_packages` at the root of the project. This folder should never be tracked with source control, and is automatically populated when using `eryx pkg`. When using git, add `eryx_packages/` to `.gitignore`. Both `eryx.toml` and `eryx.lock` should however be tracked with source control.

If an install only contains path dependencies, Eryx will not create `eryx_packages` at all, because path dependencies only exist to configure aliases.

Cyclic dependencies are not permitted. Multiple versions of the same package may be installed when required. When repository packages are used, Eryx prefers valid solutions that minimise duplicate package versions.

Within either dependency table, the table key is the dependency name used by Eryx. By default, this is also the Luau alias.

## The lockfile

Eryx emits an `eryx.lock` file whenever dependencies are installed, updated, upgraded, or removed.

The lock file is used by `eryx pkg install` for deterministic installs. When the top-level dependency specifications in `eryx.toml` still match the lock file, Eryx installs from `eryx.lock` instead of re-resolving floating dependencies.

This means:

- Branch and tag git dependencies are locked to the exact commit recorded in `eryx.lock`.
- `eryx pkg update` refreshes dependencies by re-resolving them and writing a new lock file.
- `eryx pkg update foo` refreshes only the selected top-level dependencies, while keeping other top-level dependencies at their locked versions.
- `eryx pkg upgrade` refreshes dependencies and also rewrites repository dependency versions in `eryx.toml`.

The lock file also tracks package-manager-owned aliases, so installs can preserve unrelated user aliases in `.luaurc` while cleaning up stale aliases that were previously managed by Eryx.

Workspace bootstrap installs are not added to the root `eryx.lock` unless they are also part of the root dependency graph. If a workspace package has its own `eryx.lock`, Eryx will still respect it when initializing that package in place.

## Command line

The package manager is accessed through `eryx pkg`. The following commands are available:

- `eryx pkg install`: Installs normal dependencies. Pass `--dev` to also include `dev-dependencies`.
- `eryx pkg update [deps...]`: Re-resolves normal dependencies, or only the selected top-level dependencies, and writes a new lock file. Pass `--dev` to include `dev-dependencies`.
- `eryx pkg upgrade [deps...]`: Like `update`, but also rewrites repository dependency versions in `eryx.toml` to the resolved versions. Pass `--dev` to include `dev-dependencies`.
- `eryx pkg add [...]`: Adds a new dependency. Pass `--dev` to add it under `[eryx."dev-dependencies"]`. The following sections outline the specific formats for each dependency type.
- `eryx pkg remove <dep>`: Removes an existing dependency from `[eryx.dependencies]`. Pass `--dev` to remove it from `[eryx."dev-dependencies"]` instead.
- `eryx pkg tree`: Resolve normal dependencies from `eryx.toml`, as if performing a fresh resolution, then display the dependency graph. Pass `--dev` to include `dev-dependencies`.
- `eryx pkg ls`: List normal dependencies defined in `eryx.toml`. Pass `--dev` to also list `dev-dependencies`.

## Aliases and `.luaurc`

Eryx writes package aliases into `.luaurc`.

If a package manifest sets `eryx.project.source-root`, Eryx points that package's alias at the declared source folder instead of the package directory itself. For example, a package installed into `eryx_packages/foo-1234abcd` with `source-root = "src"` will be aliased to `eryx_packages/foo-1234abcd/src`.

Workspace packages behave the same way, except their aliases point at the real package directory on disk rather than a copied install in `eryx_packages`.

When a previous `eryx.lock` is available, Eryx treats the aliases recorded in that lock as package-manager-owned. During install:

- Aliases currently owned by Eryx are updated in place.
- Stale aliases that were previously owned by Eryx are removed.
- Aliases not owned by Eryx are left alone.

When no lock file exists yet, Eryx warns before overwriting existing aliases that it cannot prove it owns.

`.config.luau` is currently not supported by the package manager.

## Monorepo workspaces

Eryx supports root-level monorepo workspace overrides through `[eryx.workspace]`.

This lets packages keep their published dependency sources, such as `git` dependencies with `subdir = "..."`, while local development resolves those package names to folders inside the current repository.

```toml
[eryx.workspace]
eryxdoc = "./packages/eryxdoc"
markdown = "./packages/markdown"
```

Workspace entries are:

- Root-only. They belong in the top-level `eryx.toml`, not in package manifests.
- Keyed by package name. The target folder must contain an `eryx.toml` whose `eryx.project.name` matches the workspace key.
- Resolved relative to the root manifest that declares them.

When a dependency matches a workspace entry:

- Eryx keeps the package in place instead of copying it into `eryx_packages`.
- Eryx still loads that package's manifest, resolves its child dependencies, and writes its local `.luaurc`.
- If the package declares `source-root`, the alias points at that subdirectory inside the real package folder.

Workspace packages are also initialized even when they are not direct dependencies of the root project. This is useful for monorepos where you want each package's local aliases set up without making the root project depend on every package.

That means:

- The root `.luaurc` only gets aliases for actual root dependencies.
- Each workspace package still gets its own `.luaurc` generated in place.
- The root `eryx.lock` only tracks packages that are actually part of the root dependency graph.

A common monorepo pattern looks like this:

```toml
# packages/eryxdoc/eryx.toml
[eryx.dependencies]
markdown = { git = "https://github.com/example/eryx", branch = "main", subdir = "packages/markdown" }
```

```toml
# repo root eryx.toml
[eryx.workspace]
eryxdoc = "./packages/eryxdoc"
markdown = "./packages/markdown"
```

In that setup:

- External users install `markdown` from git when they depend on `eryxdoc`.
- Local monorepo development resolves `markdown` to `./packages/markdown` instead.

## Dependency types

### Path dependencies

A path dependency represents a Luau alias. This dependency will emit an alias into `.luaurc`, but copies no files. The path is not investigated to discover child dependencies.

The configured path is currently used as written in `eryx.toml`; it is not rebased relative to the manifest file.

:::note
Path dependencies exist exclusively to configure Luau aliases. Eryx does not read `eryx.toml` from the target folder at all for this dependency type. That means child dependencies are ignored, and `eryx.project.source-root` is ignored too.
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
# Explicit package name
eryx pkg add --path package=./foo/bar
```

### Local dependencies

A local dependency links to a folder available on the local filesystem. The folder is installed by copying its contents into `eryx_packages`, and Eryx will attempt to discover child dependencies by loading the nearest `eryx.toml` at or above that folder.

Local dependencies should be used when the path truly represents a dependency, as opposed to just a Luau alias, which should instead be represented as a path dependency.

If the discovered manifest declares `eryx.project.source-root`, the generated alias points at that subdirectory inside the installed copy.

The configured path is currently used as written in `eryx.toml`; it is not rebased relative to the manifest file.

```toml
[eryx.dependencies]
package1 = { local = "/opt/foo/bar" }
package2 = { local = "/opt/foo/bar" }
```

Install a new local dependency with:

```sh
# Infers the name as "bar"
eryx pkg add ./foo/bar
# Explicit package name
eryx pkg add package=./foo/bar
```

### URL dependencies

A URL dependency represents an archive available as an HTTP resource. Currently only ZIP files are supported. An `eryx.toml` present inside the archive is explored to discover child dependencies.

If that manifest declares `eryx.project.source-root`, the generated alias points at that subdirectory inside the extracted package.

Optionally, a `sha256` hash can be provided for file integrity. This is strongly recommended. If the downloaded file does not match the provided hash, installation is aborted.

Only `http://` and `https://` URL schemes are supported by `eryx pkg add`, with `https://` being preferred.

If the archive contains a single top-level folder, this folder is treated as the archive root for both manifest discovery and extraction.

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

By default, an `eryx.toml` present at the repository root is used for discovery of child dependencies. Git dependencies may also specify `subdir = "..."` to treat a subfolder of the repository as the package root, which is useful for monorepos.

Only the selected package root is materialized into `eryx_packages`, even when the dependency points at a repository subdirectory.

If that manifest declares `eryx.project.source-root`, the generated alias points at that subdirectory inside the checked out package.

Although dependencies may be requested by branch or tag, Eryx resolves them to exact commits and records both the requested ref and the resolved commit in `eryx.lock`.

```toml
[eryx.dependencies]
package1 = { git = "ssh://git@git.eryx.local/package.git", rev = "f771f5..." }
package2 = { git = "ssh://git@git.eryx.local/package.git", tag = "v1.0.0" }
package3 = { git = "ssh://git@git.eryx.local/package.git", branch = "master" }
package4 = { git = "ssh://git@git.eryx.local/monorepo.git", branch = "main", subdir = "packages/markdown" }
```

Install a new Git dependency with:

```sh
# Infers the name as "package"
eryx pkg add git+ssh://git@git.eryx.local/package.git --rev f771f5
eryx pkg add git+ssh://git@git.eryx.local/package.git --tag v1.0.0
eryx pkg add git+ssh://git@git.eryx.local/package.git --branch master
eryx pkg add git+ssh://git@git.eryx.local/monorepo.git --branch main --subdir packages/markdown
# Explicit "foo" name
eryx pkg add foo=git+ssh://git@git.eryx.local/package.git --tag v1.0.0
```

### Repository dependencies

A repository dependency represents a package available on a package repository. Semantic versions are supported here to permit a range of versions.

If no version is specified, the latest available version satisfying all constraints is used.

If `repo` contains `://`, it is treated as a repository URL directly. Otherwise, it must match a key present in `[eryx.repositories]`.

If the package metadata declares `eryx.project.source-root`, the generated alias points at that subdirectory inside the installed package.

```toml
[eryx.repositories]
eryx = "https://packages.eryx.local/"

[eryx.dependencies]
package1 = { repo = "eryx", version = "^1.0.0" }
package2 = { repo = "eryx", version = "~1.5.0" }
package3 = { repo = "eryx", version = "1.1.0 || 1.2.0" }
```

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

:::warning
Repository dependencies may use `package = "..."` to override the actual package name fetched from the repository while keeping the dependency key as the Luau alias. This override is not currently exposed through `eryx pkg add`.
:::
