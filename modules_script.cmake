add_luau_script_module(http/
    src/modules/http/init.luau
    src/modules/http/body.luau
    src/modules/http/cookies.luau
    src/modules/http/multipart.luau
    src/modules/http/request.luau
    src/modules/http/util.luau
    src/modules/http/CookieJar.luau
    src/modules/http/HttpConnection.luau
    src/modules/http/HttpServer.luau
    src/modules/http/ServerResponse.luau
    src/modules/http/Session.luau
    src/modules/http/App.luau
    src/modules/http/ServerSession.luau
)
add_luau_script_module(encoding/
    src/modules/encoding/init.luau
    src/modules/encoding/base64.luau
    src/modules/encoding/base85.luau
    src/modules/encoding/hex.luau
    src/modules/encoding/url.luau
    src/modules/encoding/base32.luau
)
add_luau_script_module(data/
    src/modules/data/json.luau
    src/modules/data/yaml.luau
    src/modules/data/csv.luau
    src/modules/data/xml.luau
)
add_luau_script_module(data/toml/
    src/modules/data/toml/init.luau
    src/modules/data/toml/shared.luau
    src/modules/data/toml/encoder.luau
    src/modules/data/toml/decoder.luau
    src/modules/data/toml/cst.luau
)
add_luau_script_module(template/
    src/modules/template/init.luau
    src/modules/template/parser.luau
)

add_luau_script_module(markdown/
    src/modules/markdown/init.luau
    src/modules/markdown/parseBlock.luau
    src/modules/markdown/parseInline.luau
    src/modules/markdown/types.luau
    src/modules/markdown/html.luau
    src/modules/markdown/entities.luau
    src/modules/markdown/util.luau
    src/modules/markdown/tabUtil.luau
    src/modules/markdown/htmlRenderer.luau
)
add_luau_script_module(markdown/extensions/
    src/modules/markdown/extensions/admonition.luau
    src/modules/markdown/extensions/footnote.luau
    src/modules/markdown/extensions/footnoteInline.luau
    src/modules/markdown/extensions/table.luau
    src/modules/markdown/extensions/tabs.luau
    src/modules/markdown/extensions/strikethrough.luau
    src/modules/markdown/extensions/wikilink.luau
    src/modules/markdown/extensions/colour.luau
)
add_luau_script_module(markdown/rules/
    src/modules/markdown/rules/init.luau
    src/modules/markdown/rules/atxHeading.luau
    src/modules/markdown/rules/blockQuote.luau
    src/modules/markdown/rules/codeBlock.luau
    src/modules/markdown/rules/codeFence.luau
    src/modules/markdown/rules/html.luau
    src/modules/markdown/rules/orderedList.luau
    src/modules/markdown/rules/setextHeading.luau
    src/modules/markdown/rules/thematicBreak.luau
    src/modules/markdown/rules/unorderedList.luau
    src/modules/markdown/rules/autolink.luau
    src/modules/markdown/rules/inlineHtml.luau
)

add_luau_script_module(pprint src/modules/pprint.luau)
add_luau_script_module(argparse src/modules/argparse.luau)
add_luau_script_module(semver src/modules/semver.luau)
add_luau_script_module(mime src/modules/mime.luau)
add_luau_script_module(path src/modules/path.luau)
add_luau_script_module(signal src/modules/signal.luau)
add_luau_script_module(fs_watch src/modules/fs_watch.luau)
add_luau_script_module(net src/modules/net.luau)
add_luau_script_module(stream src/modules/stream.luau)
add_luau_script_module(project src/modules/project.luau)
add_luau_script_module(package/
    src/modules/package/cycles.luau
    src/modules/package/lockfile.luau
    src/modules/package/layout.luau
    src/modules/package/dependency.luau
    src/modules/package/execution.luau
    src/modules/package/init.luau
    src/modules/package/planner.luau
    src/modules/package/planning.luau
    src/modules/package/types.luau
    src/modules/package/util.luau
)
add_luau_script_module(package/sources/
    src/modules/package/sources/git.luau
    src/modules/package/sources/init.luau
    src/modules/package/sources/local.luau
    src/modules/package/sources/path.luau
    src/modules/package/sources/repo.luau
    src/modules/package/sources/url.luau
)
add_luau_script_module(test src/modules/test.luau)
add_luau_script_module(capability src/modules/capability.luau)
add_luau_script_module(luau/
    src/modules/luau/init.luau
    src/modules/luau/ast.luau
    src/modules/luau/parse.luau
    src/modules/luau/vm.luau
    src/modules/luau/analysis.luau
    src/modules/luau/query.luau
)
add_luau_script_module(_ffi src/modules/_ffi.luau)
add_luau_script_module(_ssl src/modules/_ssl.luau)
add_luau_script_module(sqlite3 src/modules/sqlite3.luau)
add_luau_script_module(regex src/modules/regex.luau)
add_luau_script_module(webview src/modules/webview.luau)
add_luau_script_module(crypto/hazmat/_crypto src/modules/crypto/hazmat/_crypto.luau)
add_luau_script_module(websocket src/modules/websocket.luau)

