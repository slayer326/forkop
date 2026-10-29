#!/usr/bin/env ucode

// The one answer to "which Forkop rule handles this connection", calculated
// from the generated sing-box config and the Forkop UCI config. Autotune
// apply, Diagnostics (route_trace) and every later explanation use it.
//
// Pure and read-only: no traffic, no nft, no UCI writes. The answer is the
// first sing-box route rule the connection takes (first-match). When the
// config cannot prove it — lists sing-box cannot be asked about (remote,
// not downloaded), regexes, logical rules, source-scoped rules without a
// source, unknown fields, a resolve action above the owner of a FakeIP
// connection — the result says so with a reason instead of guessing.
// The only command it runs is "sing-box rule-set match" on a local list file.
let fs = require("fs");
let constants = require("core.constants");

const TPROXY_INBOUND = constants.SB_TPROXY_INBOUND_TAG || "tproxy-in";
const DIRECT_OUTBOUND = constants.SB_DIRECT_OUTBOUND_TAG || "direct-out";
const BYPASS_OUTBOUND = constants.SB_BYPASS_OUTBOUND_TAG || "bypass-out";
const DEFAULT_SINGBOX_CONFIG = "/etc/sing-box/config.json";
const FAKEIP_PREFIX = [ "198.18.0.0", 15 ];
const LEGACY_CONNECTION_ACTIONS = [ "proxy", "outbound", "vpn" ];
const RULESET_MATCH_BIN = getenv("FORKOP_RULESET_MATCH_BIN") || "/usr/bin/sing-box";

function as_string(v) { return v == null ? "" : "" + v; }
function list_of(v) { return v == null ? [] : type(v) == "array" ? v : [ v ]; }
function words(value) {
    value = trim(replace(as_string(value), /[ \t\r\n]+/g, " "));
    return value == "" ? [] : split(value, " ");
}

// ---- Forkop UCI config ----------------------------------------------------

// A UCI value made of quoted/unquoted segments (same rules as snapshots.uc).
function uci_value(text) {
    let result = "", q = null;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (q == "'") { if (c == "'") q = null; else result += c; }
        else if (q == "\"") {
            if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
            else if (c == "\"") q = null;
            else result += c;
        }
        else if (c == "'" || c == "\"") q = c;
        else if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
        else if (c == " " || c == "\t") break;
        else result += c;
    }
    return q == null ? result : null;
}

// Sections in file order: [{ type, name, options: { key: value | [values] } }].
function parse_config(text) {
    let sections = [], current = null;
    let lines = split(as_string(text), "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        let start = match(line, /^[ \t]*config[ \t]+([A-Za-z0-9_-]+)([ \t]+['"]?([A-Za-z0-9_-]+)['"]?)?/);
        if (start != null) {
            current = { type: start[1], name: start[3] || null, options: {} };
            push(sections, current);
            continue;
        }
        let opt = match(line, /^[ \t]*(option|list)[ \t]+([A-Za-z0-9_-]+)[ \t]+(.+)$/);
        if (current == null || opt == null) continue;
        let text_value = trim(opt[3]), raw = uci_value(text_value);
        while (raw == null && i + 1 < length(lines)) { text_value += "\n" + lines[++i]; raw = uci_value(text_value); }
        if (raw == null) raw = text_value;
        if (opt[1] == "list") {
            if (type(current.options[opt[2]]) != "array") current.options[opt[2]] = [];
            push(current.options[opt[2]], raw);
        }
        else current.options[opt[2]] = raw;
    }
    return sections;
}

function enabled(section) {
    let v = section.options.enabled;
    return v == null || index([ "1", "true", "yes", "on" ], lc(as_string(v))) >= 0;
}
function find_section(sections, name) {
    for (let s in sections) if (s.type == "section" && s.name == name) return s;
    return null;
}
function settings_of(sections) {
    for (let s in sections) if (s.type == "settings") return s.options;
    return {};
}
function singbox_config_path(sections) {
    return as_string(settings_of(sections).config_path) || DEFAULT_SINGBOX_CONFIG;
}
function load_json(path) {
    let data = path == "" ? null : fs.readfile(path);
    try { return data == null ? null : json(data); } catch (e) { return null; }
}

// What the rule's strategy applies to: matcher names and sizes, no values of
// secrets (matchers are never secrets, but only counts and list names are kept).
function rule_scope(section) {
    let scope = {};
    for (let key in [ "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "community_lists",
                      "rule_set", "rule_set_with_subnets", "domain_ip_lists", "ports", "source_ip_cidr", "fully_routed_ips" ]) {
        let v = section.options[key];
        if (v == null || v == "") continue;
        scope[key] = key == "community_lists" ? (type(v) == "array" ? v : words(v)) : (type(v) == "array" ? length(v) : length(words(v)));
    }
    return scope;
}

