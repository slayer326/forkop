#!/usr/bin/env ucode

// Autotune product layer: policy, targets, groups, cached results,
// hysteresis, scheduling and safe application on top of the Stage 3-5
// tools (autotune/isolation.uc tune, autotune/apply.uc plan/apply/rollback),
// which are called as they are and never bypassed.
//
// Modes:
//   status          policy, targets and cached results (read-only)
//   target <id>     the last full tune output of one target (read-only)
//   groups          targets classified into DPI groups now (read-only; DNS)
//   policy-set <option> <value>                     (write)
//   target-set <id> <host> [enabled] [resolver] [rule_set] [sample] [pins]
//                   a host target, or with an empty host a rule-list
//                   target (autotune/lists.uc); pins: comma-separated (write)
//   target-remove <id>                              (write)
//   list-domains <rule_set>  the domains of a list a DPI rule uses, for
//                   choosing pinned domains (read-only)
//   run <all|group>     tune the targets of the groups now (write)
//   if-due              the scheduled run, when enabled and due (cron); it
//                       only measures: the mode "auto", which applied a
//                       confirmed recommendation, is off (autotune/policy.uc)
//   run-async <all|group>  start a run as a background job; prints its id
//   run-status <job>    state and result of a job (read-only)
//   rollback            the operator's rollback of the recorded apply
//                       through autotune/apply.uc rollback (write)
//   cron-sync | cron-remove   the scheduling cron line
//
// A run is marked running in the persistent state; the next run finds a
// run that died (crash, kill, reboot), records it in the history and, when
// it died while applying, counts that apply and cools its candidate down.
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/manager.uc <mode> ...
let fs = require("fs");
let resolver = require("routing.resolve");
let policy_module = require("autotune.policy");
let state_module = require("autotune.state");
let groups_module = require("autotune.groups");
let probe_module = require("autotune.probe");
let hysteresis = require("autotune.hysteresis");
let autoapply = require("autotune.autoapply");
let identity = require("core.process_identity");
let catalog = require("autotune.catalog");
let lists_module = require("autotune.lists");
let dpi_strategy = require("core.dpi_strategy");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_FILE = getenv("FORKOP_CONFIG_FILE") || "/etc/config/" + (getenv("FORKOP_CONFIG_NAME") || "forkop");
const CONFIG_PACKAGE = fs.basename(CONFIG_FILE);
const SINGBOX_CONFIG = getenv("FORKOP_AUTOTUNE_SINGBOX_CONFIG") || "";
const UCI = getenv("FORKOP_AUTOTUNE_UCI") || "uci";
const UCI_SAVEDIR = getenv("FORKOP_AUTOTUNE_UCI_SAVEDIR") || "/tmp/.uci";
const TMP_DIR = getenv("FORKOP_AUTOTUNE_TMPDIR") || "/tmp";
const DIG = getenv("FORKOP_AUTOTUNE_DIG") || "dig";
const STATE_DIR = getenv("FORKOP_AUTOTUNE_STATE_DIR") || "/var/run/forkop/autotune";
const WORKER_LOCK = STATE_DIR + "/worker.lock";
// The phase of the running tune (autotune/isolation.uc progress), tmpfs.
const TUNE_PROGRESS = STATE_DIR + "/tune-progress.json";
// The targets of the running run and their states, tmpfs (never the state
// file on flash: it changes with every target).
const RUN_PROGRESS = STATE_DIR + "/run-progress.json";
// A target never measured before is expected to take this long.
const DEFAULT_TUNE_SECONDS = 150;
// Samples of rule-list targets (autotune/lists.uc), tmpfs.
const LIST_CACHE_DIR = STATE_DIR + "/lists";
const STATE_LOCK = STATE_DIR + "/state.lock";
const JOBS_DIR = getenv("FORKOP_AUTOTUNE_JOBS_DIR") || STATE_DIR + "/jobs";
const BIN = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CRONTAB_FILE = getenv("FORKOP_CRONTAB_FILE") || "/etc/crontabs/root";
const CRONTAB = getenv("FORKOP_AUTOTUNE_CRONTAB") || "crontab";
const CRON_MARKER = "# forkop-autotune";
// The cron line only asks "is a run due?"; the policy interval decides.
const CRON_SCHEDULE = "*/15 * * * *";
// A scheduled run that could not start is retried after this delay.
const RETRY_SECONDS = 900;
const JOB_KEEP = 10;
const JOB_STARTING_GRACE = 30;
const APPLY_STATE_FILE = getenv("FORKOP_AUTOTUNE_APPLY_STATE") || "/etc/forkop/autotune-apply.json";
// Stage 5 transaction phases a running manual apply reports.
const APPLY_PHASES = [ "checking", "applying", "verifying", "rolling_back" ];
// A recommendation measured longer ago than this many intervals is stale.
const MANUAL_MAX_AGE_INTERVALS = 2;

