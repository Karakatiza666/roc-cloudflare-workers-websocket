import pf.WebSocket
import pf.Request
import pf.Response
import pf.Io
import ws.Ws
import Internal/Convert as Convert

## A roc-websocket connection over the platform's `WebSocket`: a client of a
## Worker (`connect`) or the server end of an upgrade that the Worker accepts
## itself (`accept`). Its methods are the fields of `ops` (`Ws.Timed`: the
## core and `receive_within!`).
##
## The runtime owns the wire (it answers pings, assembles fragments and does
## the closing handshake), so there is nothing at the frame level.
## `max_message` of `Ws.ConnectRequest` and `Ws.AcceptOptions` is checked as
## each message arrives: a larger one fails the connection with 1009, as over
## bytes (the runtime has the whole message by then; its own bound is the
## receive queue, `max_queued_bytes`). For what only Workers has (`max_queued_bytes`, `Message.json`, `send_json!`,
## `Io.race!` over a receive) use the platform's `WebSocket`: `Conn.of` wraps
## one, `conn.socket()` gives it back.
Conn :: { socket : WebSocket, closing : Bool, max_message : [Limit(U64), NoLimit] }.{

	## The tags the adapter adds to `Closed` and `Closing`:
	## - `InvalidClose(Str)`: `close!` got a code that may not be sent or a
	##   reason over 123 bytes.
	## - `SocketErr(Io.Thrown)`: another throw of the runtime's `send`, or of
	##   `fetch` while connecting.
	## - `Refused(Str)`: the server did not answer the upgrade with 101.
	## - `NotUpgrade(Str)`: `accept!` got a request with no `Upgrade: websocket`.
	Errors : [InvalidClose(Str), SocketErr(Io.Thrown), Refused(Str), NotUpgrade(Str)]

	## Every error of a connection.
	Error : Ws.Error(Conn.Errors)

	## The connection over a socket that the app got from the platform itself
	## (for example from `WebSocket.accept_with!` with a `max_queued_bytes`),
	## with no `max_message`.
	of : WebSocket -> Conn
	of = |socket| { socket, closing: Bool.False, max_message: NoLimit }

	## The platform socket.
	socket : Conn -> WebSocket
	socket = |conn| conn.socket

	## Send one message. On a socket that is closing or closed: `Closed` with
	## the closure once the runtime has it, else `Closing`.
	send! : Conn, Ws.Message => Try(Conn, Conn.Error)
	send! = |conn, message| match conn.socket.send!(Convert.to_platform(message)) {
		Ok({}) => Ok(conn)
		Err(Closed) => Err(ended!(conn))
		Err(Infra(SocketErr(t))) => Err(SocketErr(t))
	}

	## The next message, with no deadline. After the close, `Closed`. A
	## message over `max_message` closes with 1009 and gives
	## `Closed({ code: 1009, clean: False, by: Us, .. })`.
	receive! : Conn => Try((Conn, Ws.Message), Conn.Error)
	receive! = |conn| match conn.socket.receive!() {
		Ok(m) => checked!(conn, Convert.from_platform(m)).map_ok(|msg| (conn, msg))
		Err(Closed(c)) => Err(Closed(c))
	}

	## The next message, or `TimedOut` when `ms` pass first. A message that
	## comes after the deadline stays for the next call.
	receive_within! : Conn, U64 => Try((Conn, [Message(Ws.Message), TimedOut]), Conn.Error)
	receive_within! = |conn, ms| match conn.socket.receive().timeout(ms).run!() {
		Ok(m) => checked!(conn, Convert.from_platform(m)).map_ok(|msg| (conn, Message(msg)))
		Err(Infra(TimedOut)) => Ok((conn, TimedOut))
		Err(Closed(c)) => Err(Closed(c))
	}

	## Start the closing handshake. `receive!` then gives the messages on their
	## way and ends with `Closed({ by: Us, .. })`. A second `close!` is
	## `Closing`, or `Closed` once the runtime has the closure.
	close! : Conn, U16, Str => Try(Conn, Conn.Error)
	close! = |conn, code, reason|
		if conn.closing {
			Err(ended!(conn))
		} else {
			match conn.socket.closed!() {
				Ok(closure) => Err(Closed(closure))
				Err(NotClosed) =>
					match conn.socket.close!(code, reason) {
						Ok({}) => Ok({ ..conn, closing: Bool.True })
						Err(e) => Err(Convert.invalid_close(e, code, reason))
					}
			}
		}

	## The operations as a record, for code generic over features
	## (`Ws.close_and_wait!`, `Ws.drive!`, `Ws.messages`).
	ops : Ws.Timed(Conn, Conn.Errors)
	ops = {
		send!: |c, m| c.send!(m),
		receive!: |c| c.receive!(),
		close!: |c, code, reason| c.close!(code, reason),
		receive_within!: |c, ms| c.receive_within!(ms),
	}

	## `Ws.Connect`: `connect!` of `request.url` (`ws://`, `wss://`, or the
	## `http(s)://` form) with its `protocols` and `headers`. The extensions
	## are the server's `Sec-WebSocket-Extensions`. With no `max_message`
	## there is no limit on one message (the platform bounds the bytes queued
	## for `receive!`, 4 MiB).
	connect : Ws.Connect(Conn, Conn.Errors, {})
	connect = { connect!: connect! }

	## `Ws.Accept` of a request of the Worker: the subprotocol is the first of
	## `options.protocols` that the client offers (the server's order, the
	## platform's `WebSocket.pick_protocol`). To look at the request first, or
	## refuse it, use the platform's `Request` (`segments`, `header`,
	## `WebSocket.protocols`) and return a `Response` of its own. Return `response` from
	## `fetch!` and use the connection in its `after` work, which lives until
	## the socket closes. The extensions are `NotReported`: the runtime
	## negotiates them and does not tell.
	accept : Ws.Accept(Request, Response, Conn, Conn.Errors, {})
	accept = { accept!: accept! }
}

