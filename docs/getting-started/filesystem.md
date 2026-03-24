# Working with Files

## Interacting with files

When writing programs, it's common to need to interact with other files on the filesystem.

Eryx provides [[fs|@eryx/fs]] which allows for reading and writing of any file, along with general inspection of the filesystem.

To open a file, we use `fs.open("path", "r")`. The second argument represents the file mode:

| Mode | Meaning                                                                                                  |
| ---- | -------------------------------------------------------------------------------------------------------- |
| `r`  | Open an existing file for reading                                                                        |
| `w`  | Open a new or existing file for writing, truncating any existing content                                 |
| `a`  | Open an existing file for appending, starting writes at the end of existing content                      |
| `r+` | Open an existing file for both reading and writing                                                       |
| `w+` | Open a new or existing file for both reading and writing, truncating any existing content                |
| `a+` | Open a new or existing file for both reading and writing, starting writes at the end of existing content |

Once a file is open, we can read with `:read()` and write with `:write()`. We always have a "cursor" within a file, representing where the next read or write will start. We can get the location of this cursor (as a byte offset) with `:tell()` and move it with `:seek()`.

When writing to a file, it's not guaranteed to be written onto disk immediately. `:flush()` can be used to ensure all written content is placed onto disk.

Once we're done with a file, we can `:close()` it. If a file is not explicitly closed, Eryx will close it when the file goes out of scope.

:::caution
Strings in Luau are an arbitrary array of bytes, with no specified encoding. When working with UTF-8 files, the [utf8 library](https://luau.org/library/#utf8-library) will be required to decode the data. Because of this, `:read()` and `:readBuffer()` are functionally equivalent, differing only in the datatype they return.
:::

All of the discussed file operations above can yield. In the case where a non-yielding version is strictly required, `:...Sync()` variants are provided.

## Interacting with folders

Sometimes we don't know where the file we want is located exactly, or we wish to inspect all files in a particular folder. For these cases, `fs.listDir` will list all files in a given folder. `fs.exists`, `fs.isFile` and `fs.isDirectory` can be used to inspect the nature of a specific path.

## Interacting with paths

Filesystem paths can be complex, especially when there is a desire to support multiple operating systems. [[fs#fn-group-path|fs.path]] provides a collection of utilities for operating on paths. The most common of these utilities is `fs.path.join` which should **always** be used to combine sections of a path together.

:::caution
While tempting, avoid using `directory .. "/" .. fileName`. While this will work in the majority of cases, it can be fragile, especially if `directory` or `fileName` are not well-formed, or a mix of forward and back slashes are present.
:::

[[fs#fn-group-path|The API reference]] contains a list of all available path utilities.
