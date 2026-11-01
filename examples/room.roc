app [event!] {
	cfws: "../src/main.roc",
	pf: platform "../../cloudflare-workers-ws/platform/main.roc",
	ws: "../../roc-websocket/src/main.roc",
}

## Durable Objects that serve WebSockets with the platform's hibernation API,
## running roc-websocket handlers through `Push`. The Worker gives each upgrade
## request to an object.
##
## | Route | Object |
## | --- | --- |
## | `/chat/<name>` | class `Chat`: the generic `Chat` handlers (the same ones the Worker server runs) |
## | `/room/<name>?user=<u>` | class `Room`: handlers with a record state, the platform's tags, and the auto response (`?op=auto`, `?op=noauto`) |
## | `/notes/<name>` | class `Notes`: `Ws.Persist` with no handlers: `save <text>` and `saved` |
import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.WebSocket
import pf.Cbor
import pf.Log
import ws.Ws
import cfws.Push
import Chat

NoRpc := []

## The generic handlers, with a log line at the close.
chat_handlers : Ws.Handlers(U64, Object.Socket, Push.Errors)
chat_handlers = {
	on_open!: base.on_open!,
	on_message!: base.on_message!,
	on_close!: |n, closure| {
		Log.info!("chat closed", { count: n, code: closure.code, reason: closure.reason, clean: closure.clean, by: Str.inspect(closure.by) })
		(base.on_close!)(n, closure)
	},
}

base : Ws.Handlers(U64, Object.Socket, Push.Errors)
base = Chat.handlers(Push.ops)

count_slot : Object.Attachment(U64)
count_slot = Object.attachment("count")

chat_class : Object.Class(NoRpc)
chat_class = Object.class(
	"Chat",
	{
		fetch!: |self, req| accept!(self, req, ["chat"], count_slot, 0, chat_handlers),
		web_socket_message!: Push.message!(count_slot, chat_handlers),
		web_socket_close!: Push.closed!(count_slot, chat_handlers),
	},
)

## Accept with the platform, then `Push.opened!`.
accept! : Object.Self, Request, List(Str), Object.Attachment(s), s, Ws.Handlers(s, Object.Socket, Push.Errors) => Try(Response, _)
accept! = |self, req, protocols, slot, state, handlers| match self.accept_with!(req, { protocols: protocols }) {
	Ok({ socket, response }) => {
		Push.opened!(socket, slot, state, handlers)?
		Ok(response)
	}
	Err(NotUpgrade) => Ok(Response.from_status(426))
	Err(TooLarge) => Ok(Response.from_status(400))
}

## The state of a socket of `Room`: the user name, its subprotocol (the
## hibernation API does not keep it), and the messages it sent.
User : { name : Str, protocol : Str, sent : U64 }

user_slot : Object.Attachment(User)
user_slot = Object.attachment("user")

room_handlers : Ws.Handlers(User, Object.Socket, Push.Errors)
room_handlers = {
	on_open!: |user, socket| Ok((user, (Push.ops.send!)(socket, Text("hello ${user.name} protocol=${user.protocol}"))?)),
	on_message!: |user, socket, msg| {
		next = { ..user, sent: user.sent + 1 }
		send! = Push.ops.send!
		match msg {
			Text("whoami") => Ok((next, send!(socket, Text("${user.name} sent=${next.sent.to_str()} protocol=${user.protocol} tags=${Str.join_with(socket.tags!(), ",")}"))?))
			Text("close") => Ok((next, (Push.ops.close!)(socket, 4002, "room bye")?))
			Text("close_send") => {
				s = (Push.ops.close!)(socket, 4003, "closing")?
				after = send!(s, Text("late"))
				Log.info!("room close_send", { after: Str.inspect(after.map_ok(|_| {})) })
				Ok((next, s))
			}
			Text(t) => Ok((next, send!(socket, Text("${user.name}: ${t}"))?))
			Binary(b) => Ok((next, send!(socket, Binary(b))?))
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
				done = (Push.auto_response.set_auto_response!)(self, { request: "ping", response: "pong" })
				Ok(Response.from_text(200, Str.inspect(done.map_ok(|_| {}))))
			}
			"noauto" => {
				done = (Push.auto_response.clear_auto_response!)(self)
				Ok(Response.from_text(200, Str.inspect(done.map_ok(|_| {}))))
			}
			_ => {
				name = req.query("user") ?? "anon"
				match self.accept_with!(req, { protocols: ["v2"], tags: ["room", name] }) {
					Ok({ socket, response }) => {
						protocol = WebSocket.pick_protocol(req, ["v2"]) ?? ""
						Push.opened!(socket, user_slot, { name, protocol, sent: 0 }, room_handlers)?
						Ok(response)
					}
					Err(NotUpgrade) => Ok(Response.from_status(426))
					Err(TooLarge) => Ok(Response.from_status(400))
				}
			}
		},
		web_socket_message!: Push.message!(user_slot, room_handlers),
		web_socket_close!: Push.closed!(user_slot, room_handlers),
	},
)

notes_slot : Object.Attachment(Cbor.Bytes)
notes_slot = Object.attachment("notes")

notes : Ws.Persist(Object.Socket, Push.Errors, {})
notes = Push.persist(notes_slot)

## `Ws.Persist` alone: the platform's own handlers, with no `Ws.Handlers`.
notes_class : Object.Class(NoRpc)
notes_class = Object.class(
	"Notes",
	{
		fetch!: |self, req| match self.accept!(req) {
			Ok({ response, .. }) => Ok(response)
			Err(NotUpgrade) => Ok(Response.from_status(426))
		},
		web_socket_message!: |_self, socket, msg| {
			reply = match msg {
				Text(t) if t.starts_with("save ") =>
					match (notes.save!)(socket, t.drop_prefix("save ").to_utf8()) {
						Ok(_) => "saved"
						Err(e) => "save ${Str.inspect(e)}"
					}
				Text("big") => Str.inspect((notes.save!)(socket, List.repeat(7, 20_000)).map_ok(|_| {}))
				Text("saved") =>
					match (notes.saved!)(socket) {
						Ok(Saved(bytes)) => "saved=${Str.from_utf8(bytes) ?? "not UTF-8"}"
						Ok(Nothing) => "saved=nothing"
						Err(e) => "saved ${Str.inspect(e)}"
					}
				_ => "?"
			}
			_ = socket.send!(Text(reply))
			Ok({})
		},
		web_socket_close!: |_self, socket, closure| {
			_ = socket.close!(closure.code, closure.reason)
			Ok({})
		},
	},
)

chats : Object.Namespace(NoRpc)
chats = Object.namespace("CHATS", { class: chat_class })

rooms : Object.Namespace(NoRpc)
rooms = Object.namespace("ROOMS", { class: room_class })

notes_ns : Object.Namespace(NoRpc)
notes_ns = Object.namespace("NOTES", { class: notes_class })

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["chat", name] => chats.named(name).fetch!(req)
	["room", name] => rooms.named(name).fetch!(req)
	["notes", name] => notes_ns.named(name).fetch!(req)
	_ => Ok(Response.from_text(404, "no route"))
}

worker = Worker.new({ fetch!: fetch!, objects: [chat_class.erase(), room_class.erase(), notes_class.erase()], bindings: [chats.declare(), rooms.declare(), notes_ns.declare()] })

event! = |e| worker.event!(e)