connect! : Ws.ConnectRequest => Try(Ws.Opened(Conn), Conn.Error)
connect! = |request| {
	headers = (request.?headers ?? []).map(|(name, value)| { name, value })
	match WebSocket.connect_with!(request.url, { headers, protocols: request.?protocols ?? [] }) {
		Ok(socket) => Ok({ conn: limited(socket, request.?max_message), protocol: socket.protocol(), extensions: extensions(socket) })
		Err(NotUpgrade) => Err(Refused("the server did not answer the upgrade with 101"))
		Err(Infra(SocketErr(t))) => Err(SocketErr(t))
	}
}

accept! : Request, Ws.AcceptOptions => Try({ response : Response, opened : Ws.Opened(Conn) }, Conn.Error)
accept! = |req, options| {
	match WebSocket.accept_with!(req, { protocols: options.?protocols ?? [] }) {
		Ok({ socket, response }) => Ok({ response, opened: { conn: limited(socket, options.?max_message), protocol: socket.protocol(), extensions: extensions(socket) } })
		Err(NotUpgrade) => Err(NotUpgrade("the request has no Upgrade: websocket"))
	}
}

## The connection with the `max_message` of a request or of accept options.
limited : WebSocket, Try(U64, [MissingField]) -> Conn
limited = |socket, max| match max {
	Ok(n) => { ..Conn.of(socket), max_message: Limit(n) }
	Err(MissingField) => Conn.of(socket)
}

## A message within `max_message`. A larger one fails the connection as the
## byte-level driver does (RFC 6455 section 7.1.7): Close 1009 and the
## closure at once, with no wait for the peer's answer.
checked! : Conn, Ws.Message => Try(Ws.Message, Conn.Error)
checked! = |conn, msg| match conn.max_message {
	Limit(max) if Convert.message_size(msg) > max => {
		reason = "a message of more than ${max.to_str()} bytes"
		_ = conn.socket.close!(1009, reason)
		Err(Closed({ code: 1009, reason, clean: Bool.False, by: Us }))
	}
	_ => Ok(msg)
}

## Why a socket cannot send: its closure once the runtime has it, else
## `Closing` (the close is under way).
ended! : Conn => Conn.Error
ended! = |conn| match conn.socket.closed!() {
	Ok(closure) => Closed(closure)
	Err(NotClosed) => Closing
}

## The platform's extensions of a socket in roc-websocket's form.
extensions : WebSocket -> [Reported(List(Str)), NotReported]
extensions = |socket| match socket.extensions() {
	Ok(list) => Reported(list)
	Err(NotReported) => NotReported
}