function as_string(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    return { status: int(pipe.close()), output: as_string(data) };
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function now() { return time(); }

function config_sections() {
    let text = fs.readfile(CONFIG_FILE);
    return text == null ? null : resolver.parse_config(text);
}

// ---- read-only views -----------------------------------------------------

// A run marked running while nobody holds the worker lock ended without
// finishing: the worker crashed or the router rebooted during the run.
function worker_view(worker) {
    if (type(worker) != "object" || worker.state != "running") return worker;
    let run = null, tune = null;
    try { run = json(fs.readfile(RUN_PROGRESS)); } catch (e) { run = null; }
    try { tune = json(fs.readfile(TUNE_PROGRESS)); } catch (e) { tune = null; }
    // Only the progress of this very run.
    if (type(run) == "object" && run.started_at == worker.started_at)
        worker = { ...worker, progress: run, tune: type(tune) == "object" ? tune : null };
    let handle = fs.open(WORKER_LOCK, "re");
    if (!handle) return { ...worker, state: "crashed" };
    let free = handle.lock("xn");
    if (free) handle.lock("u");
    handle.close();
    return free ? { ...worker, state: "crashed" } : worker;
}

// A Stage 3-5 tool, invoked as its lock identity requires; its JSON output.
function run_tool(name, args, env) {
    let r = capture([ ...(env ? [ "env", ...env ] : []), "ucode", "-L", LIB_DIR, LIB_DIR + "/autotune/" + name + ".uc", ...args ]);
    let parsed = null;
    try { parsed = json(r.output); } catch (e) { parsed = null; }
    return type(parsed) == "object" ? parsed : null;
}

// The recorded Stage 5 apply as the page shows it: the group and candidate
// it changed, how it ended, whether it still waits for a decision
// (resolved: false; null when the apply tool gave no answer) and whether the
// operator can roll it back now: its candidate is still the configuration
// (an unreadable record is settled by a rollback), no apply runs and there
// is a snapshot to return to (a rollback without one can only fail), and
// whether the rule still runs a strategy that never passed its check.
// Nothing of the configuration itself (hashes, options, targets) is shown.
function apply_summary() {
    if (fs.stat(APPLY_STATE_FILE) == null) return null;
    let st = run_tool("apply", [ "status" ]);
    let s = st != null && type(st.state) == "object" ? st.state : null;
    if (s == null)
        return { phase: null, reason: "apply_status_unavailable", group: null, candidate: null, finished_at: null,
            resolved: null, diagnosis: null, in_progress: false, rollback: false, unverified_strategy: false };
    let open = index(APPLY_PHASES, s.phase) >= 0;
    let in_progress = open && st.autotune_lock_held === true;
    let candidate_active = st.diagnosis == "candidate_active" &&
        (open || s.phase == "applied" || s.phase == "needs_attention" || (s.phase == "failed" && s.reason == "interrupted_after_apply"));
    return {
        phase: type(s.phase) == "string" ? s.phase : null,
        reason: type(s.reason) == "string" ? s.reason : null,
        group: type(s.mutation) == "object" && state_module.valid_id(s.mutation.section) ? s.mutation.section : null,
        candidate: match(as_string(s.selected), /^[a-z0-9_]{1,32}$/) != null ? s.selected : null,
        finished_at: type(s.finished_at) == "int" ? s.finished_at : null,
        resolved: st.resolved === true,
        diagnosis: type(st.diagnosis) == "string" ? st.diagnosis : null,
        in_progress,
        rollback: !in_progress && st.rollback_source_present === true && (s.unreadable === true || candidate_active),
        // The rule still runs a strategy that never passed its check, on a
        // configuration edited since: nothing confirms it as last known
        // working, so applies wait (autotune/apply.uc status).
        unverified_strategy: st.unverified_strategy === true
    };
}

// The tune resolves the target itself and needs the real addresses, never
// the FakeIP answers of production DNS: the resolver of the target, else the
// first plain IPv4 bootstrap or upstream DNS server of Forkop.
function resolver_for(t, sections) {
    if (t.resolver) return { ip: t.resolver, source: "target" };
    let settings = resolver.settings_of(sections);
    for (let key in [ "bootstrap_dns_server", "dns_server" ]) {
        let values = settings[key];
        for (let v in type(values) == "array" ? values : [ values ])
            if (probe_module.valid_ipv4(trim(as_string(v)))) return { ip: trim(as_string(v)), source: "settings" };
    }
    return null;
}

function singbox_config(sections) {
    return resolver.load_json(SINGBOX_CONFIG != "" ? SINGBOX_CONFIG : resolver.singbox_config_path(sections));
}

// The targets measured: host targets as they are, a rule-list target as its
// member targets "<id>__<n>" (autotune/lists.uc). A list that gives no
// member, or a disabled one, stays one entry { list_error } that the groups
// show as outside. { targets, lists: { id: list view } }.
function expand_targets(sections, configured) {
    let targets = [], lists = {}, local = null;
    for (let t in configured) {
        if (t.rule_set == null) { push(targets, t); continue; }
        if (!t.enabled) { push(targets, { ...t, host: t.rule_set, list_error: "target_disabled" }); continue; }
        if (local == null) local = lists_module.local_rule_sets(singbox_config(sections));
        let dns = resolver_for(t, sections);
        let view = lists_module.expand(t, local[t.rule_set], dns ? dns.ip : null, LIST_CACHE_DIR, TMP_DIR, now());
        lists[t.id] = view;
        if (length(view.members) == 0) { push(targets, { ...t, host: t.rule_set, list_error: view.error || "list_has_no_domains" }); continue; }
        for (let i = 0; i < length(view.members); i++)
            push(targets, { id: lists_module.member_id(t.id, i + 1), host: view.members[i], enabled: true,
                resolver: t.resolver, parent: t.id });
    }
    return { targets, lists };
}

// The cached summary of a target, when it was measured for its host now: a
// list member keeps its id when the sample changes.
function summary_of(state, t) {
    let s = state.targets[t.id];
    return type(s) == "object" && (t.parent == null || s.host == t.host) ? s : null;
}

// Local lists the routing sends to an enabled DPI rule, for the target
// editor: [{ tag, rule, label }].
function rule_lists(sections, config) {
    let local = lists_module.local_rule_sets(config), seen = {}, result = [];
    let rules = type(config) == "object" && type(config.route) == "object" && type(config.route.rules) == "array" ? config.route.rules : [];
    for (let r in rules) {
        if (type(r) != "object" || (r.action || "route") != "route" || r.rule_set == null) continue;
        let s = resolver.section_for_outbound(sections, r.outbound);
        if (s == null || !dpi_strategy.is_dpi_action(s.options.action)) continue;
        for (let tag in type(r.rule_set) == "array" ? r.rule_set : [ r.rule_set ]) {
            if (local[tag] == null || seen[tag]) continue;
            seen[tag] = true;
            push(result, { tag, rule: s.name, label: as_string(s.options.label) || s.name });
        }
    }
    return result;
}

// The domains a list target can measure, for choosing pinned domains: only
// lists the routing sends to a DPI rule. At most LIST_DOMAINS_MAX are sent.
const LIST_DOMAINS_MAX = 2000;
function list_domains(tag) {
    tag = as_string(tag);
    if (!lists_module.valid_tag(tag)) return { status: "failed", reason: "invalid_rule_set" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let config = singbox_config(sections);
    if (length(filter(rule_lists(sections, config), (l) => l.tag == tag)) == 0) return { status: "failed", reason: "invalid_rule_set" };
    let d = lists_module.domains(lists_module.local_rule_sets(config)[tag], TMP_DIR);
    if (d.error) return { status: "failed", reason: d.error, rule_set: tag };
    return { status: "ok", rule_set: tag, total: length(d.domains), skipped: d.skipped,
        truncated: length(d.domains) > LIST_DOMAINS_MAX, domains: slice(d.domains, 0, LIST_DOMAINS_MAX) };
}

function status() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    let state = state_module.read();
    let expanded = expand_targets(sections, read.targets);
    return {
        status: "ok",
        policy: read.policy,
        errors: read.errors,
        // Configured targets, then the members of rule-list targets (parent).
        targets: [
            ...map(read.targets, (t) => ({ ...t, last: t.rule_set == null ? summary_of(state, t) : null,
                list: expanded.lists[t.id] || null })),
            ...map(filter(expanded.targets, (t) => t.parent != null), (t) => ({ ...t, last: summary_of(state, t) }))
        ],
        lists: rule_lists(sections, singbox_config(sections)),
        groups: state.groups,
        next_run_at: state.next_run_at,
        worker: worker_view(state.worker),
        recovered_at: state.recovered_at,
        state_recovered: state.recovered_from || null,
        apply: apply_summary()
    };
}

function target(id) {
    if (!state_module.valid_id(id)) return { status: "failed", reason: "invalid_target" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let known = filter(expand_targets(sections, policy_module.read(sections).targets).targets, (t) => t.id == id && t.list_error == null);
    if (length(known) == 0) return { status: "failed", reason: "unknown_target" };
    let state = state_module.read();
    let last = summary_of(state, known[0]);
    return { status: "ok", target: known[0], last, full: last != null ? state_module.load_full(id) : null };
}

// ---- groups ----------------------------------------------------------------

// How production resolves the target: the system resolver, as clients and
// autotune apply do. FakeIP when every answer is in the FakeIP range.
function production_dns(host) {
    let answers = [];
    for (let line in split(capture([ DIG, "+short", "+time=2", "+tries=1", host, "A" ]).output, "\n")) {
        line = trim(line);
        if (probe_module.valid_ipv4(line)) push(answers, line);
    }
    let fake = filter(answers, (a) => resolver.is_fakeip(a));
    return { answers: length(answers), ip: length(answers) > 0 ? answers[0] : null,
        fakeip: length(answers) > 0 && length(fake) == length(answers) };
}

// Targets classified into groups and the group results from the cached
// target summaries. Strategy identities only, never raw strategies.
function compute_groups(sections, targets, state) {
    let config = singbox_config(sections);
    let groups = {}, outside = [];
    for (let t in targets) {
        if (t.list_error != null) { push(outside, { id: t.id, host: t.host, reason: t.list_error, detail: null }); continue; }
        if (!t.enabled) { push(outside, { id: t.id, host: t.host, reason: "target_disabled", detail: null }); continue; }
        let dns = production_dns(t.host);
        // A target names no device: a rule limited to devices owns it for
        // those devices, and the group says so (source_scoped).
        let r = resolver.resolve(config, sections, resolver.target(t.host, dns.ip, { fakeip: dns.fakeip, assume_rule_source: true }));
        let c = groups_module.classify(dns, r);
        if (c.in_group == null) { push(outside, { id: t.id, host: t.host, reason: c.reason, detail: c.detail || null }); continue; }
        let g = groups[c.in_group];
        if (g == null) {
            let section = resolver.find_section(sections, c.in_group);
            g = groups[c.in_group] = { label: c.label, targets: [], current: r.dpi ? r.dpi.strategy : null,
                custom: r.dpi ? r.dpi.custom : null, fingerprint: groups_module.fingerprint(section), result: null,
                source_scoped: false };
        }
        if (c.source_scoped) g.source_scoped = true;
        push(g.targets, t.id);
    }
    for (let name, g in groups)
        g.result = groups_module.aggregate(map(g.targets, (id) => ({ id, summary: summary_of(state, filter(targets, (t) => t.id == id)[0]) })), g.current);
    return { groups, outside };
}

function groups() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    return { status: "ok", ...compute_groups(sections, expand_targets(sections, read.targets).targets, state_module.read()) };
}

// ---- cron ----------------------------------------------------------------------

function cron_line() {
    return CRON_SCHEDULE + " " + BIN + " autotune_if_due >/dev/null 2>&1 " + CRON_MARKER;
}

// Only the autotune line is added or removed; every other line stays as is.
function cron_write(enabled) {
    let existing = fs.readfile(CRONTAB_FILE);
    // A crontab that exists but cannot be read is never rewritten.
    if (existing == null && fs.stat(CRONTAB_FILE) != null) return { status: "failed", reason: "crontab_unreadable" };
    existing = as_string(existing);
    let lines = split(existing, "\n"), text = "";
    if (length(lines) > 0 && lines[length(lines) - 1] == "") pop(lines);
    for (let line in lines) if (index(line, CRON_MARKER) < 0) text += line + "\n";
    if (enabled) text += cron_line() + "\n";
    if (text == existing) return { status: "ok", enabled, changed: false };
    let tmp = trim(capture([ "mktemp", TMP_DIR + "/forkop-autotune-cron.XXXXXX" ]).output);
    if (tmp == "") return { status: "failed", reason: "tempfile_unavailable" };
    let ok = fs.writefile(tmp, text) != null && success([ CRONTAB, tmp ]);
    fs.unlink(tmp);
    return ok ? { status: "ok", enabled, changed: true } : { status: "failed", reason: "crontab_failed" };
}

function cron_sync() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    return cron_write(policy_module.read(sections).policy.mode != "off");
}

