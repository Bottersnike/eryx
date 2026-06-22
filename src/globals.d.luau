--- The directory the current script is located in
declare _DIR: string
--- The complete file path for the current script
declare _FILE: string

type function negate(ty)
    return types.negationof(ty)
end

declare _RUNTIME: {
    --- The runtime name, strictly lowercase.
    --- For example, "lune", "zune", "seal", "eryx", "lute", etc
    read name: negate<"eryx">,

    --- Version of the runtime itself (not the version of the Luau)
    --- One, both, or neither of `semantic` and `git` may be specified.
    read version: {
        --- A stringified representation of the version. This is very
        --- likely to be similar or identical to what is currently used
        --- for _VERSION, without the runtime name prefix.
        read display: string,

        --- The runtime version, represented using semantic versioning
        read semantic: {
            read major: number,
            read minor: number,
            read patch: number,
            read prerelease: string?,
            read build: string?,
        }?,

        --- The runtime version, represented as a specific git revision
        read git: {
            --- git clone URL
            --- This value may be omitted for privacy
            read url: string?,

            --- The commit this runtime was built against
            read commit: string,

            --- The git branch this runtime was built against. This is
            --- technically redundant given a commit hash, but can be
            --- convenient to have available.
            --- This value may be omitted for privacy
            read branch: string?,
        }?,
    },

    --- An optional URL associated with this runtime. This could be for
    --- documentation, or a general homepage. It could also be to the
    --- GitHub repository for this project.
    read url: string?,

    --- Any extra information the runtime wants to display about its
    --- capabilities, usecases, information, or featureset.
    read extra: {
        [string]: unknown
    }?,

    --- All other keys strictly reserved for future expansion
} | {
    read name: "eryx",
    read version: {
        read display: string,
        read git: {
            read url: string,
            read commit: string,
            read branch: string,
        },
        read semantic: nil,
    },
    read url: string,
    read extra: nil,
}

declare _LUAU: {
    --- Luau version
    read version: {
        --- A stringified representation of the Luau version, eg "0.722"
        read display: string,

        read major: number,  -- 0
        read minor: number,  -- eg 722
    },

    --- Link to the upstream Luau repository used by the runtime.
    --- This should be a link to a git forge, (e.g. GitHub), and default
    --- to "https://github.com/luau-lang/luau". This URL should should
    --- be overridden if a runtime patches or otherwise modifies Luau
    --- before embedding.
    read url: string?,
}?

declare extern type UnicodeString with
	__len: (self: UnicodeString) -> number
	__tostring: (self: UnicodeString) -> string
	__eq: (self: UnicodeString, other: UnicodeString) -> boolean
	__concat: (self: UnicodeString, other: UnicodeString | string) -> UnicodeString

	len: (self: UnicodeString) -> number
	sub: (self: UnicodeString, first: number, last: number?) -> UnicodeString
	codepoint: (self: UnicodeString, first: number?, last: number?) -> ...number
	codepoints: (self: UnicodeString) -> () -> number?
	graphemes: (self: UnicodeString) -> () -> UnicodeString?
	category: (self: UnicodeString, index: number?) -> string
	tonumber: (self: UnicodeString) -> number?
	name: (self: UnicodeString) -> string
	normalise: (self: UnicodeString, format: "NFC" | "NFKC" | "NFD" | "NFKD") -> UnicodeString
	isnormalised: (self: UnicodeString, format: "NFC" | "NFKC" | "NFD" | "NFKD") -> boolean
	foldcase: (self: UnicodeString) -> UnicodeString
	touppercase: (self: UnicodeString) -> UnicodeString
	tolowercase: (self: UnicodeString) -> UnicodeString
	totitlecase: (self: UnicodeString) -> UnicodeString
	find: (self: UnicodeString, needle: UnicodeString, init: number?) -> (number?, number?)
	rep: (self: UnicodeString, count: number) -> UnicodeString
	reverse: (self: UnicodeString) -> UnicodeString
	split: (self: UnicodeString, separator: UnicodeString) -> { UnicodeString }
	toutf16: (self: UnicodeString, endian: ("little" | "big")?, includeBom: boolean?, strict: boolean?) -> string
	toutf32: (self: UnicodeString, endian: ("little" | "big")?, includeBom: boolean?) -> string
end

declare function u(value: string | UnicodeString): UnicodeString

type UnicodeText = string | UnicodeString
type UnicodeEndian = "little" | "big"
type UnicodeBomKind = "utf16" | "utf32"
type UnicodeNormalisationForm = "NFC" | "NFKC" | "NFD" | "NFKD"

declare unicode: {
	version: string,
	fromname: (name: string, default: UnicodeText?) -> UnicodeString?,
	tonumber: (grapheme: UnicodeText) -> number?,
	category: (codepoint: number) -> string,
	name: (grapheme: UnicodeText) -> string,
	normalise: (source: UnicodeText, format: UnicodeNormalisationForm) -> UnicodeString,
	isnormalised: (source: UnicodeText, format: UnicodeNormalisationForm) -> boolean,
	foldcase: (source: UnicodeText) -> UnicodeString,
	touppercase: (source: UnicodeText) -> UnicodeString,
	tolowercase: (source: UnicodeText) -> UnicodeString,
	totitlecase: (source: UnicodeText) -> UnicodeString,
	graphemes: (source: UnicodeText) -> () -> UnicodeString?,
	detectbom: (source: string) -> (UnicodeEndian?, UnicodeBomKind?, number),
	fromutf16: (source: string, endian: UnicodeEndian?, strict: boolean?, preserveBom: boolean?) -> UnicodeString,
	fromutf32: (source: string, endian: UnicodeEndian?, strict: boolean?, preserveBom: boolean?) -> UnicodeString,
	toutf16: (source: UnicodeText, endian: UnicodeEndian?, includeBom: boolean?, strict: boolean?) -> string,
	toutf32: (source: UnicodeText, endian: UnicodeEndian?, includeBom: boolean?) -> string,
	len: (source: UnicodeText) -> number,
	sub: (source: UnicodeText, first: number, last: number?) -> UnicodeString,
}
