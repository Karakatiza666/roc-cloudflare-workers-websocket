app [event!] {
	cfws: "../src/main.roc",
	pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.6/HgUugW5V5QQbmrjdjkRhjiZ8B9D9gzpEkSwdojqJcW4p.tar.zst",
	# Temporary: the unreleased roc-websocket (0.0.5) of a local checkout beside this one.
	ws: "../../roc-websocket/src/main.roc",
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
## | `/gate/...` | `gate`, a pure decision over the upgrade, then accept with its options or refuse with its status |
import pf.Worker
import pf.WebSocket
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
	["gate", ..] =>
		match gate(upgrade_of(req)) {
			Refuse(refusal) => Ok(Response.from_text(refusal.status, refusal.body).with_headers(refusal.headers.map(|(name, value)| { name, value })))
			Accept(options) =>
				match (Conn.accept.accept!)(req, options) {
					Ok({ response, opened }) => Ok(response.after(|| chat!(opened)))
					Err(NotUpgrade(_)) => Ok(Response.from_status(426))
					Err(e) => Err(e)
				}
		}
	["plain"] => Ok(Response.from_text(200, Str.inspect((Conn.accept.accept!)(req, {}).map_ok(|_| {}))))
	_ => Ok(Response.from_text(404, "no route"))
}

## What an application looks at before it accepts: the resource (path and
## query), `Host`, the subprotocols offered in order, and every header. This
## is the byte-level `Server.Request.upgrade()` with no `Sec-WebSocket-Key`;
## on Workers it comes from the platform's `Request`.
Upgrade : { resource : Str, host : Str, protocols : List(Str), headers : List((Str, Str)) }

upgrade_of : Request -> Upgrade
upgrade_of = |req| {
	resource: match req.url().split_first("://") {
		Ok({ after, .. }) =>
			match after.split_first("/") {
				Ok({ after: path, .. }) => "/${path}"
				Err(NotFound) => "/"
			}
		Err(NotFound) => req.url()
	},
	host: req.header("host") ?? "",
	protocols: WebSocket.protocols(req),
	headers: req.headers().map(|h| (h.name, h.value)),
}

## A pure decision over an upgrade, in roc-websocket's terms only
## (`Ws.AcceptOptions`, and a refusal shaped as `Server.Refusal`), so the same
## function runs on a byte-level server over `request.upgrade()`.
gate : Upgrade -> [Accept(Ws.AcceptOptions), Refuse({ status : U16, headers : List((Str, Str)), body : Str })]
gate = |u|
	if u.resource.starts_with("/gate/private") {
		Refuse({ status: 403, headers: [("x-gate", "private")], body: "no access to ${u.resource}" })
	} else if u.resource.starts_with("/gate/chat") and !u.protocols.contains("chat") {
		Refuse({ status: 400, headers: [], body: "offer the subprotocol chat" })
	} else if u.resource.starts_with("/gate/limited") {
		Accept({ protocols: ["chat", "v2"], max_message: 16 })
	} else {
		Accept({ protocols: ["chat", "v2"] })
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
