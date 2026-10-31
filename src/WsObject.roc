import pf.Object
import pf.WebSocket
import pf.Request
import pf.Response
import pf.Cbor
import pf.Io
import ws.Ws
import Internal/Convert as Convert

## The sockets of a Durable Object (the hibernation API), as a push-model
## roc-websocket server: the runtime delivers each message and each close as
## an event, so the object has no `receive!`, and its handlers are a
## `Ws.Handlers` record.
##
## `WsObject.class` makes the whole class. The parts (`accept!`, `message!`,
## `closed!`) go into an `Object.class` of the app's own when it has more
## handlers (`init!`, `alarm!`, RPC methods, other `fetch!` routes).
##
## The adapter keeps each socket's subprotocol, the `Handlers` state `s` and
## the `Persist` bytes in the socket's attachment, so they survive the object
## leaving memory. The adapter owns that attachment slot: an app that uses
## `WsObject` keeps its per-socket data in `s` or with `save!`, not in an
## `Object.Attachment` of its own.
WsObject :: [].{

	## The tags this adapter adds to `Closed`:
	## - `InvalidClose(Str)`: `close!` got a code that may not be sent or a
	##   reason over 123 bytes.
	## - `NotOpen`: `send!` on a socket that is closing or closed. Workers gives
	##   the closure to `on_close!`, not to `send!`.
	## - `SocketErr(Io.Thrown)`: another throw of the runtime's `send`.
	## - `TooLarge(U64)`: `save!` of bytes (the size given) that make the
	##   attachment larger than Workers takes (16,384 bytes in all), or an auto
	##   response over 2,048 characters.
	## - `BadData(Str)`: the attachment of the socket cannot be read.
	Errors : [InvalidClose(Str), NotOpen, SocketErr(Io.Thrown), TooLarge(U64), BadData(Str)]

	## Every error of a connection.
	Error : [Closed(Ws.Closure), InvalidClose(Str), NotOpen, SocketErr(Io.Thrown), TooLarge(U64), BadData(Str)]

	## The operations of a connection as a record: sending, and the bytes that
	## survive hibernation.
	Ops : Ws.Sender(WsObject.Conn, WsObject.Errors, Ws.Persist(WsObject.Conn, WsObject.Errors, {}))

	## A socket of the object, for one event. Its methods are the fields of
	## `Ops`, plus `protocol` and `socket`.
	Conn :: { socket : Object.Socket, protocol : Str }.{

		## The subprotocol the handshake settled, `""` for none (kept in the
		## attachment across events).
		protocol : WsObject.Conn -> Str
		protocol = |conn| conn.protocol

		## The platform socket, for the Workers calls that have no shared
		## form (`tags!`, `auto_response_ms!`).
		socket : WsObject.Conn -> Object.Socket
		socket = |conn| conn.socket

		## Send one message. `NotOpen` when the socket is closing or closed.
		send! : WsObject.Conn, Ws.Message => Try(WsObject.Conn, WsObject.Error)
		send! = |conn, message| match conn.socket.send!(Convert.to_platform(message)) {
			Ok({}) => Ok(conn)
			Err(Closed) => Err(NotOpen)
			Err(Infra(SocketErr(t))) => Err(SocketErr(t))
		}

		## Start the closing handshake. The peer's answer is the `on_close!`
		## event, with `by: Us`.
		close! : WsObject.Conn, U16, Str => Try(WsObject.Conn, WsObject.Error)
		close! = |conn, code, reason| match conn.socket.close!(code, reason) {
			Ok({}) => Ok(conn)
			Err(e) => Err(Convert.invalid_close(e, code, reason))
		}

		## The bytes of the last `save!`, or `Nothing`.
		saved! : WsObject.Conn => Try([Saved(List(U8)), Nothing], WsObject.Error)
		saved! = |conn| {
			stored = read!(conn.socket)?
			Ok(if (stored.has_saved) Saved(stored.saved.to_list()) else Nothing)
		}

		## Keep `bytes` with the socket while the object sleeps.
		save! : WsObject.Conn, List(U8) => Try(WsObject.Conn, WsObject.Error)
		save! = |conn, bytes| {
			stored = read!(conn.socket)?
			match slot.set!(conn.socket, { ..stored, saved: Cbor.bytes(bytes), has_saved: Bool.True }) {
				Ok({}) => Ok(conn)
				Err(TooLarge) => Err(TooLarge(bytes.len()))
			}
		}
	}

	## The operations of `Conn` as a record.
	ops : WsObject.Ops
	ops = {
		send!: |c, m| c.send!(m),
		close!: |c, code, reason| c.close!(code, reason),
		saved!: |c| c.saved!(),
		save!: |c, bytes| c.save!(bytes),
	}

	## The auto response of the object: Workers answers the text `request`
	## with `response` on every socket of the object, without waking it. Its
	## scope is the object (`Object.Self`), not one connection.
	auto_response : Ws.AutoResponse(Object.Self, WsObject.Errors, {})
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

	## A class whose `fetch!` accepts each upgrade request (426 for another
	## request) with `options.protocols`, and runs `handlers` with `state` as
	## the state of each new connection.
	##
	## ```roc
	## room = WsObject.class("Room", { protocols: ["chat"], state: { count: 0 } }, {
	##     on_open!: |s, conn| Ok((s, conn)),
	##     on_message!: |s, conn, msg| Ok(({ count: s.count + 1 }, conn.send!(msg)?)),
	##     on_close!: |s, _closure| Ok(s),
	## })
	## ```
	class : Str, { protocols ?: List(Str), state : s }, Ws.Handlers(s, WsObject.Conn, e) -> Object.Class(iface) where [s.Cbor.Writable, s.Cbor.Readable(errs)]
	class = |name, options, handlers| Object.class(
		name,
		{
			fetch!: |self, req| match WsObject.accept!(self, req, { protocols: options.?protocols ?? [] }, options.state, handlers) {
				Ok(response) => Ok(response)
				Err(NotUpgrade(_)) => Ok(Response.from_status(426))
				Err(other) => Err(other)
			},
			web_socket_message!: WsObject.message!(handlers),
			web_socket_close!: WsObject.closed!(handlers),
		},
	)

	## Accept an upgrade request in the object's `fetch!`: the subprotocol is
	## the first of `options.protocols` that the client offers. Runs
	## `on_open!` with `state`, keeps the state, and gives the 101 response to
	## return. An error of `on_open!` is `Handler(e)`, and no response.
	accept! : Object.Self, Request, Ws.AcceptOptions, s, Ws.Handlers(s, WsObject.Conn, e) => Try(Response, [NotUpgrade(Str), Unsupported(Str), State(Str), Handler([Closed(Ws.Closure), ..e])]) where [s.Cbor.Writable, s.Cbor.Readable(errs)]
	accept! = |self, req, options, state, handlers| {
		Convert.no_max_message(options.?max_message)?
		protocols = options.?protocols ?? []
		match self.accept_with!(req, { protocols: protocols }) {
			Ok({ socket, response }) => {
				protocol = WebSocket.pick_protocol(req, protocols) ?? ""
				write!(socket, { protocol, state: Cbor.bytes(Cbor.encode(state)), saved: Cbor.bytes([]), has_saved: Bool.False })?
				(s1, _) = (handlers.on_open!)(state, Conn.{ socket, protocol }).map_err(|e| Handler(e))?
				keep_state!(socket, s1)?
				Ok(response)
			}
			Err(NotUpgrade) => Err(NotUpgrade("the request has no Upgrade: websocket"))
			Err(TooLarge) => crash "WsObject.accept!: acceptWebSocket refused, with no tags"
		}
	}

	## The `web_socket_message!` handler of `handlers`: `on_message!` with the
	## socket's state, then the new state is kept.
	message! : Ws.Handlers(s, WsObject.Conn, e) -> (Object.Self, Object.Socket, WebSocket.Message => Try({}, [State(Str), Handler([Closed(Ws.Closure), ..e])])) where [s.Cbor.Writable, s.Cbor.Readable(errs)]
	message! = |handlers| |_self, socket, msg| {
		(conn, s) = load!(socket)?
		(s1, _) = (handlers.on_message!)(s, conn, Convert.from_platform(msg)).map_err(|e| Handler(e))?
		keep_state!(socket, s1)
	}

	## The `web_socket_close!` handler of `handlers`: answers a close of the
	## peer (with its code, or 1000 when it sent none), then `on_close!` with
	## the socket's state and the closure.
	closed! : Ws.Handlers(s, WsObject.Conn, e) -> (Object.Self, Object.Socket, WebSocket.Closed => Try({}, [State(Str), Handler([Closed(Ws.Closure), ..e])])) where [s.Cbor.Writable, s.Cbor.Readable(errs)]
	closed! = |handlers| |_self, socket, closure| {
		if closure.by == Peer {
			_ = socket.close!(if (closure.code == 1005) 1000 else closure.code, closure.reason)
			{}
		}
		(_, s) = load!(socket)?
		_ = (handlers.on_close!)(s, closure).map_err(|e| Handler(e))?
		Ok({})
	}
}

