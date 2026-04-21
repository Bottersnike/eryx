--[=[
	A lightweight, re-entrant-safe signal/event system using a doubly-linked list
	of connections. Signals allow you to fire events and notify all connected
	callbacks.

	Handlers are invoked via `task.spawn`, so each callback runs in its own
	coroutine. Disconnecting or connecting handlers during a `Fire` is safe -
	the handler list is snapshotted before invocation.

	```luau
	local Signal = require("@eryx/signal")

	local onDamage = Signal.new()

	local conn = onDamage:connect(function(amount)
		print("Took " .. amount .. " damage!")
	end)

	onDamage:fire(25)  --> "Took 25 damage!"

	conn:disconnect()
	onDamage:fire(10)  --> (nothing, handler was disconnected)
	```
]=]
local task = require("@eryx/task")

--[=[
	Represents a single subscription to a Signal. Created by `Signal:connect`
	or `Signal:once`. Can be disconnected to stop receiving future events.
]=]
local Connection = {}
Connection.__index = Connection

export type Connection<T...> = setmetatable<{
	_signal: Signal<T...>,
	_fn: (T...) -> (),
	_next: Connection<T...>?,
	_prev: Connection<T...>?,
	read connected: boolean,
}, typeof(Connection)>

--[=[
	Disconnects this connection from its signal. Future fires will no longer
	invoke this connection's callback. Safe to call multiple times - subsequent
	calls are a no-op.
]=]
function Connection.disconnect<T...>(self: Connection<T...>)
	if not self.connected then
		return
	end
	(self :: any).connected = false

	local next = self._next
	local prev = self._prev

	if next then
		next._prev = prev
	end
	if prev then
		prev._next = next
	else
		-- We were the head
		self._signal._head = next
	end

	self._next = nil
	self._prev = nil
end

--[=[
	A generic event dispatcher. Supports connecting multiple handlers,
	one-shot handlers, yielding until the next fire, and bulk disconnection.
]=]
local Signal = {}
Signal.__index = Signal

export type Signal<T...> = setmetatable<
	{
		_head: Connection<T...>?,

		-- ! We can't include this here because of recursive types!
		-- _errorSignal: Signal<any, Connection<T...>>?,
	},
	typeof(Signal)
>

--[=[
	Creates a new Signal.

	@return Signal<T...> -- A new signal with no connections.

	```luau
	local onPlayerJoin = Signal.new()
	```
]=]
function Signal.new<T...>(): Signal<T...>
	local this = {
		_head = nil :: Connection<T...>?,
		_errorSignal = nil :: Signal<any, Connection<T...>>?,
	}

	return setmetatable(this, Signal)
end

--[=[
	Fires the signal, invoking all connected callbacks with the given arguments.
	Each handler runs in its own coroutine via `task.spawn`. The handler list
	is snapshotted before invocation, so connects/disconnects during callbacks
	are safe.

	@param ... T... -- Arguments to pass to each connected handler.
	@return boolean -- `true` if at least one handler was invoked, `false` otherwise.

	```luau
	local sig = Signal.new()
	sig:connect(function(msg) print(msg) end)
	sig:fire("hello") --> "hello", returns true
	```
]=]
function Signal.fire<T...>(self: Signal<T...>, ...: T...): boolean
	-- Snapshot connected handlers so that disconnects during
	-- callbacks cannot break traversal.
	local handlers = {}
	local node = self._head
	while node do
		if node.connected then
			table.insert(handlers, node)
		end
		node = node._next
	end

	if #handlers == 0 then
		return false
	end

	-- ! Luau can't represent tuple types, so packing T... doesn't work
	-- We cast to `any` to avoid type errors, at the expense of losing
	-- type checking
	local args = (table.pack :: any)(...)
	for _, handler in handlers do
		if handler.connected then
			task.spawn(function()
				local ok, err = pcall(function()
					(handler._fn :: any)(table.unpack(args, 1, args.n))
				end)

				if ok then
					return
				end

				local errorSignal = (self :: any)._errorSignal
				if errorSignal then
					errorSignal:fire(err, handler)
				else
					error(err)
				end
			end)
		end
	end
	return true
end

--[=[
	Yields the current coroutine until the signal is next fired, then returns
	the fired arguments.

	@return T... -- The arguments passed to the next `Fire` call.

	```luau
	-- In a coroutine:
	local damage = onDamage:wait()
	print("Waited and received:", damage)
	```
]=]
function Signal.wait<T...>(self: Signal<T...>): T...
	local thread = coroutine.running()
	self:once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

--[=[
	Disconnects all connections from this signal. All existing Connection
	objects will have their `connected` property set to `false`.
]=]
function Signal.disconnectAll<T...>(self: Signal<T...>)
	local node = self._head
	while node do
		local next = node._next; -- Semicolon for disambiguation
		(node :: any).connected = false
		node._next = nil
		node._prev = nil
		node = next
	end
	self._head = nil
end

--[=[
	Returns a lazily-created signal that fires when any handler connected to
	this signal raises an error. The error signal fires with `(err, connection)`.

	If no error handlers are connected, handler errors are re-thrown so they
	remain visible rather than being silently swallowed.

	```luau
	local sig = Signal.new()

	sig:errorSignal():connect(function(err)
		warn("signal handler failed:", err)
	end)
	```
]=]
function Signal.errorSignal<T...>(self: Signal<T...>): Signal<any, Connection<T...>>
	if not (self :: any)._errorSignal then
		(self :: any)._errorSignal = Signal.new()
	end
	-- ! Unfortunate cast required to avoid *CYCLE*
	return (self :: any)._errorSignal
end

--[=[
	Connects a callback that will be invoked whenever one of this signal's
	handlers raises an error. The callback receives the thrown value and the
	connection whose handler failed.
]=]
function Signal.connectError<T...>(
	self: Signal<T...>,
	callback: (err: any, connection: Connection<T...>) -> ()
): Connection<any, Connection<T...>>
	-- ! Unfortunate cast required to avoid *CYCLE*
	return (self :: any):errorSignal():connect(callback)
end

--[=[
	Connects a callback to this signal. The callback will be invoked each time
	the signal is fired, until the returned Connection is disconnected.

	@param callback (T...) -> () -- The function to call when the signal fires.
	@return Connection<T...> -- A connection that can be used to disconnect later.

	```luau
	local conn = signal:connect(function(value)
		print("Got:", value)
	end)
	-- Later:
	conn:disconnect()
	```
]=]
function Signal.connect<T...>(self: Signal<T...>, callback: (T...) -> ()): Connection<T...>
	local node: Connection<T...> = setmetatable({
		_signal = self,
		_fn = callback,
		_next = self._head,
		_prev = nil :: Connection<T...>?,
		connected = true,
	}, Connection)

	if self._head then
		self._head._prev = node
	end
	self._head = node

	return node :: Connection<T...>
end

--[=[
	Connects a callback that will only fire once. The connection automatically
	disconnects itself before invoking the callback.

	@param callback (T...) -> () -- The function to call on the next fire.
	@return Connection<T...> -- A connection that can be manually disconnected before it fires.

	```luau
	signal:once(function(value)
		print("Fired once with:", value)
	end)
	```
]=]
function Signal.once<T...>(self: Signal<T...>, callback: (T...) -> ()): Connection<T...>
	local conn: Connection<T...>
	conn = Signal.connect(self, function(...)
		if conn.connected then
			conn:disconnect()
			callback(...)
		end
	end)
	return conn
end

return table.freeze(Signal)
