#!/usr/bin/env ucode

let fs = require("fs");
let core_ip = require("core.ip");
let common = require("core.common");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function url_encode(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        let code = ord(c);
        if ((code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            c == "-" || c == "_" || c == "." || c == "~")
            print(c);
        else
            print(sprintf("%%%02X", code));
    }
    print("\n");
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    try {
        return json(read_stdin());
    }
    catch (e) {
        return null;
    }
}

function proxy_response_is_retryable_error() {
    let response = read_stdin();
    return index(response, "<html") == 0 || index(response, "403 Forbidden") >= 0;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function parse_json_object(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return {};
    }

    return type(value) == "object" ? value : {};
}

function parse_json_or_null(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function number_value(value) {
    value = as_string(value);
    return value == "" ? 0 : int(value);
}

function stdin_first_line_last_field() {
    let input = read_stdin();
    if (input == "")
        return;

    let newline = index(input, "\n");
    let line = newline >= 0 ? substr(input, 0, newline) : input;
    let trimmed = trim(line);
    if (trimmed == "") {
        print(line, "\n");
        return;
    }

    let fields = split(trimmed, /[ \t\r\n]+/);
    if (length(fields) > 0 && fields[0] != "")
        print(fields[length(fields) - 1], "\n");
    else
        print("\n");
}

function stdin_first_line() {
    let input = read_stdin();
    if (input == "")
        return;

    let newline = index(input, "\n");
    print(newline >= 0 ? substr(input, 0, newline + 1) : input);
}

function stdin_first_ipv4_line() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\./) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_contains(needle) {
    exit(index(read_stdin(), as_string(needle)) >= 0 ? 0 : 1);
}

function strip_leading_v(value) {
    value = as_string(value);
    print(substr(value, 0, 1) == "v" ? substr(value, 1) : value, "\n");
}

function uci_show_value(line) {
    let equals = index(as_string(line), "=");
    if (equals < 0)
        return "";

    let value = substr(line, equals + 1);
    let next_equals = index(value, "=");
    if (next_equals >= 0)
        value = substr(value, 0, next_equals);

    return replace(value, /['" ]/g, "");
}

function string_starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function uci_show_list_value(value) {
    return trim(replace(as_string(value), /['"]/g, ""));
}

function firewall_rules_from_uci_show(data) {
    let prefix = "firewall.";
    let sections = {};
    let order = [];

    for (let line in split(as_string(data), "\n")) {
        let equals = index(as_string(line), "=");
        if (equals < 0)
            continue;

        let key = substr(line, 0, equals);
        let raw_value = substr(line, equals + 1);
        if (!string_starts_with(key, prefix))
            continue;

        let rest = substr(key, length(prefix));
        if (index(rest, ".") < 0) {
            if (uci_show_list_value(raw_value) == "rule") {
                if (sections[key] == null)
                    sections[key] = {};
                push(order, key);
            }
            continue;
        }

        let option_dot = rindex(key, ".");
        let section = substr(key, 0, option_dot);
        let option = substr(key, option_dot + 1);
        if (sections[section] == null)
            sections[section] = {};
        sections[section][option] = uci_show_list_value(raw_value);
    }

    let rules = [];
    for (let section in order)
        push(rules, sections[section] || {});

    return rules;
}

function first_two_dot_fields(value) {
    let parts = split(as_string(value), ".");
    return length(parts) >= 2 ? parts[0] + "." + parts[1] : as_string(value);
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function value_in_list(values, needle) {
    for (let value in values)
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function network_endpoint_host_warnings(octets) {
    let cloudflare_octets = whitespace_values(octets);

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "endpoint_host") < 0)
            continue;

        let host = uci_show_value(line);
        if (host == "")
            continue;

        if (host == "engage.cloudflareclient.com") {
            print("engage\t", host, "\n");
            continue;
        }

        if (value_in_list(cloudflare_octets, first_two_dot_fields(host)))
            print("prefix\t", host, "\n");
    }
}

function network_wireguard_route_allowed_peers() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "wireguard_") < 0 || index(line, ".route_allowed_ips=") < 0)
            continue;
        if (uci_show_value(line) != "1")
            continue;

        let route_option = index(line, ".route_allowed_ips=");
        if (route_option > 0)
            print(substr(line, 0, route_option), "\n");
    }
}

// Masked UCI views (global_check masked, read-only role). Allowlist: only
// the options below keep their value, every other option or list value is
// replaced by MASKED, so a new secret-bearing option fails closed. Keep these
// tables and the functions below identical to the frontend copy in
// fe-app-forkop/src/forkop/tabs/diagnostic/helpers/maskDiagnostics.ts.
const UCI_MASKED_VALUE = "MASKED";

// Flags, enums, intervals, section references, display names and paths of
// Forkop's own files. Links, credentials, DNS servers and user domains/IPs
// are deliberately absent.
let uci_safe_options = {
    action: true, active_check_interval: true, applied_migrations: true, auto_hwid: true,
    auto_user_agent: true, badwan_monitored_interfaces: true, badwan_reload_delay: true,
    cache_path: true, check_interval: true, check_timeout: true, community_lists: true,
    component_update_check_enabled: true, component_update_check_interval: true,
    conditions_text_mode: true, config_path: true, config_version: true, connection_type: true,
    detect_server_country: true, direct_proxy_enabled: true, direct_proxy_port: true,
    disable_quic: true, dns_check_interval: true, dns_check_timeout: true,
    dns_detour_enabled: true, dns_detour_section: true, dns_failover_failure_threshold: true,
    dns_recovery_check_interval: true, dns_rewrite_ttl: true, dns_strategy: true, dns_type: true,
    domain_resolver_dns_type: true, domain_resolver_enabled: true, dont_touch_dhcp: true,
    download_components_via_proxy: true, download_components_via_proxy_section: true,
    download_lists_via_proxy: true, download_lists_via_proxy_section: true,
    download_subscriptions_via_proxy: true, download_via_proxy_enabled: true,
    download_via_proxy_section: true, enable_badwan_interface_monitoring: true,
    enable_output_network_interface: true, enable_yacd: true, enable_yacd_wan_access: true,
    enabled: true, exclude_countries: true, exclude_ntp: true, exclude_outbounds: true,
    exclude_regex: true, fastest_check_interval: true, filter_mode: true, group: true,
    hide_detour_outbounds: true, hide_urltest_group_outbounds: true, idle_timeout: true,
    include_countries: true, include_outbounds: true, include_regex: true,
    include_subnets: true, include_urltest_groups: true, interface: true, interfaces: true,
    interrupt_exist_connections: true, label: true, list_update_enabled: true, log_level: true,
    mixed_proxy_auth_enabled: true, mixed_proxy_enabled: true, mixed_proxy_port: true,
    name: true, node_prefix: true, order: true, outbound_detour_enabled: true,
    outbound_detour_section: true, output_network_interface: true, pick_fastest: true,
    pin_dashboard: true, ports: true, prefix_nodes: true, priority_groups: true,
    proxy_config_type: true, recovery_check_interval: true, resolve_real_ip_for_routing: true,
    rule: true, secondary_rule_sets: true, section: true, show_dashboard_metadata: true,
    shutdown_correctly: true, sort_by_latency: true, source_network_interfaces: true,
    subscription_update_enabled: true, subscription_update_interval: true,
    switch_to_faster_same_priority: true, tag: true, tolerance: true,
    torrserver_direct_enabled: true, update_interval: true, urltest_check_interval: true,
    urltest_enabled: true, urltest_exclude_countries: true, urltest_filter_mode: true,
    urltest_include_countries: true, urltest_tolerance: true, urltests: true,
    user_domain_list_type: true
};

