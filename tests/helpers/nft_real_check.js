'use strict';
// Structural checks of a real `nft -j list ruleset` for tests/nft_real.sh.
//
//   node nft_real_check.js <mode> <ruleset.json> [args...]
//
// Every mode fails (non-zero exit, assertion message) unless the listing the
// kernel returned has the expected structure. Nothing here depends on handle
// numbers; order is checked only where Forkop relies on it.
const fs = require('node:fs');
const assert = require('node:assert/strict');

const [mode, file, ...args] = process.argv.slice(2);
const input = fs.readFileSync(file, 'utf8');
// batch-queues reads an nft batch, every other mode a `nft -j list ruleset`.
const listing = mode === 'batch-queues' ? [] : JSON.parse(input).nftables;
assert.ok(Array.isArray(listing), 'nft -j output has no nftables array');

const objects = (kind) => listing.filter((o) => o[kind]).map((o) => o[kind]);
const tableNames = () => objects('table').map((t) => `${t.family} ${t.name}`).sort();
const chainOf = (table, name) => objects('chain').find((c) => c.family === 'inet' && c.table === table && c.name === name);
const rulesOf = (table, name) => objects('rule').filter((r) => r.family === 'inet' && r.table === table && r.chain === name);
const setOf = (table, name) => objects('set').find((s) => s.family === 'inet' && s.table === table && s.name === name);
const flags = (value) => [].concat(value || []);

function baseChain(table, name, type, hook, prio) {
  const chain = chainOf(table, name);
  assert.ok(chain, `chain ${table}/${name} is missing`);
  assert.deepEqual([chain.type, chain.hook, chain.prio, chain.policy], [type, hook, prio, 'accept'],
    `chain ${table}/${name} type/hook/priority/policy`);
  return chain;
}
function regularChain(table, name) {
  const chain = chainOf(table, name);
  assert.ok(chain, `chain ${table}/${name} is missing`);
  assert.equal(chain.hook, undefined, `chain ${table}/${name} must not be a base chain`);
}

// Element value as nft prints it in text form.
function text(v) {
  if (v === null || typeof v !== 'object') return String(v);
  if (v.prefix) return `${v.prefix.addr}/${v.prefix.len}`;
  if (v.range) return `${text(v.range[0])}-${text(v.range[1])}`;
  if (v.concat) return v.concat.map(text).join(' . ');
  if (v.elem) return text(v.elem.val);
  return JSON.stringify(v);
}

const isMeta = (x, key) => x && typeof x === 'object' && x.meta && x.meta.key === key;
const statementOf = (rule, key) => rule.expr.find((e) => e[key] !== undefined);
const verdict = (rule) => ['accept', 'drop', 'return', 'jump', 'goto', 'queue'].find((k) => statementOf(rule, k));
// `meta mark X` (exact match).
function exactMark(rule) {
  const m = rule.expr.map((e) => e.match).find((x) => x && x.op === '==' && isMeta(x.left, 'mark') && typeof x.right === 'number');
  return m ? m.right : null;
}
// `meta mark & M == V`, in either JSON rendering: nft >= 1.1.0 prints the
// mask as `&`; older nft prints a mask contiguous from the top bit as a prefix.
function maskedMark(rule) {
  for (const e of rule.expr) {
    const m = e.match;
    if (!m || m.op !== '==') continue;
    const masked = m.left && m.left['&'];
    if (Array.isArray(masked) && isMeta(masked[0], 'mark')) return { mask: masked[1], value: m.right, rendering: 'and' };
    if (isMeta(m.left, 'mark') && m.right && m.right.prefix)
      return { mask: Number((0xffffffffn << BigInt(32 - m.right.prefix.len)) & 0xffffffffn), value: m.right.prefix.addr, rendering: 'prefix' };
  }
  return null;
}
function setsMark(rule) {
  const s = statementOf(rule, 'mangle');
  return s && isMeta(s.mangle.key, 'mark') ? s.mangle.value : null;
}
const jumpsTo = (rule, target) => rule.expr.some((e) => e.jump && e.jump.target === target);

