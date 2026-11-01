// examples/server.roc: a Worker that accepts WebSockets (Conn.accept) and runs the generic Chat handlers with Ws.drive!.
import { client, eq, ok, sleep, waitLog, wsUrl } from './lib.mjs';

export const checks = [
  ['a request with no Upgrade is NotUpgrade', async (t) => {
    const r = await fetch(t.url + 'plain');
    eq(await r.text(), 'Err(NotUpgrade("the request has no Upgrade: websocket"))', 'Conn.accept');
    eq((await fetch(t.url + 'chat')).status, 426, '/chat');
  }],
  ['the subprotocol is the first of the server that the client offers', async (t) => {
    const a = await client(wsUrl(t.url, '/chat'), ['v2', 'chat']);
    eq(a.protocol, 'chat', 'the client sees');
    eq(await a.next(), 'welcome', 'on_open!');
    await a.close(1000, 'x');
    const open = await waitLog(t, 'chat open', (l) => l.protocol === 'chat');
    eq([open.protocol, open.extensions], ['chat', 'NotReported'], 'the Worker sees; workerd does not report the extensions of a server socket');
    const b = await client(wsUrl(t.url, '/chat'));
    eq(b.protocol, '', 'no offer: no protocol');
    await b.close(1000, 'x');
  }],
  ['Chat over drive!: text, bytes, state across messages, the close of the peer', async (t) => {
    const a = await client(wsUrl(t.url, '/chat'));
    eq(await a.next(), 'welcome', 'on_open!');
    a.send('hi');
    eq(await a.next(), 'echo hi', 'text');
    a.send(new Uint8Array([1, 2, 3]));
    eq(await a.next(), [3, 2, 1], 'bytes');
    a.send('count');
    eq(await a.next(), 'count=3', 'the state counts the messages');
    const c = await a.close(4001, 'peer bye');
    eq(c.code, 4001, 'the answer of the Worker has the code of the peer');
    eq((await waitLog(t, 'chat closed', (l) => l.count === 3)).count, 3, 'on_close! got the state');
    const l = await waitLog(t, 'chat closure', (x) => x.code === 4001);
    eq([l.by, l.reason, l.clean], ['Peer', 'peer bye', true], 'the closure of the peer');
  }],
  ['Chat over drive!: a close of the Worker ends with by Us', async (t) => {
    const a = await client(wsUrl(t.url, '/chat'));
    eq(await a.next(), 'welcome', 'on_open!');
    a.send('close');
    const c = await a.closed;
    eq([c.code, c.reason], [4000, 'bye'], 'the client got the close of the Worker');
    await waitLog(t, 'chat closed', (l) => l.count === 1);
    const l = await waitLog(t, 'chat closure', (x) => x.code === 4000);
    // The code and the reason are the ones of the reply of the peer (Node's WebSocket answers with the code and no reason).
    eq([l.by, l.reason], ['Us', ''], 'the closure of our close');
  }],
  ['receive_within!: TimedOut loses nothing', async (t) => {
    const a = await client(wsUrl(t.url, '/timed'));
    eq(await a.next(), 'tick 0', 'a tick after 200 ms');
    a.send('m1');
    a.send('m2');
    const got = [await a.next(), await a.next(), await a.next()].filter((m) => !m.startsWith('tick'));
    ok(got.length >= 1, `the messages come back: ${JSON.stringify(got)}`);
    const rest = got.length === 2 ? [] : [await a.next()];
    eq([...got, ...rest].filter((m) => !m.startsWith('tick')).slice(0, 2), ['m1', 'm2'], 'both, in order');
    await a.close(1000, 'x');
    await waitLog(t, 'timed closed', (l) => l.code === 1000 && l.by === 'Peer');
  }],
];
