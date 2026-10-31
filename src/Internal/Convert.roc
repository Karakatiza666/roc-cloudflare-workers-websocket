import pf.WebSocket
import ws.Ws

# The mappings that WsWorker and WsObject share. Hidden: main.roc does not list it.
Convert :: [].{

	to_platform : Ws.Message -> WebSocket.Message
	to_platform = |m| match m {
		Text(s) => Text(s)
		Binary(b) => Bytes(b)
	}

	from_platform : WebSocket.Message -> Ws.Message
	from_platform = |m| match m {
		Text(s) => Text(s)
		Bytes(b) => Binary(b)
	}

	## The closure of `send!` and `close!` after this endpoint's `close!`,
	## before the peer answers: the code and reason sent (roc-websocket's
	## `Client` gives the same).
	provisional : U16, Str -> Ws.Closure
	provisional = |code, reason| { code, reason, clean: Bool.False, by: Us }

	## The platform's `close!` errors as roc-websocket's `InvalidClose`.
	invalid_close : [BadCode, TooLarge], U16, Str -> [InvalidClose(Str), ..others]
	invalid_close = |e, code, reason| match e {
		BadCode => InvalidClose("the close code ${code.to_str()} may not be sent")
		TooLarge => InvalidClose("a close reason of ${reason.count_utf8_bytes().to_str()} bytes; at most 123")
	}

	## `max_message` of a request or of accept options: the platform has no
	## per-message limit (it bounds the bytes queued for `receive!`).
	no_max_message : Try(U64, [MissingField]) -> Try({}, [Unsupported(Str), ..others])
	no_max_message = |max| match max {
		Ok(_) => Err(Unsupported("max_message: the platform has no limit on one message (it bounds the bytes queued for receive!)"))
		Err(MissingField) => Ok({})
	}
}

expect Convert.from_platform(Convert.to_platform(Text("hi"))) == Text("hi")
expect Convert.from_platform(Convert.to_platform(Binary([0, 1, 255]))) == Binary([0, 1, 255])
expect Convert.to_platform(Binary([7])) == Bytes([7])
expect Convert.provisional(4000, "bye") == { code: 4000, reason: "bye", clean: Bool.False, by: Us }
expect Convert.invalid_close(BadCode, 1005, "") == InvalidClose("the close code 1005 may not be sent")
expect Convert.invalid_close(TooLarge, 1000, Str.repeat("r", 124)) == InvalidClose("a close reason of 124 bytes; at most 123")
expect Convert.no_max_message(Err(MissingField)) == Ok({})
expect Convert.no_max_message(Ok(10)) != Ok({})
