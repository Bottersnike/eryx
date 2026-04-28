local exception = {}

type ExceptionFrame = {
	source: string,
	short_src: string,
	line: number,
	functionName: string,
}

export type ExceptionType = "runtime" | "assert" | "thrown" | "syntax" | "require" | "user" | "interrupt" | "system exit"

export type Exception = {
	message: string,
	data: any?,
	type: ExceptionType,
	traceback: { ExceptionFrame },
}

function exception.new(message: string, parent: Exception?): Exception
	return nil :: any
end
function exception.format(error: Exception, useAnsi: boolean?): string
	return nil :: any
end
function exception.isInterrupt(error: any): boolean
	return nil :: any
end

return table.freeze(exception)