add_luau_script_module(unicode/
    src/modules/unicode/init.luau
)
add_luau_script_module(unicode/_data/
    src/modules/unicode/_data/data.luau
    src/modules/unicode/_data/name.luau
    src/modules/unicode/_data/type.luau
)

if(WIN32)
add_luau_script_module(webui src/modules/webui.luau)
endif()

# Documentation engine
add_luau_script_module(eryxdoc/content/
    src/modules/eryxdoc/content/article.luau
    src/modules/eryxdoc/content/modules.luau
)
add_luau_script_module(eryxdoc/extract/
    src/modules/eryxdoc/extract/classDetection.luau
    src/modules/eryxdoc/extract/comments.luau
    src/modules/eryxdoc/extract/init.luau
    src/modules/eryxdoc/extract/members.luau
    src/modules/eryxdoc/extract/signatures.luau
    src/modules/eryxdoc/extract/typeDescriber.luau
    src/modules/eryxdoc/extract/types.luau
)
add_luau_script_module(eryxdoc/parse/
    src/modules/eryxdoc/parse/doctags.luau
    src/modules/eryxdoc/parse/highlight.luau
)
add_luau_script_module(eryxdoc/render/
    src/modules/eryxdoc/render/links.luau
    src/modules/eryxdoc/render/renderer.luau
    src/modules/eryxdoc/render/sidebar.luau
)
add_luau_script_module(eryxdoc/theme/templates/
    src/modules/eryxdoc/theme/templates/_footer.html
    src/modules/eryxdoc/theme/templates/_header.html
    src/modules/eryxdoc/theme/templates/_layout.html
    src/modules/eryxdoc/theme/templates/_sidebar.html
    src/modules/eryxdoc/theme/templates/404_page.html
    src/modules/eryxdoc/theme/templates/api_page.html
    src/modules/eryxdoc/theme/templates/article_page.html
    src/modules/eryxdoc/theme/templates/index_page.html
)
add_luau_script_module(eryxdoc/theme/
    src/modules/eryxdoc/theme/eryxdoc-live-reload.js
    src/modules/eryxdoc/theme/style.css
)
add_luau_script_module(eryxdoc/
    src/modules/eryxdoc/_devServer.luau
    src/modules/eryxdoc/init.luau
    src/modules/eryxdoc/assets.luau
    src/modules/eryxdoc/warnings.luau
)

add_luau_script_module(logging/
    src/modules/logging/init.luau
    src/modules/logging/ConsoleHandler.luau
    src/modules/logging/FileHandler.luau
    src/modules/logging/JsonHandler.luau
    src/modules/logging/types.luau
)

add_luau_script_module(schema/
    src/modules/schema/init.luau
    src/modules/schema/anyOf.luau
    src/modules/schema/array.luau
    src/modules/schema/boolean.luau
    src/modules/schema/literal.luau
    src/modules/schema/map.luau
    src/modules/schema/number.luau
    src/modules/schema/optional.luau
    src/modules/schema/string.luau
    src/modules/schema/struct.luau
    src/modules/schema/types.luau
)

add_luau_script_module(tempfile src/modules/tempfile.luau)