## What the adapter keeps in the attachment of each socket: the subprotocol,
## the `Handlers` state (CBOR) and the `Persist` bytes.
Stored : { protocol : Str, state : Cbor.Bytes, saved : Cbor.Bytes, has_saved : Bool }

slot : Object.Attachment(Stored)
slot = Object.attachment("roc-cloudflare-workers-websocket")

read! : Object.Socket => Try(Stored, [BadData(Str), ..others])
read! = |socket| match slot.get!(socket) {
	Ok(stored) => Ok(stored)
	Err(NotFound) => Err(BadData("the socket has no attachment: WsObject.accept! did not accept it"))
	Err(Infra(BadData(why))) => Err(BadData(why))
}

write! : Object.Socket, Stored => Try({}, [State(Str), ..others])
write! = |socket, stored| match slot.set!(socket, stored) {
	Ok({}) => Ok({})
	Err(TooLarge) => Err(State("the attachment is over 16,384 bytes: the state takes ${stored.state.to_list().len().to_str()} bytes, the saved bytes ${stored.saved.to_list().len().to_str()}"))
}

## The connection and the state of a socket, from its attachment.
load! : Object.Socket => Try((WsObject.Conn, s), [State(Str), ..others]) where [s.Cbor.Readable(errs)]
load! = |socket| {
	stored = read!(socket).map_err(|BadData(why)| State(why))?
	match Cbor.parse(stored.state.to_list()) {
		Ok(s) => Ok((Conn.{ socket, protocol: stored.protocol }, s))
		Err(e) => Err(State("the Handlers state in the attachment: ${Str.inspect(e)}"))
	}
}

## Keep the state `s` in the attachment, with what `save!` wrote meanwhile.
keep_state! : Object.Socket, s => Try({}, [State(Str), ..others]) where [s.Cbor.Writable]
keep_state! = |socket, s| {
	stored = read!(socket).map_err(|BadData(why)| State(why))?
	write!(socket, { ..stored, state: Cbor.bytes(Cbor.encode(s)) })
}
