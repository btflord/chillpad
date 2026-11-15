// Plays the phone's part against a dry-run Chillpad and checks how the Mac copes with late Wi‑Fi packets.
//   CHILL_DRY=1 CHILL_DEBUG=1 CHILL_HEADLESS=1 CHILL_PORT=8788 build/Chillpad.app/Contents/MacOS/Chillpad 2> log.txt &
//   node scripts/jitter-test.mjs <token> <scenario>      scenario: clean | jitter | stalls | stall-stop
const [token, scenario = 'clean'] = process.argv.slice(2);
const ws = new WebSocket(`ws://127.0.0.1:${process.env.CHILL_PORT || 8788}/ws?k=${token}`);
const FRAME = 1000 / 60, N = 90, STEP = 10;
const until = (t) => new Promise((res) => { const spin = () => (performance.now() >= t ? res() : setImmediate(spin)); spin(); });
const packet = (dx, t) => { const b = new ArrayBuffer(17), v = new DataView(b); v.setUint8(0, 1); v.setFloat32(1, dx, true); v.setFloat32(5, 0, true); v.setFloat64(9, t, true); return b; };

ws.onopen = async () => {
  ws.send(JSON.stringify(['f', 1]));
  const t0 = performance.now() + 20;
  let sent = 0, held = [];
  for (let k = 0; k < N; k++) {
    const t = t0 + k * FRAME;                    // when the phone "sent" it
    let dx = STEP, delay = 0;
    if (scenario === 'jitter') delay = Math.random() * 5;
    if (scenario === 'stalls' && k % 25 >= 20 && k % 25 <= 22) delay = (23 - (k % 25)) * FRAME - 1;   // 3 packets land together, ~50 ms late
    if (scenario === 'stall-stop') { if (k >= 40) dx = 0; if (k >= 40 && k <= 42) delay = (43 - k) * FRAME - 1; }
    sent += dx;
    held.push(until(t + delay).then(() => ws.send(packet(dx, t))));
  }
  await Promise.all(held);
  ws.send(JSON.stringify(['f', 0]));
  console.log(JSON.stringify({ scenario, sent }));
  setTimeout(() => process.exit(0), 100);
};
