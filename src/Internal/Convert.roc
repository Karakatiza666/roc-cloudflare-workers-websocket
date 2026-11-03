import pf.WebSocket
import ws.Ws

# The mappings that Conn and Push share. Hidden: main.roc does not list it.
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

	## The platform's `close!` errors as roc-websocket's `InvalidClose`.
	invalid_close : [BadCode, TooLarge], U16, Str -> [InvalidClose(Str), ..others]
	invalid_close = |e, code, reason| match e {
		BadCode => InvalidClose("the close code ${code.to_str()} may not be sent")
		TooLarge => InvalidClose("a close reason of ${reason.count_utf8_bytes().to_str()} bytes; at most 123")
	}

	## The size of a message, as `max_message` counts it: the UTF-8 bytes of
	## a text, the bytes of a binary message.
	message_size : Ws.Message -> U64
	message_size = |m| match m {
		Text(s) => s.count_utf8_bytes()
		Binary(b) => b.len()
	}
}

expect Convert.from_platform(Convert.to_platform(Text("hi"))) == Text("hi")
expect Convert.from_platform(Convert.to_platform(Binary([0, 1, 255]))) == Binary([0, 1, 255])
expect Convert.to_platform(Binary([7])) == Bytes([7])
expect Convert.invalid_close(BadCode, 1005, "") == InvalidClose("the close code 1005 may not be sent")
expect Convert.invalid_close(TooLarge, 1000, Str.repeat("r", 124)) == InvalidClose("a close reason of 124 bytes; at most 123")
expect Convert.message_size(Text("héllo")) == 6
expect Convert.message_size(Binary([1, 2, 3])) == 3