function cron_remove() { return cron_write(false); }

// ---- policy and targets (write) -----------------------------------------------

function ensure_state_dir() {
    for (let dir in [ fs.dirname(STATE_DIR), STATE_DIR ])
        if (fs.stat(dir) == null && !fs.mkdir(dir, 0700) && fs.stat(dir) == null) return false;
    return true;
}

// An exclusive flock on a file in the runtime directory; released by the
// kernel when the holder exits, so a crashed worker never leaves it behind.
// Close-on-exec: the tools a run spawns, and the production daemons an
// apply's reload restarts from inside them, must not inherit the lock and
// keep it after the manager died (UC-055).
function flock(path, wait) {
    if (!ensure_state_dir()) return null;
    let handle = fs.open(path, "ae");
    if (!handle) return null;
    if (!handle.lock(wait ? "x" : "xn")) { handle.close(); return null; }
    return handle;
}
function unlock(handle) {
    if (handle) { handle.lock("u"); handle.close(); }
}

// Read-modify-write of the state file, serialized between the worker and the
// target commands.
function with_state(change) {
    let handle = flock(STATE_LOCK, true);
    let state = state_module.read();
    change(state);
    let ok = state_module.write(state);
    unlock(handle);
    return ok;
}

function uncommitted_changes() {
    let st = fs.stat(UCI_SAVEDIR + "/" + CONFIG_PACKAGE);
    return st != null && st.size > 0;
}

// trigger and candidate (a catalog id) only for autotune applies.
function history(kind, status, trigger, candidate) {
    success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", kind, status,
        as_string(trigger), as_string(candidate) ]);
}

// Set/delete UCI values with a private save directory, so the commit carries
// exactly these changes and never anything staged by someone else.
function uci_apply(ops) {
    if (uncommitted_changes()) return { status: "refused", reason: "uncommitted_uci_changes" };
    let dir = trim(capture([ "mktemp", "-d", TMP_DIR + "/forkop-autotune-policy.XXXXXX" ]).output);
    if (dir == "") return { status: "failed", reason: "tempdir_unavailable" };
    let base = [ UCI, "-c", fs.dirname(CONFIG_FILE), "-t", dir ];
    let ok = true;
    for (let op in ops) if (ok) ok = success([ ...base, ...op ]);
    if (ok) ok = success([ ...base, "commit", CONFIG_PACKAGE ]);
    system(command([ "rm", "-rf", dir ]));
    return ok ? { status: "ok" } : { status: "failed", reason: "uci_failed" };
}

function policy_set(key, value) {
    let checked = policy_module.check(key, value);
    if (checked.error) return { status: "failed", reason: checked.error, option: as_string(key) };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let previous = policy_module.read(sections).policy;
    let ops = [];
    if (filter(sections, (s) => s.type == "autotune" && s.name == "autotune")[0] == null)
        push(ops, [ "set", CONFIG_PACKAGE + ".autotune=autotune" ]);
    push(ops, [ "set", CONFIG_PACKAGE + ".autotune." + key + "=" + as_string(checked.value) ]);
    let result = uci_apply(ops);
    if (result.status != "ok") return result;
    let cron = null;
    if (key == "mode") {
        if (previous.mode != checked.value) history("autotune_mode", "success");
        cron = cron_sync().status;
    }
    return { status: "ok", option: key, value: checked.value, previous: previous[key], cron };
}

