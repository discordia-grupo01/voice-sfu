// Uso:
//   $env:LIVEKIT_URL="wss://TU-PROYECTO.livekit.cloud"; $env:LIVEKIT_TOKEN="eyJ..."
//   node webrtc-check.mjs [--expect=udp|tcp|tls|turn-udp|not-udp|any] [--relay-only]
// Env opcionales: BROWSER=chrome|msedge (default chrome), HOLD=segundos observando (default 10)
// Instalar: npm i playwright-core livekit-client
import { chromium } from 'playwright-core';
import { join, dirname } from 'node:path';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Busca livekit-client subiendo desde la carpeta del script (soporta node_modules en carpetas padre)
function findLivekitUmd() {
  let dir = dirname(fileURLToPath(import.meta.url));
  while (true) {
    const f = join(dir, 'node_modules/livekit-client/dist/livekit-client.umd.js');
    if (existsSync(f)) return f;
    const parent = dirname(dir);
    if (parent === dir) throw new Error('No encontré livekit-client. Ejecutá: npm i livekit-client');
    dir = parent;
  }
}

const { LIVEKIT_URL, LIVEKIT_TOKEN } = process.env;
if (!LIVEKIT_URL || !LIVEKIT_TOKEN) {
  console.error('Faltan LIVEKIT_URL y/o LIVEKIT_TOKEN');
  process.exit(2);
}
const expect = (process.argv.find(a => a.startsWith('--expect=')) ?? '--expect=any').split('=')[1];
const relayOnly = process.argv.includes('--relay-only');
const holdSec = Number(process.env.HOLD ?? 10);

const browser = await chromium.launch({ channel: process.env.BROWSER ?? 'chrome', headless: true });
const page = await (await browser.newContext()).newPage();

// Registrar todas las RTCPeerConnection para leer sus stats luego
await page.addInitScript(() => {
  window.__pcs = [];
  const Orig = window.RTCPeerConnection;
  window.RTCPeerConnection = class extends Orig {
    constructor(...a) { super(...a); window.__pcs.push(this); }
  };
});
await page.goto('about:blank');
await page.addScriptTag({ path: findLivekitUmd() });

const connect = await page.evaluate(async ({ url, token, relayOnly }) => {
  const room = new LivekitClient.Room();
  const t0 = performance.now();
  try {
    await room.connect(url, token, relayOnly ? { rtcConfig: { iceTransportPolicy: 'relay' } } : undefined);
    return { ok: true, ms: Math.round(performance.now() - t0) };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}, { url: LIVEKIT_URL, token: LIVEKIT_TOKEN, relayOnly });

console.log('connect:', JSON.stringify(connect));
if (!connect.ok) { await browser.close(); process.exit(1); }

// Chrome puede reportar un par relay como 'prflx'; relayProtocol es la señal confiable de TURN.
const classify = p =>
  p.relayProtocol === 'tls' ? 'tls' :
  p.relayProtocol === 'tcp' ? 'turn-tcp' :
  (p.relayProtocol === 'udp' || p.localType === 'relay') ? 'turn-udp' :
  p.protocol === 'tcp' ? 'tcp' : 'udp';

const sample = () => page.evaluate(async () => {
  const out = [];
  for (const pc of window.__pcs) {
    const stats = await pc.getStats();
    const byId = new Map();
    stats.forEach(s => byId.set(s.id, s));
    let pair;
    stats.forEach(s => { if (s.type === 'transport' && s.selectedCandidatePairId) pair = byId.get(s.selectedCandidatePairId); });
    if (!pair) continue;
    const l = byId.get(pair.localCandidateId);
    out.push({
      state: pc.connectionState,
      localType: l?.candidateType, protocol: l?.protocol, relayProtocol: l?.relayProtocol,
      rttMs: Math.round((pair.currentRoundTripTime ?? 0) * 1000),
    });
  }
  return out;
});

let last = [];
for (let t = 0; t <= holdSec; t += 2) {
  last = await sample();
  console.log(`t=${t}s`, last.map(p => ({ ...p, path: classify(p) })));
  if (t < holdSec) await page.waitForTimeout(2000);
}
await browser.close();

const connected = last.filter(p => p.state === 'connected');
if (!connected.length) { console.log('RESULT: FAIL (sin conexión al final)'); process.exit(1); }
const paths = connected.map(classify);
const ok =
  expect === 'any' ||
  (expect === 'not-udp' ? paths.every(p => p !== 'udp') : paths.every(p => p === expect));
console.log(`RESULT: ${ok ? 'PASS' : 'FAIL'} (paths=${paths.join(',')}, expected=${expect})`);
process.exit(ok ? 0 : 1);
