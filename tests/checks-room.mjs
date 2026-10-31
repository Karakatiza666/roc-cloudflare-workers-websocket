// examples/room.roc: Durable Objects with the hibernation API through WsObject. Local SQLite-backed objects.
import { client, eq, ok, sleep, waitLog, wsUrl } from './lib.mjs';

export const options = { durableObjects: { CHATS: { className: 'Chat', useSQLite: true }, ROOMS: { className: 'Room', useSQLite: true } } };

export const checks = [
  ['WsObject.class: a request with no Upgrade gets 426', async (t) => {
    eq((await fetch(t.url + 'chat/c0')).status, 426, 'the status');
  }],
  ['WsObject.class with the generic Chat handlers: state across events, bytes, the close of the peer', async (t) => {
    const a = await client(wsUrl(t.url, '/chat/c1'), ['chat']);
    eq(a.protocol, 'chat', 'the subprotocol');
    eq(await a.next(), 'welcome', 'on_open!');
    a.send('hi');
    eq(await a.next(), 'echo hi', 'text');
    a.send(new Uint8Array([1, 2, 3]));
    eq(await a.next(), [3, 2, 1], 'bytes');
    a.send('count');
    eq(await a.next(), 'count=3', 'the state, kept in the attachment between events');
    const c = await a.close(4001, 'peer bye');
    eq(c.code, 4001, 'the object answered the close with the code of the peer');
    const l = await waitLog(t, 'chat closed', (x) => x.code === 4001);
    eq([l.count, l.by, l.reason], [3, 'Peer', 'peer bye'], 'on_close! got the state and the closure');
  }],
  ['WsObject: two connections of one object keep their own state', async (t) => {
    const a = await client(wsUrl(t.url, '/chat/c2'));
    const b = await client(wsUrl(t.url, '/chat/c2'));
    eq([await a.next(), await b.next()], ['welcome', 'welcome'], 'on_open!');
    a.send('x');
    a.send('y');
    eq([await a.next(), await a.next()], ['echo x', 'echo y'], 'a');
    b.send('count');
    eq(await b.next(), 'count=1', 'b counts only its own');
    a.send('count');
    eq(await a.next(), 'count=3', 'a counts its own');
    await Promise.all([a.close(1000, ''), b.close(1000, '')]);
  }],
  ['WsObject: a close of the object ends with by Us', async (t) => {
    const a = await client(wsUrl(t.url, '/chat/c3'));
    eq(await a.next(), 'welcome', 'on_open!');
    a.send('close');
    const c = await a.closed;
    eq([c.code, c.reason], [4000, 'bye'], 'the client got the close');
    const l = await waitLog(t, 'chat closed', (x) => x.by === 'Us');
    eq([l.count, l.code], [1, 4000], 'on_close! with by Us');
  }],
  ['WsObject.accept! in an app class: the protocol and the state across events, Persist', async (t) => {
    const a = await client(wsUrl(t.url, '/room/r1?user=ann'), ['v1', 'v2']);
    eq(a.protocol, 'v2', 'the subprotocol');
    eq(await a.next(), 'hello ann protocol=v2', 'on_open!');
    a.send('saved');
    eq(await a.next(), 'saved=nothing', 'nothing saved yet');
    a.send('save some bytes');
    eq(await a.next(), 'saved', 'save!');
    a.send('saved');
    eq(await a.next(), 'saved=some bytes', 'saved! in a later event');
    a.send('whoami');
    eq(await a.next(), 'ann sent=4 protocol=v2', 'the state and the protocol from the attachment');
    a.send('big');
    eq(await a.next(), 'big=Err(TooLarge(20000))', 'over the attachment limit');
    a.send('saved');
    eq(await a.next(), 'saved=some bytes', 'a refused save! keeps the bytes');
    a.send('close');
    eq((await a.closed).code, 4002, 'the close of the object');
    const l = await waitLog(t, 'room closed', (x) => x.user === 'ann');
    eq([l.sent, l.code, l.by], [7, 4002, 'Us'], 'on_close!');
  }],
  ['WsObject.auto_response: the runtime answers ping with no event, and clear stops it', async (t) => {
    eq(await (await fetch(t.url + 'room/r2?op=auto')).text(), 'Ok({})', 'set');
    const a = await client(wsUrl(t.url, '/room/r2?user=bob'));
    eq(await a.next(), 'hello bob protocol=', 'on_open!');
    a.send('ping');
    eq(await a.next(), 'pong', 'the auto response');
    a.send('whoami');
    eq(await a.next(), 'bob sent=1 protocol=', 'the ping was no event');
    eq(await (await fetch(t.url + 'room/r2?op=noauto')).text(), 'Ok({})', 'clear');
    a.send('ping');
    eq(await a.next(), 'bob: ping', 'now the ping is a message');
    await a.close(1000, '');
  }],
  ['WsObject: send! after close! is NotOpen (Workers gives the closure to on_close!)', async (t) => {
    const a = await client(wsUrl(t.url, '/room/r3?user=cy'));
    eq(await a.next(), 'hello cy protocol=', 'on_open!');
    a.send('close_send');
    eq((await a.closed).code, 4003, 'the close');
    eq((await waitLog(t, 'room close_send')).after, 'Err(NotOpen)', 'send! after close!');
  }],
];
