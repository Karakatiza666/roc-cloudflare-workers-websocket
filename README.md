# roc-cloudflare-workers-websocket

The WebSockets of the Cloudflare Workers Roc platform as
[roc-websocket](https://github.com/Karakatiza666/roc-websocket) 0.0.1 connections. Code
written against roc-websocket's feature aliases (`Ws.Core`, `Ws.Sender`, `Ws.Handlers`, ...)
runs on Workers through this adapter. The platform keeps its Workers API; the mapping is here.

| Item | Value |
| --- | --- |
| Modules | `WsWorker` (a Worker's client and server sockets, pull), `WsObject` (Durable Object sockets, push) |
| Depends on | roc-websocket 0.0.1, the cloudflare-workers platform with the WebSocket gaps fixed (branch `websocket-gaps`, commit 7ed5b6c; not released yet) |
| Compiler | nightly-2026-10-26-3c0fffe (talon's pin) and nightly-2026-10-31-f7bef6b (roc-websocket's) both pass |
| Tests | `scripts/all_tests.sh` |
| License | UPL-1.0 (`LICENSE`) |

## Use

The package names the platform, so the app must name the same platform. Until the platform is
released with the WebSocket fixes, both name it by path; `src/main.roc` expects the
`cloudflare-workers` checkout at `../talon-ws/cloudflare-workers` next to this repository.

```roc
app [event!] {
	pf: platform "../../talon-ws/cloudflare-workers/platform/main.roc",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.1/4i6sgv5VVbr9xet5sWkRWMYa4H3dMUJSzWrMhRXsFTgn.tar.zst",
	cfws: "../src/main.roc",
}

import ws.Ws
import cfws.WsWorker

ask! : Str => Try(Ws.Message, WsWorker.Error)
ask! = |text| {
	opened = WsWorker.connect!({ url: "wss://example.com/echo", protocols: ["v1"] })?
	conn = opened.conn.send!(Text(text))?
	(conn2, reply) = conn.receive!()?
	_ = Ws.close_and_wait!(WsWorker.ops, conn2, 1000, "")?
	Ok(reply)
}
```

Each call returns the updated connection: keep using the newest one.

## API

### `WsWorker`: a Worker's own sockets

```roc
Conn                                  # methods: send!, receive!, receive_within!, close!, protocol
Ops : Ws.Timed(WsWorker.Conn, WsWorker.Errors)
ops : WsWorker.Ops
Errors : [InvalidClose(Str), NotOpen, SocketErr(Io.Thrown), Refused(Str), NotUpgrade(Str), Unsupported(Str)]
Error : [Closed(Ws.Closure), ..Errors]   # written out in the source
connect! : Ws.Request => Try({ conn : WsWorker.Conn, protocol : Str }, WsWorker.Error)
accept! : Request, Ws.AcceptOptions => Try({ conn : WsWorker.Conn, protocol : Str, response : Response }, [NotUpgrade(Str), Unsupported(Str)])
from_socket : WebSocket -> WsWorker.Conn
```

A server returns `response` from `fetch!` and runs the connection in its `after` work, which
lives until the socket closes:

```roc
match WsWorker.accept!(req, { protocols: ["chat"] }) {
	Ok({ conn, response, .. }) => Ok(response.after(|| serve!(conn)))   # serve! : WsWorker.Conn => Try({}, _)
	Err(NotUpgrade(_)) => Ok(Response.from_status(426))
	Err(e) => Err(e)
}
```

### `WsObject`: the sockets of a Durable Object

```roc
Conn                                  # methods: send!, close!, saved!, save!, protocol, socket
Ops : Ws.Sender(WsObject.Conn, WsObject.Errors, Ws.Persist(WsObject.Conn, WsObject.Errors, {}))
ops : WsObject.Ops
auto_response : Ws.AutoResponse(Object.Self, WsObject.Errors, {})
Errors : [InvalidClose(Str), NotOpen, SocketErr(Io.Thrown), TooLarge(U64), BadData(Str)]
class : Str, { protocols ?: List(Str), state : s }, Ws.Handlers(s, WsObject.Conn, e) -> Object.Class(iface)
accept! : Object.Self, Request, Ws.AcceptOptions, s, Ws.Handlers(s, WsObject.Conn, e) => Try(Response, [NotUpgrade(Str), Unsupported(Str), State(Str), Handler([Closed(Ws.Closure), ..e])])
message! : Ws.Handlers(s, WsObject.Conn, e) -> (Object.Self, Object.Socket, WebSocket.Message => Try({}, [State(Str), Handler(...)]))
closed! : Ws.Handlers(s, WsObject.Conn, e) -> (Object.Self, Object.Socket, WebSocket.Closed => Try({}, [State(Str), Handler(...)]))
```

(`s` needs `Cbor.Writable` and `Cbor.Readable`.) A package can wrap the entry points of a
Durable Object: `Object.class` is a plain function of a record of handlers. `WsObject.class`
makes the whole class from a `Ws.Handlers` record. An app with more handlers (`init!`,
`alarm!`, RPC, other routes) writes its own `Object.class` and puts `WsObject.accept!` in its
`fetch!`, `WsObject.message!(h)` as `web_socket_message!` and `WsObject.closed!(h)` as
`web_socket_close!` (`examples/room.roc` does both). The JS entry still needs
`export const Name = objectClass('Name')`, as for any class.

The handlers' state `s` is per connection, as in `Ws.drive!`. The adapter keeps it, the
subprotocol and the `Persist` bytes in the socket's attachment (CBOR), so they survive the
object leaving memory. The adapter owns that attachment slot.

## Mapping

| roc-websocket | Platform |
| --- | --- |
| `Message` `Text(s)` / `Binary(b)` | `WebSocket.Message` `Text(s)` / `Bytes(b)` |
| `Closure` | `WebSocket.Closed` (the same record: `code`, `reason`, `clean`, `by : [Peer, Us, Transport]`) |
| `Core.send!` | `ws.send!(msg)`; `Closed` → see below; `Infra(SocketErr(t))` → `SocketErr(t)` |
| `Core.receive!` | `ws.receive!()`; `Closed(c)` → `Closed(c)` |
| `Core.close!` | `ws.close!(code, reason)`; `BadCode`, `TooLarge` → `InvalidClose(Str)` |
| `ReceiveWithin.receive_within!(c, ms)` | `ws.receive().timeout(ms).run!()`; `Infra(TimedOut)` → `Ok(TimedOut)` (the message stays queued) |
| `Request` `url`, `protocols`, `headers` | `WebSocket.connect_with!(url, { protocols, headers })`; not 101 → `Refused(Str)` |
| `AcceptOptions.protocols` | `WebSocket.accept_with!(req, { protocols })` / `Object.Self.accept_with!(req, { protocols })` |
| the chosen subprotocol | `ws.protocol()`; for an object, `WebSocket.pick_protocol` at accept, kept in the attachment |
| `Sender.send!` / `close!` (object) | `Object.Socket.send!` / `close!` |
| `Handlers.on_open!` | after `Object.Self.accept_with!`, in the object's `fetch!` |
| `Handlers.on_message!` | `web_socket_message!` |
| `Handlers.on_close!` | `web_socket_close!` and its `WebSocket.Closed`; a close by the peer is answered first with its code (1000 for 1005) |
| `Persist.saved!` / `save!` | an `Object.Attachment` of the adapter: `Cbor.Bytes`, 16,384 bytes for the whole attachment |
| `AutoResponse` (scope: the object) | `Object.Self.set_auto_response!` / `clear_auto_response!` |
| `Handlers` state `s` | CBOR in the same attachment, read before and written after each event |

## Features

| Feature | Worker socket | Object socket | Why not |
| --- | --- | --- | --- |
| `Core` | yes | no `receive!` (push) | |
| `Sender` | yes (in `Core`) | yes | |
| `ReceiveWithin` | yes | no | an object has no receive |
| `Handlers` | with `Ws.drive!` | yes | |
| `Persist` | no | yes | a Worker socket does not hibernate |
| `AutoResponse` | no | yes, on `Object.Self` | per object in Workers, not per connection |
| `Ping`, `Pong`, `Frames` | no | no | the runtime owns the wire and answers pings itself |
| `Poll` | no | no | a socket wait has no platform deadline |
| `Buffered` | no | no | workerd has no `bufferedAmount` |
| `Topics` | no | no | Workers tags are fixed at accept; there is no subscribe/unsubscribe |
| `Dial`, `Accept` | no (see below) | no | |

`connect!` and `accept!` exist, but not as the `Dial` and `Accept` fields:

- `Ws.Opened` has `extensions`, and Workers does not report them. A server socket's
  `extensions` is `""` even when workerd negotiated `permessage-deflate` (probe: a Node
  client offering it gets it), and a client socket's 101 headers are not exposed. Giving `[]`
  would be made up, so `connect!` returns `{ conn, protocol }`.
- `Accept.accept!` returns only the connection, but on Workers the 101 response must be the
  return value of `fetch!` and the connection lives in its `after` work, so `accept!` also
  returns `response`.

## Where the shared types and the platform differ

- **`send!` on a closed socket.** The platform gives a bare `Closed`. After this endpoint's
  `close!`, the connection value remembers the code and reason, and `send!`/`close!` give
  `Closed({ code, reason, clean: False, by: Us })`, as roc-websocket's own client does. After a
  close by the peer or the transport there is no record (it is behind the queued messages,
  which `receive!` must still deliver), so `send!` gives `NotOpen`. An object socket always
  gives `NotOpen`: Workers delivers the closure as the `web_socket_close!` event.
- **A stale connection value.** `close!` on a value from before a finished close (for example
  the one passed to `Ws.close_and_wait!`) is `Ok`: the platform's `close!` of a closed socket
  succeeds, and the value cannot know.
- **`max_message`** of `Request` and `AcceptOptions` is `Unsupported(Str)`: the platform has no
  limit on one message. It bounds the bytes queued for `receive!` instead (4 MiB; more closes
  the socket with 1008 by `Us`), which `WebSocket.accept_with!` / `connect_with!` set
  (`from_socket` wraps such a socket).
- **When the object closes first**, the closure has the code and reason of the peer's reply
  (Node's WebSocket replies with the code and no reason).

## Limits

- The attachment of an object socket holds the subprotocol, the CBOR of `s` and the saved
  bytes: 16,384 bytes in all. Over it, `save!` is `TooLarge(n)`, a state write is `State(Str)`.
- An app that uses `WsObject` must not set its own `Object.Attachment` on those sockets.
- The DO examples run locally without hibernation; the state path is the same (every event
  reads the attachment), but eviction itself is not exercised.

## Tests

```sh
scripts/all_tests.sh          # fmt, check, roc test, build the examples to wasm32, run them in Miniflare
ROC=/path/to/roc scripts/all_tests.sh
```

`tests/run.mjs` loads an example's wasm with the platform's JS shim in Miniflare, as the
platform's conformance runner does, and runs `tests/checks-<example>.mjs` with Node WebSocket
clients and a Node `ws` server:

| Example | Checks |
| --- | --- |
| `examples/client.roc` | subprotocol and header, text, bytes, `receive_within!` (`TimedOut`, then the message), `send!`/`close!` after `close!`, a close by the peer (`Closed` by `Peer`, then `NotOpen`), `InvalidClose`, `Unsupported`, `Refused`, `Ws.close_and_wait!` |
| `examples/server.roc` | 426 / `NotUpgrade`, subprotocol choice, generic `Chat` handlers over `Ws.drive!` (state, bytes, closes by `Peer` and `Us`), `receive_within!` ticks |
| `examples/room.roc` | `WsObject.class` with the same generic `Chat` handlers, state per connection across events, the parts in an app class, protocol from the attachment, `Persist` and its limit, `AutoResponse` set and clear, `NotOpen` after `close!` |

Known platform issue: a clean close after a message exchange is sometimes reported as
`Closed({ code: 1006, by: Transport, reason: "Uncaught Error: Network connection lost." })`
(reproduced with the platform alone; plain JS in the same Miniflare does not show it).