// Every state entry of a target: its own and those of its list members.
function forget_target(state, id) {
    for (let key in keys(state.targets))
        if (key == id || substr(key, 0, length(id) + 2) == id + "__") delete state.targets[key];
}

function target_set(id, host, enabled, resolver_ip, rule_set, sample, pins) {
    if (!policy_module.valid_target_id(id)) return { status: "failed", reason: "invalid_target_id" };
    host = lc(as_string(host));
    rule_set = as_string(rule_set);
    sample = as_string(sample);
    pins = uniq(filter(map(split(as_string(pins), /[ ,]+/), (p) => lc(trim(p))), (p) => p != ""));
    let list = rule_set != "";
    if (list) {
        if (host != "") return { status: "failed", reason: "host_and_rule_set" };
        if (!lists_module.valid_tag(rule_set)) return { status: "failed", reason: "invalid_rule_set" };
        if (sample != "" && !lists_module.valid_sample(sample)) return { status: "failed", reason: "invalid_sample" };
        if (length(pins) > lists_module.MAX_SAMPLE || length(filter(pins, (p) => !probe_module.valid_host(p))) > 0)
            return { status: "failed", reason: "invalid_pin" };
    }
    else if (!probe_module.valid_host(host)) return { status: "failed", reason: "invalid_host" };
    enabled = enabled == null || as_string(enabled) == "" ? "1" : as_string(enabled);
    if (index([ "0", "1" ], enabled) < 0) return { status: "failed", reason: "invalid_enabled" };
    resolver_ip = as_string(resolver_ip);
    if (resolver_ip != "" && !probe_module.valid_ipv4(resolver_ip)) return { status: "failed", reason: "invalid_resolver" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let existing = filter(sections, (s) => s.name == id)[0];
    if (existing != null && existing.type != "autotune_target") return { status: "failed", reason: "id_in_use" };
    if (existing == null && length(filter(sections, (s) => s.type == "autotune_target")) >= policy_module.MAX_TARGETS)
        return { status: "refused", reason: "too_many_targets" };
    let path = CONFIG_PACKAGE + "." + id;
    // uci delete of a missing option fails: only delete what exists.
    let ops = [ [ "set", path + "=autotune_target" ], [ "set", path + ".enabled=" + enabled ] ];
    let drop = (option) => { if (existing != null && existing.options[option] != null) push(ops, [ "delete", path + "." + option ]); };
    if (resolver_ip != "") push(ops, [ "set", path + ".resolver=" + resolver_ip ]);
    else drop("resolver");
    drop("pin");
    if (list) {
        drop("host");
        push(ops, [ "set", path + ".rule_set=" + rule_set ]);
        if (sample != "") push(ops, [ "set", path + ".sample=" + sample ]); else drop("sample");
        for (let p in pins) push(ops, [ "add_list", path + ".pin=" + p ]);
    } else {
        drop("rule_set");
        drop("sample");
        push(ops, [ "set", path + ".host=" + host ]);
    }
    let result = uci_apply(ops);
    if (result.status != "ok") return result;
    // Results measured for another host or list say nothing about the new one.
    if (existing != null && (lc(as_string(existing.options.host)) != host || as_string(existing.options.rule_set) != rule_set))
        with_state((state) => forget_target(state, id));
    if (list)
        return { status: "ok", target: { id, host: null, rule_set, sample: sample != "" ? int(sample) : lists_module.DEFAULT_SAMPLE,
            pins, enabled: enabled == "1", resolver: resolver_ip || null } };
    return { status: "ok", target: { id, host, enabled: enabled == "1", resolver: resolver_ip || null } };
}

function target_remove(id) {
    if (!policy_module.valid_target_id(id)) return { status: "failed", reason: "invalid_target_id" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let existing = filter(sections, (s) => s.name == id && s.type == "autotune_target")[0];
    if (existing == null) return { status: "failed", reason: "unknown_target" };
    let result = uci_apply([ [ "delete", CONFIG_PACKAGE + "." + id ] ]);
    if (result.status != "ok") return result;
    with_state((state) => forget_target(state, id));
    return { status: "ok", removed: id };
}

// ---- scheduled runs ----------------------------------------------------------

let interrupted = false;

function script(name) { return LIB_DIR + "/autotune/" + name + ".uc"; }
function self_pid() { return as_string(fs.readlink("/proc/self")); }

// Whatever makes a measurement now unsafe or meaningless, as the apply tool
// itself reports it (read-only). for_apply: an apply also waits for an
// explicit start after an explicit stop (D-15, UC-056); measuring does not.
function blocker(for_apply) {
    let s = run_tool("apply", [ "status" ]);
    if (s == null) return "apply_status_unavailable";
    if (for_apply && s.service_stopped === true) return "service_stopped";
    // A guard a failed lifecycle transition kept: only a restart removes it.
    if (s.runtime_guard === true) return "runtime_guard_active";
    if (length(s.guards || []) > 0) return "dpi_guard_present";
    if (s.snapshot_operation) return "snapshot_operation_active";
    if (s.service_action) return s.service_action;
    if (s.autotune_lock_held) return "autotune_in_progress";
    if (type(s.state) == "object" && s.resolved === false) return "apply_unresolved";
    return null;
}


function tune_target(t, probes, dns_resolver) {
    // The policy value is an upper bound: a run has a fixed number of source
    // ports, shared by every supported candidate (isolation.uc tune).
    fs.unlink(TUNE_PROGRESS);
    return run_tool("isolation", [ "tune", t.host, "max:" + as_string(probes), dns_resolver ], [ "FORKOP_AUTOTUNE_PROGRESS=" + TUNE_PROGRESS ]) ||
        { status: "failed", reason: "tune_output_invalid" };
}

// Groups of this run: every group, one named group, or for a scheduled run
// one group in turn, so a run stays short and every group gets its turn.
function choose(names, scope, rotation) {
    names = sort(names);
    if (scope == "all") return names;
    if (scope == "auto") return length(names) > 0 ? [ names[rotation % length(names)] ] : [];
    return index(names, scope) >= 0 ? [ scope ] : null;
}

// The results go into the state as it is now: a target changed or removed
// during the run keeps what the target commands left.
function merge(updates) {
    return with_state((state) => {
        let sections = config_sections();
        // Without the configuration nothing can be checked: only the run
        // itself is recorded.
        if (sections != null) {
            let targets = expand_targets(sections, policy_module.read(sections).targets).targets;
            for (let id, summary in updates.targets) {
                let t = filter(targets, (x) => x.id == id)[0];
                if (t != null && t.host == summary.host) state.targets[id] = summary;
            }
            for (let name, group in updates.groups) state.groups[name] = group;
            // A disabled rule keeps its group (and its cooldowns); a deleted
            // one does not.
            state_module.prune(state, map(targets, (t) => t.id),
                map(filter(sections, (s) => s.type == "section"), (s) => s.name));
        }
        // Apply records are kept whatever else changed: they are the budget.
        for (let a in updates.applies) push(state.applies, a);
        state.worker = updates.worker;
        if (updates.rotation != null) state.rotation = updates.rotation;
        if (updates.next_run_at != null) state.next_run_at = updates.next_run_at;
    });
}

// One confirmed recommendation through the Stage 5 transaction: plan from
// the representative's tune output of this run, then apply (snapshot,
// guarded reload, production verification, automatic rollback). Returns the
// apply record for the state.
// trigger: "schedule" (autonomous, mode auto) or "manual" (the operator's
// explicit apply, mode recommend). A manual apply never counts against the
// daily limit of autonomous applies; everything else is the same.
function apply_group(name, aggregate, full, dns_resolver, trigger) {
    let manual = trigger == "manual";
    let record = { at: now(), group: name, candidate: aggregate.candidate, representative: aggregate.representative,
        status: "not_applied", reason: null, counted: false, trigger: manual ? "manual" : "automatic" };
    let reason = blocker(true);
    if (reason != null) { record.reason = reason; return record; }
    // The policy is read again: the mode may have been switched off while
    // the targets were measured.
    let sections = config_sections();
    if (sections == null || policy_module.read(sections).policy.mode != (manual ? "recommend" : "auto")) { record.reason = "mode_changed"; return record; }
    let dir = trim(capture([ "mktemp", "-d", TMP_DIR + "/forkop-autotune-apply.XXXXXX" ]).output);
    if (dir == "") { record.reason = "tempdir_unavailable"; return record; }
    let selection = dir + "/selection.json", plan_file = dir + "/plan.json";
    let plan = fs.writefile(selection, sprintf("%J\n", full)) != null ? run_tool("apply", [ "plan", selection, dns_resolver ]) : null;
    if (plan == null) record.reason = "plan_unavailable";
    else if (plan.status == "no_change_required") { record.status = "no_change_required"; record.reason = plan.reason; }
    else if (plan.status != "ready") record.reason = "plan_" + as_string(plan.status) + ":" + as_string(plan.reason);
    // The plan must change exactly the rule and candidate this group
    // confirmed; routing edits since the classification make it void.
    else if (type(plan.owner) != "object" || plan.owner.section != name) record.reason = "owner_changed";
    else if (plan.selected != aggregate.candidate) record.reason = "plan_candidate_differs";
    else if (fs.writefile(plan_file, sprintf("%J\n", plan)) == null) record.reason = "plan_write_failed";
    else {
        // A crash from here on leaves an apply of unknown outcome; the next
        // run counts it and cools the candidate down (recover_crashed_run).
        with_state((state) => {
            if (type(state.worker) == "object")
                state.worker = { ...state.worker, phase: "applying", group: name, candidate: aggregate.candidate, phase_at: now() };
        });
        let result = run_tool("apply", [ "apply", plan_file, dns_resolver ]);
        let o = autoapply.outcome(result);
        record.status = o.status;
        record.reason = type(result) == "object" ? result.reason || null : "apply_output_invalid";
        record.counted = manual ? false : o.counted;
        record.attempted = o.counted;
        record.outcome = o;
        if (o.history != null) history("autotune_apply", o.history, record.trigger, aggregate.candidate);
    }
    system(command([ "rm", "-rf", dir ]));
    return record;
}

// Temporary selection/plan directories of a run that died; only called
// with the worker lock held, so none of them belongs to a live run.
function remove_stale_apply_dirs() {
    for (let name in fs.lsdir(TMP_DIR) || [])
        if (match(name, /^forkop-autotune-apply\.[A-Za-z0-9]+$/) != null)
            system(command([ "rm", "-rf", TMP_DIR + "/" + name ]));
}

// Marks this run as running in the state (flash), so a crash or a reboot
// during the run is found by the next one. A previous run still marked
// running died: it is recorded, and an apply it was doing counts against
// the daily limit and cools its candidate down, since its outcome is not
// known (autotune/apply.uc itself keeps the transaction recoverable).
// A manual apply (kind "apply") is marked the same way; its crash cools the
// candidate down but is not counted against the autonomous daily limit.
function begin_run(trigger, scope, started, policy, extra) {
    let crashed = null, previous = null;
    with_state((state) => {
        previous = state.worker;
        if (type(state.worker) == "object" && state.worker.state == "running") {
            crashed = { ...state.worker, state: "crashed", detected_at: now() };
            if (crashed.phase == "applying" && state_module.valid_id(crashed.group)) {
                let manual = crashed.kind == "apply";
                push(state.applies, { at: int(crashed.phase_at) || now(), group: crashed.group, candidate: crashed.candidate,
                    representative: null, status: "unknown", reason: "worker_crashed_during_apply", counted: !manual,
                    attempted: true, trigger: manual ? "manual" : "automatic" });
                let g = type(state.groups[crashed.group]) == "object" ? state.groups[crashed.group] : hysteresis.empty_group();
                g = hysteresis.start_cooldown(g, crashed.candidate, policy.cooldown_seconds, now());
                g.pending = null;
                g.ready = false;
                state.groups[crashed.group] = g;
            }
        }
        let pid = self_pid();
        state.worker = { state: "running", pid, ticks: identity.start_ticks(pid), trigger, scope, started_at: started,
            phase: "measuring", ...(extra || {}) };
    });
    if (crashed != null) history("autotune_run", "failure");
    return { crashed, previous };
}

function run_locked(scope, trigger) {
    let started = now();
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections), policy = read.policy;
    let crashed = begin_run(trigger, scope, started, policy).crashed;
    remove_stale_apply_dirs();
    let local = state_module.read();
    // A state recovered from a corrupt file in this very run.
    let recovered_at = local.recovered_at != null ? local.recovered_at : local.recovered_from != null ? started : null;
    let updates = { targets: {}, groups: {}, applies: [], worker: null, rotation: null, next_run_at: null };
    let report = {}, tuned = [], unmeasured = [], outside = [], chosen = [], stop = null, results = {}, applied = null;
    let unknown_group = false;

    let reason = blocker();
    if (reason == null) {
        let measured = expand_targets(sections, read.targets).targets;
        let computed = compute_groups(sections, measured, local);
        outside = computed.outside;
        chosen = choose(keys(computed.groups), scope, local.rotation);
        if (chosen == null) { unknown_group = true; chosen = []; }
        // What the page shows while the run goes: every target of the run in
        // order, its state and result, and how long it is expected to take
        // (its last measurement, else a default).
        let items = [];
        for (let name in chosen)
            for (let id in computed.groups[name].targets) {
                let t = filter(measured, (x) => x.id == id)[0];
                let last = summary_of(local, t);
                push(items, { id, host: t.host, parent: t.parent || null, group: name, state: "pending",
                    expected_s: last != null && int(last.duration_s) > 0 ? int(last.duration_s) : DEFAULT_TUNE_SECONDS });
            }
        let set_item = (id, change) => {
            for (let item in items) if (item.id == id) for (let k, v in change) item[k] = v;
            let tmp = RUN_PROGRESS + ".tmp";
            if (fs.writefile(tmp, sprintf("%J
", { started_at: started, total: length(items),
                done: length(filter(items, (i) => i.state == "done" || i.state == "skipped")), items })) != null)
                fs.rename(tmp, RUN_PROGRESS);
        };
        if (length(items) > 0) set_item(null, {});
        for (let name in chosen) {
            let g = computed.groups[name];
            for (let id in g.targets) {
                if (interrupted) { stop = "interrupted"; break; }
                stop = blocker();
                if (stop != null) break;
                let t = filter(measured, (x) => x.id == id)[0];
                let dns_resolver = resolver_for(t, sections);
                if (dns_resolver == null) {
                    push(unmeasured, { id, reason: "resolver_missing" });
                    set_item(id, { state: "skipped", reason: "resolver_missing" });
                    continue;
                }
                let begun = now();
                set_item(id, { state: "running", started_at: begun });
                let result = tune_target(t, policy.probes, dns_resolver.ip);
                // Neither says anything about the target: nothing is recorded.
                if (result.status == "busy") { stop = "autotune_in_progress"; break; }
                if (result.status == "interrupted") { stop = "interrupted"; break; }
                updates.targets[id] = state_module.record_tune(local, id, result,
                    { host: t.host, group: name, fingerprint: g.fingerprint }, now());
                updates.targets[id].duration_s = now() - begun;
                set_item(id, { state: "done", finished_at: now(), status: result.status, selected: result.selected || null,
                    confidence: result.confidence || null, reason: result.reason || null });
                results[id] = { full: result, resolver: dns_resolver.ip };
                push(tuned, id);
            }
            if (stop != null) break;
            // Only what this run measured counts: a cached result never
            // confirms a recommendation a second time.
            let aggregate = groups_module.aggregate(map(g.targets, (id) => ({ id, summary: updates.targets[id] || null })), g.current);
            let observed = hysteresis.observe(local.groups[name], { ...aggregate, fingerprint: g.fingerprint }, policy, now());
            let was_ready = type(local.groups[name]) == "object" && local.groups[name].ready === true;
            if (observed.ready && !was_ready) history("autotune_recommendation", "success");
            let group = { ...observed.group, label: g.label, targets: g.targets, current: g.current, source_scoped: g.source_scoped,
                events: observed.events, ready: observed.ready, required: observed.required, result: aggregate };
            // At most one production change per run.
            let decision = applied != null ? { apply: false, reason: "one_apply_per_run" } : autoapply.decide({
                policy, trigger, group, result: aggregate, custom: g.custom, applies: local.applies, now: now(),
                cooldown_until: hysteresis.cooldown_until(group, aggregate.candidate), recovered_at });
            if (decision.apply && results[aggregate.representative] == null) decision = { apply: false, reason: "representative_not_measured" };
            group.decision = { reason: decision.reason, at: now() };
            if (decision.apply) {
                let rep = results[aggregate.representative];
                applied = apply_group(name, aggregate, rep.full, rep.resolver, trigger);
                group.last_apply = applied;
                if (applied.outcome != null && applied.outcome.cooldown)
                    group = hysteresis.start_cooldown(group, aggregate.candidate, policy.cooldown_seconds, now());
                if (applied.outcome != null && applied.outcome.reset) { group.pending = null; group.ready = false; }
                push(local.applies, applied);
                push(updates.applies, applied);
            }
            local.groups[name] = updates.groups[name] = group;
            report[name] = { result: aggregate, events: observed.events, ready: observed.ready, required: observed.required,
                decision: decision.reason, apply: decision.apply ? applied : null };
        }
        reason = stop;
    }

    let result = reason == null ? "completed" : reason == "interrupted" ? "interrupted" : "skipped";
    if (unknown_group) { result = "failed"; reason = "unknown_group"; }
    else if (result == "completed" && length(chosen) == 0) reason = "no_groups";
    // An unfinished group keeps its turn.
    if (scope == "auto" && result == "completed" && length(chosen) > 0) updates.rotation = local.rotation + 1;
    if (trigger == "schedule")
        updates.next_run_at = result == "completed" ? started + policy.interval_seconds : now() + RETRY_SECONDS;
    updates.worker = { state: "finished", trigger, scope, started_at: started, finished_at: now(), result, reason,
        groups: chosen, tuned, unmeasured, applied: applied != null ? applied.status : null,
        recovered: crashed != null ? { started_at: crashed.started_at, trigger: crashed.trigger, phase: crashed.phase,
            group: crashed.group || null } : null };
    merge(updates);
    fs.unlink(RUN_PROGRESS);
    fs.unlink(TUNE_PROGRESS);
    if (unknown_group) return { status: "failed", reason: "unknown_group", group: scope };
    return { status: "ok", result, reason, trigger, scope, groups: report, tuned, unmeasured, outside,
        applied, recovered: updates.worker.recovered, next_run_at: updates.next_run_at };
}

