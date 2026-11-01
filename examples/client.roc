app [event!] {
	cfws: "../src/main.roc",
	pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.2/f352LLRKJCZ4JJVEocp3H9e4e6Sxa6Ym5CxZ1GZCpfd.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.3/FvsFHmH7m6LoMumXLxEHEfUoApGWdkgoFshfYEctaMNM.tar.zst",
}

## A Worker that connects out to a WebSocket server (`?url=ws://...`) through
## `Conn.connect` (`Ws.Connect`) and answers with what it saw.
##
## | Route | Does |
## | --- | --- |
## | `/talk` | subprotocols, a header, the extensions, text, bytes, `receive_within!`, `close!`, then `send!` and `close!` before the peer answers |
## | `/exchange?n=30` | `n` times: one message each way, then `Ws.close_and_wait!` at once |
## | `/peer_close` | the server closes: `Closed` by the peer from `receive!`, then the same closure from `send!` and `close!` |
## | `/stale` | `close!` on the connection value from before `Ws.close_and_wait!` |
## | `/errors` | `close!` with a code that may not be sent, `max_message`, a server that refuses |
import pf.Worker
import pf.Request
import pf.Response
import ws.Ws
import cfws.Conn

fetch! : Request => Try(Response, _)
fetch! = |req| {
	url = req.query("url") ?? ""
	text = match req.segments() {
		["talk"] => show(talk!(url))
		["exchange"] => show(exchange!(url, U64.from_str(req.query("n") ?? "1") ?? 1))
		["peer_close"] => show(peer_close!(url))
		["stale"] => show(stale!(url))
		["errors"] => errors!(url)
		_ => "no route"
	}
	Ok(Response.from_text(200, text))
}

show : Try(Str, Conn.Error) -> Str
show = |r| match r {
	Ok(s) => s
	Err(e) => "Err ${Str.inspect(e)}"
}

connect! : Ws.ConnectRequest => Try(Ws.Opened(Conn), Conn.Error)
connect! = |request| (Conn.connect.connect!)(request)

talk! : Str => Try(Str, Conn.Error)
talk! = |url| {
	opened = connect!({ url, protocols: ["chat", "v2"], headers: [("x-test", "yes")] })?
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
		"protocol=${opened.protocol} extensions=${Str.inspect(opened.extensions)} info=${Str.inspect(info)} bytes=${Str.inspect(bytes)} first=${Str.inspect(first)} second=${Str.inspect(second)} sent=${Str.inspect(sent.map_ok(|_| {}))} again=${Str.inspect(again.map_ok(|_| {}))} final=${Str.inspect(final.map_ok(|(_, m)| m))}",
	)
}

## The sequence of the 1006 that the platform fixed: a message each way, then
## the close at once. The closures, counted.
exchange! : Str, U64 => Try(Str, Conn.Error)
exchange! = |url, n| {
	var $clean = 0.U64
	var $other = []
	var $i = 0
	while $i < n {
		opened = connect!({ url: url })?
		c0 = opened.conn.send!(Text("still"))?
		(c1, _) = c0.receive!()?
		closure = Ws.close_and_wait!(Conn.ops, c1, 1000, "")?
		if closure == { code: 1000, reason: "", clean: Bool.True, by: Us } {
			$clean = $clean + 1
		} else {
			$other = $other.append(closure)
		}
		$i = $i + 1
	}
	Ok("clean=${$clean.to_str()} other=${Str.inspect($other)}")
}

## The server closes with 4005: `receive!` gives the closure, then `send!` and
## `close!` give the same one.
peer_close! : Str => Try(Str, Conn.Error)
peer_close! = |url| {
	opened = connect!({ url: url })?
	c0 = opened.conn.send!(Text("close me"))?
	got = c0.receive!()
	sent = c0.send!(Text("late"))
	closed = c0.close!(1000, "")
	Ok("got=${Str.inspect(got.map_ok(|(_, m)| m))} sent=${Str.inspect(sent.map_ok(|_| {}))} close=${Str.inspect(closed.map_ok(|_| {}))}")
}

## A value from before the end of the close knows nothing of it; the runtime
## does.
stale! : Str => Try(Str, Conn.Error)
stale! = |url| {
	opened = connect!({ url: url })?
	closure = Ws.close_and_wait!(Conn.ops, opened.conn, 4001, "generic")?
	again = opened.conn.close!(1000, "")
	sent = opened.conn.send!(Text("x"))
	Ok("closure=${Str.inspect(closure)} close=${Str.inspect(again.map_ok(|_| {}))} send=${Str.inspect(sent.map_ok(|_| {}))}")
}

## Errors that are not closures.
errors! : Str => Str
errors! = |url| {
	limit = connect!({ url, max_message: 10 }).map_ok(|_| {})
	refused = connect!({ url: url.replace_each("ws://", "http://").concat("/no") }).map_ok(|_| {})
	codes = match connect!({ url: url }) {
		Ok(opened) => {
			bad = opened.conn.close!(1005, "").map_ok(|_| {})
			long = opened.conn.close!(1000, Str.repeat("r", 124)).map_ok(|_| {})
			# After two refused closes the connection is still open.
			still = match opened.conn.send!(Text("still")) {
				Ok(c) => c.receive!().map_ok(|(_, m)| m)
				Err(e) => Err(e)
			}
			_ = Ws.close_and_wait!(Conn.ops, opened.conn, 1000, "")
			"bad=${Str.inspect(bad)} long=${Str.inspect(long)} still=${Str.inspect(still)}"
		}
		Err(e) => "Err ${Str.inspect(e)}"
	}
	"limit=${Str.inspect(limit)} refused=${Str.inspect(refused)} ${codes}"
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
