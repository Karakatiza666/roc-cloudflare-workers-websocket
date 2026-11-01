// examples/client.roc: a Worker that connects out to a WebSocket server of Node (the `ws` package of Miniflare).
// The server: "info" gives the protocol it picked and the header x-test, "delay <ms> <text>" gives the text after <ms>,
// "close me" closes with 4005 "peer bye", other text comes back as "echo <text>", bytes come back. It refuses the
// path /no (403).
import { eq } from './lib.mjs';

let wss = null, server = '';
export async function setup(t) {
  const { WebSocketServer } = t.wsPackage();
  wss = new WebSocketServer({ port: 0, host: '127.0.0.1', verifyClient: (info) => info.req.url !== '/no' });
  wss.on('connection', (ws, req) => ws.on('message', (m, binary) => {
    if (binary) return ws.send(m);
    const text = m.toString();
    const d = /^delay (\d+) (.*)$/.exec(text);
    if (text === 'info') ws.send(`proto=${ws.protocol} x-test=${req.headers['x-test']}`);
    else if (text === 'close me') ws.close(4005, 'peer bye');
    else if (d) setTimeout(() => ws.send(d[2]), Number(d[1]));
    else ws.send(`echo ${text}`);
  }));
  await new Promise((r) => wss.once('listening', r));
  server = `ws://127.0.0.1:${wss.address().port}`;
}
export async function teardown() {
  wss?.close();
}
const get = async (t, path, extra = '') => (await fetch(`${t.url}${path}?url=${encodeURIComponent(server)}${extra}`)).text();

const closure = (code, reason, by = 'Us', clean = 'True') => `{ by: ${by}, clean: ${clean}, code: ${code}, reason: "${reason}" }`;

export const checks = [
  ['Connect: subprotocol, header, extensions; send!, receive!, receive_within!; Closing before the peer answers', async (t) => {
    eq(await get(t, 'talk'), [
      'protocol=chat extensions=Reported([])',
      'info=Text("proto=chat x-test=yes")',
      'bytes=Binary([0, 1, 255])',
      'first=TimedOut',
      'second=Message(Text("late"))',
      'sent=Err(Closing)',
      'again=Err(Closing)',
      `final=Err(Closed(${closure(1000, 'done')}))`,
    ].join(' '), 'the answer');
  }],
  ['a message each way, then close_and_wait! at once, 30 times: every close is clean', async (t) => {
    eq(await get(t, 'exchange', '&n=30'), 'clean=30 other=[]', 'the closures');
  }],
  ['the peer closes: the same closure from receive!, send! and close!', async (t) => {
    const c = `Err(Closed(${closure(4005, 'peer bye', 'Peer')}))`;
    eq(await get(t, 'peer_close'), `got=${c} sent=${c} close=${c}`, 'the answer');
  }],
  ['a stale connection value: close! and send! give the closure the runtime has', async (t) => {
    const c = closure(4001, 'generic');
    eq(await get(t, 'stale'), `closure=${c} close=Err(Closed(${c})) send=Err(Closed(${c}))`, 'the answer');
  }],
  ['errors: max_message, a refused upgrade, close codes and reasons that may not be sent', async (t) => {
    eq(await get(t, 'errors'), [
      'limit=Err(Unsupported("max_message: the platform has no limit on one message (it bounds the bytes queued for receive!)"))',
      'refused=Err(Refused("the server did not answer the upgrade with 101"))',
      'bad=Err(InvalidClose("the close code 1005 may not be sent"))',
      'long=Err(InvalidClose("a close reason of 124 bytes; at most 123"))',
      'still=Ok(Text("echo still"))',
    ].join(' '), 'the answer');
  }],
];
