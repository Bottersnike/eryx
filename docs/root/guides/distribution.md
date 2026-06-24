# Distributing your Programs

Once your program works, you need a way to get it onto someone else's machine. Eryx gives you a spectrum of options, from simply copying your scripts next to a runtime, all the way to producing a single self-contained executable. There is no single "right" way; pick the one that matches how much you care about file count versus flexibility.

## Shipping sources alongside a runtime

The most direct approach is to distribute your `.luau` files and let an Eryx runtime execute them. The user runs your entrypoint just like you do during development:

```sh
eryx main.luau
```

How many files that involves depends on which build of Eryx you ship:

- **Standard build.** The `eryx` executable, its shared library, and a `modules/` folder containing the standard library, all sitting together. The runtime loads the standard library (and any native modules) from disk at startup. This is the most flexible option and the one you develop against, but it's several files that all need to stay together.

- **Embed (single-file) build.** A single `eryx` binary with the entire standard library compiled directly into it: no `modules/` folder, no separate shared library, no DLL loading. You ship that one binary plus your `.luau` source tree, and that's it.

:::note
Shipping an embed build next to your sources is a completely legitimate way to distribute a program, and often the simplest. You get down to "two things to copy", the runtime and your code, without giving up readable source files or reaching for any bundling step. The [[#bundling-into-a-single-executable|virtual filesystem]] is *not* the only path to a clean distribution.
:::

There is also a **hybrid build**, which embeds the standard library into the executable but keeps the shared library as a separate file. This gives you a two-file runtime that still supports loading native (DLL/`.so`) modules from disk, useful when you depend on native modules but still want a compact runtime.

## Bundling into a single executable

When you want your users to receive *one file*, Eryx can pack your project and the runtime together using the [[vfs-behaviour|virtual filesystem]]. At build time a file archive is appended to a copy of the Eryx runtime; at run time that combined executable reads your scripts directly from itself.

The easiest way is the [[compile]] command:

```sh
eryx compile . dist/my-app.exe src/main.luau
```

This walks the project root, bundles every file it finds, and writes a standalone executable whose entrypoint is `src/main.luau`. The same thing is available programmatically via `vfs.build` if you need more control over exactly which files are included:

```luau
local vfs = require("@eryx/vfs")

vfs.build({
    outputExe = "dist/my-app.exe",
    root = "C:/projects/my_app",
    entrypoint = "src/main.luau",
    files = { "C:/projects/my_app/src", "C:/projects/my_app/.luaurc" },
})
```

### Choosing the base runtime

A bundle is a *clone* of an existing Eryx executable with your files appended, so what the bundle needs at run time is inherited from whichever runtime it was cloned from. By default that's the currently running `eryx`.

This matters for getting a truly standalone result:

- Clone a **standard** build and the bundled executable still expects the standard library's `modules/` folder and shared library to be available alongside it, so it isn't self-contained on its own.
- Clone an **embed** build (pass it with `--source-exe`, or run the `compile` from an embed build) and the standard library is already baked into the base, so the resulting bundle is a genuine single file with no external dependencies.

```sh
eryx compile . dist/my-app.exe src/main.luau --source-exe ./eryx-embed
```

:::warning
If you bundle from a standard build, the output executable must still be able to find the runtime files it depends on. The simplest fix is to keep the bundle in the same directory as the original Eryx executable, or bundle from an embed build to avoid the problem entirely.
:::

By default, bundled programs run in **isolated** mode: scripts inside the bundle cannot fall through to the real filesystem to resolve `require`s or config. That's the safe default for distribution. See [[vfs-behaviour|the virtual filesystem]] for the details of isolation and require resolution inside a bundle.

## Choosing an approach

| Approach | What you ship | Single file? | Native DLL modules? | Best for |
| -------- | ------------- | ------------ | ------------------- | -------- |
| Standard runtime + sources | `eryx` + shared lib + `modules/` + your code | No | Yes | Development; environments you control |
| Embed runtime + sources | One `eryx` binary + your code | Almost (runtime + sources) | No | Simple distribution while keeping readable sources |
| Hybrid runtime + sources | `eryx` + shared lib + your code | No | Yes | Compact runtime that still needs native modules |
| Bundle from embed build | One executable | Yes | No | Shipping a finished app to end users |

For the mechanics behind bundling (the archive format, require resolution order across the VFS, embedded, and filesystem layers, and isolation) see [[vfs-behaviour|the virtual filesystem]] and [[module-resolution|library resolution]].
