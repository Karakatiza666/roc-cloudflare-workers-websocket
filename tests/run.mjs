// Runs one example app (a wasm built from examples/<name>.roc) in Miniflare, as the conformance runner of the platform
// does (cloudflare-workers/conformance/run.mjs): the modules are tests/worker-<name>.js, the JS shim of the platform
// (js/*.js) and app.wasm. Then the checks of tests/checks-<name>.mjs run against it.
// Usage: node tests/run.mjs <name> <wasm>. Env: PLATFORM, a directory with the shim in js/ (default: the bundle of the
// platform URL of src/main.roc in the roc package cache, where `roc check` put it; or a cloudflare-workers checkout),
// MINIFLARE (the package).
import { readFileSync, readdirSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const name = process.argv[2];
const wasm = process.argv[3];
const platform = process.env.PLATFORM ?? cachedPlatform();
if (!existsSync(join(platform, 'js'))) {
  console.log(`FAIL start: no js/ in ${platform} (run roc check first, or set PLATFORM)`);
  process.exit(1);
}
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const runDir = join(here, '../.cache/tmp', `run-${process.pid}`);
mkdirSync(runDir, { recursive: true });
process.env.TMPDIR = runDir;
process.on('exit', () => rmSync(runDir, { recursive: true, force: true }));
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);

const suite = await import(pathToFileURL(join(here, `checks-${name}.mjs`)));
const modules = [
  { type: 'ESModule', path: join(here, 'worker.js'), contents: readFileSync(join(here, `worker-${name}.js`), 'utf8') },
  ...readdirSync(join(platform, 'js')).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(here, 'js', f), contents: readFileSync(join(platform, 'js', f), 'utf8') })),
  { type: 'CompiledWasm', path: join(here, 'app.wasm'), contents: readFileSync(wasm) },
];
const logs = [];
const mf = new Miniflare(convertV4MiniflareOptions({
  modules,
  modulesRoot: here,
  compatibilityDate: '2026-10-01',
  compatibilityFlags: ['enable_request_signal'],
  port: 0,
  handleStructuredLogs: (l) => logs.push(l),
  ...(suite.options ?? {}),
}));
let failed = 0, passed = 0;
const ctx = { mfDir, logs, mf, wsPackage: () => createRequire(import.meta.url)(join(dirname(mfDir), 'ws')) };
try {
  ctx.url = String(await mf.ready);
  if (suite.setup) await suite.setup(ctx);
  for (const [check, fn] of suite.checks) {
    try {
      const detail = await fn(ctx);
      passed++;
      console.log(`PASS ${check}${detail ? `: ${detail}` : ''}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${check}: ${String(e?.stack ?? e).slice(0, 1500)}`);
    }
  }
} catch (e) {
  failed++;
  console.log(`FAIL start: ${String(e?.message ?? e).slice(0, 1500)}`);
} finally {
  if (suite.teardown) await suite.teardown(ctx);
  await mf.dispose();
}
if (failed) console.log(logs.map((l) => `${l.level}: ${l.message}`).join('\n').slice(-4000));
console.log(`${name}: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

// The directory of the platform bundle in roc's package cache: $XDG_CACHE_HOME/roc/packages/<hash>, or
// ~/.cache/roc/packages/<hash>, where <hash> is the file name of the URL in the header of src/main.roc.
function cachedPlatform() {
  const header = readFileSync(join(here, '../src/main.roc'), 'utf8');
  const hash = header.match(/platform "https:\/\/[^"]*\/([^/"]+)\.tar\.zst"/)?.[1];
  if (!hash) {
    console.log('FAIL start: src/main.roc names no platform URL; set PLATFORM');
    process.exit(1);
  }
  return join(process.env.XDG_CACHE_HOME ?? join(homedir(), '.cache'), 'roc', 'packages', hash);
}
