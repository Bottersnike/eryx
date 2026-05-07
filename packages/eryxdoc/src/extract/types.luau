-- Shared type definitions for the documentation extraction pipeline.

local luau = require("@eryx/luau/ast")
local doctags = require("../parse/doctags")

type ParsedDoc = doctags.ParsedDoc

export type SignaturePart = {
	text: string,
	typeRef: boolean?,
	hoverText: string?,
	kind: ("type" | "param" | "punct" | "keyword" | "name" | "plain")?,
}

export type ParamMeta = {
	name: string?,
	type: string?,
	typeParts: { SignaturePart }?,
	description: string?,
}

export type ReturnMeta = {
	type: string?,
	typeParts: { SignaturePart }?,
	description: string?,
}

export type SignatureMeta = {
	name: string,
	owner: string?,
	isMethod: boolean?,
	generics: { string }?,
	params: { ParamMeta }?,
	returns: { ReturnMeta }?,
}

export type OverloadDoc = {
	doc: string?,
	location: luau.Location,
	params: { string }?,
	returnStr: string?,
	parsedDoc: ParsedDoc?,
	yields: boolean,
	isMethod: boolean,
	selfType: string?,
	owner: string?,
	generics: { string }?,
	signature: string,
	signatureFull: string,
	signatureParts: { SignaturePart }?,
	signatureMeta: SignatureMeta?,
}

-- Unified doc record for functions, methods, and properties.
-- Used both as top-level functions and as class members/metamethods.
-- Properties (non-function type table fields) have params=nil.
export type FuncDoc = {
	name: string,
	doc: string?,
	location: luau.Location,
	params: { string }?, -- nil for properties; {"name: type", ...} for callables
	returnStr: string?,
	parsedDoc: ParsedDoc?,
	yields: boolean,
	isMethod: boolean,
	selfType: string?,
	owner: string?,
	generics: { string }?,
	signature: string,
	signatureFull: string,
	signatureParts: { SignaturePart }?,
	signatureMeta: SignatureMeta?,
	overloads: { OverloadDoc }?,
}

export type TypeDoc = {
	name: string,
	exported: boolean,
	kind: "class" | "table" | "alias",
	doc: string?,
	extendsTypes: { string }?,
	signatureFull: string?,
	signatureParts: { SignaturePart }?,
	location: luau.Location,
	members: { FuncDoc }?,
	generics: { string }?,
	parsedDoc: ParsedDoc?,
	classImplTable: string?,
	classFieldsType: string?,
	isPrimaryExport: boolean?,
	metamethods: { FuncDoc }?,
	aliasedTypeNode: luau.AstType?,
}

export type ConstDoc = {
	name: string,
	value: string,
	doc: string?,
	groupTitle: string?,
	owner: string?,
}

export type ExtractedDocs = {
	types: { TypeDoc },
	functions: { FuncDoc },
	constants: { ConstDoc },
	moduleDescription: string?,
	moduleRoot: string?, -- name of the returned table (e.g. "fs"), used to strip owner prefixes in display
}

-- Internal struct holding everything extracted from an ExprFunction node.
export type RawFuncSig = {
	params: { string },
	paramNames: { string? },
	paramTypeParts: { { SignaturePart }? },
	paramTypeNodes: { (luau.AstType | luau.AstTypePack)? },
	retStr: string?,
	retNode: (luau.AstType | luau.AstTypePack)?,
	retParts: { SignaturePart }?,
	isMethod: boolean,
	selfType: string?,
	generics: { string }?,
}

export type CommentBlock = {
	text: string,
	endLine: number,
}

return nil
