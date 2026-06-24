# Globals

Eryx introduces a small number of globals into the Luau environment.

## \_DIR

This global is a string representing the directory where the current script is located.

Note that current script here refers to the script containing the reference to `_DIR`, not the current working directory or the script used as the program's entrypoint.

In non-script environments, such as the REPL, this value is `nil`.

## \_FILE

This global is a string representing the complete path for the current script.

In non-script environments, such as the REPL, this value is `nil`.

## \_RUNTIME

This global identifies the current runtime (Eryx) and its configuration. It follows [[001-runtime|the \_RUNTIME specification]].

## \_LUAU

This global identifies the current Luau version and its configuration. It follows [[001-runtime|the \_RUNTIME specification]].

## u and unicode

These two globals introduce native unicode strings into Luau. Documentation is provided in the [[unicode|unicode documentation]].
