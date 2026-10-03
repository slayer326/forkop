#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
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

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function csv_to_json_array(value) {
    value = as_string(value);
    write_compact_string_array(value == "" ? [] : split(value, ","));
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J\n", value));
}

// The generated sing-box config and its copies carry every outbound secret
// (UC-037): the file is created 0600, and an existing file is narrowed to
// 0600 before any content is written, whatever the process umask.
function write_private_json_file(path, value) {
    let fh = fs.open(path, "w", 0600);
    if (fh == null)
        return null;
    if (!fs.chmod(path, 0600)) {
        fh.close();
        return null;
    }
    let written = fh.write(sprintf("%J\n", value));
    fh.close();
    return written;
}

function strip_internal_fields(value) {
    if (type(value) == "array") {
        for (let i = 0; i < length(value); i++)
            value[i] = strip_internal_fields(value[i]);
        return value;
    }

    if (type(value) == "object") {
        for (let key in keys(value)) {
            if (substr(key, 0, 2) == "__") {
                delete value[key];
                continue;
            }
            value[key] = strip_internal_fields(value[key]);
        }
    }

    return value;
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    let text = trim(as_string(value));
    return text == "" ? [] : split(text, " ");
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;
    let value = option(section, key, fallback ? "1" : "0");
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

// Clash API authentication (UC-035): the one predicate shared by the config
// generator (controller secret), every backend request to the controller, the
// validator and the reload signature. A secret is in effect exactly when this
// value is not empty; YACD and WAN access only change where the controller
// listens.
function clash_api_secret(section) {
    return trim(option(section, "yacd_secret_key", ""));
}

// A strong Clash API secret (D-1 (b)): 256 random bits as hex, or null when
// the random source is unavailable. The source is only overridden by tests.
function random_hex_secret() {
    let fh = fs.open(getenv("FORKOP_SECRET_RANDOM_SOURCE") || "/dev/urandom", "r");
    if (fh == null)
        return null;
    let bytes = fh.read(32);
    fh.close();
    return type(bytes) == "string" && length(bytes) == 32 ? hexenc(bytes) : null;
}

function int_option(section, key, fallback) {
    let value = option(section, key, fallback);
    if (match(value, /[^0-9]/))
        return int(fallback, 10);
    return int(value, 10);
}

// Validating a binary (SRS) rule-set: `sing-box rule-set match` parses the
// whole file before it answers, so a truncated, corrupt or non-SRS file still
// fails, and nothing is expanded into JSON on the way. Decompiling a list only
// to throw the JSON away cost about 60 MB of peak RSS for a 40k-domain rule set
// on a 234 MB router, against about 34 MB for this - and the list update is
// what runs out of memory first on a small router.
//
// The probe value does not change the answer: a match and a miss both exit 0.
// It is a name that cannot match, so nothing is printed either.
const SRS_VALIDATION_PROBE = "forkop-srs-validation.invalid";

function srs_validation_args(path) {
    return [ "sing-box", "rule-set", "match", "-f", "binary", as_string(path), SRS_VALIDATION_PROBE ];
}

return {
    as_string,
    read_json_file,
    read_stdin,
    read_stdin_json,
    write_json,
    write_compact_string_array,
    csv_to_json_array,
    write_json_file,
    write_private_json_file,
    strip_internal_fields,
    array_or_empty,
    object_or_empty,
    object_key_count,
    option,
    list_option,
    bool_option,
    int_option,
    clash_api_secret,
    random_hex_secret,
    SRS_VALIDATION_PROBE,
    srs_validation_args
};
