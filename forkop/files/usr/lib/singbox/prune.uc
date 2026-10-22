#!/usr/bin/env ucode

// Only subscription outbounds are candidates. Follow references from the
// generated configuration and from non-subscription outbounds, then keep the
// complete dependency chain (provider groups and detours included). A server
// excluded by every URLTest/Priority group is not loaded by sing-box.
function candidate_references(value, candidates, found) {
    if (type(value) == "string") {
        if (candidates[value])
            found[value] = true;
        return;
    }
    if (type(value) == "array") {
        for (let item in value)
            candidate_references(item, candidates, found);
        return;
    }
    if (type(value) != "object")
        return;
    for (let key, item in value) {
        // An outbound's own tag declares it; it is not a reference to it.
        if (key != "tag")
            candidate_references(item, candidates, found);
    }
}

function unused_outbounds(config, candidate_tags) {
    if (type(config) != "object" || type(config.outbounds) != "array")
        return [];

    let candidates = {};
    let by_tag = {};
    for (let outbound in config.outbounds) {
        let tag = type(outbound) == "object" ? outbound.tag : null;
        if (type(tag) == "string" && candidate_tags[tag]) {
            candidates[tag] = true;
            by_tag[tag] = outbound;
        }
    }
    if (length(keys(candidates)) == 0)
        return [];

    let reachable = {};
    for (let key, value in config)
        if (key != "outbounds")
            candidate_references(value, candidates, reachable);
    for (let outbound in config.outbounds)
        if (type(outbound) == "object" && !candidates[outbound.tag])
            candidate_references(outbound, candidates, reachable);

    // A reachable subscription group may reference a leaf, and a reachable
    // leaf may depend on another via detour. Walk until no dependency remains.
    let pending = keys(reachable);
    while (length(pending) > 0) {
        let tag = pop(pending);
        let references = {};
        candidate_references(by_tag[tag], candidates, references);
        for (let dependency in keys(references)) {
            if (reachable[dependency])
                continue;
            reachable[dependency] = true;
            push(pending, dependency);
        }
    }

    let retained = [];
    let removed = [];
    for (let outbound in config.outbounds) {
        if (type(outbound) == "object" && candidates[outbound.tag] && !reachable[outbound.tag])
            push(removed, outbound.tag);
        else
            push(retained, outbound);
    }
    config.outbounds = retained;
    return removed;
}

return { unused_outbounds };