// Options that are safe only in one section type: the WAN interface of
// /etc/config/network and dnsmasq of /etc/config/dhcp.
let uci_safe_section_options = {
    interface: {
        auto: true, defaultroute: true, delegate: true, demand: true, device: true,
        disabled: true, force_link: true, ifname: true, ip6assign: true, ipv6: true,
        keepalive: true, metric: true, mtu: true, multipath: true, norelease: true,
        peerdns: true, proto: true, reqaddress: true, reqprefix: true, type: true
    },
    dnsmasq: {
        allservers: true, authoritative: true, boguspriv: true, cachesize: true, confdir: true,
        dnsforwardmax: true, domain: true, domainneeded: true, ednspacket_max: true,
        expandhosts: true, filter_a: true, filter_aaaa: true, filterwin2k: true, leasefile: true,
        local: true, localise_queries: true, localservice: true, localuse: true, logqueries: true,
        nonegcache: true, nonwildcard: true, noresolv: true, port: true, readethers: true,
        rebind_localhost: true, rebind_protection: true, resolvfile: true, sequential_ip: true,
        server: true, strictorder: true
    }
};

// URL-valued options: the scheme, host and path stay visible, userinfo,
// query and fragment are masked.
let uci_url_options = {
    domain_ip_lists: true, health_url: true, latency_test_url: true, local_domain_lists: true,
    local_subnet_lists: true, mirror_base_url: true, remote_domain_lists: true,
    remote_subnet_lists: true, rule_set: true, rule_set_with_subnets: true, testing_url: true,
    urltest_testing_url: true
};