function run(scope, trigger) {
    scope = as_string(scope);
    if (scope != "all" && scope != "auto" && !state_module.valid_id(scope)) return { status: "failed", reason: "invalid_scope" };
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { status: "busy", reason: "autotune_worker_running" };
    let output = run_locked(scope, trigger || "manual");
    unlock(lock);
    return output;
}

// The cron entry: a run when autotune is enabled and the interval passed.
function if_due() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    if (read.policy.mode == "off") return { status: "ok", result: "skipped", reason: "mode_off" };
    let state = state_module.read();
    if (state.next_run_at != null && now() < state.next_run_at)
        return { status: "ok", result: "skipped", reason: "not_due", next_run_at: state.next_run_at };
    if (length(filter(read.targets, (t) => t.enabled)) == 0) return { status: "ok", result: "skipped", reason: "no_targets" };
    return run("auto", "schedule");
}

// ---- manual apply ------------------------------------------------------------
//
// The operator's explicit apply of a confirmed recommendation (mode
// recommend). The caller names only the group: the candidate, the current
// strategy, the owner and the measurement all come from the state and are
// checked again against the configuration and the routing right now. The
// change itself is the Stage 5 plan + apply transaction (apply_group), never
// a lighter path. Every refusal happens before any production change.

// What the stored recommendation of a group says, or why it cannot be
// applied: { reason } or { group, result }.
function manual_recommendation(state, name, policy, at) {
    let g = state.groups[name];
    if (type(g) != "object" || type(g.result) != "object") return { reason: "no_recommendation" };
    let r = g.result;
    if (r.status == "conflict") return { reason: "conflict" };
    if (r.status == "direct_stable" || r.candidate == "direct") return { reason: "direct_not_applicable" };
    if (r.status != "recommendation" || !r.candidate) return { reason: "no_recommendation" };
    if (g.ready !== true || type(g.pending) != "object" || g.pending.candidate != r.candidate) return { reason: "not_confirmed" };
    if (!policy_module.confidence_at_least(r.confidence, policy.min_confidence)) return { reason: "confidence_too_low" };
    let measured = type(g.last) == "object" ? int(g.last.at) : 0;
    if (measured <= 0 || at - measured > MANUAL_MAX_AGE_INTERVALS * int(policy.interval_seconds))
        return { reason: "recommendation_stale" };
    if (hysteresis.in_cooldown(g, r.candidate, at)) return { reason: "candidate_in_cooldown" };
    return { group: g, result: r };
}

