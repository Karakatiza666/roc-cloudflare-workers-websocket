app [event!] {
	cfws: "../src/main.roc",
	pf: platform "../../talon-ws/cloudflare-workers/platform/main.roc",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.1/4i6sgv5VVbr9xet5sWkRWMYa4H3dMUJSzWrMhRXsFTgn.tar.zst",
}

## A Worker that connects out to a WebSocket server (`?url=ws://...`) and
## answers with what it saw, one route for each behaviour.
##
## | Route | Does |
## | --- | --- |
## | `/talk` | connect with subprotocols and a header; text, bytes, `receive_within!`, `close!`, then `send!` and `close!` before the peer answers |
## | `/peer_close` | the server closes: `receive!` gives `Closed` by the peer, `send!` then gives `NotOpen` |
## | `/errors` | `close!` with a code that may not be sent, `max_message`, a server that refuses |
## | `/close_and_wait` | the generic `Ws.close_and_wait!` over `WsWorker.ops` |
import pf.Worker
import pf.Request
import pf.Response
import ws.Ws
import cfws.WsWorker

fetch! : Request => Try(Response, _)
fetch! = |req| {
	url = req.query("url") ?? ""
	text = match req.segments() {
		["talk"] => show(talk!(url))
		["peer_close"] => show(peer_close!(url))
		["errors"] => errors!(url)
		["close_and_wait"] => show(close_and_wait!(url))
		_ => "no route"
	}
	Ok(Response.from_text(200, text))
}

show : Try(Str, WsWorker.Error) -> Str
show = |r| match r {
	Ok(s) => s
	Err(e) => "Err ${Str.inspect(e)}"
}

talk! : Str => Try(Str, WsWorker.Error)
talk! = |url| {
	opened = WsWorker.connect!({ url, protocols: ["chat", "v2"], headers: [("x-test", "yes")] })?
	c0 = opened.conn.send!(Text("info"))?
	(c1, info) = c0.receive!()?
	c2 = c1.send!(Binary([0, 1, 255]))?
	(c3, bytes) = c2.receive!()?
	c4 = c3.send!(Text("delay 300 late"))?
	(c5, first) = c4.receive_within!(50)?
	(c6, second) = c5.receive_within!(2_000)?
	c7 = c6.close!(1000, "done")?
	sent = c7.send!(Text("after"))
	again = c7.close!(4000, "again")
	final = c7.receive!()
	Ok(
		"protocol=${opened.protocol} conn.protocol=${c7.protocol()} info=${Str.inspect(info)} bytes=${Str.inspect(bytes)} first=${Str.inspect(first)} second=${Str.inspect(second)} sent=${Str.inspect(sent.map_ok(|_| {}))} again=${Str.inspect(again.map_ok(|_| {}))} final=${Str.inspect(final.map_ok(|(_, m)| m))}",
	)
}

## The server closes with 4005. `send!` on the closed connection.
peer_close! : Str => Try(Str, WsWorker.Error)
peer_close! = |url| {
	opened = WsWorker.connect!({ url: url })?
	c0 = opened.conn.send!(Text("close me"))?
	got = c0.receive!()
	sent = c0.send!(Text("late"))
	Ok("got=${Str.inspect(got.map_ok(|(_, m)| m))} sent=${Str.inspect(sent.map_ok(|_| {}))}")
}

close_and_wait! : Str => Try(Str, WsWorker.Error)
close_and_wait! = |url| {
	opened = WsWorker.connect!({ url: url })?
	closure = Ws.close_and_wait!(WsWorker.ops, opened.conn, 4001, "generic")?
	Ok(Str.inspect(closure))
}

## Errors that are not closures.
errors! : Str => Str
errors! = |url| {
	limit = WsWorker.connect!({ url, max_message: 10 }).map_ok(|_| {})
	refused = WsWorker.connect!({ url: url.replace_each("ws://", "http://").concat("/no") }).map_ok(|_| {})
	codes = match WsWorker.connect!({ url: url }) {
		Ok(opened) => {
			bad = opened.conn.close!(1005, "").map_ok(|_| {})
			long = opened.conn.close!(1000, Str.repeat("r", 124)).map_ok(|_| {})
			# After two refused closes the connection is still open.
			still = match opened.conn.send!(Text("still")) {
				Ok(c) => c.receive!().map_ok(|(_, m)| m)
				Err(e) => Err(e)
			}
			_ = Ws.close_and_wait!(WsWorker.ops, opened.conn, 1000, "")
			"bad=${Str.inspect(bad)} long=${Str.inspect(long)} still=${Str.inspect(still)}"
		}
		Err(e) => "Err ${Str.inspect(e)}"
	}
	"limit=${Str.inspect(limit)} refused=${Str.inspect(refused)} ${codes}"
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
