app [event!] {
	cfws: "../src/main.roc",
	pf: platform "../../talon-ws/cloudflare-workers/platform/main.roc",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.1/4i6sgv5VVbr9xet5sWkRWMYa4H3dMUJSzWrMhRXsFTgn.tar.zst",
}

## Durable Objects that serve WebSockets with the hibernation API, through
## `WsObject`. The Worker gives each upgrade request to an object.
##
## | Route | Object |
## | --- | --- |
## | `/chat/<name>` | class `Chat`: `WsObject.class` with the generic `Chat` handlers (the same ones the Worker server runs) |
## | `/room/<name>?user=<u>` | class `Room`: an `Object.class` of the app with the parts of `WsObject`; per-socket state, `save`/`saved` use `Persist` |
## | `/room/<name>?op=auto` | `WsObject.auto_response` sets the reply "pong" to "ping" for the object |
import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Log
import ws.Ws
import cfws.WsObject
import Chat

NoRpc := []

chat_class : Object.Class(NoRpc)
chat_class = WsObject.class("Chat", { protocols: ["chat"], state: 0 }, logged(Chat.handlers(WsObject.ops)))

chats : Object.Namespace(NoRpc)
chats = Object.namespace("CHATS", { class: chat_class })

## The `Chat` handlers with a log line at the close.
logged : Ws.Handlers(U64, c, e) -> Ws.Handlers(U64, c, e)
logged = |h| {
	on_open!: h.on_open!,
	on_message!: h.on_message!,
	on_close!: |n, closure| {
		Log.info!("chat closed", { count: n, code: closure.code, reason: closure.reason, clean: closure.clean, by: Str.inspect(closure.by) })
		(h.on_close!)(n, closure)
	},
}

## The state of a socket of `Room`: the user name, and the messages it sent.
User : { name : Str, sent : U64 }

room_handlers : Ws.Handlers(User, WsObject.Conn, WsObject.Errors)
room_handlers = {
	on_open!: |user, conn| Ok((user, conn.send!(Text("hello ${user.name} protocol=${conn.protocol()}"))?)),
	on_message!: |user, conn, msg| {
		next = { ..user, sent: user.sent + 1 }
		match msg {
			Text("whoami") => Ok((next, conn.send!(Text("${user.name} sent=${next.sent.to_str()} protocol=${conn.protocol()}"))?))
			Text(t) if t.starts_with("save ") => {
				c = conn.save!(t.drop_prefix("save ").to_utf8())?
				Ok((next, c.send!(Text("saved"))?))
			}
			Text("saved") => {
				got = match conn.saved!()? {
					Saved(bytes) => Str.from_utf8(bytes) ?? "not UTF-8"
					Nothing => "nothing"
				}
				Ok((next, conn.send!(Text("saved=${got}"))?))
			}
			Text("big") => {
				too_big = conn.save!(List.repeat(7, 20_000))
				Ok((next, conn.send!(Text("big=${Str.inspect(too_big.map_ok(|_| {}))}"))?))
			}
			Text("close") => Ok((next, conn.close!(4002, "room bye")?))
			Text("close_send") => {
				c = conn.close!(4003, "closing")?
				after = c.send!(Text("late"))
				Log.info!("room close_send", { after: Str.inspect(after.map_ok(|_| {})) })
				Ok((next, c))
			}
			Text(t) => Ok((next, conn.send!(Text("${user.name}: ${t}"))?))
			Binary(b) => Ok((next, conn.send!(Binary(b))?))
		}
	},
	on_close!: |user, closure| {
		Log.info!("room closed", { user: user.name, sent: user.sent, code: closure.code, by: Str.inspect(closure.by) })
		Ok(user)
	},
}

room_class : Object.Class(NoRpc)
room_class = Object.class(
	"Room",
	{
		fetch!: |self, req| match req.query("op") ?? "" {
			"auto" => {
				done = (WsObject.auto_response.set_auto_response!)(self, { request: "ping", response: "pong" })
				Ok(Response.from_text(200, Str.inspect(done.map_ok(|_| {}))))
			}
			"noauto" => {
				done = (WsObject.auto_response.clear_auto_response!)(self)
				Ok(Response.from_text(200, Str.inspect(done.map_ok(|_| {}))))
			}
			_ =>
				match WsObject.accept!(self, req, { protocols: ["v2"] }, { name: req.query("user") ?? "anon", sent: 0 }, room_handlers) {
					Ok(response) => Ok(response)
					Err(NotUpgrade(_)) => Ok(Response.from_status(426))
					Err(e) => Err(e)
				}
		},
		web_socket_message!: WsObject.message!(room_handlers),
		web_socket_close!: WsObject.closed!(room_handlers),
	},
)

rooms : Object.Namespace(NoRpc)
rooms = Object.namespace("ROOMS", { class: room_class })

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["chat", name] => chats.named(name).fetch!(req)
	["room", name] => rooms.named(name).fetch!(req)
	_ => Ok(Response.from_text(404, "no route"))
}

worker = Worker.new({ fetch!: fetch!, objects: [chat_class.erase(), room_class.erase()], bindings: [chats.declare(), rooms.declare()] })

event! = |e| worker.event!(e)