// The group as the configuration and the routing define it now must still
// be the one measured: same rule, same targets, same rule options, same
// strategy, and the stored measurements still recommend the same candidate.
function manual_fresh(sections, targets, state, name, stored) {
    let computed = compute_groups(sections, targets, state);
    let now_g = computed.groups[name];
    if (now_g == null) return { reason: "owner_changed" };
    // As for autonomous applies: a custom strategy of the user is kept.
    if (now_g.custom === true) return { reason: "custom_strategy_kept" };
    if (now_g.fingerprint != stored.group.fingerprint) return { reason: "rule_changed" };
    if (as_string(now_g.current) != as_string(stored.group.current)) return { reason: "strategy_changed" };
    if (join(",", sort([ ...now_g.targets ])) != join(",", sort([ ...(stored.group.targets || []) ]))) return { reason: "targets_changed" };
    let r = now_g.result;
    if (r.status != "recommendation" || r.candidate != stored.result.candidate || r.representative == null)
        return { reason: "recommendation_changed" };
    for (let id in now_g.targets) {
        let summary = state.targets[id];
        if (type(summary) == "object" && summary.fingerprint != null && summary.fingerprint != now_g.fingerprint)
            return { reason: "rule_changed" };
    }
    return { group: now_g, result: r };
}

function manual_apply_locked(name, job) {
    let started = now();
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable", group: name };
    let read = policy_module.read(sections), policy = read.policy;
    let refuse = (reason) => ({ status: "refused", result: "refused", reason, group: name });
    if (policy.mode != "recommend") return refuse(policy.mode == "off" ? "mode_off" : "mode_not_recommend");
    let state = state_module.read();
    if (state.recovered_from != null) return refuse("state_recovered");
    let stored = manual_recommendation(state, name, policy, started);
    if (stored.reason) return refuse(stored.reason);
    let candidate = stored.result.candidate;
    let entry = catalog.find(candidate);
    let checked = entry ? catalog.validate_entry(entry) : null;
    if (checked == null || checked.state != "supported" || checked.protocol != "tcp") return refuse("candidate_unsupported");
    let reason = blocker(true);
    if (reason != null) return refuse(reason);

    let begun = begin_run("manual", name, started, policy,
        { kind: "apply", job: job || null, phase: "checking", group: name, candidate, phase_at: started });
    let finish = (output) => {
        with_state((s) => {
            // The last run stays what the status shows; the apply is in the
            // group record and the apply list.
            let prev = begun.previous;
            s.worker = type(prev) == "object" && prev.state == "running" ? { ...prev, state: "crashed", detected_at: now() } : prev;
        });
        return output;
    };

    let measured = expand_targets(sections, read.targets).targets;
    let fresh = manual_fresh(sections, measured, state, name, stored);
    if (fresh.reason) return finish(refuse(fresh.reason));
    let rep = fresh.result.representative;
    let t = filter(measured, (x) => x.id == rep)[0];
    let full = state_module.load_full(rep);
    if (t == null || type(full) != "object" || full.status != "selected" || full.selected != candidate ||
        type(full.target) != "object" || full.target.host != t.host)
        return finish(refuse("measurement_unavailable"));
    let dns_resolver = resolver_for(t, sections);
    if (dns_resolver == null) return finish(refuse("resolver_missing"));

    let record = apply_group(name, fresh.result, full, dns_resolver.ip, "manual");
    with_state((s) => {
        let g = type(s.groups[name]) == "object" ? s.groups[name] : hysteresis.empty_group();
        g.last_apply = record;
        if (record.outcome != null && record.outcome.cooldown)
            g = hysteresis.start_cooldown(g, candidate, policy.cooldown_seconds, now());
        if (record.outcome != null && record.outcome.reset) { g.pending = null; g.ready = false; }
        s.groups[name] = g;
        push(s.applies, record);
    });
    let ran = record.outcome != null || record.status == "no_change_required";
    return finish({ status: record.status == "applied" || record.status == "no_change_required" ? "ok" : ran ? "failed" : "refused",
        result: ran ? record.status : "refused", reason: record.reason, group: name, candidate,
        trigger: "manual", finished_at: now() });
}