// scheme://userinfo@host/path?query#fragment -> userinfo, query and
// fragment masked; with mask_path the path too. A value that is not an
// http(s) URL or a plain local path is masked completely.
function mask_url_value(value, mask_path) {
    value = as_string(value);
    let parts = match(value, /^([A-Za-z][A-Za-z0-9+.-]*:\/\/)?([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/);
    if (parts == null)
        return UCI_MASKED_VALUE;

    let scheme = as_string(parts[1]);
    let authority = as_string(parts[2]);
    let path = as_string(parts[3]);
    // Without a scheme, userinfo can hide in what looks like a path
    // ("//user@host", "https:/user@host").
    if (scheme == "" && (substr(value, 0, 2) == "//" || index(value, "@") >= 0))
        return UCI_MASKED_VALUE;
    let at = rindex(authority, "@");
    if (at >= 0)
        authority = UCI_MASKED_VALUE + "@" + substr(authority, at + 1);
    if (mask_path && path != "" && path != "/")
        path = "/" + UCI_MASKED_VALUE;
    return scheme + authority + path + (parts[4] != null ? "?" + UCI_MASKED_VALUE : "") +
        (parts[5] != null ? "#" + UCI_MASKED_VALUE : "");
}

function mask_http_url_value(value) {
    let scheme = match(as_string(value), /^([A-Za-z][A-Za-z0-9+.-]*):\/\//);
    if (scheme != null && index([ "http", "https" ], lc(scheme[1])) < 0)
        return UCI_MASKED_VALUE;
    return mask_url_value(value, false);
}

// Scans UCI value text from the given quote state; returns the quote that is
// still open at the end (null when closed), the unquoted value and whether a
// trailing comment follows it.
function uci_value_scan(text, quote) {
    let result = "";
    let comment = false;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (quote == "'") {
            if (c == "'") quote = null; else result += c;
        }
        else if (quote == "\"") {
            if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
            else if (c == "\"") quote = null;
            else result += c;
        }
        else if (c == "'" || c == "\"") quote = c;
        else if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
        else if (c == "#") { comment = true; break; }
        else if (c != " " && c != "\t" && c != "\r") result += c;
    }
    return { quote, value: result, comment };
}

function uci_mask_state() {
    return { quote: null, section_type: "" };
}

function uci_option_safe(state, name) {
    let extra = uci_safe_section_options[state.section_type];
    return uci_safe_options[name] || (extra != null && extra[name]);
}

// The option prefix with a re-quoted value (a trailing comment is dropped).
function uci_quoted_line(prefix, value) {
    return prefix + "'" + replace(value, /'/g, "'\\''") + "'";
}

// Masks one UCI line. Lines that are not UCI (and are not the continuation
// of a masked multi-line value) are returned as null, the caller decides.
function mask_uci_line(state, line) {
    line = as_string(line);
    let indent = match(line, /^[ \t]*/)[0];

    if (state.quote != null) {
        let closing = state.quote;
        state.quote = uci_value_scan(line, state.quote).quote;
        return indent + UCI_MASKED_VALUE + (state.quote == null ? closing : "");
    }

    let header = match(line, /^[ \t]*(#[ \t#]*)?config[ \t]+([A-Za-z0-9_-]+)([ \t]+['"]?[A-Za-z0-9_-]+['"]?)?[ \t]*$/);
    if (header != null) {
        if (header[1] == null)
            state.section_type = header[2];
        return line;
    }

    let option = match(line, /^([ \t]*(#[ \t#]*)?(option|list)[ \t]+([A-Za-z0-9_-]+)[ \t]*)(.*)$/);
    if (option != null) {
        let name = option[4];
        let scan = uci_value_scan(option[5], null);
        if (scan.quote == null && uci_option_safe(state, name))
            return scan.comment ? uci_quoted_line(option[1], scan.value) : line;
        if (scan.quote == null && uci_url_options[name])
            return uci_quoted_line(option[1], mask_http_url_value(scan.value));
        state.quote = scan.quote;
        return option[1] + "'" + UCI_MASKED_VALUE + (scan.quote == null ? "'" : "");
    }

    if (match(line, /^[ \t]*$/) != null)
        return line;
    if (match(line, /^[ \t]*#/) != null)
        return indent + "# " + UCI_MASKED_VALUE;
    return null;
}

// Whole UCI file: anything that is not UCI syntax is masked too.
function mask_uci_text_line(state, line) {
    let masked = mask_uci_line(state, line);
    return masked != null ? masked : match(as_string(line), /^[ \t]*/)[0] + UCI_MASKED_VALUE;
}

function file_lines(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    data = as_string(data);
    let lines = split(data, "\n");
    if (length(lines) > 0 && lines[length(lines) - 1] == "")
        pop(lines);
    return lines;
}

function wan_config_masked(path) {
    let in_wan = false;
    let state = uci_mask_state();

    for (let line in file_lines(path)) {
        let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
        if (state.quote == null && length(fields) > 0 && fields[0] == "config")
            in_wan = length(fields) >= 3 && fields[1] == "interface" && fields[2] == "'wan'";

        let masked = mask_uci_text_line(state, line);
        if (in_wan)
            print(masked, "\n");
    }
}

function forkop_config_masked(path) {
    let state = uci_mask_state();
    for (let line in file_lines(path))
        print(mask_uci_text_line(state, line), "\n");
}

function dhcp_dnsmasq_config(path) {
    let data = fs.readfile(path);
    let in_dnsmasq = false;

    if (data == null)
        exit(1);

    let lines = split(as_string(data), "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (i == length(lines) - 1 && line == "" && substr(as_string(data), length(data) - 1) == "\n")
            continue;

        if (match(as_string(line), /^config /) != null) {
            let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
            in_dnsmasq = length(fields) >= 2 && fields[1] == "dnsmasq";
        }

        if (in_dnsmasq)
            print(line, "\n");
    }
}

function only_digits(value) {
    value = as_string(value);
    return value != "" && match(value, /^[0-9]+$/) != null;
}

function firewall_port_token_contains(token, port) {
    token = as_string(token);
    port = as_string(port);

    let dash = index(token, "-");
    let colon = index(token, ":");
    if (dash < 0 && colon < 0)
        return token == port;

    let separator = dash >= 0 ? dash : colon;
    let start = substr(token, 0, separator);
    let end = substr(token, separator + 1);
    if (!only_digits(start) || !only_digits(end) || !only_digits(port))
        return false;

    port = int(port);
    return port >= int(start) && port <= int(end);
}

function firewall_port_spec_contains(spec, port) {
    spec = as_string(spec);
    if (spec == "")
        return true;

    for (let token in split(replace(spec, /,/g, " "), /[ \t\r\n]+/))
        if (token != "" && firewall_port_token_contains(token, port))
            return true;

    return false;
}

function firewall_proto_spec_contains(spec, proto) {
    spec = as_string(spec);
    proto = as_string(proto);
    if (spec == "")
        return true;

    for (let token in split(spec, /[ \t\r\n]+/)) {
        if (token == "all" || token == "any" || token == "tcpudp" || token == "tcp/udp" || token == proto)
            return true;
    }

    return false;
}

function firewall_rules_allow_port_proto(rules, port, proto) {
    for (let rule in rules) {
        let enabled = as_string(rule.enabled);
        if (enabled != "" && enabled != "1")
            continue;

        if (uc(as_string(rule.target)) != "ACCEPT")
            continue;

        let src = as_string(rule.src);
        if (src != "" && src != "wan" && src != "*")
            continue;

        let dest = as_string(rule.dest);
        if (dest != "" && dest != "*")
            continue;

        let src_port = as_string(rule.src_port);
        if (src_port != "" && src_port != "*")
            continue;

        if (as_string(rule.family) == "ipv6")
            continue;

        if (!firewall_proto_spec_contains(rule.proto, proto))
            continue;

        if (!firewall_port_spec_contains(rule.dest_port, port))
            continue;

        return true;
    }

    return false;
}

function firewall_port_open_for_proto(port, proto) {
    return firewall_rules_allow_port_proto(firewall_rules_from_uci_show(read_stdin()), port, proto);
}

function firewall_required_protocols_open(port, required_proto) {
    let rules = firewall_rules_from_uci_show(read_stdin());

    for (let proto in whitespace_values(required_proto))
        if (!firewall_rules_allow_port_proto(rules, port, proto))
            return false;

    return true;
}

function server_required_inbound_proto(protocol) {
    protocol = as_string(protocol);
    if (protocol == "json_inbound")
        print("\n");
    else
        print(protocol == "hysteria2" ? "udp" : "tcp", "\n");
}

function server_runtime_type_for_protocol(protocol) {
    protocol = as_string(protocol);
    if (protocol == "json_inbound")
        print("\n");
    else if (protocol == "mtproto")
        print("mtproxy\n");
    else
        print(protocol, "\n");
}

function arg_bool(value) {
    return value === true || value == "true" || value == "1" || value == 1;
}

function arg_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9-]/))
        return 0;
    return int(value);
}

function flag_is_one(value) {
    return as_string(value) == "1";
}

function flag_is_true(value) {
    return value == true || as_string(value) == "true" || as_string(value) == "1";
}

function server_listen_requires_firewall(listen, wan_ip, listen_is_public) {
    listen = as_string(listen);
    wan_ip = as_string(wan_ip);

    if (listen == "0.0.0.0" || listen == "::" || arg_bool(listen_is_public))
        return true;
    for (let ip in whitespace_values(wan_ip))
        if (ip == listen)
            return true;
    return false;
}

function object_value(object, key) {
    return type(object) == "object" && object[key] != null ? as_string(object[key]) : "";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function str_startswith(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function str_endswith(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function str_remove_suffix(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return str_endswith(value, suffix) ? substr(value, 0, length(value) - length(suffix)) : value;
}

function contains(values, needle) {
    needle = as_string(needle);
    for (let value in array_or_empty(values))
        if (as_string(value) == needle)
            return true;
    return false;
}

function netstat_fields(line) {
    line = trim(as_string(line));
    return line == "" ? [] : split(line, /[ \t\r\n]+/);
}

function netstat_addr_port(addr) {
    addr = as_string(addr);
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, colon + 1) : addr;
}

function netstat_addr_host(addr) {
    addr = as_string(addr);
    if (substr(addr, 0, 1) == "[") {
        let end = index(addr, "]");
        return end > 0 ? substr(addr, 1, end - 1) : addr;
    }
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, 0, colon) : addr;
}

function ipv4_like(value) {
    return match(as_string(value), /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) != null;
}

function valid_ipv4(value) {
    return core_ip.valid_ipv4(value, false, false);
}

function valid_public_ipv4(value) {
    value = as_string(value);
    if (!valid_ipv4(value))
        return false;

    let parts = split(value, ".");
    let a = int(parts[0]);
    let b = int(parts[1]);

    if (a == 0 || a == 10 || a == 127 || a >= 224)
        return false;
    if (a == 169 && b == 254)
        return false;
    if (a == 192 && (b == 168 || b == 0 || b == 2))
        return false;
    if (a == 198 && (b == 18 || b == 19 || b == 51))
        return false;
    if (a == 203 && b == 0)
        return false;
    if (a == 100 && b >= 64 && b <= 127)
        return false;
    if (a == 172 && b >= 16 && b <= 31)
        return false;

    return true;
}

function valid_public_ipv6(value) {
    value = lc(as_string(value));
    if (!core_ip.valid_ipv6(value))
        return false;
    if (value == "::" || value == "::1")
        return false;
    if (substr(value, 0, 4) == "fe80" || substr(value, 0, 2) == "ff")
        return false;
    if (substr(value, 0, 2) == "fc" || substr(value, 0, 2) == "fd")
        return false;
    if (index(value, "2001:db8") == 0)
        return false;
    return true;
}

function valid_public_ip(value) {
    return valid_public_ipv4(value) || valid_public_ipv6(value);
}

function netstat_addr_matches(addr, listen, port) {
    addr = as_string(addr);
    listen = as_string(listen);
    port = as_string(port);

    if (netstat_addr_port(addr) != port)
        return false;

    let host = netstat_addr_host(addr);
    if (host == "0.0.0.0" || host == "::")
        return true;
    if (listen == "0.0.0.0")
        return ipv4_like(host);
    if (listen == "::")
        return index(host, ":") >= 0;

    return host == listen;
}

function netstat_server_port_listening_in_data(data, listen, port, proto) {
    listen = as_string(listen);
    port = as_string(port);
    proto = as_string(proto);

    for (let line in split(as_string(data), "\n")) {
        let fields = netstat_fields(line);
        if (length(fields) < 4 || !str_startswith(fields[0], proto))
            continue;

        if (netstat_addr_matches(fields[3], listen, port))
            return true;
    }

    return false;
}

function netstat_server_port_listening(listen, port, proto) {
    return netstat_server_port_listening_in_data(read_stdin(), listen, port, proto);
}

function server_required_ports_listening(listen, port, required_proto) {
    let data = read_stdin();

    for (let proto in whitespace_values(required_proto))
        if (!netstat_server_port_listening_in_data(data, listen, port, proto))
            return false;

    return true;
}

function sorted_unique_strings(values) {
    let result = [];
    for (let value in values) {
        value = as_string(value);
        if (value != "" && !contains(result, value))
            push(result, value);
    }

    sort(result, function(a, b) {
        return a < b ? -1 : (a > b ? 1 : 0);
    });
    return result;
}

function sorted_unique_lines(values) {
    let result = [];
    for (let value in values) {
        value = as_string(value);
        if (!contains(result, value))
            push(result, value);
    }

    sort(result, function(a, b) {
        return a < b ? -1 : (a > b ? 1 : 0);
    });
    return result;
}

function stdin_sorted_unique_space_list() {
    let lines = split(read_stdin(), "\n");

    if (length(lines) > 0 && lines[length(lines) - 1] == "")
        lines = slice(lines, 0, length(lines) - 1);

    print(replace(join(" ", sorted_unique_lines(lines)), /[ \t\r\n]+$/, ""), "\n");
}

function public_host_flags(public_host, public_host_ips, wan_ip, wan_public) {
    let resolved = -1;
    let public_ip = -1;
    let matches_wan = -1;
    let ips = whitespace_values(public_host_ips);

    if (as_string(public_host) != "") {
        if (length(ips) > 0) {
            resolved = 1;
            public_ip = 1;
            for (let ip in ips)
                if (!valid_public_ip(ip))
                    public_ip = 0;

            if (as_string(wan_public) == "1") {
                matches_wan = 0;
                for (let wan in whitespace_values(wan_ip)) {
                    if (contains(ips, wan)) {
                        matches_wan = 1;
                        break;
                    }
                }
            }
        }
        else {
            resolved = 0;
        }
    }

    print(resolved, " ", public_ip, " ", matches_wan, "\n");
}

function netstat_server_port_conflict_owner_list(data, listen, port, proto) {
    let owners = [];
    let line_number = 0;
    let owner_supported = false;

    for (let line in split(as_string(data), "\n")) {
        line_number++;
        if (line_number == 2) {
            owner_supported = index(as_string(line), "PID/Program") >= 0;
            continue;
        }

        if (!owner_supported)
            continue;

        let fields = netstat_fields(line);
        if (length(fields) < 4 || !str_startswith(fields[0], proto) || !netstat_addr_matches(fields[3], listen, port))
            continue;

        let owner = length(fields) > 0 ? as_string(fields[length(fields) - 1]) : "";
        if (owner == "" || owner == "-" || owner == "LISTEN")
            owner = "unknown";
        if (!str_endswith(owner, "/sing-box"))
            push(owners, owner);
    }

    return sorted_unique_strings(owners);
}

function netstat_server_port_conflict_owners(listen, port, proto) {
    print(join(" ", netstat_server_port_conflict_owner_list(read_stdin(), listen, port, proto)), "\n");
}

function server_required_port_conflict_owners(listen, port, required_proto) {
    let data = read_stdin();
    let owners = [];

    for (let proto in whitespace_values(required_proto))
        for (let owner in netstat_server_port_conflict_owner_list(data, listen, port, proto))
            if (!contains(owners, owner))
                push(owners, owner);

    print(join(" ", sorted_unique_strings(owners)), "\n");
}

function nft_line_is_count_element(line) {
    line = trim(as_string(line));
    return line != "" && match(substr(line, 0, 1), /^[0-9]$/) != null;
}

function render_nft_chain_config_blocks() {
    let lines = split(read_stdin(), "\n");

    for (let i = 1; i < length(ARGV); i++) {
        let chain = as_string(ARGV[i]);
        let in_block = false;
        let needle = "chain " + chain + " {";

        for (let line in lines) {
            line = as_string(line);
            if (!in_block && index(line, needle) < 0)
                continue;

            if (!in_block)
                in_block = true;

            if (index(line, "elements") < 0 && !nft_line_is_count_element(line))
                print(line, "\n");

            if (index(line, "}") >= 0)
                in_block = false;
        }
    }
}

function nft_chain_counter_status() {
    let rules_exist = 0;
    let counters = 0;

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "counter") < 0)
            continue;

        rules_exist = 1;
        if (index(line, "packets 0 bytes 0") < 0)
            counters = 1;
    }

    print(rules_exist, " ", counters, "\n");
}

function print_line(value) {
    print(value, "\n");
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function stdin_json() {
    let value = read_stdin_json();
    if (value == null)
        exit(1);
    write_json(value);
}

function json_error(message) {
    write_json({ error: as_string(message) });
}

function mask_ipv6_line(line) {
    let matched = match(line, /([0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+):.*/);
    return matched ? matched[1] + ":XXXX:XXXX:XXXX" : line;
}

function render_proxy_response_ip_mask() {
    let response = read_stdin();
    let lines = split(response, "\n");
    let ipv4_lines = [];
    let ipv6_like = false;

    for (let line in lines) {
        let matched = match(line, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
        if (matched)
            push(ipv4_lines, "X.X.X." + matched[4]);

        if (match(line, /^[0-9a-fA-F:]*::[0-9a-fA-F:]*$/) || match(line, /^[0-9a-fA-F:]+$/))
            ipv6_like = true;
    }

    if (length(ipv4_lines) > 0) {
        for (let line in ipv4_lines)
            print_line(line);
        return;
    }

    if (ipv6_like) {
        for (let i = 0; i < length(lines); i++) {
            if (i == length(lines) - 1 && lines[i] == "")
                continue;
            print_line(mask_ipv6_line(lines[i]));
        }
        return;
    }

    exit(1);
}

function service_status_label(running, enabled) {
    running = arg_number(running);
    enabled = arg_number(enabled);

    if (running == 1)
        return enabled == 1 ? "running & enabled" : "running but disabled";

    return enabled == 1 ? "stopped but enabled" : "stopped & disabled";
}

function write_service_status_json(running, enabled, status_or_dns_configured, dns_configured) {
    if (dns_configured == null)
        dns_configured = status_or_dns_configured;

    write_json({
        running: arg_number(running),
        enabled: arg_number(enabled),
        status: service_status_label(running, enabled),
        dns_configured: arg_number(dns_configured)
    });
}

function stdin_service_status_running() {
    let value = read_stdin_json();
    if (type(value) != "object")
        exit(1);

    exit(number_value(value.running) == 1 ? 0 : 1);
}

function service_list_instance_running(name) {
    let value = object_or_empty(read_stdin_json());
    let service = object_or_empty(value[as_string(name)]);
    let instances = object_or_empty(service.instances);

    for (let key in instances) {
        let instance = object_or_empty(instances[key]);
        if (flag_is_true(instance.running))
            exit(0);
    }

    exit(1);
}

function write_dns_check_json(dns_type, dns_server, dns_status, dns_on_router, bootstrap_dns_server, bootstrap_dns_status, dhcp_config_status, dont_touch_dhcp) {
    write_json({
        dns_type: as_string(dns_type),
        dns_server: as_string(dns_server),
        dns_status: arg_number(dns_status),
        dns_on_router: arg_number(dns_on_router),
        bootstrap_dns_server: as_string(bootstrap_dns_server),
        bootstrap_dns_status: arg_number(bootstrap_dns_status),
        dhcp_config_status: arg_number(dhcp_config_status),
        dont_touch_dhcp: arg_number(dont_touch_dhcp)
    });
}

function write_nft_check_json(table_exist, rules_mangle_exist, rules_mangle_counters, rules_mangle_output_exist, rules_mangle_output_counters, rules_proxy_exist, rules_proxy_counters, rules_other_mark_exist) {
    write_json({
        table_exist: arg_number(table_exist),
        rules_mangle_exist: arg_number(rules_mangle_exist),
        rules_mangle_counters: arg_number(rules_mangle_counters),
        rules_mangle_output_exist: arg_number(rules_mangle_output_exist),
        rules_mangle_output_counters: arg_number(rules_mangle_output_counters),
        rules_proxy_exist: arg_number(rules_proxy_exist),
        rules_proxy_counters: arg_number(rules_proxy_counters),
        rules_other_mark_exist: arg_number(rules_other_mark_exist)
    });
}

function write_sing_box_check_json(sing_box_installed, sing_box_version_ok, sing_box_extended, sing_box_service_exist, sing_box_autostart_disabled, sing_box_process_running, sing_box_ports_listening) {
    write_json({
        sing_box_installed: arg_number(sing_box_installed),
        sing_box_version_ok: arg_number(sing_box_version_ok),
        sing_box_extended: arg_number(sing_box_extended),
        sing_box_service_exist: arg_number(sing_box_service_exist),
        sing_box_autostart_disabled: arg_number(sing_box_autostart_disabled),
        sing_box_process_running: arg_number(sing_box_process_running),
        sing_box_ports_listening: arg_number(sing_box_ports_listening)
    });
}

function write_fakeip_check_json(fakeip_status, fakeip_address) {
    write_json({
        fakeip: arg_bool(fakeip_status),
        IP: as_string(fakeip_address)
    });
}

function fakeip_address_status(address) {
    print(match(as_string(address), /^198\.(18|19)\./) != null ? "true\n" : "false\n");
}

function repeat_char(char, count) {
    let result = "";
    for (let i = 0; i < count; i++)
        result += char;
    return result;
}

function first_field(value, separator) {
    let marker = index(value, separator);
    return marker < 0 ? value : substr(value, 0, marker);
}

function mask_dns_server(value) {
    value = as_string(value);
    if (str_endswith(value, ".dns.nextdns.io")) {
        let nextdns_id = first_field(value, ".");
        print_line(repeat_char("*", length(nextdns_id)) + ".dns.nextdns.io");
        return;
    }

    if (str_startswith(value, "dns.nextdns.io/")) {
        let path = substr(value, length("dns.nextdns.io/"));
        print_line("dns.nextdns.io/" + repeat_char("*", length(path)));
        return;
    }

    // A DoH path or URL userinfo/query can identify the account (UC-002),
    // as can the first label of a private resolver host such as
    // <id>.dns.controld.com or <id>.d.adguard-dns.com.
    let masked = mask_url_value(value, true);
    let host = match(masked, /^([A-Za-z][A-Za-z0-9+.-]*:\/\/)?([^\/?#@]*@)?([^.\/?#:@\[]+)(\.[^\/?#:@]+)(.*)$/);
    if (host != null && length(split(host[4], ".")) >= 4 && match(host[3] + host[4], /^[0-9.]+$/) == null)
        masked = as_string(host[1]) + as_string(host[2]) + UCI_MASKED_VALUE + host[4] + host[5];
    print_line(masked);
}

function render_flag_line(value, key, ok_message, fail_message) {
    print_line((flag_is_one(value[key]) ? ok_message : fail_message));
}

function sing_box_core_label(value) {
    if (flag_is_one(value.sing_box_extended) && flag_is_one(value.sing_box_compressed))
        return "extended compressed";
    if (flag_is_one(value.sing_box_extended))
        return "extended";
    if (flag_is_one(value.sing_box_tiny))
        return "tiny";
    return "";
}

function sing_box_version_note_label(value) {
    if (flag_is_one(value.sing_box_extended) && flag_is_one(value.sing_box_compressed))
        return "compressed";
    if (flag_is_one(value.sing_box_tiny))
        return "tiny";
    return "";
}

function sing_box_version_is_known(version) {
    version = lc(trim(as_string(version)));
    return version != "" &&
        version != "loading" &&
        version != "unknown" &&
        version != "not installed";
}

function format_sing_box_version(value, version) {
    version = as_string(version);
    if (!sing_box_version_is_known(version))
        return version;

    let variant = sing_box_version_note_label(value);
    return variant != "" ? version + " (" + variant + ")" : version;
}

function render_global_sing_box_check() {
    let value = object_or_empty(read_stdin_json());

    render_flag_line(value, "sing_box_installed", "\u2705 Sing-box installed", "\u274c Sing-box installed");
    render_flag_line(value, "sing_box_version_ok", "\u2705 Sing-box version is compatible (newer than 1.12.4)", "\u274c Sing-box version is not compatible (older than 1.12.4)");

    if (flag_is_one(value.sing_box_extended))
        print_line("Sing-box extended detected");
    else
        print_line("Sing-box regular build detected");

    render_flag_line(value, "sing_box_service_exist", "\u2705 Sing-box service exist", "\u274c Sing-box service exist");
    render_flag_line(value, "sing_box_autostart_disabled", "\u2705 Sing-box autostart disabled", "\u274c Sing-box autostart disabled");
    render_flag_line(value, "sing_box_process_running", "\u2705 Sing-box process running", "\u274c Sing-box process running");
    render_flag_line(value, "sing_box_ports_listening", "\u2705 Sing-box listening ports", "\u274c Sing-box listening ports");
}

function render_global_system_info() {
    let value = object_or_empty(read_stdin_json());
    let forkop_version = object_value(value, "forkop_version") || "unknown";
    let luci_app_version = object_value(value, "luci_app_version") || "unknown";
    let sing_box_version = object_value(value, "sing_box_version") || "unknown";
    let openwrt_version = object_value(value, "openwrt_version") || "unknown";
    let device_model = object_value(value, "device_model") || "unknown";

    let sing_box_core = sing_box_core_label(value) || "regular";
    print_line("Sing-box core: " + sing_box_core);

    print_line("\ud83d\udd73\ufe0f Forkop:   " + forkop_version);
    print_line("\ud83d\udd73\ufe0f LuCI App:      " + luci_app_version);
    print_line("\ud83d\udce6 Sing-box:      " + format_sing_box_version(value, sing_box_version));
    print_line("\ud83d\udedc OpenWrt:       " + openwrt_version);
    print_line("\ud83d\udedc Device:        " + device_model);
}

function render_global_fakeip_check() {
    let value = object_or_empty(read_stdin_json());
    let fakeip_address = object_value(value, "IP");

    if (flag_is_true(value.fakeip))
        print_line("\u2705 Sing-box FakeIP DNS works: " + fakeip_address);
    else
        print_line("\u274c Sing-box FakeIP DNS does NOT work");
}

function render_global_dns_check(dont_touch_dhcp) {
    let value = object_or_empty(read_stdin_json());
    let dns_type = object_value(value, "dns_type") || "unknown";
    let dns_server = object_value(value, "dns_server") || "unknown";
    let bootstrap_dns_server = object_value(value, "bootstrap_dns_server");
    let dns_position = number_value(value.dns_server_count) > 1
        ? " (priority " + as_string(number_value(value.dns_server_index) + 1) + "/" + as_string(number_value(value.dns_server_count)) + ")"
        : "";
    let bootstrap_position = number_value(value.bootstrap_dns_server_count) > 1
        ? " (priority " + as_string(number_value(value.bootstrap_dns_server_index) + 1) + "/" + as_string(number_value(value.bootstrap_dns_server_count)) + ")"
        : "";
    let dump_dhcp_config = false;

    if (bootstrap_dns_server != "") {
        print_line((flag_is_one(value.bootstrap_dns_status) ? "\u2705 Bootstrap DNS: " : "\u274c Bootstrap DNS: ") + bootstrap_dns_server + bootstrap_position);
    }

    print_line((flag_is_one(value.dns_status) ? "\u2705 Main DNS: " : "\u274c Main DNS: ") + dns_server + " [" + dns_type + "]" + dns_position);
    print_line(flag_is_one(value.dns_on_router) ? "\u2705 DNS on router" : "\u274c DNS on router");

    if (as_string(dont_touch_dhcp) == "1") {
        print_line("\u26a0\ufe0f dont_touch_dhcp is enabled. \ud83d\udcc4 DHCP config:");
        dump_dhcp_config = true;
    }
    else if (!flag_is_one(value.dhcp_config_status)) {
        print_line("\u274c DHCP configuration differs from template. \ud83d\udcc4 DHCP config:");
        dump_dhcp_config = true;
    }
    else {
        print_line("\u2705 /etc/config/dhcp");
    }

    exit(dump_dhcp_config ? 10 : 0);
}

function render_global_nft_check() {
    let value = read_stdin_json();
    if (type(value) != "object")
        exit(1);

    render_flag_line(value, "table_exist", "\u2705 Table exist", "\u274c Table exist");
    render_flag_line(value, "rules_mangle_exist", "\u2705 Rules mangle exist", "\u274c Rules mangle exist");
    render_flag_line(value, "rules_mangle_counters", "\u2705 Rules mangle counters", "\u26a0\ufe0f  Rules mangle counters");
    render_flag_line(value, "rules_mangle_output_exist", "\u2705 Rules mangle output exist", "\u274c Rules mangle output exist");
    render_flag_line(value, "rules_mangle_output_counters", "\u2705 Rules mangle output counters", "\u26a0\ufe0f  Rules mangle output counters");
    render_flag_line(value, "rules_proxy_exist", "\u2705 Rules proxy exist", "\u274c Rules proxy exist");
    render_flag_line(value, "rules_proxy_counters", "\u2705 Rules proxy counters", "\u26a0\ufe0f  Rules proxy counters");

    if (flag_is_one(value.rules_other_mark_exist))
        print_line("\u26a0\ufe0f  Additional marking rules found:");
    else
        print_line("\u2705 No other marking rules found");
}

function global_nft_other_mark_exists() {
    let value = read_stdin_json();
    exit(type(value) == "object" && flag_is_one(value.rules_other_mark_exist) ? 0 : 1);
}

function nft_ruleset_other_mark_lines(table_name) {
    table_name = as_string(table_name);
    let in_forkop_table = false;

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "table inet " + table_name) >= 0) {
            in_forkop_table = true;
            continue;
        }

        if (match(line, /^table/) != null)
            in_forkop_table = false;

        if (!in_forkop_table && (index(line, "mark set") >= 0 || index(line, "meta mark") >= 0))
            print_line(line);
    }
}

function nft_set_element_count() {
    let value = object_or_empty(read_stdin_json());

    for (let item in array_or_empty(value.nftables)) {
        if (type(item) != "object" || type(item.set) != "object")
            continue;

        print_line(length(array_or_empty(item.set.elem)));
        return;
    }

    print_line("0");
}

function line_contains(line, needle) {
    return index(as_string(line), as_string(needle)) >= 0;
}

function print_lines(lines, start, end) {
    for (let i = start; i < end; i++)
        print_line(lines[i]);
}

function is_udp_unsupported_outbound_log(line) {
    return index(as_string(line), "UDP is not supported by outbound:") >= 0;
}

function render_matching_log_tail(needle, max_lines) {
    let lines = split(read_stdin(), "\n");
    let filtered = [];
    let udp_http_notice_emitted = false;

    for (let line in lines) {
        if (line == "")
            continue;
        if (line_contains(line, needle))
        {
            if (needle == "sing-box" && is_udp_unsupported_outbound_log(line)) {
                if (!udp_http_notice_emitted) {
                    push(filtered, "UDP traffic through HTTP outbounds is not supported by sing-box; repeated UDP warnings for HTTP outbounds are hidden by Forkop.");
                    udp_http_notice_emitted = true;
                }
                continue;
            }

            push(filtered, line);
        }
    }

    if (length(filtered) == 0)
        exit(1);

    max_lines = int(max_lines || "100", 10) || 100;
    let start = length(filtered) > max_lines ? length(filtered) - max_lines : 0;
    print_lines(filtered, start, length(filtered));
}

function render_forkop_logs() {
    let lines = split(read_stdin(), "\n");
    let filtered = [];
    let start = -1;
    let udp_http_notice_emitted = false;

    for (let line in lines) {
        if (line == "")
            continue;
        if (!line_contains(line, "forkop") && !line_contains(line, "sing-box"))
            continue;

        if (line_contains(line, "sing-box") && is_udp_unsupported_outbound_log(line)) {
            if (!udp_http_notice_emitted) {
                push(filtered, "UDP traffic through HTTP outbounds is not supported by sing-box; repeated UDP warnings for HTTP outbounds are hidden by Forkop.");
                udp_http_notice_emitted = true;
            }
            continue;
        }

        if (line_contains(line, "forkop") && line_contains(line, "Starting Forkop"))
            start = length(filtered);

        push(filtered, line);
    }

    if (length(filtered) == 0)
        exit(1);

    if (start >= 0) {
        print_lines(filtered, start, length(filtered));
        return;
    }

    print_line("No 'Starting Forkop' message found, showing last 100 lines");
    start = length(filtered) > 100 ? length(filtered) - 100 : 0;
    print_lines(filtered, start, length(filtered));
}

function file_first_line(path, fallback) {
    let data = fs.readfile(path);
    let result = "";

    if (data != null) {
        let lines = split(as_string(data), "\n");
        if (length(lines) > 0)
            result = str_remove_suffix(as_string(lines[0]), "\r");
    }

    if (result == "")
        result = as_string(fallback);

    print_line(result);
}

function js_var_string_value(path, var_name) {
    let data = fs.readfile(path);
    var_name = as_string(var_name);

    if (data == null || var_name == "")
        return;

    for (let line in split(as_string(data), "\n")) {
        let matched = match(line, /^[ \t]*var[ \t]+([^ \t=]+)[ \t]*=[ \t]*"([^"]*)"/);
        if (matched != null && matched[1] == var_name) {
            print_line(matched[2]);
            return;
        }
    }
}

function key_value_file_value(path, key) {
    let data = fs.readfile(path);
    key = as_string(key);

    if (data == null || key == "")
        return;

    let prefix = key + "=";
    for (let line in split(as_string(data), "\n")) {
        line = str_remove_suffix(as_string(line), "\r");
        if (!str_startswith(line, prefix))
            continue;

        let value = substr(line, length(prefix));
        if (length(value) >= 2) {
            let quote = substr(value, 0, 1);
            if ((quote == "\"" || quote == "'") && str_endswith(value, quote))
                value = substr(value, 1, length(value) - 2);
        }
        print_line(value);
        return;
    }
}

function system_info_cache_valid(path, forkop_version, luci_app_version, ttl, now) {
    let cache = read_json_file(path);
    if (type(cache) != "object")
        return false;

    now = arg_number(now);
    ttl = arg_number(ttl);
    let cached_at = arg_number(cache.generated_at || 0);

    if (now > 0 && cached_at > 0 && ttl > 0 && now - cached_at >= ttl)
        return false;

    return cache.forkop_version == forkop_version && cache.luci_app_version == luci_app_version;
}

// Keys whose values are masked in the masked sing-box config (read-only
// role). Keep identical to SING_BOX_MASKED_KEYS in maskDiagnostics.ts.
let masked_sing_box_keys = {
    access_key_id: true,
    address: true,
    advertise_routes: true,
    api_token: true,
    auth: true,
    auth_key: true,
    auth_str: true,
    client_key: true,
    control_url: true,
    domain: true,
    domain_keyword: true,
    domain_regex: true,
    domain_suffix: true,
    email: true,
    excluded_source_ip_cidr: true,
    exit_node: true,
    extra_headers: true,
    fingerprint: true,
    headers: true,
    host: true,
    hostname: true,
    ip_cidr: true,
    key: true,
    key_id: true,
    listen: true,
    listen_port: true,
    local_address: true,
    mac_key: true,
    obfs: true,
    password: true,
    path: true,
    peer_public_key: true,
    plugin_opts: true,
    pre_shared_key: true,
    private_key: true,
    private_key_passphrase: true,
    public_key: true,
    secret: true,
    secret_access_key: true,
    server: true,
    server_name: true,
    server_port: true,
    server_ports: true,
    service_name: true,
    short_id: true,
    source_ip_cidr: true,
    torrc: true,
    user: true,
    username: true,
    uuid: true
};

// An object with an address (a WireGuard peer) also hides its port; any
// URL string keeps only scheme, host and path (links are masked whole).
function mask_sing_box_value(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value)
            push(result, mask_sing_box_value(item));
        return result;
    }

    if (type(value) == "object") {
        let result = {};
        for (let key, item in value)
            result[key] = masked_sing_box_keys[key] || (key == "port" && value.address != null) ?
                "MASKED" : mask_sing_box_value(item);
        return result;
    }

    if (type(value) == "string" && match(value, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) != null)
        return mask_http_url_value(value);

    return value;
}

function mask_sing_box_config(path) {
    write_json(mask_sing_box_value(read_json_file(path)));
}

function prepare_check_proxy_config(input_path, output_path, cache_path) {
    let config = object_or_empty(read_json_file(input_path));
    config.inbounds = [];
    config.services = [];
    if (type(config.experimental) == "object") {
        if (type(config.experimental.cache_file) == "object")
            config.experimental.cache_file.path = as_string(cache_path);
        delete config.experimental.clash_api;
    }

    // A copy of the full config in /tmp: private like the original (UC-037).
    if (!common.write_private_json_file(output_path, config))
        exit(1);
}

function check_proxy_outbound_tag(config_path, domain) {
    let config = object_or_empty(read_json_file(config_path));
    for (let rule in array_or_empty(config.route && config.route.rules)) {
        if (type(rule) != "object")
            continue;
        if (contains(array_or_empty(rule.domain), domain)) {
            print_line(as_string(rule.outbound || ""));
            return;
        }
    }
}

function http_response_with_status() {
    let lines = split(read_stdin(), "\n");
    let status = length(lines) > 0 ? as_string(lines[length(lines) - 1]) : "";
    let body_lines = length(lines) > 0 ? slice(lines, 0, length(lines) - 1) : [];

    return {
        status_text: status,
        status: int(status || "0", 10) || 0,
        body: join("\n", body_lines)
    };
}

function write_clash_api_error(status, body) {
    let result = {
        success: false,
        http_code: status
    };

    if (body != "")
        result.body = body;

    write_json(result);
    exit(1);
}

function clash_set_group_proxy_result(group_tag, proxy_tag) {
    let response = http_response_with_status();

    if (response.status == 204) {
        write_json({ success: true, group: as_string(group_tag), proxy: as_string(proxy_tag) });
        return;
    }

    if (response.status == 404) {
        write_json({ success: false, error: "group_not_found", message: as_string(group_tag) + " does not exist" });
        exit(1);
    }

    if (response.status == 400) {
        if (line_contains(response.body, "not found"))
            write_json({ success: false, error: "proxy_not_found", message: as_string(proxy_tag) + " not found in group " + as_string(group_tag) });
        else
            write_json({ success: false, error: "bad_request", message: "Invalid request" });
        exit(1);
    }

    write_clash_api_error(response.status, response.body);
}

function clash_close_connection_result(connection_id) {
    let response = http_response_with_status();

    if (response.status == 200 || response.status == 204) {
        write_json({ success: true, connection_id: as_string(connection_id) });
        return;
    }

    if (response.status == 404) {
        write_json({ success: false, error: "connection_not_found", connection_id: as_string(connection_id) });
        exit(1);
    }

    write_clash_api_error(response.status, response.body);
}

function clash_close_all_connections_result() {
    let response = http_response_with_status();

    if (response.status == 200 || response.status == 204) {
        write_json({ success: true });
        return;
    }

    write_clash_api_error(response.status, response.body);
}

function clash_set_group_proxy_payload(proxy_tag) {
    write_json({ name: as_string(proxy_tag) });
}

function clash_proxy_tags_lines(proxy_tags_json) {
    let proxy_tags = parse_json_or_null(proxy_tags_json);
    if (type(proxy_tags) != "array")
        exit(1);

    for (let proxy_tag in proxy_tags) {
        if (type(proxy_tag) != "string" || proxy_tag == "")
            exit(1);
        print(proxy_tag, "\n");
    }
}

function clash_proxy_latencies_result(count, failed) {
    let has_failed = as_string(failed) != "0";
    write_json({
        success: !has_failed,
        count: int(as_string(count || "0"), 10) || 0,
        failed: has_failed
    });
    if (has_failed)
        exit(1);
}

function clash_unknown_action() {
    write_json({
        error: "unknown action",
        available: [
            "get_proxies",
            "get_connections",
            "get_proxy_latency",
            "get_proxy_latencies",
            "get_group_latency",
            "set_group_proxy",
            "close_connection",
            "close_all_connections"
        ]
    });
}

let mode = ARGV[0];

if (mode == "proxy-response-ip-mask")
    render_proxy_response_ip_mask();
else if (mode == "url-encode")
    url_encode(ARGV[1]);
else if (mode == "stdin-json")
    stdin_json();
else if (mode == "stdin-first-line-last-field")
    stdin_first_line_last_field();
else if (mode == "stdin-first-line")
    stdin_first_line();
else if (mode == "stdin-sorted-unique-space-list")
    stdin_sorted_unique_space_list();
else if (mode == "public-host-flags")
    public_host_flags(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "stdin-first-ipv4-line")
    stdin_first_ipv4_line();
else if (mode == "stdin-contains")
    stdin_contains(ARGV[1]);
else if (mode == "strip-leading-v")
    strip_leading_v(ARGV[1]);
else if (mode == "network-endpoint-host-warnings")
    network_endpoint_host_warnings(ARGV[1]);
else if (mode == "network-wireguard-route-allowed-peers")
    network_wireguard_route_allowed_peers();
else if (mode == "wan-config-masked")
    wan_config_masked(ARGV[1]);
else if (mode == "forkop-config-masked")
    forkop_config_masked(ARGV[1]);
else if (mode == "dhcp-dnsmasq-config")
    dhcp_dnsmasq_config(ARGV[1]);
else if (mode == "firewall-port-token-contains")
    exit(firewall_port_token_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "firewall-port-spec-contains")
    exit(firewall_port_spec_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "firewall-proto-spec-contains")
    exit(firewall_proto_spec_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "firewall-port-open")
    exit(firewall_port_open_for_proto(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "firewall-required-protocols-open")
    exit(firewall_required_protocols_open(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "server-required-inbound-proto")
    server_required_inbound_proto(ARGV[1]);
else if (mode == "server-runtime-type-for-protocol")
    server_runtime_type_for_protocol(ARGV[1]);
else if (mode == "server-listen-requires-firewall")
    exit(server_listen_requires_firewall(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "server-port-listening")
    exit(netstat_server_port_listening(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "server-required-ports-listening")
    exit(server_required_ports_listening(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "server-port-conflict-owners")
    netstat_server_port_conflict_owners(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "server-required-port-conflict-owners")
    server_required_port_conflict_owners(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "json-error")
    json_error(ARGV[1]);
else if (mode == "service-status-json")
    write_service_status_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "service-status-running")
    stdin_service_status_running();
else if (mode == "service-list-instance-running")
    service_list_instance_running(ARGV[1]);
else if (mode == "dns-check-json")
    write_dns_check_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]);
else if (mode == "nft-check-json")
    write_nft_check_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]);
else if (mode == "sing-box-check-json")
    write_sing_box_check_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "fakeip-check-json")
    write_fakeip_check_json(ARGV[1], ARGV[2]);
else if (mode == "fakeip-address-status")
    fakeip_address_status(ARGV[1]);
else if (mode == "mask-dns-server")
    mask_dns_server(ARGV[1]);
else if (mode == "global-sing-box-check")
    render_global_sing_box_check();
else if (mode == "global-system-info")
    render_global_system_info();
else if (mode == "global-fakeip-check")
    render_global_fakeip_check();
else if (mode == "global-dns-check")
    render_global_dns_check(ARGV[1]);
else if (mode == "global-nft-check")
    render_global_nft_check();
else if (mode == "global-nft-other-mark-exists")
    global_nft_other_mark_exists();
else if (mode == "nft-ruleset-other-mark-lines")
    nft_ruleset_other_mark_lines(ARGV[1]);
else if (mode == "nft-set-element-count")
    nft_set_element_count();
else if (mode == "nft-chain-config-blocks")
    render_nft_chain_config_blocks();
else if (mode == "nft-chain-counter-status")
    nft_chain_counter_status();
else if (mode == "forkop-logs")
    render_forkop_logs();
else if (mode == "matching-log-tail")
    render_matching_log_tail(ARGV[1], ARGV[2]);
else if (mode == "file-first-line")
    file_first_line(ARGV[1], ARGV[2]);
else if (mode == "js-var-string-value")
    js_var_string_value(ARGV[1], ARGV[2]);
else if (mode == "key-value-file-value")
    key_value_file_value(ARGV[1], ARGV[2]);
else if (mode == "system-info-cache-valid")
    exit(system_info_cache_valid(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
else if (mode == "mask-sing-box-config")
    mask_sing_box_config(ARGV[1]);
else if (mode == "proxy-response-is-retryable-error")
    exit(proxy_response_is_retryable_error() ? 0 : 1);
else if (mode == "prepare-check-proxy-config")
    prepare_check_proxy_config(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "check-proxy-outbound-tag")
    check_proxy_outbound_tag(ARGV[1], ARGV[2]);
else if (mode == "clash-set-group-proxy-result")
    clash_set_group_proxy_result(ARGV[1], ARGV[2]);
else if (mode == "clash-close-connection-result")
    clash_close_connection_result(ARGV[1]);
else if (mode == "clash-close-all-connections-result")
    clash_close_all_connections_result();
else if (mode == "clash-set-group-proxy-payload")
    clash_set_group_proxy_payload(ARGV[1]);
else if (mode == "clash-proxy-tags-lines")
    clash_proxy_tags_lines(ARGV[1]);
else if (mode == "clash-proxy-latencies-result")
    clash_proxy_latencies_result(ARGV[1], ARGV[2]);
else if (mode == "clash-unknown-action")
    clash_unknown_action();
else {
    warn("Usage: diagnostics/status.uc <operation> ...\n");
    exit(1);
}
