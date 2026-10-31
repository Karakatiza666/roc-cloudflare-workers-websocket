// Helpers of the checks: a WebSocket client of Node (the same shape as `client` of
// cloudflare-workers/conformance/checks/websocket.mjs), asserts, and the log lines of the app.
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}
export function ok(cond, what) {
  if (!cond) throw new Error(what);
}
// `next()` gives the next message (text, or the bytes as an array), or throws after `ms`. `closed`: the close event.
export function client(url, protocols) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, protocols);
    ws.binaryType = 'arraybuffer';
    const got = [];
    const waiters = [];
    const closed = new Promise((r) => ws.addEventListener('close', (e) => r({ code: e.code, reason: e.reason, clean: e.wasClean })));
    ws.addEventListener('message', (e) => {
      const v = typeof e.data === 'string' ? e.data : [...new Uint8Array(e.data)];
      const w = waiters.shift();
      if (w) w(v);
      else got.push(v);
    });
    ws.addEventListener('open', () => resolve({
      ws,
      closed,
      protocol: ws.protocol,
      send: (v) => ws.send(v),
      next: (ms = 3000) => (got.length ? Promise.resolve(got.shift()) : new Promise((r, j) => {
        const timer = setTimeout(() => {
          waiters.splice(waiters.indexOf(f), 1);
          j(new Error(`no message in ${ms} ms`));
        }, ms);
        const f = (v) => (clearTimeout(timer), r(v));
        waiters.push(f);
      })),
      pending: () => got.slice(),
      close: (code, reason) => (ws.close(code, reason), closed),
    }));
    ws.addEventListener('error', () => reject(new Error(`the WebSocket to ${url} failed`)));
  });
}
export const wsUrl = (base, path) => base.replace(/^http/, 'ws').replace(/\/$/, '') + path;
// The structured log lines of the app with the message `msg` (Log.info! writes `{"msg":...,...fields}`).
export const logOf = (t, msg) => t.logs.filter((l) => String(l.message).includes(`"msg":"${msg}"`)).map((l) => JSON.parse(String(l.message).slice(String(l.message).indexOf('{'))));
export async function waitLog(t, msg, pred = () => true) {
  for (let i = 0; i < 60; i++) {
    const l = logOf(t, msg).find(pred);
    if (l) return l;
    await sleep(50);
  }
  throw new Error(`no log line ${msg}: ${JSON.stringify(t.logs.slice(-10))}`);
}