// ---- which rule handles the target ---------------------------------------

function in_prefix(ip, prefix, len) {
    let parse = (t) => {
        let m = match(as_string(t), /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
        if (m == null) return null;
        return ((int(m[1]) * 256 + int(m[2])) * 256 + int(m[3])) * 256 + int(m[4]);
    };
    let a = parse(ip), b = parse(prefix);
    if (a == null || b == null) return false;
    let size = 1;
    for (let i = 0; i < 32 - len; i++) size *= 2;
    return int(a / size) == int(b / size);
}
function cidr_contains(cidr, ip) {
    let m = match(as_string(cidr), /^([0-9.]+)(\/([0-9]+))?$/);
    return m != null && in_prefix(ip, m[1], m[3] ? int(m[3]) : 32);
}
function is_fakeip(ip) {
    return in_prefix(ip, FAKEIP_PREFIX[0], FAKEIP_PREFIX[1]);
}

// The connection being asked about. fakeip: the target reaches sing-box as
// a FakeIP address (replaced by the domain name); defaults to whether ip is
// in the FakeIP range. Without a source, source-scoped rules are undecidable,
// unless assume_rule_source asks "for the devices of the first source-scoped
// rule that takes the destination" (resolve() then names the address it used).
function target(host, ip, opts) {
    opts = type(opts) == "object" ? opts : {};
    return {
        host: lc(as_string(host)),
        ip: as_string(ip),
        fakeip: opts.fakeip != null ? !!opts.fakeip : is_fakeip(ip),
        network: lc(as_string(opts.network || "tcp")),
        port: opts.port != null && as_string(opts.port) != "" ? int(opts.port) : 443,
        source: as_string(opts.source),
        assume_rule_source: opts.assume_rule_source === true
    };
}

function port_matches(rule, port) {
    if (rule.port == null && rule.port_range == null) return true;
    for (let p in list_of(rule.port)) if (int(p) == port) return true;
    for (let r in list_of(rule.port_range)) {
        let m = match(as_string(r), /^([0-9]*):([0-9]*)$/);
        if (m && (m[1] == "" || port >= int(m[1])) && (m[2] == "" || port <= int(m[2]))) return true;
    }
    return false;
}
const RULE_KEYS = [ "action", "outbound", "inbound", "domain", "domain_suffix", "domain_keyword", "domain_regex",
    "ip_cidr", "rule_set", "source_ip_cidr", "port", "port_range", "network", "protocol" ];
// Sniffed protocols a TCP connection can never have (disable_quic adds a
// protocol=quic reject rule in front of every section rule).
const UDP_ONLY_PROTOCOLS = [ "quic", "dtls", "stun" ];
const RESOLVE_KEYS = [ "action", "server", "strategy", "disable_cache", "rewrite_ttl", "client_subnet" ];

// A copy of a rule without the given (action-specific) option keys.
function filter_keys(r, drop) {
    let copy = {};
    for (let k, v in r) if (index(drop, k) < 0) copy[k] = v;
    return copy;
}

function shell_quote(v) { return "'" + replace(as_string(v), /'/g, "'\''") + "'"; }

// The local list files of the generated config: { tag: { format, path } }.
function local_rule_sets(config) {
    let result = {};
    let list = type(config) == "object" && type(config.route) == "object" ? config.route.rule_set : null;
    for (let e in list_of(list)) {
        if (type(e) != "object" || e.type != "local" || as_string(e.tag) == "" || as_string(e.path) == "") continue;
        let format = e.format == null ? "source" : as_string(e.format);
        if (format != "binary" && format != "source") continue;
        result[e.tag] = { format, path: as_string(e.path) };
    }
    return result;
}

// Whether a list holds the value, asked of sing-box itself: "match", "no",
// or "unknown" when it cannot be asked (no local file, a failing command).
// sing-box prints the matching rule and exits 0 either way. It prints it
// through its logger, which writes to stderr, so both streams are read.
function rule_set_holds(entry, value) {
    if (entry == null || fs.stat(entry.path) == null) return "unknown";
    let pipe = fs.popen(join(" ", map([ RULESET_MATCH_BIN, "rule-set", "match", "-f", entry.format, entry.path, value ], shell_quote)) +
        " 2>&1", "r");
    if (pipe == null) return "unknown";
    let output = as_string(pipe.read("all"));
    if (pipe.close() != 0) return "unknown";
    return match(output, /(^|\n)match rules\./) != null ? "match" : "no";
}

// The values a list is asked about: the name a FakeIP connection reaches
// sing-box with; a real-address connection also by its address. null: the
// target is not a plain host/address and is never handed to a command.
function rule_set_values(t) {
    let values = [];
    if (t.host != "") {
        if (match(t.host, /^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/) == null) return null;
        push(values, t.host);
    }
    if (!t.fakeip && t.ip != "") {
        if (match(t.ip, /^[0-9a-fA-F:.]+$/) == null) return null;
        push(values, t.ip);
    }
    return values;
}

// Whether a rule's matchers take the connection: "match", "no", or
// { reason } when that cannot be decided statically.
// A FakeIP connection reaches sing-box as the domain name (the FakeIP
// address is replaced by the FQDN), so ip_cidr matches nothing unless a
// resolve action filled real addresses in (route_owner refuses to decide
// past one); a real-address connection is matched by ip_cidr and by the
// sniffed domain. lists: local_rule_sets() of the config; without it a
// rule_set matcher is undecidable.
function rule_matches(r, t, lists) {
    if (r.type == "logical" || r.invert) return { reason: "logical_rule" };
    for (let key in keys(r)) if (index(RULE_KEYS, key) < 0) return { reason: "unknown_rule_field:" + key };
    if (r.network != null && index(list_of(r.network), t.network) < 0) return "no";
    if (!port_matches(r, t.port)) return "no";
    if (r.protocol != null) {
        if (t.network != "tcp") return { reason: "protocol_matcher" };
        let tcp_possible = filter(list_of(r.protocol), (p) => index(UDP_ONLY_PROTOCOLS, p) < 0);
        if (length(tcp_possible) == 0) return "no";
        return { reason: "protocol_matcher" };
    }
    let host = t.host, dest_fields = 0, dest = "no";
    let hit = () => { dest = "match"; };
    let unknown = () => { if (dest != "match") dest = "unknown"; };
    for (let d in list_of(r.domain)) { dest_fields++; if (host != "" && lc(d) == host) hit(); }
    for (let d in list_of(r.domain_suffix)) {
        dest_fields++;
        if (host == "") continue;
        // sing-box: ".example.com" matches subdomains only, "example.com"
        // the domain itself and its subdomains.
        let s = lc(d), sub_only = substr(s, 0, 1) == ".";
        if (sub_only) s = substr(s, 1);
        if ((!sub_only && host == s) || (length(host) > length(s) + 1 && substr(host, length(host) - length(s) - 1) == "." + s)) hit();
    }
    for (let d in list_of(r.domain_keyword)) { dest_fields++; if (host != "" && index(host, lc(d)) >= 0) hit(); }
    for (let d in list_of(r.domain_regex)) { dest_fields++; unknown(); }
    for (let c in list_of(r.ip_cidr)) { dest_fields++; if (!t.fakeip && cidr_contains(c, t.ip)) hit(); }
    for (let n in list_of(r.rule_set)) {
        dest_fields++;
        if (dest == "match") continue;
        let values = type(lists) == "object" ? rule_set_values(t) : null, held = "no";
        if (values == null) { unknown(); continue; }
        for (let v in values) {
            let answer = rule_set_holds(lists[n], v);
            if (answer == "match") { held = "match"; break; }
            if (answer == "unknown") held = "unknown";
        }
        if (held == "match") hit(); else if (held == "unknown") unknown();
    }
    if (dest_fields > 0 && dest == "no") return "no";
    if (dest == "unknown") return { reason: "undecidable_matcher" };
    if (r.source_ip_cidr != null) {
        if (t.source == "") return { reason: "source_scoped_rule" };
        let inside = false;
        for (let c in list_of(r.source_ip_cidr)) if (cidr_contains(c, t.source)) inside = true;
        if (!inside) return "no";
    }
    return "match";
}

// First sing-box route rule the connection takes from the transparent proxy
// inbound: { decided, kind: outbound|reject|final, outbound, rule, reason }.
function route_owner(config, t) {
    let rules = type(config) == "object" && type(config.route) == "object" && type(config.route.rules) == "array" ? config.route.rules : null;
    if (rules == null) return { decided: false, reason: "singbox_config_unavailable" };
    let lists = local_rule_sets(config);
    for (let i = 0; i < length(rules); i++) {
        let r = rules[i];
        if (type(r) != "object") continue;
        if (r.inbound != null && index(list_of(r.inbound), TPROXY_INBOUND) < 0) continue;
        let action = r.action || "route";
        if (action == "resolve") {
            if (!t.fakeip) continue;
            if (rule_matches(filter_keys(r, RESOLVE_KEYS), t, lists) != "no") return { decided: false, reason: "resolve_rule", rule: i };
            continue;
        }
        if (action != "route" && action != "reject") continue;
        let m = rule_matches(r, t, lists);
        if (m == "no") continue;
        if (type(m) == "object")
            return { decided: false, reason: m.reason, rule: i, sources: m.reason == "source_scoped_rule" ? list_of(r.source_ip_cidr) : null };
        if (action == "reject") return { decided: true, kind: "reject", rule: i };
        return { decided: true, kind: "outbound", outbound: r.outbound, rule: i, source_scoped: r.source_ip_cidr != null };
    }
    return { decided: true, kind: "final", outbound: config.route.final || null, rule: null };
}

// The enabled Forkop rule (config section) behind an outbound tag:
// <name>-out, <name>-out-<n>, <name>-urltest[-<id>]-out, <name>-<n>-out, ...
function section_for_outbound(sections, tag) {
    tag = as_string(tag);
    let best = null;
    for (let s in sections) {
        let name = as_string(s.name);
        if (s.type != "section" || !enabled(s) || name == "" || substr(tag, 0, length(name) + 1) != name + "-") continue;
        if (match(tag, /-out(-[0-9]+)?$/) == null) continue;
        if (best == null || length(name) > length(best.name)) best = s;
    }
    return best;
}

// An address the rule's source_ip_cidr covers: the base address of its first
// IPv4 entry (the resolver compares IPv4 sources only).
function source_of(cidrs) {
    for (let c in list_of(cidrs)) {
        let m = match(as_string(c), /^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(\/[0-9]+)?$/);
        if (m != null) return m[1];
    }
    return null;
}

// Undecidable: the config does not say. Unsupported: a rule shape the
// static resolver does not evaluate. Unavailable: no config to read.
function status_for(reason) {
    reason = as_string(reason);
    if (reason == "singbox_config_unavailable") return "unavailable";
    if (reason == "logical_rule" || reason == "protocol_matcher" || substr(reason, 0, 19) == "unknown_rule_field:") return "unsupported";
    return "undecidable";
}

// Structured answer for (config, sections, target):
// { status: decided|undecidable|unsupported|unavailable, reason,
//   route: outbound|reject|final, route_rule, kind: rule|bypass|block|direct|outbound,
//   section, label, action, outbound, scope, provenance,
//   source_scope: null | { source, assumed } — the owner is a source-scoped
//   rule; assumed: the answer holds for the rule's own devices only (the
//   target asked with assume_rule_source and named no source) }
function resolve(config, sections, t) {
    let route = route_owner(config, t), assumed = null;
    if (!route.decided && route.reason == "source_scoped_rule" && t.assume_rule_source) {
        assumed = source_of(route.sources);
        if (assumed != null) route = route_owner(config, { ...t, source: assumed });
    }
    let result = { status: "decided", reason: null, route: null, route_rule: route.rule, kind: null,
        section: null, label: null, action: null, outbound: null, scope: null,
        provenance: "simulated", source_scope: null };
    if (!route.decided) {
        result.status = status_for(route.reason);
        result.reason = route.reason;
        result.provenance = "unknown";
        return result;
    }
    result.route = route.kind;
    result.outbound = route.outbound || null;
    if (route.source_scoped === true) result.source_scope = { source: assumed != null ? assumed : t.source, assumed: assumed != null };
    if (route.kind == "reject") { result.kind = "block"; result.action = "block"; return result; }
    if (result.outbound == BYPASS_OUTBOUND) { result.kind = "bypass"; result.action = "bypass"; return result; }
    if (route.kind == "final" && (result.outbound == null || result.outbound == DIRECT_OUTBOUND)) {
        result.kind = "direct"; result.action = "direct"; return result;
    }
    let section = section_for_outbound(sections, result.outbound);
    if (section == null) {
        result.kind = result.outbound == DIRECT_OUTBOUND ? "direct" : "outbound";
        result.action = result.kind == "direct" ? "direct" : null;
        return result;
    }
    let action = as_string(section.options.action);
    if (index(LEGACY_CONNECTION_ACTIONS, action) >= 0) action = "connection";
    result.kind = "rule";
    result.section = section.name;
    result.label = as_string(section.options.label) || section.name;
    result.action = action;
    result.scope = { rule: section.name, matchers: rule_scope(section) };
    return result;
}

return {
    parse_config, enabled, find_section, settings_of, singbox_config_path, load_json,
    rule_scope, is_fakeip, target, rule_matches, route_owner, section_for_outbound, resolve
};
