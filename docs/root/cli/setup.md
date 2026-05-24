# setup

`eryx setup` configures your current project so editors and tooling can resolve `@eryx/*` modules.

## Usage

```sh
eryx setup
```

## What it does

`eryx setup` looks for Eryx's bundled modules and then updates `.luaurc` in the current directory to add an `eryx` alias.

If `.luaurc` does not exist, it creates one. If it already exists, it updates the `aliases.eryx` entry.

## Notes

- This command currently does not edit `.config.luau`
- Embedded builds may not provide this command
- You may need to restart your editor after running it

## Example

```sh
eryx setup
```