const modes = {
  // tables <json> <inet table>...: exactly these tables exist, all inet.
  tables() {
    assert.deepEqual(tableNames(), args.map((name) => `inet ${name}`).sort(), 'tables');
  },

  // production <json> <table> <outbound mark> <queue: yes|no> [<mark>:<queue>...]
  production() {
    const [table, outboundText, queueSupported, ...providers] = args;
    const outbound = Number(outboundText);
    baseChain(table, 'dns_redirect', 'nat', 'prerouting', -101);
    baseChain(table, 'mangle', 'filter', 'prerouting', -149);
    baseChain(table, 'mangle_output', 'route', 'output', -150);
    baseChain(table, 'proxy', 'filter', 'prerouting', -100);
    regularChain(table, 'priority_rules');
    regularChain(table, 'priority_output_rules');
    assert.ok(rulesOf(table, 'mangle').some((r) => jumpsTo(r, 'priority_rules')), 'mangle must jump to priority_rules');
    const first = rulesOf(table, 'priority_output_rules')[0];
    assert.ok(first && first.expr.some((e) => e.match && e.match.op === '!=' && isMeta(e.match.left, 'mark') && e.match.right === 0) &&
      verdict(first) === 'return', 'priority_output_rules must start with "meta mark != 0 return"');

    // The outbound (autotune probe) mark leaves mangle_output before anything
    // can re-mark, jump or queue it.
    const out = rulesOf(table, 'mangle_output');
    // Tested as a single bit, so policy routers' own mark bits do not hide it.
    const ownBit = (r) => { const m = maskedMark(r); return m !== null && m.mask === outbound && m.value === outbound; };
    const bypass = out.findIndex((r) => ownBit(r) && verdict(r) === 'return');
    assert.ok(bypass >= 0, 'mangle_output has no outbound mark bypass');
    out.forEach((r, i) => {
      if (setsMark(r) !== null || statementOf(r, 'jump') || statementOf(r, 'queue') || (exactMark(r) !== null && exactMark(r) !== outbound))
        assert.ok(i > bypass, `mangle_output rule ${i} (${JSON.stringify(r.expr)}) precedes the outbound mark bypass`);
    });

    // Provider rules: route mark -> NFQUEUE, after the desync returns.
    const found = [];
    out.forEach((r, i) => {
      const mark = exactMark(r);
      if (mark === null || mark === outbound) return;
      const q = statementOf(r, 'queue');
      if (queueSupported === 'yes') {
        assert.ok(q, `provider rule for mark ${mark} does not queue`);
        assert.ok(flags(q.queue.flags).includes('bypass'), `queue for mark ${mark} lacks bypass`);
      }
      found.push(`${mark}:${q ? q.queue.num : '-'}`);
      const desyncReturns = out.slice(0, i).filter((p) => maskedMark(p) && verdict(p) === 'return').map((p) => maskedMark(p).mask);
      assert.ok(desyncReturns.includes(0x40000000) && desyncReturns.includes(0x20000000),
        `provider rule for mark ${mark} is not preceded by the desync returns`);
    });
    const expected = providers.flatMap((p) => {
      const [mark, queue] = p.split(':');
      const entry = `${Number(mark)}:${queueSupported === 'yes' ? queue : '-'}`;
      return [entry, entry];                          // tcp and udp
    });
    assert.deepEqual(found.sort(), expected.sort(), 'provider route marks and queues');
  },

  // batch-queues <batch> <table> <mark>:<queue>...: the queue statements of a
  // batch the kernel stage took without them (no nft_queue), as nft parsed
  // and evaluated them: every provider route mark queues tcp and udp to its
  // queue with bypass, and no other rule of the table queues.
  'batch-queues'() {
    const [table, ...providers] = args;
    const found = input.split('\n').filter((l) => l.startsWith(`add rule inet ${table} `) && / queue /.test(l)).map((l) => {
      const m = l.match(/^add rule inet \S+ mangle_output meta mark (0x[0-9a-f]+) meta l4proto (tcp|udp) counter queue num (\d+) bypass$/);
      assert.ok(m, `unexpected queue rule in the batch: ${l}`);
      return `${Number(m[1])}:${m[2]}:${m[3]}`;
    });
    const expected = providers.flatMap((p) => {
      const [mark, queue] = p.split(':');
      return ['tcp', 'udp'].map((proto) => `${Number(mark)}:${proto}:${queue}`);
    });
    assert.deepEqual(found.sort(), expected.sort(), 'provider route marks, protocols and queues in the batch');
  },

  // set <json> <table> <set> <element>...: the set holds these elements.
  set() {
    const [table, name, ...elements] = args;
    const set = setOf(table, name);
    assert.ok(set, `set ${table}/${name} is missing`);
    const have = (set.elem || []).map(text);
    for (const e of elements) assert.ok(have.includes(e), `set ${name} lacks ${e}; has ${JSON.stringify(have)}`);
  },

  // order <json> <table> <chain> <set A> <set B>: the first rule using set A
  // precedes the first rule using set B.
  order() {
    const [table, chain, first, second] = args;
    const rules = rulesOf(table, chain);
    const at = (set) => rules.findIndex((r) => JSON.stringify(r.expr).includes(`"@${set}"`));
    assert.ok(at(first) >= 0 && at(second) >= 0, `${table}/${chain} lacks rules for ${first} or ${second}`);
    assert.ok(at(first) < at(second), `${table}/${chain}: ${first} must be decided before ${second}`);
  },

  // verdicts <json> <table> <chain> <set> <accept-unmarked|accept-mark:N>:
  // every rule using the set ends like that.
  verdicts() {
    const [table, chain, set, kind] = args;
    const rules = rulesOf(table, chain).filter((r) => JSON.stringify(r.expr).includes(`"@${set}"`));
    assert.ok(rules.length > 0, `${table}/${chain} has no rule for ${set}`);
    const mark = kind === 'accept-unmarked' ? null : Number(kind.split(':')[1]);
    for (const r of rules) {
      assert.equal(verdict(r), 'accept', `${set} rule verdict`);
      assert.equal(setsMark(r), mark, `${set} rule mark`);
    }
  },

  // empty-set <json> <table> <set>...
  'empty-set'() {
    const [table, ...names] = args;
    for (const name of names) {
      const set = setOf(table, name);
      assert.ok(set, `set ${table}/${name} is missing`);
      assert.deepEqual((set.elem || []).map(text), [], `set ${name} must be empty`);
    }
  },

  // dpi-guard <json> <table>: prints the mark rendering ("and" or "prefix").
  'dpi-guard'() {
    const [table] = args;
    baseChain(table, 'output', 'filter', 'output', -149);
    assert.equal(objects('chain').filter((c) => c.table === table).length, 1, `${table} has extra chains`);
    const rules = rulesOf(table, 'output');
    const marks = rules.map((r) => {
      assert.equal(verdict(r), 'drop', `${table} rule does not drop`);
      const m = maskedMark(r);
      assert.ok(m && m.mask === 0xff000000, `${table} rule does not match the provider mark byte`);
      return m;
    });
    assert.deepEqual(marks.map((m) => m.value).sort(), [0x01000000, 0x02000000], `${table} provider marks`);
    process.stdout.write(`${marks[0].rendering}\n`);
  },

  // transition-guard <json> <table> <mark>
  'transition-guard'() {
    const [table, markText] = args;
    const mark = Number(markText);
    baseChain(table, 'forkop_transition_guard', 'filter', 'prerouting', -101);
    const rules = rulesOf(table, 'forkop_transition_guard');
    assert.equal(rules.length, 1, 'transition guard rule count');
    const m = maskedMark(rules[0]);
    assert.ok(m && m.mask === mark && m.value === mark, 'transition guard must match the FakeIP mark');
    assert.ok(statementOf(rules[0], 'counter') && verdict(rules[0]) === 'drop', 'transition guard must count and drop');
  },

  // absent-chain <json> <table> <chain>
  'absent-chain'() {
    const [table, name] = args;
    assert.equal(chainOf(table, name), undefined, `chain ${table}/${name} must be gone`);
  },

  // torrserver <json> <table> <mark> <cgroup|->
  torrserver() {
    const [table, markText, cgroup] = args;
    baseChain(table, 'output', 'route', 'output', -151);
    const rules = rulesOf(table, 'output');
    assert.equal(rules.length, 1, 'TorrServer Direct rule count');
    assert.equal(rules[0].comment, 'Forkop TorrServer Direct');
    assert.equal(setsMark(rules[0]), Number(markText), 'TorrServer Direct must set the outbound mark');
    if (cgroup !== '-') {
      const socket = rules[0].expr.map((e) => e.match).find((m) => m && m.left && m.left.socket);
      assert.ok(socket && socket.left.socket.key === 'cgroupv2' && socket.right === cgroup, 'TorrServer Direct cgroup match');
    }
  },

  // isolation <json> <table> <probe mark> <production table>
  //   <comment>:<queue:N|accept|-> (- : the queue statement the kernel lacks)
  isolation() {
    const [table, markText, production, switchable] = args;
    const probeMark = Number(markText);
    baseChain(table, 'premark', 'route', 'output', -152);
    baseChain(table, 'output', 'route', 'output', -151);
    const premark = rulesOf(table, 'premark');
    assert.deepEqual(premark.map((r) => r.comment), ['probe_mark']);
    assert.equal(setsMark(premark[0]), probeMark, 'premark must set the probe mark');
    assert.equal(verdict(premark[0]), 'accept');
    const [comment, action, queue] = switchable.split(':');
    const out = rulesOf(table, 'output');
    assert.deepEqual(out.map((r) => r.comment), ['reinjected', 'reinjected_bare', comment, 'unexpected'], 'probe chain order');
    assert.equal(setsMark(out[0]), probeMark);
    assert.equal(setsMark(out[1]), probeMark);
    assert.equal(exactMark(out[2]), probeMark, 'the switchable rule takes only the probe mark');
    if (action === 'queue') {
      const q = statementOf(out[2], 'queue');
      assert.ok(q && q.queue.num === Number(queue), `switchable rule must queue to ${queue}`);
    }
    else if (action === '-') assert.equal(verdict(out[2]), undefined, 'switchable rule without its queue statement');
    else assert.equal(verdict(out[2]), action, 'switchable rule verdict');
    assert.equal(verdict(out[3]), 'drop');
    // probe_counters() needs a counter on every rule of the table.
    for (const r of [...premark, ...out]) assert.ok(statementOf(r, 'counter'), `rule ${r.comment} has no counter`);
    // The probe chains run before every production output hook.
    for (const c of objects('chain').filter((x) => x.table === production && x.hook === 'output'))
      assert.ok(c.prio > -151, `production chain ${c.name} (priority ${c.prio}) runs before the probe chains`);
  },

  // handle <json> <table> <chain> <comment>: prints the rule handle.
  handle() {
    const [table, chain, comment] = args;
    const rule = rulesOf(table, chain).find((r) => r.comment === comment);
    assert.ok(rule, `rule ${comment} is missing in ${table}/${chain}`);
    process.stdout.write(`${rule.handle}\n`);
  },

  // normalize <json> <table>: the table without handles and counter values.
  normalize() {
    const [table] = args;
    const strip = (v) => {
      if (Array.isArray(v)) return v.map(strip);
      if (!v || typeof v !== 'object') return v;
      const out = {};
      for (const k of Object.keys(v).sort()) {
        if (k === 'handle') continue;
        out[k] = k === 'counter' && v[k] && typeof v[k] === 'object' ? { packets: 0, bytes: 0 } : strip(v[k]);
      }
      return out;
    };
    const own = listing.filter((o) => {
      const kind = Object.keys(o)[0];
      return kind !== 'metainfo' && o[kind].family === 'inet' && (o[kind].table === table || (kind === 'table' && o[kind].name === table));
    });
    process.stdout.write(`${JSON.stringify(strip(own))}\n`);
  },

  // elements <json> <table> <set>: prints the elements of a set as JSON.
  elements() {
    const [table, name] = args;
    const set = setOf(table, name);
    assert.ok(set, `set ${table}/${name} is missing`);
    process.stdout.write(`${JSON.stringify((set.elem || []).map(text))}\n`);
  },
};

assert.ok(modes[mode], `unknown mode ${mode}`);
modes[mode]();
