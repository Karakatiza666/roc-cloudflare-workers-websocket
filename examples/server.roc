app [event!] {
	cfws: "../src/main.roc",
	pf: platform "../../talon-ws/cloudflare-workers/platform/main.roc",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.1/4i6sgv5VVbr9xet5sWkRWMYa4H3dMUJSzWrMhRXsFTgn.tar.zst",
}

## A Worker that accepts WebSockets itself (no Durable Object) and runs the
## generic `Chat` handlers over each one with `Ws.drive!`.
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
import cfws.WsWorker
import Chat

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["chat"] =>
		match WsWorker.accept!(req, { protocols: ["chat", "v2"] }) {
			Ok({ conn, protocol, response }) => Ok(response.after(|| chat!(conn, protocol)))
			Err(NotUpgrade(_)) => Ok(Response.from_status(426))
			Err(e) => Err(e)
		}
	["timed"] =>
		match WsWorker.accept!(req, {}) {
			Ok({ conn, response, .. }) => Ok(response.after(|| ticks!(conn, 0)))
			Err(NotUpgrade(_)) => Ok(Response.from_status(426))
			Err(e) => Err(e)
		}
	["plain"] => Ok(Response.from_text(200, Str.inspect(WsWorker.accept!(req, {}).map_ok(|_| {}))))
	_ => Ok(Response.from_text(404, "no route"))
}

chat! : WsWorker.Conn, Str => Try({}, WsWorker.Error)
chat! = |conn, protocol| {
	Log.info!("chat open", { protocol: protocol })
	h = Chat.handlers(WsWorker.ops)
	handlers = {
		on_open!: h.on_open!,
		on_message!: h.on_message!,
		on_close!: |n, closure| {
			Log.info!("chat closure", { code: closure.code, reason: closure.reason, clean: closure.clean, by: Str.inspect(closure.by) })
			(h.on_close!)(n, closure)
		},
	}
	match Ws.drive!(WsWorker.ops, conn, 0, handlers) {
		Ok(count) => Log.info!("chat closed", { count: count })
		Err(e) => Log.info!("chat failed", { error: Str.inspect(e) })
	}
	Ok({})
}

## "tick" for each 200 ms with no message, the message back otherwise.
ticks! : WsWorker.Conn, U64 => Try({}, WsWorker.Error)
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
