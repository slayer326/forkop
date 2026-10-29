#!/usr/bin/env ucode

// Autotune policy and targets from the Forkop UCI config:
//
//   config autotune 'autotune'
//       option mode 'off'                 # off | recommend (a stored auto reads as recommend)
//       option interval '6h'              # between scheduled runs
//       option confirmations '3'          # same result N runs in a row
//       option min_confidence 'high'      # high | medium (auto needs high)
//       option max_applies_per_day '1'
//       option cooldown '24h'             # after a rollback of a candidate
//       option probes '5'                 # probes per candidate and run
//
//   config autotune_target '<id>'
//       option host 'youtube.com'
//       option enabled '1'
//       option resolver '192.0.2.53'      # optional, else the router DNS
//
//   config autotune_target '<id>'        # a rule list instead of a host
//       option rule_set '<sing-box rule set tag>'   # autotune/lists.uc
//       option sample '3'
//       list pin '<domain>'
//
// A missing section means the defaults (mode off): nothing is migrated or
// written. The DPI group of a target is never stored; it is calculated from
// the routing (routing/resolve.uc). Pure: reads parsed sections only.
let probe_module = require("autotune.probe");
let lists_module = require("autotune.lists");

// The "auto" mode, in which Forkop applied a confirmed recommendation by
// itself, is turned off: a strategy changes only when an administrator
// applies it. A stored "auto" reads as "recommend", and policy-set refuses it.
// autotune/autoapply.uc still decides, and always answers mode_not_auto.
const MODES = [ "off", "recommend" ];
const RETIRED_MODES = { auto: "recommend" };
const CONFIDENCES = [ "medium", "high" ];
const DEFAULTS = {
    mode: "off", interval: "6h", confirmations: 3, min_confidence: "high",
    max_applies_per_day: 1, cooldown: "24h", probes: 5
};
const LIMITS = {
    interval: [ 3600, 7 * 86400 ],
    cooldown: [ 3600, 30 * 86400 ],
    confirmations: [ 2, 10 ],
    max_applies_per_day: [ 0, 5 ],
    probes: [ 3, 7 ]
};
const MAX_TARGETS = 16;

function as_string(v) { return v == null ? "" : "" + v; }

// sing-box style duration ("6h", "90m", "1d12h") in whole seconds, or null.
function duration_seconds(value) {
    let rest = as_string(value), total = 0;
    if (rest == "") return null;
    let units = { s: 1, m: 60, h: 3600, d: 86400 };
    while (rest != "") {
        let m = match(rest, /^([0-9]+)([smhd])/);
        if (m == null) return null;
        total += int(m[1]) * units[m[2]];
        rest = substr(rest, length(m[0]));
    }
    return total > 0 ? total : null;
}

function int_value(value) {
    let text = as_string(value);
    return match(text, /^[0-9]+$/) != null ? int(text) : null;
}

// One policy option: { value } or { error }.
function check(key, value) {
    value = as_string(value);
    if (key == "mode")
        return index(MODES, value) >= 0 ? { value } : { error: "invalid_mode" };
    if (key == "min_confidence")
        return index(CONFIDENCES, value) >= 0 ? { value } : { error: "invalid_confidence" };
    if (key == "interval" || key == "cooldown") {
        let seconds = duration_seconds(value);
        if (seconds == null) return { error: "invalid_duration" };
        if (seconds < LIMITS[key][0] || seconds > LIMITS[key][1]) return { error: "duration_out_of_range" };
        return { value, seconds };
    }
    if (key == "confirmations" || key == "max_applies_per_day" || key == "probes") {
        let n = int_value(value);
        if (n == null) return { error: "invalid_number" };
        if (n < LIMITS[key][0] || n > LIMITS[key][1]) return { error: "number_out_of_range" };
        return { value: n };
    }
    return { error: "unknown_option" };
}

function valid_target_id(id) {
    return match(as_string(id), /^[A-Za-z0-9_]{1,32}$/) != null;
}

// { policy, targets: [{ id, host, enabled, resolver }], errors: [{ option, error }] }
// An invalid option falls back to its default and is reported, so a bad
// value can never make autotune more aggressive than the defaults.
function read(sections) {
    let options = {};
    for (let s in sections || []) if (s.type == "autotune" && s.name == "autotune") options = s.options;
    let policy = {}, errors = [];
    for (let key, fallback in DEFAULTS) {
        let raw = options[key];
        if (raw == null || as_string(raw) == "") { policy[key] = fallback; continue; }
        if (key == "mode" && RETIRED_MODES[as_string(raw)] != null) { policy[key] = RETIRED_MODES[as_string(raw)]; continue; }
        let checked = check(key, raw);
        if (checked.error) { push(errors, { option: key, error: checked.error }); policy[key] = fallback; }
        else policy[key] = checked.value;
    }
    policy.interval_seconds = duration_seconds(policy.interval);
    policy.cooldown_seconds = duration_seconds(policy.cooldown);
    // Autonomous apply never acts on less than high confidence.
    policy.apply_min_confidence = "high";

    let targets = [];
    for (let s in sections || []) {
        if (s.type != "autotune_target") continue;
        let host = lc(as_string(s.options.host)), resolver = as_string(s.options.resolver);
        let rule_set = as_string(s.options.rule_set), sample = as_string(s.options.sample);
        let pins = map(type(s.options.pin) == "array" ? s.options.pin : s.options.pin != null ? [ s.options.pin ] : [], (p) => lc(as_string(p)));
        let enabled = s.options.enabled == null || index([ "1", "true", "yes", "on" ], lc(as_string(s.options.enabled))) >= 0;
        let list = rule_set != "";
        let problem = !valid_target_id(s.name) ? "invalid_target_id"
            : list && host != "" ? "host_and_rule_set"
            : list && !lists_module.valid_tag(rule_set) ? "invalid_rule_set"
            : list && sample != "" && !lists_module.valid_sample(sample) ? "invalid_sample"
            : list && (length(pins) > lists_module.MAX_SAMPLE || length(filter(pins, (p) => !probe_module.valid_host(p))) > 0) ? "invalid_pin"
            : !list && !probe_module.valid_host(host) ? "invalid_host"
            : resolver != "" && !probe_module.valid_ipv4(resolver) ? "invalid_resolver"
            : length(targets) >= MAX_TARGETS ? "too_many_targets" : null;
        if (problem != null) { push(errors, { target: as_string(s.name), error: problem }); continue; }
        let t = { id: s.name, host: list ? null : host, enabled, resolver: resolver != "" ? resolver : null };
        if (list) { t.rule_set = rule_set; t.sample = sample != "" ? int(sample) : lists_module.DEFAULT_SAMPLE; t.pins = uniq(pins); }
        push(targets, t);
    }
    return { policy, targets, errors };
}

function confidence_at_least(confidence, minimum) {
    let order = { low: 0, medium: 1, high: 2 };
    return order[as_string(confidence)] != null && order[as_string(confidence)] >= order[as_string(minimum)];
}

return { DEFAULTS, LIMITS, MODES, MAX_TARGETS, read, check, duration_seconds, valid_target_id, confidence_at_least };
