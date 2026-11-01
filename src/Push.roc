import pf.Object
import pf.WebSocket
import pf.Cbor
import pf.Io
import ws.Ws
import Internal/Convert as Convert

## roc-websocket's push model over the sockets of a Durable Object (the
## platform's hibernation API): the connection is the platform's
## `Object.Socket`, `ops` is `Ws.Push`, and `opened!`, `message!` and `closed!`
## run a `Ws.Handlers` record from the app's own `Object.class`:
##
## ```roc
## state_slot : Object.Attachment(U64)
## state_slot = Object.attachment("state")
##
## room = Object.class("Room", {
##     fetch!: |self, req| {
##         { socket, response } = self.accept_with!(req, { protocols: ["chat"] })?
##         Push.opened!(socket, state_slot, 0, handlers)?
##         Ok(response)
##     },
##     web_socket_message!: Push.message!(state_slot, handlers),
##     web_socket_close!: Push.closed!(state_slot, handlers),
## })
## ```
##
## The handlers' state `s` is per connection, as in `Ws.drive!`, and lives in
## the socket's attachment, the app's `Object.Attachment(s)`, so it survives
## the object leaving memory. Everything else (accepting, tags, subprotocols,
## broadcasts, the list of sockets) is the platform's `Object` API.
Push :: [].{

	## The tags the adapter adds to `Closed` and `Closing`:
	## - `InvalidClose(Str)`: `close!` got a code that may not be sent or a
	##   reason over 123 bytes.
	## - `SocketErr(Io.Thrown)`: another throw of the runtime's `send`.
	## - `TooLarge(U64)`: an auto response of that many bytes, or `save!` of
	##   that many bytes, over the Workers limit.
	## - `BadData(Str)`: the saved bytes cannot be read.
	Errors : [InvalidClose(Str), SocketErr(Io.Thrown), TooLarge(U64), BadData(Str)]

	## `send!` and `close!` over `Object.Socket`. A socket that is closing or
	## closed gives `Closing`: Workers gives the closure to `web_socket_close!`
	## (`on_close!`), not to `send!`.
	ops : Ws.Push(Object.Socket, Push.Errors)
	ops = {
		send!: |socket, message| match socket.send!(Convert.to_platform(message)) {
			Ok({}) => Ok(socket)
			Err(Closed) => Err(Closing)
			Err(Infra(SocketErr(t))) => Err(SocketErr(t))
		},
		close!: |socket, code, reason| match socket.close!(code, reason) {
			Ok({}) => Ok(socket)
			Err(e) => Err(Convert.invalid_close(e, code, reason))
		},
	}

	## `Ws.Persist` over an attachment of bytes that the app declares
	## (`Object.attachment(name)`). A socket has one attachment slot, so this
	## and a Handlers state slot on the same socket exclude each other.
	persist : Object.Attachment(Cbor.Bytes) -> Ws.Persist(Object.Socket, Push.Errors, {})
	persist = |slot| {
		saved!: |socket| match slot.get!(socket) {
			Ok(bytes) => Ok(Saved(bytes.to_list()))
			Err(NotFound) => Ok(Nothing)
			Err(Infra(BadData(why))) => Err(BadData(why))
		},
		save!: |socket, bytes| match slot.set!(socket, Cbor.bytes(bytes)) {
			Ok({}) => Ok(socket)
			Err(TooLarge) => Err(TooLarge(bytes.len()))
		},
	}

	## The object's auto response (`Object.Self.set_auto_response!`): Workers
	## keeps one per object, so the scope `c` is the object, and the reply is
	## sent on each of its sockets without waking it.
	auto_response : Ws.AutoResponse(Object.Self, Push.Errors, {})
	auto_response = {
		set_auto_response!: |self, pair| match self.set_auto_response!(pair) {
			Ok({}) => Ok(self)
			Err(TooLarge) => Err(TooLarge(pair.request.count_utf8_bytes().max(pair.response.count_utf8_bytes())))
		},
		clear_auto_response!: |self| {
			self.clear_auto_response!()
			Ok(self)
		},
	}

	## Call in the object's `fetch!` after `accept!`/`accept_with!` of the
	## platform: runs `on_open!` with `state` and keeps the state it gives in
	## `slot`.
	opened! : Object.Socket, Object.Attachment(s), s, Ws.Handlers(s, Object.Socket, e) => Try({}, [Handler([Closed(Ws.Closure), Closing, ..e]), Attachment([NotFound, Infra([BadData(Str)]), TooLarge])])
	opened! = |socket, slot, state, handlers| {
		(s1, _) = (handlers.on_open!)(state, socket).map_err(|e| Handler(e))?
		keep!(slot, socket, s1)
	}

	## The `web_socket_message!` handler: `on_message!` with the state in
	## `slot`, then the new state is kept.
	message! : Object.Attachment(s), Ws.Handlers(s, Object.Socket, e) -> (Object.Self, Object.Socket, WebSocket.Message => Try({}, [Handler([Closed(Ws.Closure), Closing, ..e]), Attachment([NotFound, Infra([BadData(Str)]), TooLarge])]))
	message! = |slot, handlers| |_self, socket, msg| {
		s = load!(slot, socket)?
		(s1, _) = (handlers.on_message!)(s, socket, Convert.from_platform(msg)).map_err(|e| Handler(e))?
		keep!(slot, socket, s1)
	}

	## The `web_socket_close!` handler: answers a close of the peer (with its
	## code, or 1000 when it sent none), then `on_close!` with the state in
	## `slot` and the closure.
	closed! : Object.Attachment(s), Ws.Handlers(s, Object.Socket, e) -> (Object.Self, Object.Socket, WebSocket.Closed => Try({}, [Handler([Closed(Ws.Closure), Closing, ..e]), Attachment([NotFound, Infra([BadData(Str)]), TooLarge])]))
	closed! = |slot, handlers| |_self, socket, closure| {
		if closure.by == Peer {
			_ = socket.close!(if (closure.code == 1005) 1000 else closure.code, closure.reason)
			{}
		}
		s = load!(slot, socket)?
		_ = (handlers.on_close!)(s, closure).map_err(|e| Handler(e))?
		Ok({})
	}
}

load! : Object.Attachment(s), Object.Socket => Try(s, [Attachment([NotFound, Infra([BadData(Str)]), TooLarge]), ..others])
load! = |slot, socket| match slot.get!(socket) {
	Ok(s) => Ok(s)
	Err(NotFound) => Err(Attachment(NotFound))
	Err(Infra(BadData(why))) => Err(Attachment(Infra(BadData(why))))
}

keep! : Object.Attachment(s), Object.Socket, s => Try({}, [Attachment([NotFound, Infra([BadData(Str)]), TooLarge]), ..others])
keep! = |slot, socket, s| match slot.set!(socket, s) {
	Ok({}) => Ok({})
	Err(TooLarge) => Err(Attachment(TooLarge))
}