function manual_apply(name, job) {
    name = as_string(name);
    if (!state_module.valid_id(name)) return { status: "failed", reason: "invalid_group" };
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { status: "busy", result: "refused", reason: "autotune_worker_running", group: name };
    let output = manual_apply_locked(name, job);
    unlock(lock);
    return output;
}

// ---- operator rollback -------------------------------------------------------
//
// The operator's rollback of the recorded apply (design H.7), through the
// Stage 5 tool: it restores the before-autotune snapshot and proves that the
// previous strategy runs again; an unreadable record returns to
// last-known-working (autotune/apply.uc rollback). Never next to a run or an
// apply of the worker. A rolled back candidate pauses in its group like one
// that failed its verification, and the group shows the rollback as its last
// change, also one that did not finish (needs_attention): the card never
// keeps the outcome of the apply before it. It is no apply of the daily
// budget. restored: the configuration was replaced (an unreadable record
// whose configuration already was last-known-working is only set aside).
function operator_rollback() {
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { status: "busy", result: "refused", reason: "autotune_worker_running" };
    let r = run_tool("apply", [ "rollback" ]) || { status: "failed", reason: "rollback_output_invalid" };
    let group = type(r.mutation) == "object" && state_module.valid_id(r.mutation.section) ? r.mutation.section : null;
    let candidate = match(as_string(r.selected), /^[a-z0-9_]{1,32}$/) != null ? r.selected : null;
    if ((r.status == "rolled_back" || r.status == "needs_attention") && group != null && candidate != null) {
        let sections = config_sections();
        let policy = policy_module.read(sections || []).policy;
        with_state((state) => {
            let g = type(state.groups[group]) == "object" ? state.groups[group] : hysteresis.empty_group();
            g.last_apply = { at: now(), group, candidate, representative: null, status: r.status,
                reason: "operator_rollback", counted: false, attempted: true, trigger: "manual" };
            g = hysteresis.start_cooldown(g, candidate, policy.cooldown_seconds, now());
            g.pending = null;
            g.ready = false;
            state.groups[group] = g;
        });
    }
    unlock(lock);
    return { status: r.status == "rolled_back" ? "ok" : r.status == "busy" ? "busy" : "failed",
        result: as_string(r.status) || "failed", reason: r.reason || null, group, candidate,
        restored: r.status == "rolled_back" && type(r.rollback) == "object" && r.rollback.status == "success", finished_at: now() };
}

// ---- background jobs ---------------------------------------------------------

