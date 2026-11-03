// examples/room.roc: Durable Objects with the platform's hibernation API, running roc-websocket handlers through Push.
// Local SQLite-backed objects.
import { burst, client, eq, waitLog, wsUrl } from './lib.mjs';

export const options = {
  durableObjects: {
    CHATS: { className: 'Chat', useSQLite: true },
    ROOMS: { className: 'Room', useSQLite: true },
    NOTES: { className: 'Notes', useSQLite: true },
  },
};

export const checks = [
  ['a request with no Upgrade gets 426', async (t) => {
    eq((await fetch(t.url + 'chat/c0')).status, 426, 'the status');
  }],
  ['the generic Chat handlers: state across events, bytes, the close of the peer', async (t) => {
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
  ['two connections of one object keep their own state', async (t) => {
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
  ['a close of the object ends with by Us', async (t) => {
    const a = await client(wsUrl(t.url, '/chat/c3'));
    eq(await a.next(), 'welcome', 'on_open!');
    a.send('close');
    const c = await a.closed;
    eq([c.code, c.reason], [4000, 'bye'], 'the client got the close');
    const l = await waitLog(t, 'chat closed', (x) => x.by === 'Us');
    eq([l.count, l.code], [1, 4000], 'on_close! with by Us');
  }],
  ['the platform accept_with! (protocols, tags) with a record state', async (t) => {
    const a = await client(wsUrl(t.url, '/room/r1?user=ann'), ['v1', 'v2']);
    eq(a.protocol, 'v2', 'the subprotocol');
    eq(await a.next(), 'hello ann protocol=v2', 'on_open!');
    a.send('hi');
    eq(await a.next(), 'ann: hi', 'a message');
    a.send('whoami');
    eq(await a.next(), 'ann sent=2 protocol=v2 tags=room,ann', 'the state from the attachment, the platform tags');
    a.send('close');
    eq((await a.closed).code, 4002, 'the close of the object');
    const l = await waitLog(t, 'room closed', (x) => x.user === 'ann');
    eq([l.sent, l.code, l.by], [3, 4002, 'Us'], 'on_close!');
  }],
  ['send! after close! is Closing (Workers gives the closure to on_close!)', async (t) => {
    const a = await client(wsUrl(t.url, '/room/r3?user=cy'));
    eq(await a.next(), 'hello cy protocol=', 'on_open!');
    a.send('close_send');
    eq((await a.closed).code, 4003, 'the close');
    eq((await waitLog(t, 'room close_send')).after, 'Err(Closing)', 'send! after close!');
  }],
  ['AutoResponse over Object.Self: the runtime answers ping with no event, and clear stops it', async (t) => {
    eq(await (await fetch(t.url + 'room/r2?op=auto')).text(), 'Ok({})', 'set');
    const a = await client(wsUrl(t.url, '/room/r2?user=bob'));
    eq(await a.next(), 'hello bob protocol=', 'on_open!');
    a.send('ping');
    eq(await a.next(), 'pong', 'the auto response');
    a.send('whoami');
    eq(await a.next(), 'bob sent=1 protocol= tags=room,bob', 'the ping was no event');
    eq(await (await fetch(t.url + 'room/r2?op=noauto')).text(), 'Ok({})', 'clear');
    a.send('ping');
    eq(await a.next(), 'bob: ping', 'now the ping is a message');
    await a.close(1000, '');
  }],
  ['Persist over an attachment of bytes', async (t) => {
    const a = await client(wsUrl(t.url, '/notes/n1'));
    a.send('saved');
    eq(await a.next(), 'saved=nothing', 'nothing saved yet');
    a.send('save some bytes');
    eq(await a.next(), 'saved', 'save!');
    a.send('saved');
    eq(await a.next(), 'saved=some bytes', 'saved! in a later event');
    a.send('big');
    eq(await a.next(), 'Err(TooLarge(20000))', 'over the attachment limit');
    a.send('saved');
    eq(await a.next(), 'saved=some bytes', 'a refused save! keeps the bytes');
    await a.close(1000, '');
  }],
  ['messages and the Close in one burst: every reply is sent, then the close completes and on_close! runs', async (t) => {
    const r = await burst(t, '/chat/burst', 100);
    eq(r.got.length, 101, 'welcome and 100 replies');
    eq(r.got[100], 'echo m99', 'the last reply');
    eq(r.closed, { code: 4001, reason: 'burst' }, 'the answer to the Close');
    await waitLog(t, 'chat closed', (l) => l.count === 100 && l.code === 4001);
  }],
];
