"use strict";

// Metamorphic properties of routing/resolve.uc over generated sing-box rule
// lists (UC-156, safety invariants 7 and 8: first match, fail closed):
//   - rules appended after the first deciding rule never change the answer;
//   - rules the connection cannot take (another inbound, network udp) inserted
//     before it only shift the rule index;
//   - an undecidable matcher (rule_set, domain_regex, source-scoped) inserted
//     before it makes the answer "undecidable" at that rule, never another
//     decided owner;
//   - domain, domain_suffix (leading dot: subdomains only) and domain_keyword
//     match like an independent model, case-insensitively.
// Usage: route_resolver.js <forkop lib> <forkop.uci fixture>

const assert = require("node:assert/strict");
const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require("./scaffold");

const [lib, uciFixture] = process.argv.slice(2);
const seed = seedFrom(1560001);
const rng = new Rng(seed);
const CASES = casesFrom(400);

const HOSTS = ["www.youtube.com", "youtube.com", "m.youtube.com", "i.ytimg.com", "discord.com",
  "cdn.discordapp.com", "example.org", "a.b.example.org", "xn--80ak6aa92e.com"];
const SUFFIXES = ["youtube.com", "discord.com", "example.org", "b.example.org", "com", "org", "tube.com",
  "ytimg.com", "discordapp.com", "www.youtube.com"];
const KEYWORDS = ["tube", "disc", "exam", "zzz", "ytimg"];
const OUTBOUNDS = ["main-out", "youtube-out", "discord-out", "direct-out", "bypass-out"];

function mixCase(value) {
  return rng.pickWeighted([[3, value], [1, value.toUpperCase()],
    [1, [...value].map((c) => (rng.bool() ? c.toUpperCase() : c)).join("")]]);
}

// A rule whose matchers resolve.uc decides statically.
function decidableRule() {
  const rule = { action: rng.pickWeighted([[5, "route"], [1, "reject"]]) };
  if (rule.action === "route") rule.outbound = rng.pick(OUTBOUNDS);
  if (rng.bool(0.7)) rule.inbound = rng.bool(0.8) ? "tproxy-in" : ["mixed-in", "tproxy-in"];
  const kinds = rng.subset(["domain_suffix", "domain", "domain_keyword", "ip_cidr", "port", "port_range", "network"], 0.35);
  if (!kinds.length) kinds.push(rng.pick(["domain_suffix", "domain", "domain_keyword"]));
  for (const kind of kinds) {
    if (kind === "domain_suffix") rule.domain_suffix = rng.array(1, 2, () => (rng.bool(0.25) ? "." : "") + mixCase(rng.pick(SUFFIXES)));
    if (kind === "domain") rule.domain = rng.array(1, 2, () => mixCase(rng.pick(HOSTS)));
    if (kind === "domain_keyword") rule.domain_keyword = [rng.pick(KEYWORDS)];
    if (kind === "ip_cidr") rule.ip_cidr = [rng.pick(["142.250.0.0/16", "10.0.0.0/8", "142.250.1.1"])];
    if (kind === "port") rule.port = [rng.pick([443, 80, 8443])];
    if (kind === "port_range") rule.port_range = [rng.pick(["400:500", ":442", "444:", "443:443"])];
    if (kind === "network") rule.network = rng.pick(["tcp", ["tcp", "udp"], "udp"]);
  }
  return rule;
}

// Rules the static resolver never takes for decisions of its own.
function noiseRule() {
  return rng.pick([
    { action: "sniff", inbound: "tproxy-in" },
    { action: "hijack-dns", inbound: ["dns-in"] },
    { inbound: ["dns-in"], action: "route", outbound: "main-out", rule_set: ["dns-list"] },
  ]);
}

// A rule the TCP connection from the transparent proxy inbound cannot take.
function skippedRule() {
  const rule = rng.bool() ? { ...decidableRule(), network: "udp" } : { ...anyRule(), inbound: ["dns-in"] };
  if (rule.network === "udp") delete rule.protocol;
  return rule;
}

// A rule the resolver cannot decide statically for this connection.
function undecidableRule() {
  const rule = { action: rng.pickWeighted([[4, "route"], [1, "reject"]]) };
  if (rule.action === "route") rule.outbound = rng.pick(OUTBOUNDS);
  if (rng.bool(0.6)) rule.inbound = "tproxy-in";
  const kind = rng.pick(["rule_set", "domain_regex", "source_ip_cidr"]);
  if (kind === "rule_set") rule.rule_set = ["remote-list"];
  if (kind === "domain_regex") rule.domain_regex = [".*tube.*"];
  if (kind === "source_ip_cidr") rule.source_ip_cidr = ["192.168.1.2/32"];
  return rule;
}

function anyRule() {
  return rng.pickWeighted([[6, decidableRule], [1, noiseRule], [1, undecidableRule]])();
}

function target() {
  const fakeip = rng.bool(0.75);
  return { host: mixCase(rng.pick(HOSTS)), fakeip, ip: fakeip ? "198.18.0.7" : "142.250.1.1" };
}