// Where a running manual apply is: the worker phase, and while the Stage 5
// transaction runs, its phase (only the phase name of the apply record).
function apply_progress(id) {
    let w = state_module.read().worker;
    if (type(w) != "object" || w.kind != "apply" || w.job != id || w.state != "running") return { phase: "starting", apply_phase: null };
    let apply_phase = null;
    if (w.phase == "applying") {
        let data = fs.readfile(APPLY_STATE_FILE), s = null;
        try { s = data == null ? null : json(data); } catch (e) { s = null; }
        if (type(s) == "object" && int(s.started_at) >= int(w.phase_at) - 1 && index(APPLY_PHASES, s.phase) >= 0)
            apply_phase = s.phase;
    }
    return { phase: index([ "checking", "applying" ], w.phase) >= 0 ? w.phase : "checking", apply_phase };
}

function valid_job_id(id) { return match(as_string(id), /^[0-9]{1,12}_[0-9]{1,10}$/) != null; }
function job_path(id) { return JOBS_DIR + "/" + id + ".json"; }
function job_read(id) {
    let data = fs.readfile(job_path(id)), parsed = null;
    try { parsed = data == null ? null : json(data); } catch (e) { parsed = null; }
    return type(parsed) == "object" ? parsed : null;
}
function job_write(job) {
    if (!ensure_state_dir() || (fs.stat(JOBS_DIR) == null && !fs.mkdir(JOBS_DIR, 0700) && fs.stat(JOBS_DIR) == null)) return false;
    let path = job_path(job.id), tmp = path + ".tmp." + self_pid();
    if (fs.writefile(tmp, sprintf("%J\n", job)) == null) { fs.unlink(tmp); return false; }
    if (!fs.rename(tmp, path)) { fs.unlink(tmp); return false; }
    return true;
}
// The newest jobs are kept; ids start with the creation time.
function job_prune() {
    let ids = sort(map(filter(fs.lsdir(JOBS_DIR) || [], (n) => match(n, /^[0-9]+_[0-9]+\.json$/) != null),
        (n) => substr(n, 0, length(n) - 5)), (a, b) => {
        let d = int(split(a, "_")[0]) - int(split(b, "_")[0]);
        return d != 0 ? d : (a < b ? -1 : a > b ? 1 : 0);
    });
    for (let i = 0; i < length(ids) - JOB_KEEP; i++) fs.unlink(job_path(ids[i]));
}

// A job is a run (kind "run", the default of older job files) or a manual
// apply (kind "apply"); both go through the same files and status command.
function job_mode(job) { return job.kind == "apply" ? "apply-job" : "run-job"; }

function job_alive(job) {
    return type(job.pid) == "string" && type(job.ticks) == "string" &&
        identity.matches_record({ pid: job.pid, ticks: job.ticks }, "ucode",
            [ "ucode", "-L", LIB_DIR, script("manager"), job_mode(job), job.id ], false, true) != "";
}

function job_start(kind, scope) {
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let probe = flock(WORKER_LOCK, false);
    if (probe == null) return { status: "busy", reason: "autotune_worker_running" };
    unlock(probe);
    let job = { id: now() + "_" + self_pid(), kind, scope, state: "starting", created_at: now(),
        started_at: null, finished_at: null, pid: null, ticks: null, result: null };
    if (!job_write(job)) return { status: "failed", reason: "job_write_failed" };
    let worker = command([ "ucode", "-L", LIB_DIR, script("manager"), job_mode(job), job.id, scope ]);
    if (system(command([ "sh", "-c", worker + " >/dev/null 2>&1 </dev/null &" ])) != 0) {
        fs.unlink(job_path(job.id));
        return { status: "failed", reason: "job_start_failed" };
    }
    job_prune();
    return { status: "ok", job: job.id };
}

function run_async(scope) {
    scope = as_string(scope);
    if (scope != "all" && !state_module.valid_id(scope)) return { status: "failed", reason: "invalid_scope" };
    return job_start("run", scope);
}

function apply_async(name) {
    name = as_string(name);
    if (!state_module.valid_id(name)) return { status: "failed", reason: "invalid_group" };
    return job_start("apply", name);
}

function run_job(id, scope, kind) {
    let job = valid_job_id(id) ? job_read(id) : null;
    if (job == null || job.state != "starting" || job.scope != scope || (job.kind || "run") != kind)
        return { status: "failed", reason: "unknown_job" };
    job.pid = self_pid();
    job.ticks = identity.start_ticks(job.pid);
    job.state = "running";
    job.started_at = now();
    job_write(job);
    let output = kind == "apply" ? manual_apply(scope, id) : run(scope, "manual");
    job.state = "finished";
    job.finished_at = now();
    job.result = output;
    job_write(job);
    return output;
}

function run_status(id) {
    if (!valid_job_id(id)) return { status: "failed", reason: "invalid_job" };
    let job = job_read(id);
    if (job == null) return { status: "failed", reason: "unknown_job" };
    // A job whose worker is gone without finishing is reported, not rewritten.
    if ((job.state == "running" && !job_alive(job)) ||
        (job.state == "starting" && now() - int(job.created_at) > JOB_STARTING_GRACE))
        job.state = "lost";
    if (job.kind == "apply" && job.state == "running") job.progress = apply_progress(id);
    return { status: "ok", job };
}

// ---- entry ---------------------------------------------------------------

if (sourcepath(1) != null && sourcepath(1) != "")
    return { status, target, groups, list_domains, policy_set, target_set, target_remove, run, if_due, run_async, run_status,
        manual_apply, apply_async, operator_rollback, cron_sync, cron_remove };

let mode = ARGV[0] || "";
let output = null;
if (mode == "status") output = status();
else if (mode == "target") output = target(ARGV[1]);
else if (mode == "groups") output = groups();
else if (mode == "policy-set") output = policy_set(ARGV[1], ARGV[2]);
else if (mode == "target-set") output = target_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "target-remove") output = target_remove(ARGV[1]);
else if (mode == "list-domains") output = list_domains(ARGV[1]);
else if (index([ "run", "if-due", "run-job", "apply", "apply-job" ], mode) >= 0) {
    // A stop request ends the run after the current target.
    if (type(signal) == "function")
        for (let name in [ "SIGINT", "SIGTERM", "SIGHUP" ])
            signal(name, function() { interrupted = true; });
    output = mode == "run" ? run(ARGV[1], "manual") : mode == "if-due" ? if_due() : mode == "apply" ? manual_apply(ARGV[1]) :
        run_job(ARGV[1], ARGV[2], mode == "apply-job" ? "apply" : "run");
}
else if (mode == "run-async") output = run_async(ARGV[1]);
else if (mode == "apply-async") output = apply_async(ARGV[1]);
else if (mode == "run-status") output = run_status(ARGV[1]);
else if (mode == "rollback") output = operator_rollback();
else if (mode == "cron-sync") output = cron_sync();
else if (mode == "cron-remove") output = cron_remove();
else {
    warn("Usage: autotune/manager.uc <status|target <id>|groups|policy-set <option> <value>|" +
        "target-set <id> <host> [enabled] [resolver] [rule_set] [sample] [pins]|target-remove <id>|list-domains <rule_set>|run <all|group>|if-due|" +
        "run-async <all|group>|run-status <job>|apply <group>|apply-async <group>|rollback|cron-sync|cron-remove>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(output.status == "ok" ? 0 : 1);
