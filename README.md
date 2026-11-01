# roc-cloudflare-workers-websocket

[roc-websocket](https://github.com/Karakatiza666/roc-websocket)'s shared WebSocket features over
the WebSockets of the `cloudflare-workers` Roc platform. Code written against roc-websocket's
feature aliases (`Ws.Core`, `Ws.Timed`, `Ws.Push`, `Ws.Handlers`, ...) runs on Workers through it.

The adapter implements only the shared features, in roc-websocket's terms. What only Workers has
(Durable Object classes, accepting with tags, the socket list, broadcasts, typed attachments,
`max_queued_bytes`, `send_json!`, `Io.race!` over a receive) stays the platform's own API: the
connections here are, or wrap, the platform's `WebSocket` and `Object.Socket`, so an app uses
both side by side.

| Item | Value |
| --- | --- |
| Modules | `Conn` (a Worker's client and server sockets, pull), `Push` (Durable Object sockets, push) |
| Depends on | roc-websocket 0.0.3; the cloudflare-workers platform 0.0.2 (both by their release URLs) |
| Compiler | Roc nightly-2026-10-31-f7bef6b, the nightly the platform 0.0.2 needs (`.roc-version`, which CI installs) |
| Tests | `scripts/all_tests.sh` |
| License | UPL-1.0 (`LICENSE`) |

## Use

The package names the platform, so the app names the same one: the cloudflare-workers platform
0.0.2 and roc-websocket 0.0.3. It needs Roc nightly-2026-10-31-f7bef6b.

```roc
app [event!] {
	pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.2/f352LLRKJCZ4JJVEocp3H9e4e6Sxa6Ym5CxZ1GZCpfd.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.3/FvsFHmH7m6LoMumXLxEHEfUoApGWdkgoFshfYEctaMNM.tar.zst",
	cfws: "https://github.com/Karakatiza666/roc-cloudflare-workers-websocket/releases/download/0.0.1/3663v9dUdg2mfv4XAdGHHq7k9McDJ29CNGMhfhKortVH.tar.zst",
}

import ws.Ws
import cfws.Conn

ask! : Str => Try(Ws.Message, Conn.Error)
ask! = |text| {
	opened = (Conn.connect.connect!)({ url: "wss://example.com/echo", protocols: ["v1"] })?
	conn = opened.conn.send!(Text(text))?
	(conn2, reply) = conn.receive!()?
	_ = Ws.close_and_wait!(Conn.ops, conn2, 1000, "")?
	Ok(reply)
}
```

Each call returns the updated connection: keep using the newest one.

## API

### `Conn`: the platform's `WebSocket` as a pull connection

| Name | Type |
| --- | --- |
| `Conn` | the connection; methods `send!`, `receive!`, `receive_within!`, `close!`, `socket` |
| `Conn.ops` | `Ws.Timed(Conn, Conn.Errors)` (the core and `receive_within!`) |
| `Conn.connect` | `Ws.Connect(Conn, Conn.Errors, {})` |
| `Conn.accept` | `Ws.Accept(Request, Response, Conn, Conn.Errors, {})` |
| `Conn.of`, `conn.socket()` | `WebSocket -> Conn`, `Conn -> WebSocket`: to and from the platform's socket |
| `Conn.Errors` | `[InvalidClose(Str), SocketErr(Io.Thrown), Refused(Str), NotUpgrade(Str), Unsupported(Str)]` |
| `Conn.Error` | `Ws.Error(Conn.Errors)`: `[Closed(Ws.Closure), Closing, ..Conn.Errors]` |

A Worker server returns `response` from `fetch!` and runs the connection in its `after` work,
which lives until the socket closes:

```roc
match (Conn.accept.accept!)(req, { protocols: ["chat"] }) {
	Ok({ response, opened }) => Ok(response.after(|| serve!(opened.conn)))
	Err(NotUpgrade(_)) => Ok(Response.from_status(426))
	Err(e) => Err(e)
}
```

### `Push`: the sockets of a Durable Object

The connection is the platform's `Object.Socket`. Accepting, tags and subprotocols are the
platform's `Object.Self.accept_with!`; `Push` runs a `Ws.Handlers` record from the app's own
`Object.class`, keeping the per-connection state `s` in an `Object.Attachment(s)` that the app
declares:

```roc
state_slot : Object.Attachment(U64)
state_slot = Object.attachment("state")

room = Object.class("Room", {
	fetch!: |self, req| match self.accept_with!(req, { protocols: ["chat"] }) {
		Ok({ socket, response }) => {
			Push.opened!(socket, state_slot, 0, handlers)?
			Ok(response)
		}
		Err(_) => Ok(Response.from_status(426))
	},
	web_socket_message!: Push.message!(state_slot, handlers),
	web_socket_close!: Push.closed!(state_slot, handlers),
})
```

| Name | Type |
| --- | --- |
| `Push.ops` | `Ws.Push(Object.Socket, Push.Errors)` (`send!`, `close!`) |
| `Push.persist(slot)` | `Object.Attachment(Cbor.Bytes) -> Ws.Persist(Object.Socket, Push.Errors, {})` |
| `Push.auto_response` | `Ws.AutoResponse(Object.Self, Push.Errors, {})`: Workers keeps one per object, so the scope is the object |
| `Push.opened!` | `Object.Socket, Object.Attachment(s), s, Ws.Handlers(s, Object.Socket, e) => Try({}, ...)`, after the platform's accept |
| `Push.message!(slot, h)` | the `web_socket_message!` handler |
| `Push.closed!(slot, h)` | the `web_socket_close!` handler; answers a close of the peer (its code, or 1000 for 1005) first |
| `Push.Errors` | `[InvalidClose(Str), SocketErr(Io.Thrown), TooLarge(U64), BadData(Str)]` |

The handler errors are `Handler(e)` (an error of the app's handlers) and `Attachment(e)` (the
platform's attachment errors, as they are). A socket has one attachment slot: the Handlers state
and `Push.persist` on one socket exclude each other.

## Mapping

| roc-websocket | Platform |
| --- | --- |
| `Message` `Text(s)` / `Binary(b)` | `WebSocket.Message` `Text(s)` / `Bytes(b)` |
| `Closure` | `WebSocket.Closed` (the same record) |
| `send!` | `ws.send!(msg)`; `Closed` → `Closed(record)` from `ws.closed!()`, or `Closing` while there is none |
| `receive!` | `ws.receive!()` |
| `close!` | `ws.close!(code, reason)`; `BadCode`, `TooLarge` → `InvalidClose(Str)`; on a closing or closed socket as `send!` |
| `receive_within!(c, ms)` | `ws.receive().timeout(ms).run!()`; `Infra(TimedOut)` → `Ok(TimedOut)` (the message stays queued) |
| `Connect.connect!` | `WebSocket.connect_with!(url, { protocols, headers })`; not 101 → `Refused(Str)`; `extensions: Reported(...)` from the 101 response |
| `Accept.accept!` | `WebSocket.accept_with!(req, { protocols })`; `response` is the 101; `extensions: NotReported` |
| `Push.send!` / `close!` | `Object.Socket.send!` / `close!`; a closed socket is `Closing` (Workers gives the closure to `web_socket_close!`) |
| `Handlers.on_open!` | `Push.opened!` after `Object.Self.accept!`/`accept_with!` |
| `Handlers.on_message!` / `on_close!` | `web_socket_message!` / `web_socket_close!` with `WebSocket.Closed` |
| `Persist` | an `Object.Attachment(Cbor.Bytes)` |
| `AutoResponse` (scope: the object) | `Object.Self.set_auto_response!` / `clear_auto_response!` |

## Features

| Feature | `Conn` | `Push` | Why not |
| --- | --- | --- | --- |
| `Core` | yes | `Sender` only (push) | |
| `ReceiveWithin` | yes | no | an object has no receive |
| `Connect`, `Accept` | yes | accept is the platform's | |
| `Handlers` | with `Ws.drive!` | yes | |
| `Persist` | no | yes | a Worker socket does not hibernate |
| `AutoResponse` | no | yes, on `Object.Self` | |
| `Ping`, `Pong`, `Frames` | no | no | the runtime owns the wire and answers pings itself |
| `Poll` | no | no | a socket wait has no platform deadline |
| `Buffered` | no | no | workerd has no `bufferedAmount` |
| `Topics` | no | no | Workers tags are fixed at accept; there is no subscribe |

## Limits

- `max_message` of `Request` and `AcceptOptions` is `Unsupported(Str)`: the platform has no limit
  on one message. It bounds the bytes queued for `receive!` (4 MiB; more closes the socket with
  1008 by `Us`); set it with the platform's `accept_with!`/`connect_with!` and wrap the socket
  with `Conn.of`.
- When this endpoint closes first, the closure has the code and reason of the peer's reply.
- The Durable Object checks run locally without hibernation; every event reads the state from
  the attachment, but eviction itself is not exercised.

## Tests

```sh
ROC=/path/to/roc scripts/all_tests.sh   # fmt, check, roc test, build the examples to wasm32, run them in Miniflare
ROC=/path/to/roc scripts/bundle.sh 0.0.1      # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh       # the examples against dist/*.tar.zst (or a release URL), in Miniflare
```

The Miniflare runs need Node (26) and a global wrangler (`npm install -g wrangler`), whose
Miniflare `tests/run.mjs` loads (`MINIFLARE` names another). `tests/run.mjs` loads an example's
wasm with the platform's JS shim in Miniflare, as the platform's conformance runner does, and
runs `tests/checks-<example>.mjs` with Node WebSocket clients and a Node `ws` server. The shim is
the `js/` of the platform bundle that `roc check` downloaded to the roc package cache
(`$XDG_CACHE_HOME/roc/packages/<hash>`, by default `~/.cache/roc/packages/<hash>`); `PLATFORM`
names another directory with a `js/`, such as a cloudflare-workers checkout.

| Example | Checks |
| --- | --- |
| `examples/client.roc` | `Conn.connect`: subprotocol, header, extensions, text, bytes, `receive_within!`, `Closing` before the peer answers, 30 clean closes right after a message exchange, the peer's closure from `receive!`, `send!` and `close!`, a stale value, `InvalidClose`, `Unsupported`, `Refused` |
| `examples/server.roc` | `Conn.accept`: 426 / `NotUpgrade`, subprotocol, `NotReported` extensions, the generic `Chat` handlers over `Ws.drive!` (state, bytes, closes by `Peer` and `Us`), `receive_within!` ticks |
| `examples/room.roc` | `Push` in the app's own classes: the same `Chat` handlers, state per connection across events, the platform's tags and subprotocol, `Closing` after `close!`, `AutoResponse`, `Persist` and its limit |

CI (`.github/workflows/tests.yaml`) runs `scripts/all_tests.sh` and `scripts/test_bundle.sh` on
Linux x86_64 and arm64 and macOS with the nightly of `.roc-version`, Node 26 and wrangler; a tag
`X.Y.Z` runs `release.yml`, which publishes the bundle and the docs and then tests the published
URL.

## Changes

### 0.0.1

The first release, over roc-websocket 0.0.3 and the cloudflare-workers platform 0.0.2:

- `Conn`: the platform's `WebSocket` as `Ws.Timed`, with `Conn.connect` (`Ws.Connect`) and
  `Conn.accept` (`Ws.Accept`). `Ws.messages` over `Conn.ops` ends with `Err(Closed(closure))`.
- `Push`: `Ws.Push`, `Ws.Persist` and `Ws.AutoResponse` over a Durable Object's sockets, and
  `opened!`, `message!` and `closed!` to run a `Ws.Handlers` record from the app's own class.
- `Conn.Error` is `Ws.Error(Conn.Errors)`; the handler errors of `Push` are
  `Handler(Ws.Error(e))` and `Attachment(...)`.
- Needs Roc nightly-2026-10-31-f7bef6b. `Push` matches the handlers' results in place of
  `.map_err(...)?`, which compiled but trapped at the app's first call with this nightly
  (roc-lang/roc#12762).
