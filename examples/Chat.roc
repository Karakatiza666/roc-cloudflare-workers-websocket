import ws.Ws

## Handlers that work over the sending operations of any roc-websocket
## adapter: the Worker server runs them with `Ws.drive!` over `Conn.ops`,
## the Durable Object through `Push.message!` over `Push.ops`. The state is
## the number of messages of the connection.
Chat :: [].{

	handlers : Ws.Sender(c, e, r) -> Ws.Handlers(U64, c, e)
	handlers = |ops| {
		on_open!: |n, conn| Ok((n, (ops.send!)(conn, Text("welcome"))?)),
		on_message!: |n, conn, msg| {
			count = n + 1
			next = match msg {
				Text("close") => (ops.close!)(conn, 4000, "bye")?
				Text("count") => (ops.send!)(conn, Text("count=${count.to_str()}"))?
				Text(t) => (ops.send!)(conn, Text("echo ${t}"))?
				Binary(b) => (ops.send!)(conn, Binary(b.rev()))?
			}
			Ok((count, next))
		},
		on_close!: |n, _closure| Ok(n),
	}
}
