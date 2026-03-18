add_luau_script_module(http src/modules/http.luau)
add_luau_script_module(encoding/
    src/modules/encoding/init.luau
    src/modules/encoding/base64.luau
    src/modules/encoding/base85.luau
    src/modules/encoding/hex.luau
    src/modules/encoding/json.luau
    src/modules/encoding/url.luau
    src/modules/encoding/yaml.luau
    src/modules/encoding/base32.luau
    src/modules/encoding/csv.luau
)
add_luau_script_module(template/
    src/modules/template/init.luau
    src/modules/template/parser.luau
)
add_luau_script_module(markdown/
    src/modules/markdown/init.luau
    src/modules/markdown/parse.luau
    src/modules/markdown/html.luau
)
add_luau_script_module(pprint src/modules/pprint.luau)
add_luau_script_module(argparse src/modules/argparse.luau)
add_luau_script_module(mime src/modules/mime.luau)
add_luau_script_module(signal src/modules/signal.luau)
add_luau_script_module(net src/modules/net.luau)
add_luau_script_module(test src/modules/test.luau)
