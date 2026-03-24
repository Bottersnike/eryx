# Editor Setup

As Eryx is based on Luau, a majority of existing Luau tooling will function as-is. [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) is recommended as the language server provider when using any editor that supports LSPs.

Once you've setup a workspace and installed an LSP, the following command can be used to generate a `.luaurc` file in the current working directory:

```sh
eryx setup
```

This file is not strictly necessary for Eryx itself, but Luau tooling is unaware of the `@eryx` prefix for requires.

You may need to restart your editor after running this command for the changes to take effect.
