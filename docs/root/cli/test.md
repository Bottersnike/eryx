# test

`eryx test` runs `.test.luau` suites.

## Usage

```sh
eryx test <path>
```

## Arguments

### `<path>`

A file or directory to test.

If `<path>` is a directory, Eryx runs all test suites in that directory. If it is a file, Eryx runs just that file.

## Examples

Run one suite:

```sh
eryx test sample/class_test.luau
```

Run all suites in a directory:

```sh
eryx test src/modules
```
