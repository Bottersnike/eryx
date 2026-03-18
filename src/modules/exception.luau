local exception = {}

type ExceptionFrame = {
	source: string,
	short_src: string,
	line: number,
	functionName: string,
	lineContext: string,
}

export type ExceptionType = "runtime" | "assert" | "thrown" | "syntax" | "require" | "user" | "interrupt" | "system exit"

export type Exception = {
	message: string,
	type: ExceptionType,
	traceback: { ExceptionFrame },
}

function exception.new(message: string): Exception
	return nil :: any
end
function exception.format(error: Exception): string
	return nil :: any
end

return exception
