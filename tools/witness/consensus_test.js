// consensus_test.js — exercises the witness-consensus determination
// logic from viz.html under jsc.  Doesn't need a browser; doesn't need
// a network.  Verifies that the four interesting cases (consensus,
// divergent, behind beacon, no live witnesses) classify correctly.
//
// Run:  jsc tools/witness/consensus_test.js

"use strict";

// Mirror the classification logic from viz.html — kept separate so we
// can drive it without DOM dependencies.  If viz.html changes, update
// this in lockstep.
function classify(beacon, results) {
  const live = results.filter(r => r.src === 'live');
  const total = results.length;
  if (live.length === 0) return 'no-live';
  if (live.length < total) return 'partial';
  const pulseSet = new Set(live.map(r => r.body.pulse_id));
  const valueSet = new Set(live.map(r => r.body.value_hex));
  if (pulseSet.size > 1) return 'divergent';
  if (valueSet.size > 1) return 'value-mismatch';
  if (beacon && beacon.pulse_id !== [...pulseSet][0]) return 'behind';
  if (live.some(r => r.body.chain_verified === false)) return 'chain-break';
  return 'consensus';
}

function W(node, body) { return { src: 'live', meta: { node }, body }; }
function F(node, body) { return { src: 'fixture', meta: { node }, body }; }
function E(node)       { return { src: 'error', meta: { node } }; }

const cases = [
  // 1. happy path — single witness in consensus with beacon.
  { name: 'consensus single',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [ W('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: true }) ],
    want:    'consensus' },
  // 2. two witnesses agreeing.
  { name: 'consensus dual',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [
      W('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
      W('mini',   { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
    ],
    want: 'consensus' },
  // 3. one witness in fixture mode (counted as not-live).
  { name: 'partial — one fixture',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [
      W('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
      F('mini',   { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
    ],
    want: 'partial' },
  // 4. all fixtures (zero live).
  { name: 'no-live (all fixtures)',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [
      F('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
    ],
    want: 'no-live' },
  // 5. divergent pulse_ids — actual fork in the wild.
  { name: 'divergent pulse_id',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [
      W('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
      W('mini',   { pulse_id: 99,  value_hex: 'bb', chain_verified: true }),
    ],
    want: 'divergent' },
  // 6. same pulse, different value — value tampered.
  { name: 'value mismatch',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [
      W('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
      W('mini',   { pulse_id: 100, value_hex: 'cc', chain_verified: true }),
    ],
    want: 'value-mismatch' },
  // 7. witnesses lag the beacon.
  { name: 'behind beacon',
    beacon:  { pulse_id: 102, value_hex: 'dd' },
    results: [
      W('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: true }),
    ],
    want: 'behind' },
  // 8. chain break observed.
  { name: 'chain break',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [
      W('fleet0', { pulse_id: 100, value_hex: 'aa', chain_verified: false }),
    ],
    want: 'chain-break' },
  // 9. error result (HTTP fail, no fixture).
  { name: 'error → behaves like not-live',
    beacon:  { pulse_id: 100, value_hex: 'aa' },
    results: [ E('fleet0') ],
    want: 'no-live' },
];

let pass = 0, fail = 0;
for (const c of cases) {
  const got = classify(c.beacon, c.results);
  const ok  = got === c.want;
  print(`  ${ok ? '✓' : '✗'} ${c.name.padEnd(34)} got=${got.padEnd(16)} want=${c.want}`);
  if (ok) pass++; else fail++;
}
print(`\n${pass}/${cases.length} passed`);
print(fail === 0 ? 'PASS — witness consensus logic' : 'FAIL — see ✗ rows above');
quit(fail === 0 ? 0 : 1);
