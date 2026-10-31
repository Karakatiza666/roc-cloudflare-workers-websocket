import pf.WebSocket
import pf.Request
import pf.Response
import pf.Io
import ws.Ws
import Internal/Convert as Convert

## WebSocket connections of a Worker, as roc-websocket connections: a client
## (`connect!`) and the server end of an upgrade (`accept!`). Both are the
## platform's `WebSocket`, whose messages Roc pulls with `receive!`.
##
## The runtime owns the wire: it answers pings, assembles fragments and does
## the closing handshake, so the adapter has the core and a receive with a
## deadline (`Ws.Timed`), and nothing at the frame level.
WsWorker :: [].{

	## The tags this adapter adds to `Closed`:
	## - `InvalidClose(Str)`: `close!` got a code that may not be sent or a
	##   reason over 123 bytes.
	## - `NotOpen`: `send!` on a connection that the peer or the transport
	##   closed. The platform does not give the closure there; `receive!` does.
	## - `SocketErr(Io.Thrown)`: another throw of the runtime's `send`, or of
	##   `fetch` while connecting.
	## - `Refused(Str)`: the server did not answer the upgrade with 101.
	## - `NotUpgrade(Str)`: `accept!` got a request with no `Upgrade: websocket`.
	## - `Unsupported(Str)`: an option that the platform does not have
	##   (`max_message`).
	Errors : [InvalidClose(Str), NotOpen, SocketErr(Io.Thrown), Refused(Str), NotUpgrade(Str), Unsupported(Str)]

	## Every error of a connection.
	Error : [Closed(Ws.Closure), InvalidClose(Str), NotOpen, SocketErr(Io.Thrown), Refused(Str), NotUpgrade(Str), Unsupported(Str)]

	## The operations as a record: the core and `receive_within!`.
	Ops : Ws.Timed(WsWorker.Conn, WsWorker.Errors)

	## A connection: the platform socket, and the close this endpoint started,
	## if any. Its methods are the fields of `Ops`, plus `protocol`.
	Conn :: { socket : WebSocket, closing : [Open, Closing(U16, Str)] }.{

		## The subprotocol the handshake settled, `""` for none.
		protocol : WsWorker.Conn -> Str
		protocol = |conn| conn.socket.protocol()

		## Send one message. After `close!`, `Closed` with the code this
		## endpoint sent (as roc-websocket's client gives). After a close by
		## the peer or the transport, `NotOpen`.
		send! : WsWorker.Conn, Ws.Message => Try(WsWorker.Conn, WsWorker.Error)
		send! = |conn, message| match conn.socket.send!(Convert.to_platform(message)) {
			Ok({}) => Ok(conn)
			Err(Closed) => Err(not_open(conn))
			Err(Infra(SocketErr(t))) => Err(SocketErr(t))
		}

		## The next message, with no deadline. After the close, `Closed` with
		## the close record of the runtime.
		receive! : WsWorker.Conn => Try((WsWorker.Conn, Ws.Message), WsWorker.Error)
		receive! = |conn| match conn.socket.receive!() {
			Ok(m) => Ok((conn, Convert.from_platform(m)))
			Err(Closed(c)) => Err(Closed(c))
		}

		## The next message, or `TimedOut` when `ms` pass first. A message that
		## comes after the deadline stays for the next call.
		receive_within! : WsWorker.Conn, U64 => Try((WsWorker.Conn, [Message(Ws.Message), TimedOut]), WsWorker.Error)
		receive_within! = |conn, ms| match conn.socket.receive().timeout(ms).run!() {
			Ok(m) => Ok((conn, Message(Convert.from_platform(m))))
			Err(Infra(TimedOut)) => Ok((conn, TimedOut))
			Err(Closed(c)) => Err(Closed(c))
		}

		## Start the closing handshake. `receive!` then gives the messages on
		## their way and ends with `Closed({ by: Us, .. })`.
		close! : WsWorker.Conn, U16, Str => Try(WsWorker.Conn, WsWorker.Error)
		close! = |conn, code, reason| match conn.closing {
			Closing(sent, why) => Err(Closed(Convert.provisional(sent, why)))
			Open =>
				match conn.socket.close!(code, reason) {
					Ok({}) => Ok({ ..conn, closing: Closing(code, reason) })
					Err(e) => Err(Convert.invalid_close(e, code, reason))
				}
		}
	}

	## The operations of `Conn` as a record, for code generic over features
	## (`Ws.close_and_wait!`, `Ws.drive!`, `Ws.messages`).
	ops : WsWorker.Ops
	ops = {
		send!: |c, m| c.send!(m),
		receive!: |c| c.receive!(),
		close!: |c, code, reason| c.close!(code, reason),
		receive_within!: |c, ms| c.receive_within!(ms),
	}

	## Connect to `request.url` (`ws://`, `wss://`, or the `http(s)://` form)
	## with its `protocols` and `headers`. `max_message` is `Unsupported`:
	## the platform has no limit on one message; it bounds the bytes queued for `receive!` (4 MiB).
	##
	## ```roc
	## opened = WsWorker.connect!({ url: "wss://example.com/rpc", protocols: ["v1"] })?
	## conn = opened.conn.send!(Text("hi"))?
	## ```
	connect! : Ws.Request => Try({ conn : WsWorker.Conn, protocol : Str }, WsWorker.Error)
	connect! = |request| {
		Convert.no_max_message(request.?max_message)?
		headers = (request.?headers ?? []).map(|(name, value)| { name, value })
		match WebSocket.connect_with!(request.url, { headers, protocols: request.?protocols ?? [] }) {
			Ok(socket) => Ok({ conn: opened(socket), protocol: socket.protocol() })
			Err(NotUpgrade) => Err(Refused("the server did not answer the upgrade with 101"))
			Err(Infra(SocketErr(t))) => Err(SocketErr(t))
		}
	}

	## Accept an upgrade request, picking the first of `options.protocols`
	## that the client offers. Return `response` from the `fetch!` handler and
	## use `conn` in its `after` work, which lives until the socket closes:
	##
	## ```roc
	## match WsWorker.accept!(req, { protocols: ["chat"] }) {
	##     Ok({ conn, response, .. }) => Ok(response.after(|| serve!(conn)))
	##     Err(NotUpgrade(_)) => Ok(Response.from_status(426))
	##     Err(other) => Err(other)
	## }
	## ```
	accept! : Request, Ws.AcceptOptions => Try({ conn : WsWorker.Conn, protocol : Str, response : Response }, [NotUpgrade(Str), Unsupported(Str)])
	accept! = |req, options| {
		Convert.no_max_message(options.?max_message)?
		match WebSocket.accept_with!(req, { protocols: options.?protocols ?? [] }) {
			Ok({ socket, response }) => Ok({ conn: opened(socket), protocol: socket.protocol(), response })
			Err(NotUpgrade) => Err(NotUpgrade("the request has no Upgrade: websocket"))
		}
	}

	## A connection over a socket the app got from the platform itself (for
	## example from `WebSocket.accept_with!` with a `max_queued_bytes`).
	from_socket : WebSocket -> WsWorker.Conn
	from_socket = |socket| opened(socket)
}

opened : WebSocket -> WsWorker.Conn
opened = |socket| { socket, closing: Open }

not_open : WsWorker.Conn -> WsWorker.Error
not_open = |conn| match conn.closing {
	Closing(code, reason) => Closed(Convert.provisional(code, reason))
	Open => NotOpen
}
