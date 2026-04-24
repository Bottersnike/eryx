--[=[
XML module – DOM parsing, manipulation, serialisation and XPath queries.

Backed by pugixml. Provides two core types:
- [[XmlDocument]]: An XML document that owns the DOM tree.
- [[XmlNode]]: A lightweight handle to a single element within a document.

## Availability
This module is a typed facade over an optional pugixml backend. In
builds without XML support, `require("@eryx/xml")` fails immediately
with a clear capability error.

## Quick start
```luau
local xml = require("xml")
local doc = xml.parse('<root><item id="1">Hello</item></root>')
local root = doc:root()
print(root.name)                    --> "root"
print(root:child("item"):text())    --> "Hello"
print(root:child("item"):attr("id")) --> "1"

-- XPath
for _, node in doc:xpath("//item[@id]") do
    print(node.name, node:attr("id"))
end
```
]=]

local capability = require("@eryx/capability")
local path = require("@eryx/path")
local xml = {}

type PathLike = path.PathLike

--- Node type string
export type NodeType = "element" | "pcdata" | "cdata" | "comment" | "pi" | "declaration" | "doctype" | "document" | "null"

--[=[
A lightweight handle to a single node in an XML DOM tree.

Nodes remain valid as long as their owning `XmlDocument` is alive.
Reading `.name`, `.type`, or `.value` uses `__index` and does not
require a method call.
]=]
export type XmlNode = setmetatable<
	{
		--- The element/PI tag name, or `""` for text/comment nodes.
		name: string,
		--- The node type (see [[NodeType]]).
		type: NodeType,
		--- Shorthand for the first PCDATA/CDATA child's content (like `Text()`).
		value: string,

		--- Returns the concatenated text content of this element (first PCDATA/CDATA child).
		text: (self: XmlNode) -> string,

		--- Sets the text content of this element (creates a PCDATA child if needed).
		setText: (self: XmlNode, value: string) -> (),

		--- Returns a list of element children.  If `name` is given, only children with that tag name are included.
		children: (self: XmlNode, name: string?) -> { XmlNode },

		--- Returns the first child element with the given tag name, or `nil` if not found.
		child: (self: XmlNode, name: string) -> XmlNode?,

		--- Appends a new child element with the given tag name.
		appendChild: (self: XmlNode, name: string) -> XmlNode,

		--- Prepends a new child element with the given tag name.
		prependChild: (self: XmlNode, name: string) -> XmlNode,

		--- Removes a child by tag name or by XmlNode reference.
		removeChild: (self: XmlNode, child: string | XmlNode) -> (),

		--- Returns the parent node, or `nil` for the document root.
		parent: (self: XmlNode) -> XmlNode?,

		--- Returns the next sibling element.  If `name` is given, skips siblings until one with a matching tag name is found.
		nextSibling: (self: XmlNode, name: string?) -> XmlNode?,

		--- Returns the previous sibling element.
		prevSibling: (self: XmlNode, name: string?) -> XmlNode?,

		--- Returns the value of the attribute `name`, or `nil`.
		attr: (self: XmlNode, name: string) -> string?,

		--- Sets (or creates) the attribute `name` to `value`.
		setAttr: (self: XmlNode, name: string, value: string) -> (),

		--- Removes the attribute with the given name.
		removeAttr: (self: XmlNode, name: string) -> (),

		--- Returns all attributes as a `{ [name] = value }` dictionary.
		attrs: (self: XmlNode) -> { [string]: string },

		--- Evaluates an XPath expression relative to this node and
		--- returns all matching nodes.
		xpath: (self: XmlNode, query: string) -> { XmlNode },

		--- Evaluates an XPath expression and returns the first match,
		--- or `nil`. ]]
		xpathOne: (self: XmlNode, query: string) -> XmlNode?,

		--- Evaluates an XPath expression that returns a scalar value
		--- (string, number, or boolean) rather than a node set.
		xpathValue: (self: XmlNode, query: string) -> string | number | boolean | nil,

		--- Returns the absolute path of this node from the document root.
		--- Uses `delimiter` (default `"/"`) to separate path segments.
		path: (self: XmlNode, delimiter: string?) -> string,

		--- Changes this element's tag name.
		setName: (self: XmlNode, name: string) -> (),
	},
	{
		__tostring: (self: XmlNode) -> string,
	}
>

--[=[
An XML document that owns a DOM tree.

The document is the entry point for parsing and serialisation.  It
exposes XPath queries directly so you don't always need to grab the
root element first.
]=]
export type XmlDocument = setmetatable<
	{
		--- Returns the document element (the single top-level element).
		root: (self: XmlDocument) -> XmlNode?,

		--[=[
			Serialises the entire document to a string.
			@param indent  Indentation string (default `"\t"`).
			@param flags   `"raw"` | `"no_declaration"` | `nil` (default
						includes a declaration and pretty-prints).
		]=]
		save: (self: XmlDocument, indent: string?, flags: string?) -> string,

		--[=[
			Writes the document to a file on disk.
		]=]
		saveFile: (self: XmlDocument, path: PathLike, indent: string?, flags: string?) -> (),

		--- Evaluates an XPath expression on the whole document and returns all matching nodes.
		xpath: (self: XmlDocument, query: string) -> { XmlNode },

		--- Evaluates an XPath expression and returns the first match, or `nil`.
		xpathOne: (self: XmlDocument, query: string) -> XmlNode?,

		--- Appends a top-level child element (useful when building documents from scratch with `xml.document()`).
		appendChild: (self: XmlDocument, name: string) -> XmlNode,
	},
	{
		__tostring: (self: XmlDocument) -> string,
	}
>

--[=[
	Parses an XML string and returns a new document.
	@error Throws if the input is not well-formed XML.
]=]
function xml.parse(source: string): XmlDocument
	return nil :: any
end

--[=[
	Loads and parses an XML file from disk.
	@error Throws if the file cannot be read or the XML is malformed.
]=]
function xml.load(path: PathLike): XmlDocument
	return nil :: any
end

--[=[
	Creates a new, empty XML document.
	Use `AppendChild()` to add a root element and build the tree programmatically.
]=]
function xml.document(): XmlDocument
	return nil :: any
end

return table.freeze(
	capability.require("@eryx/_native/xml", "XML parsing support", "Enable XML support to use @eryx/xml.")
) :: typeof(xml)
