// Test helper only. The player has no JavaScript or reference codec dependency.
const fs = require('fs');
const [ours, reference] = process.argv.slice(2);
const minSnr = Number(process.argv[4] ?? 90), maxError = Number(process.argv[5] ?? 0.0001);
const a = fs.readFileSync(ours), b = fs.readFileSync(reference);
if (a.length !== b.length || a.length % 8 !== 0) {
  throw new Error(`PCM lengths differ: ${a.length} / ${b.length}`);
}
let signal = 0, error = 0, peakError = 0, peak = 0;
for (let i = 0; i < a.length; i += 4) {
  const x = a.readFloatLE(i), y = b.readFloatLE(i), d = x - y;
  if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`Nonfinite sample at ${i / 4}`);
  signal += y * y;
  error += d * d;
  peakError = Math.max(peakError, Math.abs(d));
  peak = Math.max(peak, Math.abs(y));
}
const snrDb = error === 0 ? null : 10 * Math.log10(signal / error);
const result = { frames: a.length / 8, snrDb, peakError, referencePeak: peak };
console.log(JSON.stringify(result));
if (peakError > maxError || (snrDb !== null && snrDb < minSnr)) process.exitCode = 1;
