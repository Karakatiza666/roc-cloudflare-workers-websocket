app [event!] {
	cfws: "../src/main.roc",
	pf: platform "../../cloudflare-workers-ws/platform/main.roc",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.2/8ruw5bazzn7Xrtd3nGUTv5aGRVg3tSskgxeWbyGYsFZL.tar.zst",
}

## A Worker that accepts WebSockets itself (no Durable Object) and runs the
## generic `Chat` handlers over each one with `Ws.drive!`, through `Conn.accept`
## (`Ws.Accept`) and `Conn.ops` (`Ws.Timed`).
##
## | Route | Does |
## | --- | --- |
## | `/chat` | accept with the subprotocols `chat` and `v2`; `Chat` until the close |
## | `/timed` | accept; answer "tick" when no message comes for 200 ms (`receive_within!`) |
## | `/plain` | `accept!` of a request with no `Upgrade` |
import pf.Worker
import pf.Request
import pf.Response
import pf.Log
import ws.Ws
import cfws.Conn
import Chat

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["chat"] =>
		match (Conn.accept.accept!)(req, { protocols: ["chat", "v2"] }) {
			Ok({ response, opened }) => Ok(response.after(|| chat!(opened)))
			Err(NotUpgrade(_)) => Ok(Response.from_status(426))
			Err(e) => Err(e)
		}
	["timed"] =>
		match (Conn.accept.accept!)(req, {}) {
			Ok({ response, opened }) => Ok(response.after(|| ticks!(opened.conn, 0)))
			Err(NotUpgrade(_)) => Ok(Response.from_status(426))
			Err(e) => Err(e)
		}
	["plain"] => Ok(Response.from_text(200, Str.inspect((Conn.accept.accept!)(req, {}).map_ok(|_| {}))))
	_ => Ok(Response.from_text(404, "no route"))
}

chat! : Ws.Opened(Conn) => Try({}, Conn.Error)
chat! = |opened| {
	Log.info!("chat open", { protocol: opened.protocol, extensions: Str.inspect(opened.extensions) })
	h = Chat.handlers(Conn.ops)
	handlers = {
		on_open!: h.on_open!,
		on_message!: h.on_message!,
		on_close!: |n, closure| {
			Log.info!("chat closure", { code: closure.code, reason: closure.reason, clean: closure.clean, by: Str.inspect(closure.by) })
			(h.on_close!)(n, closure)
		},
	}
	match Ws.drive!(Conn.ops, opened.conn, 0, handlers) {
		Ok(count) => Log.info!("chat closed", { count: count })
		Err(e) => Log.info!("chat failed", { error: Str.inspect(e) })
	}
	Ok({})
}

## "tick" for each 200 ms with no message, the message back otherwise.
ticks! : Conn, U64 => Try({}, Conn.Error)
ticks! = |conn, n| match conn.receive_within!(200) {
	Ok((c, TimedOut)) =>
		match c.send!(Text("tick ${n.to_str()}")) {
			Ok(c2) => ticks!(c2, n + 1)
			Err(e) => Err(e)
		}
	Ok((c, Message(m))) =>
		match c.send!(m) {
			Ok(c2) => ticks!(c2, n)
			Err(e) => Err(e)
		}
	Err(Closed(closure)) => {
		Log.info!("timed closed", { code: closure.code, by: Str.inspect(closure.by) })
		Ok({})
	}
	Err(e) => Err(e)
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