const UCODE = `
let r = require("routing.resolve");
let sections = r.parse_config(__fs.readfile(getenv("ROUTE_FORKOP_UCI")));
const OUTBOUNDS = [
    { type: "direct", tag: "direct-out" },
    { type: "direct", tag: "bypass-out" },
    { type: "vless", tag: "main-out" },
    { type: "direct", tag: "youtube-out", routing_mark: 16777217 },
    { type: "direct", tag: "discord-out", routing_mark: 16777218 }
];
function evaluate(input) {
    if (input.rule != null)
        return r.rule_matches(input.rule, r.target(input.host, "198.18.0.7", { fakeip: true }));
    let config = { route: { final: "direct-out", rules: input.rules }, outbounds: OUTBOUNDS };
    return r.resolve(config, sections, r.target(input.host, input.ip, { fakeip: input.fakeip }));
}
`;
const resolve = (inputs) => ucodeBatch(lib, UCODE, inputs, { ROUTE_FORKOP_UCI: uciFixture });

// Base cases: rule lists without undecidable matchers, so most are decided.
const bases = Array.from({ length: CASES }, () => ({
  rules: rng.array(0, 6, () => rng.pickWeighted([[6, decidableRule], [1, noiseRule]])()),
  ...target(),
}));
const baseResults = resolve(bases);
const decided = bases.map((b, i) => ({ ...b, result: baseResults[i] })).filter((b) => b.result.status === "decided");
exercised("decided base cases", decided.length, CASES / 4);
exercised("decided by a rule", decided.filter((b) => b.result.route_rule !== null).length, CASES / 8);
exercised("decided by the final outbound", decided.filter((b) => b.result.route_rule === null).length, CASES / 20);

const variants = [];
for (const base of decided) {
  const owner = base.result.route_rule;
  const upTo = owner === null ? base.rules.length : owner;
  if (owner !== null)
    variants.push({ kind: "append", base, input: { ...base, rules: [...base.rules.slice(0, owner + 1), ...rng.array(1, 4, anyRule)] } });
  const p1 = rng.int(0, upTo);
  variants.push({ kind: "skipped", base, at: p1,
    input: { ...base, rules: [...base.rules.slice(0, p1), skippedRule(), ...base.rules.slice(p1)] } });
  const p2 = rng.int(0, upTo);
  variants.push({ kind: "undecidable", base, at: p2,
    input: { ...base, rules: [...base.rules.slice(0, p2), undecidableRule(), ...base.rules.slice(p2)] } });
}

// Domain matchers against an independent model.
const LABELS = ["www", "m", "a", "b", "youtube", "example", "com", "org", "ru", "xn--p1ai", "cdn"];
const domainCases = Array.from({ length: CASES }, () => {
  const labels = rng.array(1, 4, () => rng.pick(LABELS));
  const host = labels.join(".");
  const kind = rng.pick(["domain_suffix", "domain", "domain_keyword"]);
  let value;
  if (kind === "domain_keyword") value = rng.bool(0.6) ? host.slice(rng.int(0, host.length - 1)).slice(0, rng.int(1, 6)) : rng.pick(LABELS);
  else if (rng.bool(0.6)) value = labels.slice(rng.int(0, labels.length - 1)).join(".");
  else value = rng.array(1, 3, () => rng.pick(LABELS)).join(".");
  if (kind === "domain_suffix" && rng.bool(0.3)) value = "." + value;
  return { host: mixCase(host), rule: { action: "route", outbound: "main-out", [kind]: [mixCase(value)] }, kind, value };
});
function modelMatch({ host, kind, value }) {
  const h = host.toLowerCase();
  let v = value.toLowerCase();
  if (kind === "domain") return h === v;
  if (kind === "domain_keyword") return h.includes(v);
  const subOnly = v.startsWith(".");
  if (subOnly) v = v.slice(1);
  return (!subOnly && h === v) || (h.length > v.length + 1 && h.endsWith("." + v));
}

const results = resolve([...variants.map((v) => v.input), ...domainCases]);
const variantResults = results.slice(0, variants.length);
const domainResults = results.slice(variants.length);

forAll("appending rules after the deciding rule changes nothing", seed, variants, (v, i) => {
  if (v.kind !== "append") return;
  assert.deepEqual(variantResults[i], v.base.result);
});
forAll("rules the connection cannot take only shift the rule index", seed, variants, (v, i) => {
  if (v.kind !== "skipped") return;
  const owner = v.base.result.route_rule;
  assert.deepEqual(variantResults[i], { ...v.base.result, route_rule: owner === null ? null : owner + 1 });
});
forAll("an undecidable matcher before the deciding rule is never guessed past", seed, variants, (v, i) => {
  if (v.kind !== "undecidable") return;
  const got = variantResults[i];
  assert.equal(got.status, "undecidable");
  assert.equal(got.route_rule, v.at, "undecidable at the inserted rule");
  assert.equal(got.provenance, "unknown");
  for (const key of ["kind", "section", "action", "outbound"]) assert.equal(got[key], null, key);
});
forAll("domain matchers follow the sing-box semantics case-insensitively", seed, domainCases, (c, i) => {
  assert.equal(domainResults[i], modelMatch(c) ? "match" : "no");
});
exercised("appended variants", variants.filter((v) => v.kind === "append").length, CASES / 8);
exercised("matching domain cases", domainCases.filter((c) => modelMatch(c)).length, CASES / 5);
exercised("non-matching domain cases", domainCases.filter((c) => !modelMatch(c)).length, CASES / 5);

console.log(`route resolver properties passed (seed ${seed}: ${bases.length} rule lists, ${decided.length} decided, ` +
  `${variants.length} variants, ${domainCases.length} domain cases)`);
