"use strict";
"require form";
"require baseclass";
"require fs";
"require network";
"require ui";
"require uci";
"require view.forkop.local_devices as localDevices";
"require view.forkop.main as main";

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;
const ACTION_PROVIDERS_AVAILABILITY_EVENT =
  main.FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT ||
  "forkop:action-providers-availability";
const RULE_SET_ITEM_SETTINGS_KEY = "rule_set_settings";
const ROUTING_ACTIONS = [
  "connection",
  "proxy",
  "outbound",
  "vpn",
  "bypass",
  "block",
  "zapret",
  "zapret2",
  "byedpi",
];
const CONNECTIONS_BLOCKED_INTERFACES = [
  "br-lan",
  "eth0",
  "eth1",
  "wan",
  "phy0-ap0",
  "phy1-ap0",
  "pppoe-wan",
  "lan",
];

function valuesToText(values) {
  if (!values) {
    return "";
  }

  if (Array.isArray(values)) {
    return values.filter(Boolean).join("\n");
  }

  return values ? `${values}` : "";
}

function normalizeOptionValues(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .filter(Boolean)
      .map((item) => `${item}`.trim())
      .filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function getUciSectionName(section) {
  return section && section[".name"] ? section[".name"] : "";
}

function getUciSectionLabel(section) {
  return (section && section.label) || getUciSectionName(section);
}

function isOutboundDetourTargetSection(section, currentSectionId) {
  const sectionName = getUciSectionName(section);
  const action = (section && section.action) || "";

  return (
    sectionName &&
    sectionName !== currentSectionId &&
    section.enabled !== "0" &&
    ["connection", "proxy", "outbound", "vpn"].includes(action)
  );
}

// Cascade is only valid on Connection rules (config/validator.uc aborts
// otherwise). The cascade options are hidden in the modal and kept via
// `retain`, so they are dropped explicitly once the rule stops being one:
// when the modal changes its action from a Connection action to another.
// A save that keeps the action keeps them whatever it is (D-22 b); the
// _hidden_cascade notice says why they fail and offers Clear.
function isOutboundDetourRuleAction(action) {
  return ["connection", "proxy", "outbound", "vpn"].includes(
    `${action || "connection"}`,
  );
}

// The action the rule had when the modal loaded it: when these options
// parse, the action option has already written the chosen one.
function loadOutboundDetourOption(parentLoad) {
  return function (section_id) {
    this.loadedRuleActions = Object.assign({}, this.loadedRuleActions, {
      [section_id]: uci.get(UCI_PACKAGE, section_id, "action"),
    });
    return parentLoad.apply(this, arguments);
  };
}

function parseOutboundDetourOption(parentParse) {
  return function (section_id) {
    const loaded = this.loadedRuleActions?.[section_id];
    const action = this.section.formvalue(section_id, "action");

    if (
      loaded !== undefined &&
      isOutboundDetourRuleAction(loaded) &&
      !isOutboundDetourRuleAction(action)
    ) {
      return Promise.resolve(this.remove(section_id));
    }

    return parentParse.apply(this, arguments);
  };
}

// DNS rules do not match destination IPs and ports, so these fields are
// hidden for them. A DNS rule saved as it is keeps what it stores (the Legacy
// settings notice names it and removes it on request); a rule switched to
// DNS in the modal drops it.
function keepHiddenForDnsRule(option) {
  const remove = option.remove;

  option.load = loadOutboundDetourOption(option.load);
  option.remove = function (section_id) {
    if (
      !this.isActive(section_id) &&
      this.loadedRuleActions?.[section_id] === "dns" &&
      this.section.formvalue(section_id, "action") === "dns"
    ) {
      return;
    }

    return remove.apply(this, arguments);
  };
  return option;
}

function getOutboundDetourTargetSections(currentSectionId) {
  return (uci.sections(UCI_PACKAGE, "section") || []).filter((section) =>
    isOutboundDetourTargetSection(section, currentSectionId),
  );
}

function getDefaultOutboundDetourSection(currentSectionId) {
  const targetSections = getOutboundDetourTargetSections(currentSectionId);

  return targetSections.length ? getUciSectionName(targetSections[0]) : "";
}

function refreshOutboundDetourSectionOptionValues(option, sectionId) {
  option.keylist = [];
  option.vallist = [];

  getOutboundDetourTargetSections(sectionId).forEach((targetSection) => {
    option.value(
      getUciSectionName(targetSection),
      getUciSectionLabel(targetSection),
    );
  });
}

// Hidden cascade settings (UC-041, D-22 b). The Cascade editor is gone, but
// a rule may still keep outbound_detour_enabled/outbound_detour_section from
// an earlier version or the CLI: the generator still applies them and the
// validator refuses them when they cannot work
// (config/validator.uc validate_outbound_detours_rows()).
const CONNECTION_RULE_ACTIONS = ["connection", "proxy", "outbound", "vpn"];

function ruleSectionFlag(section, key, fallback) {
  const value =
    section && section[key] !== undefined && section[key] !== null
      ? backendOptionText(section[key])
      : fallback
        ? "1"
        : "0";

  return ["1", "true", "yes", "on"].includes(value);
}

function isConnectionRuleSection(section) {
  return CONNECTION_RULE_ACTIONS.includes(
    backendOptionText(section && section.action),
  );
}

// Why the validator refuses the cascade of a rule, in its order of checks,
// or "" when it accepts it.
function hiddenCascadeProblem(section_id, target) {
  const rules = {};
  (uci.sections(UCI_PACKAGE, "section") || []).forEach((item) => {
    rules[getUciSectionName(item)] = item;
  });
  const label = (name) => getUciSectionLabel(rules[name]) || name;

  if (!isConnectionRuleSection(rules[section_id])) {
    return _("this rule is not a Connection rule");
  }
  if (!target) {
    return _("no transit rule is selected");
  }
  if (target === section_id) {
    return _("the rule cannot use itself");
  }
  if (!rules[target]) {
    return _("the transit rule “%s” no longer exists").format(target);
  }
  if (!ruleSectionFlag(rules[target], "enabled", true)) {
    return _("the transit rule “%s” is disabled").format(label(target));
  }
  if (!isConnectionRuleSection(rules[target])) {
    return _("the transit rule “%s” is not a Connection rule").format(
      label(target),
    );
  }

  const seen = new Set();
  for (let current = target; current; ) {
    if (current === section_id) {
      return _("the rules connect through each other in a loop");
    }
    const row = rules[current];
    if (
      seen.has(current) ||
      !row ||
      !ruleSectionFlag(row, "enabled", true) ||
      !isConnectionRuleSection(row) ||
      !ruleSectionFlag(row, "outbound_detour_enabled", false)
    ) {
      break;
    }
    seen.add(current);
    current = backendOptionText(row.outbound_detour_section);
  }

  return "";
}

// The stored cascade of a rule, or null. The old editor stored
// outbound_detour_enabled '0' on every Connection rule: that alone is not a
// setting.
function hiddenCascadeState(section_id) {
  const enabled = backendFlag(section_id, "outbound_detour_enabled");
  const target = backendOptionText(
    uci.get(UCI_PACKAGE, section_id, "outbound_detour_section"),
  );

  if (!enabled && !target) {
    return null;
  }

  return {
    enabled,
    target,
    targetLabel:
      getUciSectionLabel(uci.get(UCI_PACKAGE, target)) || target || "—",
    problem: enabled ? hiddenCascadeProblem(section_id, target) : "",
  };
}

function renderHiddenCascadeNotice(option, section_id) {
  const state = option.cascadeStates ? option.cascadeStates[section_id] : null;
  const node = E("div", { class: "alert-message warning fkp-legacy-settings" });

  if (!state) {
    return node;
  }

  // A role that may not change the configuration learns only that the
  // setting exists (D-22 b).
  if (option.map.readonly) {
    node.append(
      E(
        "p",
        {},
        _(
          "This rule has a hidden cascade setting from an earlier version. An administrator can clear it.",
        ),
      ),
    );
    return node;
  }

  let description;
  if (!state.enabled) {
    description = _(
      "This rule keeps a switched-off cascade setting from an earlier version (transit rule “%s”). It has no effect.",
    ).format(state.targetLabel);
  } else if (state.problem) {
    description = _(
      "This rule has a cascade setting from an earlier version, which the editor no longer shows. Applying the configuration fails while it is set: %s.",
    ).format(state.problem);
  } else {
    description = _(
      "This rule has a cascade setting from an earlier version, which the editor no longer shows: servers of this rule connect through the rule “%s”.",
    ).format(state.targetLabel);
  }

  const actions = E("div", { class: "fkp-legacy-settings__actions" });
  const clear = () => {
    // Staged like any other edit of the rule: Save keeps it, Dismiss
    // restores the options (the hidden fields retain what uci holds).
    uci.unset(UCI_PACKAGE, section_id, "outbound_detour_enabled");
    uci.unset(UCI_PACKAGE, section_id, "outbound_detour_section");
    node.textContent = "";
    node.append(
      E(
        "p",
        {},
        _("The cascade setting is cleared. Save the rule to keep the change."),
      ),
    );
  };
  const showActions = () => {
    actions.textContent = "";
    actions.append(
      E(
        "button",
        {
          type: "button",
          class: "btn cbi-button cbi-button-negative",
          click: confirm,
        },
        _("Clear…"),
      ),
    );
  };
  const confirm = () => {
    actions.textContent = "";
    actions.append(
      E(
        "p",
        {},
        _(
          "Clear the cascade setting of this rule? When you save the rule, %s and %s are removed and its servers connect without a transit rule. Nothing else in the rule changes.",
        ).format("outbound_detour_enabled", "outbound_detour_section"),
      ),
      E("div", { class: "fkp-legacy-settings__buttons" }, [
        E(
          "button",
          { type: "button", class: "btn cbi-button", click: showActions },
          _("Cancel"),
        ),
        " ",
        E(
          "button",
          {
            type: "button",
            class: "btn cbi-button cbi-button-negative",
            click: clear,
          },
          _("Clear"),
        ),
      ]),
    );
  };

  showActions();
  // In an array LuCI adds the text as a text node: the label is a UCI value.
  node.append(E("p", {}, [description]), actions);
  return node;
}

function isDnsDetourTargetSection(section, currentSectionId) {
  const sectionName = getUciSectionName(section);
  const action = (section && section.action) || "";

  if (
    !sectionName ||
    sectionName === currentSectionId ||
    section.enabled === "0"
  ) {
    return false;
  }

  if (["connection", "proxy", "outbound", "vpn"].includes(action)) {
    return true;
  }
  if (action === "zapret") {
    return isZapretInstalledForUi();
  }
  if (action === "zapret2") {
    return isZapret2InstalledForUi();
  }
  return action === "byedpi" && isByedpiInstalledForUi();
}

function refreshDnsDetourSectionOptionValues(option, sectionId) {
  option.keylist = [];
  option.vallist = [];

  (uci.sections(UCI_PACKAGE, "section") || [])
    .filter((section) => isDnsDetourTargetSection(section, sectionId))
    .forEach((targetSection) => {
      option.value(
        getUciSectionName(targetSection),
        getUciSectionLabel(targetSection),
      );
    });
}

// A select keeps its saved value even when that value is no longer offered:
// LuCI would show the first choice instead and the next Save would write it
// without the user noticing. The kept choice is labelled, and validation
// refuses it until the user picks another value (UC-008).
function keepUnavailableChoice(option, value, describe) {
  const key = value == null ? "" : `${value}`;

  option.unavailableChoices = {};
  if (!key || (option.keylist || []).includes(key)) {
    return;
  }

  const unavailable = describe(key);
  option.value(key, unavailable.label);
  option.unavailableChoices[key] = unavailable.message;
}

function unavailableChoiceError(option, value) {
  const choices = option.unavailableChoices || {};
  const key = value == null ? "" : `${value}`;

  return Object.prototype.hasOwnProperty.call(choices, key)
    ? choices[key]
    : null;
}

function isActionProviderInstalledForUi(action) {
  switch (action) {
    case "zapret":
      return isZapretInstalledForUi();
    case "zapret2":
      return isZapret2InstalledForUi();
    case "byedpi":
      return isByedpiInstalledForUi();
    default:
      return true;
  }
}

function describeUnavailableSection(name) {
  const target = uci.get(UCI_PACKAGE, name);

  if (!target || target[".type"] !== "section") {
    return {
      label: _("%s (unavailable)").format(name),
      message: _(
        "The selected section no longer exists. Choose another section.",
      ),
    };
  }

  const label = getUciSectionLabel(target);
  if (target.enabled === "0") {
    return {
      label: _("%s (disabled)").format(label),
      message: _(
        "The selected section is disabled. Enable it or choose another section.",
      ),
    };
  }

  if (!isActionProviderInstalledForUi(target.action)) {
    return {
      label: _("%s (provider not installed)").format(label),
      message: _(
        "The DPI provider of the selected section is not installed. Install it in Components or choose another section.",
      ),
    };
  }

  return {
    label: _("%s (unavailable)").format(label),
    message: _(
      "The selected section cannot be used here. Choose another section.",
    ),
  };
}

function dependsOnRoutingAction(option) {
  ROUTING_ACTIONS.forEach((action) => option.depends("action", action));
  return option;
}

function dependsOnRuleConditions(option) {
  const routingConditions = [
    "domain",
    "ip_cidr",
    "community_lists",
    "rule_set",
    "secondary_rule_sets",
    "domain_ip_lists",
    "ports",
  ];
  ROUTING_ACTIONS.forEach((action) =>
    routingConditions.forEach((condition) =>
      option.depends({ action, [condition]: /\S/ }),
    ),
  );
  [
    "domain",
    "community_lists",
    "_dns_rule_set",
    "_dns_domain_ip_lists",
  ].forEach((condition) =>
    option.depends({ action: "dns", [condition]: /\S/ }),
  );
  return option;
}

const ZAPRET_LEGACY_DEFAULT_NFQWS_OPT =
  "--filter-tcp=80 <HOSTLIST> --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin --new --filter-udp=443 <HOSTLIST_NOAUTO> --dpi-desync=fake --dpi-desync-repeats=11 --new --filter-tcp=443 <HOSTLIST> --dpi-desync=multidisorder --dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1";

const ZAPRET_DEFAULT_NFQWS_OPT =
  "--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin";

const ZAPRET2_DEFAULT_NFQWS2_OPT =
  "--filter-tcp=80 --filter-l7=http --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 --new --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6";

const BYEDPI_DEFAULT_CMD_OPTS = "-o 2 --auto=t,r,a,s -d 2";
const ANNOTATED_TEXTAREA_STYLE_ID = "fkp-annotated-textarea-styles";
const CONNECTIONS_DYNLIST_STYLE_ID = "fkp-connections-dynlist-styles";
const NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS = 500;
const NFQWS_VALIDATION_COMMAND = "/usr/bin/forkop";
const nfqwsRemoteValidationCache = new Map();
const nfqwsRemoteValidationInflight = new Map();
const nfqwsRemoteValidationUnavailable = new Map();
const nfqws2RemoteValidationCache = new Map();
const nfqws2RemoteValidationInflight = new Map();
const nfqws2RemoteValidationUnavailable = new Map();
const byedpiRemoteValidationCache = new Map();
const byedpiRemoteValidationInflight = new Map();
const byedpiRemoteValidationUnavailable = new Map();
const BYEDPI_LONG_VALUE_OPTIONS = new Set([
  "--max-conn",
  "--conn-ip",
  "--buf-size",
  "--debug",
  "--def-ttl",
  "--auto",
  "--auto-mode",
  "--cache-ttl",
  "--cache-dump",
  "--timeout",
  "--proto",
  "--hosts",
  "--ipset",
  "--pf",
  "--round",
  "--split",
  "--disorder",
  "--oob",
  "--disoob",
  "--fake",
  "--fake-sni",
  "--ttl",
  "--fake-offset",
  "--fake-data",
  "--fake-tls-mod",
  "--oob-data",
  "--mod-http",
  "--tlsrec",
  "--tlsminor",
  "--udp-fake",
]);
const BYEDPI_LONG_FLAG_OPTIONS = new Set([
  "--md5sig",
  "--tfo",
  "--drop-sack",
  "--no-domain",
  "--no-udp",
]);
const BYEDPI_SHORT_VALUE_OPTIONS = new Set([
  "-c",
  "-I",
  "-b",
  "-x",
  "-g",
  "-A",
  "-L",
  "-u",
  "-y",
  "-T",
  "-K",
  "-H",
  "-j",
  "-V",
  "-R",
  "-s",
  "-d",
  "-o",
  "-q",
  "-f",
  "-n",
  "-t",
  "-O",
  "-l",
  "-Q",
  "-e",
  "-M",
  "-r",
  "-m",
  "-a",
]);
const BYEDPI_SHORT_FLAG_OPTIONS = new Set(["-N", "-U", "-F", "-S", "-Y"]);
const NFQWS_OPTIONAL_ARG_OPTIONS = new Set([
  "--comment",
  "--ctrack-disable",
  "--debug",
  "--dpi-desync-any-protocol",
  "--dpi-desync-autottl",
  "--dpi-desync-autottl6",
  "--dpi-desync-skip-nosni",
  "--dpi-desync-tcp-flags-set",
  "--dpi-desync-tcp-flags-unset",
  "--dup-autottl",
  "--dup-autottl6",
  "--dup-replace",
  "--dup-tcp-flags-set",
  "--dup-tcp-flags-unset",
  "--ipcache-hostname",
  "--orig-autottl",
  "--orig-autottl6",
  "--orig-tcp-flags-set",
  "--orig-tcp-flags-unset",
  "--synack-split",
]);
const NFQWS_NO_ARG_OPTIONS = new Set([
  "--bind-fix4",
  "--bind-fix6",
  "--daemon",
  "--domcase",
  "--dry-run",
  "--hostcase",
  "--hostnospace",
  "--methodeol",
  "--new",
  "--skip",
  "--version",
]);
const NFQWS_REQUIRED_ARG_OPTIONS = new Set([
  "--ctrack-timeouts",
  "--dpi-desync",
  "--dpi-desync-badack-increment",
  "--dpi-desync-badseq-increment",
  "--dpi-desync-cutoff",
  "--dpi-desync-fake-dht",
  "--dpi-desync-fake-discord",
  "--dpi-desync-fake-http",
  "--dpi-desync-fake-quic",
  "--dpi-desync-fake-stun",
  "--dpi-desync-fake-syndata",
  "--dpi-desync-fake-tcp-mod",
  "--dpi-desync-fake-tls",
  "--dpi-desync-fake-tls-mod",
  "--dpi-desync-fake-unknown",
  "--dpi-desync-fake-unknown-udp",
  "--dpi-desync-fake-wireguard",
  "--dpi-desync-fakedsplit-mod",
  "--dpi-desync-fakedsplit-pattern",
  "--dpi-desync-fooling",
  "--dpi-desync-fwmark",
  "--dpi-desync-hostfakesplit-midhost",
  "--dpi-desync-hostfakesplit-mod",
  "--dpi-desync-ipfrag-pos-tcp",
  "--dpi-desync-ipfrag-pos-udp",
  "--dpi-desync-repeats",
  "--dpi-desync-split-http-req",
  "--dpi-desync-split-pos",
  "--dpi-desync-split-seqovl",
  "--dpi-desync-split-seqovl-pattern",
  "--dpi-desync-split-tls",
  "--dpi-desync-start",
  "--dpi-desync-ts-increment",
  "--dpi-desync-ttl",
  "--dpi-desync-ttl6",
  "--dpi-desync-udplen-increment",
  "--dpi-desync-udplen-pattern",
  "--dup",
  "--dup-badack-increment",
  "--dup-badseq-increment",
  "--dup-cutoff",
  "--dup-fooling",
  "--dup-ip-id",
  "--dup-start",
  "--dup-ts-increment",
  "--dup-ttl",
  "--dup-ttl6",
  "--filter-l3",
  "--filter-l7",
  "--filter-tcp",
  "--filter-udp",
  "--hostlist",
  "--hostlist-auto",
  "--hostlist-auto-debug",
  "--hostlist-auto-fail-threshold",
  "--hostlist-auto-fail-time",
  "--hostlist-auto-retrans-threshold",
  "--hostlist-domains",
  "--hostlist-exclude",
  "--hostlist-exclude-domains",
  "--hostspell",
  "--ip-id",
  "--ipcache-lifetime",
  "--ipset",
  "--ipset-exclude",
  "--ipset-exclude-ip",
  "--ipset-ip",
  "--orig-mod-cutoff",
  "--orig-mod-start",
  "--orig-ttl",
  "--orig-ttl6",
  "--pidfile",
  "--qnum",
  "--uid",
  "--user",
  "--wsize",
  "--wssize",
  "--wssize-cutoff",
  "--wssize-forced-cutoff",
]);
const NFQWS2_OPTIONAL_ARG_OPTIONS = new Set([
  "--chdir",
  "--comment",
  "--ctrack-disable",
  "--debug",
  "--hostlist-auto-retrans-reset",
  "--intercept",
  "--ipcache-hostname",
  "--new",
  "--payload-disable",
  "--reasm-disable",
  "--server",
  "--template",
  "--writeable",
]);
const NFQWS2_NO_ARG_OPTIONS = new Set([
  "--bind-fix4",
  "--bind-fix6",
  "--daemon",
  "--dry-run",
  "--skip",
  "--version",
]);
const NFQWS2_REQUIRED_ARG_OPTIONS = new Set([
  "--blob",
  "--cookie",
  "--ctrack-timeouts",
  "--filter-l3",
  "--filter-l7",
  "--filter-tcp",
  "--filter-udp",
  "--fwmark",
  "--fuzz",
  "--hostlist",
  "--hostlist-auto",
  "--hostlist-auto-debug",
  "--hostlist-auto-fail-threshold",
  "--hostlist-auto-fail-time",
  "--hostlist-auto-retrans-threshold",
  "--hostlist-domains",
  "--hostlist-exclude",
  "--hostlist-exclude-domains",
  "--import",
  "--in-range",
  "--ipcache-lifetime",
  "--ipset",
  "--ipset-exclude",
  "--ipset-exclude-ip",
  "--ipset-ip",
  "--lua-gc",
  "--lua-init",
  "--lua-desync",
  "--name",
  "--out-range",
  "--payload",
  "--pidfile",
  "--qnum",
  "--uid",
  "--user",
]);
const actionProvidersAvailabilityState = {
  loaded: false,
  zapretInstalled: false,
  zapret2Installed: false,
  byedpiInstalled: false,
};
let actionProvidersAvailabilityPromise = null;
let actionProvidersAvailabilityLoader = null;
const outboundNameChoicesCache = new Map();
const outboundNameChoicesInflight = new Map();
const outboundNameSourceOptions = new Map();
const sectionGroupSourceOptions = new Map();
const dashboardFilterChoiceRefreshers = new Map();
const SECTION_CACHE_DIR = "/var/run/forkop/section-cache";
const COUNTRY_CODES =
  "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW XK".split(
    " ",
  );
const REGION_NAME_FALLBACKS = {
  XK: "Kosovo",
};
let regionDisplayNamesCache = {};

function updateActionProvidersAvailabilityState(nextState) {
  if (!nextState) {
    return;
  }

  actionProvidersAvailabilityState.loaded = true;

  if (typeof nextState.zapretInstalled !== "undefined") {
    actionProvidersAvailabilityState.zapretInstalled = Boolean(
      nextState.zapretInstalled,
    );
  }

  if (typeof nextState.zapret2Installed !== "undefined") {
    actionProvidersAvailabilityState.zapret2Installed = Boolean(
      nextState.zapret2Installed,
    );
  }

  if (typeof nextState.byedpiInstalled !== "undefined") {
    actionProvidersAvailabilityState.byedpiInstalled = Boolean(
      nextState.byedpiInstalled,
    );
  }

  actionProvidersAvailabilityPromise = null;
}

function updateActionProvidersAvailabilityFromSystemInfo(systemInfo) {
  if (!systemInfo || !systemInfo.providerInfoLoaded) {
    return;
  }

  updateActionProvidersAvailabilityState({
    zapretInstalled: Boolean(systemInfo.zapret_installed),
    zapret2Installed: Boolean(systemInfo.zapret2_installed),
    byedpiInstalled: Boolean(systemInfo.byedpi_installed),
  });
}

function setActionProvidersAvailabilityLoader(loader) {
  actionProvidersAvailabilityLoader =
    typeof loader === "function" ? loader : null;
}

if (typeof window !== "undefined") {
  window.addEventListener(ACTION_PROVIDERS_AVAILABILITY_EVENT, (event) => {
    updateActionProvidersAvailabilityState(event.detail);
  });
}

if (main.store && typeof main.store.subscribe === "function") {
  main.store.subscribe((next, _prev, diff) => {
    if (!diff || diff.diagnosticsSystemInfo) {
      updateActionProvidersAvailabilityFromSystemInfo(
        next.diagnosticsSystemInfo,
      );
    }
  });
}

function getLuciLanguage() {
  if (typeof L !== "undefined" && L.env && L.env.lang) {
    return `${L.env.lang}`.replace("_", "-");
  }

  if (document.documentElement.lang) {
    return document.documentElement.lang;
  }

  return navigator.language || "en";
}

function getRegionDisplayName(code) {
  const normalizedCode = `${code || ""}`.toUpperCase();
  const language = getLuciLanguage();
  const cacheKey = `${language}:${normalizedCode}`;

  if (regionDisplayNamesCache[cacheKey]) {
    return regionDisplayNamesCache[cacheKey];
  }

  try {
    if (typeof Intl !== "undefined" && Intl.DisplayNames) {
      const displayNames = new Intl.DisplayNames([language, "en"], {
        type: "region",
      });
      const displayName = displayNames.of(normalizedCode);
      if (displayName && displayName !== normalizedCode) {
        regionDisplayNamesCache[cacheKey] = displayName;
        return displayName;
      }
    }
  } catch (_error) {
    // Fall through to the static fallback.
  }

  const fallback = REGION_NAME_FALLBACKS[normalizedCode] || normalizedCode;
  regionDisplayNamesCache[cacheKey] = fallback;
  return fallback;
}

function getCountryFlagEmoji(code) {
  const normalizedCode = `${code || ""}`.toUpperCase();

  if (!/^[A-Z]{2}$/.test(normalizedCode)) {
    return "";
  }

  return String.fromCodePoint(
    ...normalizedCode
      .split("")
      .map((char) => 0x1f1e6 + char.charCodeAt(0) - 65),
  );
}

function getCountryOptionLabel(code) {
  return `${getCountryFlagEmoji(code)} ${getRegionDisplayName(code)}`;
}

function validateCountryCode(_section_id, value) {
  const values = Array.isArray(value) ? value : [value];
  const normalizedValues = values
    .filter((item) => item && `${item}`.length)
    .map((item) => `${item}`.toUpperCase());

  if (!normalizedValues.length) {
    return true;
  }

  return normalizedValues.every((item) => COUNTRY_CODES.includes(item))
    ? true
    : _("Unknown country");
}

function plainObject(value) {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value
    : {};
}

function safeCacheSectionName(section_id) {
  return /^[A-Za-z0-9_-]+$/.test(`${section_id || ""}`);
}

function filteredOutboundMetadataFromCache(cache) {
  const metadata = plainObject(plainObject(cache).outboundMetadata);
  const names = plainObject(metadata.names);
  const countries = plainObject(metadata.countries);
  const candidateTags = Array.isArray(cache.urltestCandidateTags)
    ? cache.urltestCandidateTags
    : [];
  const groups = plainObject(cache.urltestGroups);
  const result = {
    names: {},
    countries: {},
  };

  if (candidateTags.length > 0) {
    candidateTags.forEach((tag) => {
      tag = `${tag || ""}`;
      if (!tag) {
        return;
      }
      if (names[tag] != null) {
        result.names[tag] = names[tag];
      }
      if (countries[tag] != null) {
        result.countries[tag] = countries[tag];
      }
    });
    return result;
  }

  Object.entries(names).forEach(([tag, name]) => {
    if (!groups[tag]) {
      result.names[tag] = name;
    }
  });
  Object.entries(countries).forEach(([tag, country]) => {
    if (!groups[tag]) {
      result.countries[tag] = country;
    }
  });

  return result;
}

function readOutboundMetadataFromSectionCache(section_id) {
  if (!safeCacheSectionName(section_id)) {
    return Promise.resolve({ names: {}, countries: {} });
  }

  return fs
    .read(`${SECTION_CACHE_DIR}/${section_id}.json`)
    .then((raw) => filteredOutboundMetadataFromCache(JSON.parse(raw || "{}")))
    .catch(() => ({ names: {}, countries: {} }));
}

function loadOutboundNameChoices(section_id) {
  if (outboundNameChoicesCache.has(section_id)) {
    return Promise.resolve(outboundNameChoicesCache.get(section_id));
  }

  if (outboundNameChoicesInflight.has(section_id)) {
    return outboundNameChoicesInflight.get(section_id);
  }

  const task = readOutboundMetadataFromSectionCache(section_id)
    .then((metadata) => {
      const names = Object.values(plainObject(metadata.names));

      const choices = names
        .filter(Boolean)
        .filter((name, index, values) => values.indexOf(name) === index)
        .sort((a, b) => `${a}`.localeCompare(`${b}`));

      outboundNameChoicesCache.set(section_id, choices);

      return choices;
    })
    .catch(() => [])
    .finally(() => {
      outboundNameChoicesInflight.delete(section_id);
    });

  outboundNameChoicesInflight.set(section_id, task);

  return task;
}

function normalizeDynamicListItems(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .map((item) => `${item || ""}`.trim())
      .filter((item) => item.length);
  }

  const normalized = `${value}`.trim();
  return normalized.length ? [normalized] : [];
}

function uniqueDynamicListItems(value) {
  const seen = new Set();
  const result = [];

  normalizeDynamicListItems(value).forEach((item) => {
    if (!seen.has(item)) {
      seen.add(item);
      result.push(item);
    }
  });

  return result;
}

function readItemSettingsMap(section_id, settingsKey) {
  const raw = uci.get(UCI_PACKAGE, section_id, settingsKey);

  if (!raw) {
    return {};
  }

  try {
    const parsed = JSON.parse(`${raw}`);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch (_error) {
    return {};
  }
}

function compactItemSettings(values) {
  const result = {};

  Object.entries(values || {}).forEach(([key, value]) => {
    if (value === undefined || value === null || value === "") {
      return;
    }

    if (Array.isArray(value)) {
      const items = value
        .map((item) => `${item || ""}`.trim())
        .filter((item) => item.length);

      if (items.length) {
        result[key] = items;
      }
      return;
    }

    result[key] = `${value}`;
  });

  return result;
}

function writeItemSettingsMap(section_id, settingsKey, map) {
  const result = {};

  Object.entries(map || {}).forEach(([item, settings]) => {
    const compact = compactItemSettings(settings);
    if (item && Object.keys(compact).length) {
      result[item] = compact;
    }
  });

  if (Object.keys(result).length) {
    uci.set(UCI_PACKAGE, section_id, settingsKey, JSON.stringify(result));
  } else {
    uci.unset(UCI_PACKAGE, section_id, settingsKey);
  }
}

function cleanupListItemSettings(section_id, settingsKey, values) {
  if (!settingsKey) {
    return;
  }

  const keep = new Set(normalizeDynamicListItems(values));
  const map = readItemSettingsMap(section_id, settingsKey);
  let changed = false;

  Object.keys(map).forEach((item) => {
    if (!keep.has(item)) {
      delete map[item];
      changed = true;
    }
  });

  if (changed) {
    writeItemSettingsMap(section_id, settingsKey, map);
  }
}

function itemSettingsFlag(settings, key, defaultValue) {
  const value = settings ? settings[key] : null;

  if (value === undefined || value === null || value === "") {
    return Boolean(defaultValue);
  }

  return value === true || `${value}` === "1";
}

function ensureConnectionsDynamicListStyles() {
  if (document.getElementById(CONNECTIONS_DYNLIST_STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      "style",
      { id: CONNECTIONS_DYNLIST_STYLE_ID },
      `
.fkp-connections-dynlist > .item {
  --fkp-dynlist-action-width: 2em;
  padding-right: calc(var(--fkp-dynlist-action-width) * 2);
  position: relative;
}

.fkp-connections-dynlist > .item > .fkp-dynlist-settings {
  align-items: center;
  border: 1px solid var(--border-color-high, currentColor);
  border-right: 0;
  border-radius: 0;
  bottom: -1px;
  color: inherit;
  cursor: pointer;
  display: inline-flex;
  font: inherit;
  font-size: 0.9em;
  justify-content: center;
  line-height: 1;
  min-height: 0;
  min-width: var(--fkp-dynlist-action-width);
  padding: 0;
  pointer-events: auto;
  position: absolute;
  right: calc(var(--fkp-dynlist-action-width) - 1px);
  user-select: none;
  text-decoration: none;
  top: -1px;
  width: var(--fkp-dynlist-action-width);
  z-index: 1;
}

.fkp-connections-dynlist > .item > .fkp-dynlist-settings:hover,
.fkp-connections-dynlist > .item > .fkp-dynlist-settings:focus {
  --focus-color-rgb: 82, 168, 236;
  outline: 0;
  border-color: rgba(var(--focus-color-rgb), 0.8) !important;
  box-shadow: inset 0 1px 3px hsla(var(--border-color-low-hsl), .01), 0 0 8px rgba(var(--focus-color-rgb), 0.6);
  text-decoration: none;
}

.fkp-connections-dynlist > .add-item > .cbi-dropdown {
  width: 100%;
}

.fkp-interface-dynlist-label {
  align-items: center;
  display: inline-flex;
  gap: 0.25em;
  max-width: 100%;
  vertical-align: middle;
}

.fkp-interface-dynlist-label > img {
  flex: 0 0 auto;
  height: 1.35em;
  width: auto;
}

.fkp-interface-dynlist-label > span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.fkp-button-add-dynlist > .add-item {
  align-items: stretch;
  background: transparent;
  border: 0;
  border-radius: 0;
  box-shadow: none;
  display: flex;
  margin-top: 4px;
  max-width: 100%;
  min-width: 0;
  overflow: visible;
  padding: 0;
  width: var(--fkp-button-add-width, 210px);
}

.fkp-button-add-dynlist > .add-item > input[type="text"] {
  display: none !important;
}

.fkp-button-add-dynlist > .add-item > .cbi-button-add {
  align-items: center !important;
  background: linear-gradient(var(--background-color-high, var(--primary, ButtonFace)) 0%, var(--border-color-low, var(--primary, ButtonFace)) 100%) !important;
  border: 1px solid var(--border-color-high, var(--primary, currentColor)) !important;
  border-radius: 3px !important;
  box-shadow: inset 0 1px 3px hsla(var(--border-color-low-hsl, 0, 0%, 0%), .01) !important;
  box-sizing: border-box !important;
  color: var(--text-color-medium, var(--white, ButtonText)) !important;
  cursor: pointer !important;
  display: flex !important;
  font-size: 13px !important;
  height: 30px !important;
  justify-content: flex-start !important;
  margin-left: 0 !important;
  max-height: 30px !important;
  min-height: 30px !important;
  max-width: 100% !important;
  overflow: hidden !important;
  padding: 0 4px !important;
  text-overflow: ellipsis !important;
  transition: border linear .2s, box-shadow linear .2s !important;
  white-space: nowrap !important;
  width: 100% !important;
}

.fkp-button-add-dynlist > .add-item > .cbi-button-add:hover,
.fkp-button-add-dynlist > .add-item > .cbi-button-add:focus {
  border-color: rgba(82, 168, 236, .8) !important;
  box-shadow: inset 0 1px 3px hsla(var(--border-color-low-hsl, 0, 0%, 0%), .01), 0 0 8px rgba(82, 168, 236, .6) !important;
  outline: 0;
}

body.modal-overlay-active > #modal_overlay > .modal.cbi-modal > .cbi-map.flash {
  animation: none !important;
}

`,
    ),
  );
}

function findDynamicListItemByValue(dl, value) {
  const stringValue = `${value}`;
  const items = dl.querySelectorAll(".item");

  for (let i = 0; i < items.length; i += 1) {
    const hidden = items[i].querySelector('input[type="hidden"]');
    if (
      hidden &&
      hidden.parentNode === items[i] &&
      hidden.value === stringValue
    ) {
      return items[i];
    }
  }

  return null;
}

function dynamicListItemCurrentValue(item, fallback) {
  const hidden = item ? item.querySelector('input[type="hidden"]') : null;
  return hidden && hidden.parentNode === item ? hidden.value : fallback;
}

function dynamicListItemValues(dl) {
  return Array.from(dl.querySelectorAll(".item"))
    .map((item) => {
      const hidden = item.querySelector('input[type="hidden"]');
      return hidden && hidden.parentNode === item ? hidden.value : null;
    })
    .filter((value) => value != null);
}

function updateDynamicListItemLabel(item, label) {
  const labelNode = item ? item.querySelector(".fkp-dynlist-label") : null;
  if (labelNode) {
    labelNode.textContent = `${label || ""}`;
  }
}

function addDynamicListItem(widget, value, text) {
  if (!widget || !widget.node) {
    return null;
  }

  const normalized = `${value || ""}`.trim();
  if (!normalized) {
    return null;
  }

  if (
    typeof widget.options.hasEquivalentValue === "function" &&
    widget.options.hasEquivalentValue(normalized, widget.node)
  ) {
    widget.dispatchCbiDynlistChange(widget.node, normalized);
    return null;
  }

  widget.addItem(widget.node, normalized, text || null, false);
  widget.dispatchCbiDynlistChange(widget.node, normalized);
  updateButtonAddDynamicListLayout(widget.node, widget.options.addButtonLabel);

  return findDynamicListItemByValue(widget.node, normalized);
}

function updateButtonAddDynamicListLayout(dl, label) {
  const addButton = dl ? dl.querySelector(".add-item > .cbi-button-add") : null;
  if (!addButton) {
    return;
  }

  addButton.textContent = label || "+";
  addButton.setAttribute("role", "button");
  addButton.setAttribute("tabindex", "0");
  dl.style.setProperty(
    "--fkp-button-add-width",
    dl.querySelector(".item") ? "100%" : "210px",
  );
}

function setDynamicListItemValue(item, value) {
  const hidden = item ? item.querySelector('input[type="hidden"]') : null;
  if (hidden && hidden.parentNode === item) {
    hidden.value = `${value || ""}`;
  }
}

function parseOutboundJsonObject(value) {
  try {
    const parsed = JSON.parse(`${value || ""}`);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : null;
  } catch (_error) {
    return null;
  }
}

function outboundJsonDisplayTag(value) {
  const parsed = parseOutboundJsonObject(value);
  const tag = parsed && typeof parsed.tag === "string" ? parsed.tag.trim() : "";
  return tag || "";
}

function outboundJsonListItemLabel(value) {
  return E(
    "span",
    { class: "fkp-dynlist-label" },
    outboundJsonDisplayTag(value) || _("JSON outbound"),
  );
}

function cleanFormSectionData(sectionData) {
  const result = {};

  Object.entries(sectionData || {}).forEach(([key, value]) => {
    if (!key || key.charAt(0) === ".") {
      return;
    }

    result[key] = Array.isArray(value) ? value.slice() : value;
  });

  return result;
}

const SettingsUIDynamicList = ui.DynamicList.extend({
  render() {
    ensureConnectionsDynamicListStyles();

    const node = ui.DynamicList.prototype.render.apply(this, arguments);
    node.classList.add("fkp-connections-dynlist");
    return node;
  },

  addItem(dl, value, text, flash) {
    if (
      flash &&
      typeof this.options.hasEquivalentValue === "function" &&
      this.options.hasEquivalentValue(value, dl)
    ) {
      this.dispatchCbiDynlistChange(dl, value);
      return;
    }

    const itemText =
      typeof this.options.itemLabel === "function"
        ? this.options.itemLabel(value, text)
        : text;

    ui.DynamicList.prototype.addItem.call(this, dl, value, itemText, flash);

    const item = findDynamicListItemByValue(dl, value);
    const hasSettings =
      typeof this.options.hasSettings === "function"
        ? this.options.hasSettings(value)
        : true;

    if (!item || item.querySelector(".fkp-dynlist-settings") || !hasSettings) {
      return;
    }

    item.appendChild(
      E(
        "span",
        {
          role: "button",
          tabindex: this.options.disabled ? null : "0",
          class: "fkp-dynlist-settings",
          "aria-label": _("Settings"),
          "aria-disabled": this.options.disabled ? "true" : null,
          click: (event) => {
            event.preventDefault();
            event.stopPropagation();

            if (this.options.disabled) {
              return;
            }

            if (typeof this.options.settingsHandler === "function") {
              this.options.settingsHandler(
                dynamicListItemCurrentValue(item, value),
                item,
                this,
                {},
              );
            }
          },
          keydown: (event) => {
            if (event.key !== "Enter" && event.key !== " ") {
              return;
            }

            event.preventDefault();
            event.stopPropagation();

            if (
              !this.options.disabled &&
              typeof this.options.settingsHandler === "function"
            ) {
              this.options.settingsHandler(
                dynamicListItemCurrentValue(item, value),
                item,
                this,
                {},
              );
            }
          },
        },
        "\u2699",
      ),
    );
  },
  handleClick(event) {
    if (event.target.closest(".fkp-dynlist-settings")) {
      return;
    }

    return ui.DynamicList.prototype.handleClick.apply(this, arguments);
  },
});

const ButtonAddSettingsUIDynamicList = SettingsUIDynamicList.extend({
  render() {
    const node = SettingsUIDynamicList.prototype.render.apply(this, arguments);
    node.classList.add("fkp-button-add-dynlist");

    const input = node.querySelector('.add-item > input[type="text"]');
    if (input) {
      input.setAttribute("aria-hidden", "true");
      input.setAttribute("tabindex", "-1");
    }

    updateButtonAddDynamicListLayout(node, this.options.addButtonLabel);

    node.addEventListener("cbi-dynlist-change", () => {
      updateButtonAddDynamicListLayout(node, this.options.addButtonLabel);
    });

    return node;
  },

  addButtonItem() {
    if (typeof this.options.settingsHandler === "function") {
      this.options.settingsHandler("", null, this, { adding: true });
    }
  },

  handleClick(event) {
    if (
      !this.options.disabled &&
      event.target.closest(".add-item > .cbi-button-add")
    ) {
      event.preventDefault();
      event.stopPropagation();
      this.addButtonItem(event.currentTarget);
      return;
    }

    return SettingsUIDynamicList.prototype.handleClick.apply(this, arguments);
  },

  handleKeydown(event) {
    if (
      !this.options.disabled &&
      event.target.closest(".add-item > .cbi-button-add") &&
      (event.key === "Enter" || event.key === " ")
    ) {
      event.preventDefault();
      event.stopPropagation();
      this.addButtonItem(event.currentTarget);
      return;
    }

    return ui.DynamicList.prototype.handleKeydown.apply(this, arguments);
  },
});

const SettingsDynamicList = form.DynamicList.extend({
  childOwner(section_id) {
    return typeof this.childOwnerId === "function"
      ? `${this.childOwnerId(section_id) || ""}`.trim()
      : section_id;
  },

  parentSection(section_id) {
    return typeof this.parentSectionId === "function"
      ? `${this.parentSectionId(section_id) || ""}`.trim()
      : section_id;
  },

  load(section_id) {
    if (this.childType) {
      return getChildItemIds(
        this.childOwner(section_id),
        this.childType,
        this.ownerOption,
      );
    }

    return form.DynamicList.prototype.load.apply(this, arguments);
  },

  renderWidget(section_id, _option_index, cfgvalue) {
    const value = cfgvalue != null ? cfgvalue : this.default;
    const choices = this.transformChoices();
    const WidgetClass = this.buttonAdd
      ? ButtonAddSettingsUIDynamicList
      : SettingsUIDynamicList;
    const widget = new WidgetClass(L.toArray(value), choices, {
      id: this.cbid(section_id),
      sort: this.keylist,
      allowduplicates: this.allowduplicates,
      optional: this.optional || this.rmempty,
      datatype: this.datatype,
      placeholder: this.placeholder,
      validate: L.bind(this.validate, this, section_id),
      disabled: this.readonly != null ? this.readonly : this.map.readonly,
      addButtonLabel:
        typeof this.addButtonLabel === "function"
          ? this.addButtonLabel(section_id)
          : this.addButtonLabel,
      settingsHandler: (itemValue, _item, widget, context) => {
        if (typeof this.renderItemSettingsModal === "function") {
          const ownerId = this.childOwner(section_id);
          this.renderItemSettingsModal(
            ownerId,
            `${itemValue}`,
            this,
            widget,
            _item,
            Object.assign({}, context || {}, {
              parentSectionId: this.parentSection(section_id),
              ownerId,
            }),
          );
        }
      },
      itemLabel: (itemValue, text) => {
        if (typeof this.renderListItemLabel === "function") {
          return this.renderListItemLabel(
            this.childOwner(section_id),
            `${itemValue}`,
            text,
          );
        }

        return text;
      },
      hasSettings: (itemValue) => {
        if (typeof this.hasItemSettings === "function") {
          return this.hasItemSettings(
            this.childOwner(section_id),
            `${itemValue}`,
          );
        }

        if (this.childType) {
          return isExistingChildItem(
            this.childOwner(section_id),
            `${itemValue}`,
            this.childType,
            this.ownerOption,
          );
        }

        return true;
      },
      hasEquivalentValue: (itemValue, dl) => {
        const inputValueForItem = (value) => {
          const ownerId = this.childOwner(section_id);

          if (typeof this.inputValueForItem === "function") {
            return `${this.inputValueForItem(ownerId, `${value || ""}`) || ""}`.trim();
          }

          if (this.childType && this.childValueOption) {
            return childItemInputValue(
              ownerId,
              `${value || ""}`,
              this.childType,
              this.childValueOption,
              this.ownerOption,
            );
          }

          return `${value || ""}`.trim();
        };
        const normalized = inputValueForItem(itemValue);

        return Boolean(
          normalized &&
            dynamicListItemValues(dl).some(
              (existingValue) =>
                inputValueForItem(existingValue) === normalized,
            ),
        );
      },
    });

    const node = widget.render();
    if (typeof this.onListChange === "function") {
      node.addEventListener("cbi-dynlist-change", () => {
        this.onListChange(section_id);
      });
    }

    return node;
  },

  // What parse refuses for the items of an active list; the rule modal asks
  // before anything is written (refuseInvalidModalSave).
  checkBeforeSave(section_id) {
    if (typeof this.validateItemsOnSave !== "function") {
      return true;
    }

    return this.validateItemsOnSave(
      this.childType ? this.childOwner(section_id) : section_id,
      this.formvalue(section_id),
      this,
      section_id,
    );
  },

  parse(section_id) {
    if (this.isActive(section_id)) {
      const result = this.checkBeforeSave(section_id);
      if (result !== true) {
        return rejectInvalidOption(this, section_id, result);
      }
    }

    return form.DynamicList.prototype.parse.apply(this, arguments);
  },

  write(section_id, value) {
    if (this.childType) {
      const ownerId = this.childOwner(section_id);
      const itemIds = materializeChildItems(
        ownerId,
        {
          typeName: this.childType,
          valueOption: this.childValueOption,
          ownerOption: this.ownerOption,
          createId: this.createId,
          defaults: this.childDefaults,
          stagedSettings:
            typeof this.stagedChildSettings === "function"
              ? (itemValue, itemId, created) =>
                  this.stagedChildSettings(ownerId, itemValue, itemId, created)
              : null,
        },
        value,
      );
      cleanupRemovedChildItems(
        ownerId,
        this.childType,
        itemIds,
        this.ownerOption,
      );
      if (typeof this.afterMaterializeChildItems === "function") {
        this.afterMaterializeChildItems(ownerId, itemIds);
      }
      uci.unset(UCI_PACKAGE, section_id, this.option);
      cleanupListItemSettings(ownerId, this.settingsKey, itemIds);
      if (typeof this.clearStagedChildSettings === "function") {
        this.clearStagedChildSettings(ownerId);
      }
      return;
    }

    const result = form.DynamicList.prototype.write.apply(this, arguments);
    cleanupListItemSettings(section_id, this.settingsKey, value);
    return result;
  },

  remove(section_id) {
    if (this.childType) {
      cleanupRemovedChildItems(
        this.childOwner(section_id),
        this.childType,
        [],
        this.ownerOption,
      );
      uci.unset(UCI_PACKAGE, section_id, this.option);
      return;
    }

    if (this.settingsKey) {
      uci.unset(UCI_PACKAGE, section_id, this.settingsKey);
    }

    return form.DynamicList.prototype.remove.apply(this, arguments);
  },
});

const ButtonAddSettingsDynamicList = SettingsDynamicList.extend({
  buttonAdd: true,
});

function configureLiveDynamicListChoices(option, getChoices) {
  option.renderWidget = function (section_id, _option_index, cfgvalue) {
    const values = L.toArray(cfgvalue != null ? cfgvalue : this.default);
    const choices = getChoices(section_id, values);
    const labels = {};
    choices.forEach((choice) => {
      labels[choice.value] = choice.label;
    });
    refreshOptionChoices(this, choices);
    let choiceSignature = JSON.stringify(
      choices.map((choice) => [choice.value, choice.label]),
    );
    // form.DynamicList passes null when there are no choices, which permanently
    // renders a plain input. An empty object keeps the stock combobox alive so
    // later live choices can be added without reopening the modal.
    const widget = new ui.DynamicList(values, labels, {
      id: this.cbid(section_id),
      sort: this.keylist,
      allowduplicates: this.allowduplicates,
      optional: this.optional || this.rmempty,
      datatype: this.datatype,
      placeholder: this.placeholder,
      validate: L.bind(this.validate, this, section_id),
      disabled: this.readonly != null ? this.readonly : this.map.readonly,
    });
    const node = widget.render();
    const refreshChoices = () => {
      if (!node.isConnected) {
        return false;
      }

      const currentValues = widget.getValue();
      const currentChoices = getChoices(section_id, currentValues);
      const currentLabels = {};
      currentChoices.forEach((choice) => {
        currentLabels[choice.value] = choice.label;
      });
      const currentSignature = JSON.stringify(
        currentChoices.map((choice) => [choice.value, choice.label]),
      );

      if (currentSignature === choiceSignature) {
        return;
      }
      choiceSignature = currentSignature;

      refreshOptionChoices(this, currentChoices);
      widget.choices = currentLabels;
      widget.clearChoices();
      widget.addChoices(
        currentChoices.map((choice) => choice.value),
        currentLabels,
      );
      return true;
    };
    const refreshBeforeOpening = (event) => {
      if (event.target && event.target.closest(".add-item")) {
        refreshChoices();
      }
    };
    node.addEventListener("mousedown", refreshBeforeOpening, true);
    node.addEventListener("focusin", refreshBeforeOpening, true);

    if (!dashboardFilterChoiceRefreshers.has(section_id)) {
      dashboardFilterChoiceRefreshers.set(section_id, new Set());
    }
    dashboardFilterChoiceRefreshers.get(section_id).add(refreshChoices);

    return node;
  };
}

function countryChoices() {
  return COUNTRY_CODES.map((code) => ({
    value: code,
    label: getCountryOptionLabel(code),
  })).sort((a, b) => a.label.localeCompare(b.label));
}

function currentOutboundNameChoices(section_id, values) {
  if (!outboundNameChoicesCache.has(section_id)) {
    loadOutboundNameChoices(section_id);
  }

  const seen = new Set();
  const result = [];
  const append = (name) => {
    const value = `${name || ""}`.trim();
    if (!value || seen.has(value)) {
      return;
    }

    seen.add(value);
    result.push({ value, label: value });
  };

  (outboundNameChoicesCache.get(section_id) || []).forEach(append);
  currentDraftOutboundNames(section_id).forEach(append);
  normalizeDynamicListItems(values).forEach(append);

  return result.sort((a, b) => a.label.localeCompare(b.label));
}

function currentSourceOptionValues(section_id, optionName) {
  const liveValues = currentLiveDynamicListValues(section_id, optionName);
  if (liveValues != null) {
    return liveValues;
  }

  const option = outboundNameSourceOptions.get(optionName);

  if (option && typeof option.formvalue === "function") {
    try {
      const value = option.formvalue(section_id);
      if (value != null) {
        return normalizeDynamicListItems(value);
      }
    } catch (_error) {
      // Fall back to the LuCI UCI cache when the section widget is not mounted.
    }
  }

  return getConfigListValues(section_id, optionName);
}

function currentLiveDynamicListValues(section_id, optionName) {
  if (typeof document === "undefined") {
    return null;
  }

  const widget = document.getElementById(
    `cbid.${UCI_PACKAGE}.${section_id}.${optionName}`,
  );
  if (!widget) {
    return null;
  }

  const values = Array.from(
    widget.querySelectorAll('.item > input[type="hidden"]'),
  )
    .map((input) => `${input.value || ""}`.trim())
    .filter(Boolean);
  const pendingInput = widget.querySelector('.add-item > input[type="text"]');
  const pendingValue = `${(pendingInput && pendingInput.value) || ""}`.trim();

  if (
    pendingValue &&
    !pendingInput.classList.contains("cbi-input-invalid") &&
    !values.includes(pendingValue)
  ) {
    values.push(pendingValue);
  }

  return values;
}

function currentDraftOutboundNames(section_id) {
  const names = [];

  currentSourceOptionValues(section_id, "selector_proxy_links").forEach(
    (value, index) => {
      const name = main.getProxyUrlName(`${value || ""}`);
      names.push(name || `${section_id}-${index + 1}-out`);
    },
  );
  currentSourceOptionValues(section_id, "interfaces").forEach((itemId) => {
    const normalized = childItemInputValue(
      section_id,
      itemId,
      "section_interface",
      "name",
    ).trim();
    if (normalized) {
      names.push(normalized);
    }
  });
  currentSourceOptionValues(section_id, "outbound_jsons").forEach((value) => {
    const tag = outboundJsonDisplayTag(value);
    if (tag) {
      names.push(tag);
    }
  });

  return names;
}

function currentSectionGroupValues(section_id, typeName) {
  const liveValues = currentLiveDynamicListValues(section_id, typeName);
  if (liveValues != null) {
    return liveValues;
  }

  const option = sectionGroupSourceOptions.get(typeName);
  if (option && typeof option.formvalue === "function") {
    try {
      const value = option.formvalue(section_id);
      if (value != null) {
        return normalizeDynamicListItems(value);
      }
    } catch (_error) {
      // Fall back to the child sections when the widget is not mounted.
    }
  }

  return getChildItemIds(section_id, typeName);
}

function sectionGroupDisplayName(section_id, typeName, value) {
  const itemId = `${value || ""}`.trim();
  if (isExistingChildItem(section_id, itemId, typeName)) {
    return `${uci.get(UCI_PACKAGE, itemId, "name") || itemId}`.trim();
  }

  const option = sectionGroupSourceOptions.get(typeName);
  const pending =
    option && option.pendingChildSettings
      ? option.pendingChildSettings[section_id]
      : null;
  const settings = pending && pending[itemId];
  return `${(settings && settings.name) || itemId}`.trim();
}

function currentSectionGroupChoices(section_id, selectedValues = []) {
  const seen = new Set();
  const result = [];
  const append = (typeName, value) => {
    value = `${value || ""}`.trim();
    if (!value) {
      return;
    }

    const name = sectionGroupDisplayName(section_id, typeName, value) || value;
    if (seen.has(name)) {
      return;
    }

    seen.add(name);
    result.push({ value: name, label: name });
  };

  currentSectionGroupValues(section_id, "urltest").forEach((value) =>
    append("urltest", value),
  );
  currentSectionGroupValues(section_id, "priority_group").forEach((value) =>
    append("priority_group", value),
  );
  normalizeDynamicListItems(selectedValues).forEach((value) => {
    value = `${value || ""}`.trim();
    if (value && !seen.has(value)) {
      seen.add(value);
      result.push({ value, label: value });
    }
  });

  return result.sort((left, right) => left.label.localeCompare(right.label));
}

function refreshDashboardFilterChoiceWidgets(section_id) {
  const refreshers = dashboardFilterChoiceRefreshers.get(section_id);
  if (!refreshers) {
    return;
  }

  refreshers.forEach((refresh) => {
    if (refresh() === false) {
      refreshers.delete(refresh);
    }
  });

  if (refreshers.size === 0) {
    dashboardFilterChoiceRefreshers.delete(section_id);
  }
}

function isDownloadThroughTargetSection(section, currentSectionId) {
  const sectionName = getUciSectionName(section);
  const action = (section && section.action) || "";

  if (
    !sectionName ||
    sectionName === currentSectionId ||
    section.enabled === "0"
  ) {
    return false;
  }

  if (["connection", "proxy", "outbound", "vpn"].includes(action)) {
    return true;
  }

  if (action === "zapret") {
    return isZapretInstalledForUi();
  }

  if (action === "zapret2") {
    return isZapret2InstalledForUi();
  }

  if (action === "byedpi") {
    return isByedpiInstalledForUi();
  }

  return false;
}

function subscriptionDownloadTargetChoices(section_id) {
  return (uci.sections(UCI_PACKAGE, "section") || [])
    .filter((section) => isDownloadThroughTargetSection(section, section_id))
    .map((section) => ({
      value: getUciSectionName(section),
      label: getUciSectionLabel(section),
    }));
}

function dnsTypeChoices() {
  return [
    { value: "doh", label: _("DNS over HTTPS (DoH)") },
    { value: "dot", label: _("DNS over TLS (DoT)") },
    { value: "doq", label: _("DNS over QUIC (DoQ)") },
    { value: "udp", label: "UDP" },
  ];
}

function isConnectionNetworkInterfaceAllowed(deviceName, device) {
  if (CONNECTIONS_BLOCKED_INTERFACES.includes(deviceName)) {
    return false;
  }

  if (!device) {
    return true;
  }

  const type = device.getType();
  const isWireless =
    type === "wifi" || type === "wireless" || type.indexOf("wlan") >= 0;

  return !isWireless;
}

function renderNetworkInterfaceChoice(device) {
  const name = device.getName();
  const type = device.getType();

  return E([
    E("img", {
      title: device.getI18n(),
      src: L.resource(
        "icons/%s%s.svg".format(type, device.isUp() ? "" : "_disabled"),
      ),
    }),
    E("span", { class: "hide-open" }, [name]),
    E("span", { class: "hide-close" }, [device.getI18n()]),
  ]);
}

function renderNetworkInterfaceListItem(device, fallbackName) {
  const name = device ? device.getName() : fallbackName;
  const type = device ? device.getType() : "ethernet";
  const up = device ? device.isUp() : false;

  return E("span", { class: "fkp-interface-dynlist-label" }, [
    E("img", {
      title: device ? device.getI18n() : _("Network Interface"),
      src: L.resource("icons/%s%s.svg".format(type, up ? "" : "_disabled")),
    }),
    E("span", {}, [name]),
  ]);
}

function refreshNetworkInterfaceOptionValues(option) {
  option.keylist = [];
  option.vallist = [];
  option.interfaceChoiceMap = {};
  option.interfaceDeviceMap = {};

  (option.devices || []).forEach((device) => {
    const name = device.getName();
    const type = device.getType();

    if (
      name === "lo" ||
      type === "alias" ||
      !isConnectionNetworkInterfaceAllowed(name, device)
    ) {
      return;
    }

    option.value(name, renderNetworkInterfaceChoice(device));
    option.interfaceChoiceMap[name] = true;
    option.interfaceDeviceMap[name] = device;
  });
}

const InterfaceSettingsDynamicList = SettingsDynamicList.extend({
  load(section_id) {
    return network.getDevices().then(
      L.bind(function (devices) {
        this.devices = devices || [];
        refreshNetworkInterfaceOptionValues(this);

        return this.super("load", section_id);
      }, this),
    );
  },

  validate(section_id, value) {
    value = childItemInputValue(section_id, value, "section_interface", "name");

    if (!value || value.length === 0) {
      return true;
    }

    if (!this.interfaceChoiceMap || !this.interfaceChoiceMap[value]) {
      return _("Select an existing network interface");
    }

    return true;
  },

  renderListItemLabel(section_id, value, text) {
    value = childItemInputValue(section_id, value, "section_interface", "name");

    return renderNetworkInterfaceListItem(
      this.interfaceDeviceMap ? this.interfaceDeviceMap[value] : null,
      value || text,
    );
  },

  // The backend uses the legacy `list interfaces` only while the rule has
  // no interface items (config/connections.uc interfaces()). The widget
  // shows the items only, so an empty widget keeps a legacy list it never
  // showed; a list the removed items shadowed goes with them.
  remove(section_id) {
    const ownerId = this.childOwner(section_id);
    const hadItems =
      getChildItemIds(ownerId, this.childType, this.ownerOption).length > 0;

    cleanupRemovedChildItems(ownerId, this.childType, [], this.ownerOption);
    if (hadItems) {
      uci.unset(UCI_PACKAGE, section_id, this.option);
    }
  },
});

function urlTestFilterModeChoices() {
  return [
    { value: "disabled", label: _("All servers") },
    { value: "exclude", label: _("All except selected") },
    { value: "include", label: _("Only selected") },
    { value: "mixed", label: _("Only selected except exclusions") },
  ];
}

function priorityLevelFilterModeChoices() {
  return [
    { value: "disabled", label: _("All remaining servers") },
    { value: "include", label: _("Only selected") },
    { value: "exclude", label: _("All remaining except selected") },
    { value: "mixed", label: _("Only selected except exclusions") },
  ];
}

function serverCountryDetectionChoices() {
  return [
    { value: "flag_emoji", label: _("By flag emoji from name") },
    { value: "country_is", label: _("Via country.is") },
  ];
}

function proxyProtocolChoices() {
  return [
    ["vless", "VLESS"],
    ["vmess", "VMess"],
    ["trojan", "Trojan"],
    ["shadowsocks", "Shadowsocks"],
    ["socks", "SOCKS"],
    ["http", "HTTP"],
    ["hysteria2", "Hysteria2"],
    ["direct", "Direct"],
  ];
}

function proxyTransportChoices() {
  return [
    ["tcp", "TCP"],
    ["ws", "WebSocket"],
    ["grpc", "gRPC"],
    ["http", "HTTP"],
    ["httpupgrade", "HTTPUpgrade"],
    ["xhttp", "XHTTP"],
  ];
}

function proxySecurityChoices() {
  return [
    ["none", "None"],
    ["tls", "TLS"],
    ["reality", "Reality"],
  ];
}

function addProxyParameterFilterOptions(itemSection, options) {
  const prefix = options.prefix;
  const dependencies = options.dependencies;

  let o = itemSection.option(
    form.Flag,
    `${prefix}_proxy_parameters`,
    options.toggleLabel,
    options.toggleDescription,
  );
  dependencies.forEach((dependency) => o.depends(dependency));
  o.default = "0";
  o.rmempty = false;

  [
    [
      "protocols",
      _("Protocol"),
      options.protocolDescription,
      proxyProtocolChoices(),
    ],
    [
      "transports",
      _("Transport"),
      options.transportDescription,
      proxyTransportChoices(),
    ],
    [
      "securities",
      _("Security"),
      options.securityDescription,
      proxySecurityChoices(),
    ],
  ].forEach(([suffix, label, description, choices]) => {
    const list = itemSection.option(
      form.DynamicList,
      `${prefix}_${suffix}`,
      label,
      description,
    );
    dependencies.forEach((dependency) =>
      list.depends(
        Object.assign({}, dependency, {
          [`${prefix}_proxy_parameters`]: "1",
        }),
      ),
    );
    list.rmempty = true;
    choices.forEach(([value, choiceLabel]) => list.value(value, choiceLabel));
    list.placeholder = _("-- Select --");
  });
}

function urlTestUrlChoices() {
  return Array.isArray(main.LATENCY_TEST_URL_OPTIONS)
    ? main.LATENCY_TEST_URL_OPTIONS
    : [main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204"];
}

function validateUrlTestTolerance(value) {
  if (!value || `${value}`.length === 0) {
    return _("Must be a number in the range of 0 - 10000");
  }

  const normalized = `${value}`;
  const parsed = parseFloat(normalized);
  if (
    /^[0-9]+$/.test(normalized) &&
    !isNaN(parsed) &&
    isFinite(parsed) &&
    parsed >= 0 &&
    parsed <= 10000
  ) {
    return true;
  }

  return _("Must be a number in the range of 0 - 10000");
}

function validateUrlTestUrl(value) {
  const validation = main.validateUrl(`${value || ""}`.trim());
  return validation.valid ? true : validation.message;
}

function optionMapValue(option, section_id, key) {
  const value =
    option && option.map && option.map.data
      ? option.map.data.get(option.map.config, section_id, key)
      : uci.get(UCI_PACKAGE, section_id, key);

  return value == null ? "" : value;
}

function subscriptionUrlSettingsKeys() {
  return [
    "subscription_update_enabled",
    "subscription_update_interval",
    "download_via_proxy_enabled",
    "download_via_proxy_section",
    "prefix_nodes",
    "node_prefix",
    "include_urltest_groups",
  ];
}

function defaultSubscriptionUrlSettings() {
  return {
    subscription_update_enabled: "1",
    subscription_update_interval: "4h",
    download_via_proxy_enabled: "0",
    download_via_proxy_section: "",
    prefix_nodes: "0",
    node_prefix: "",
    include_urltest_groups: "1",
  };
}

function flintnetSubscriptionUrl(value) {
  try {
    return (
      new URL(`${value || ""}`.trim()).hostname.toLowerCase() ===
      "sub.flintnet.pro"
    );
  } catch (_error) {
    return false;
  }
}

function subscriptionUrlChildDefaults() {
  return Object.assign(defaultSubscriptionUrlSettings(), {
    include_urltest_groups: (value) =>
      flintnetSubscriptionUrl(value) ? "0" : "1",
  });
}

function interfaceSettingsKeys() {
  return [
    "domain_resolver_enabled",
    "domain_resolver_dns_type",
    "domain_resolver_dns_server",
  ];
}

function defaultInterfaceSettings() {
  return {
    domain_resolver_enabled: "0",
    domain_resolver_dns_type: "udp",
    domain_resolver_dns_server: "8.8.8.8",
  };
}

function subscriptionUserAgentChoices() {
  return [
    "sing-box",
    "Happ",
    "v2rayN",
    "v2rayNG",
    "v2RayTun",
    "Incy",
    "Hiddify",
    "HiddifyNext",
    "Clash",
    "Clash.Meta",
    "ClashMetaForAndroid",
    "Mihomo",
    "NekoBox",
    "Karing",
    "Husi",
  ];
}

function urlTestSettingsKeys() {
  return [
    "name",
    "check_interval",
    "tolerance",
    "testing_url",
    "idle_timeout",
    "interrupt_exist_connections",
    "pin_dashboard",
    "filter_mode",
    "detect_server_country",
    "include_countries",
    "include_outbounds",
    "include_regex",
    "include_proxy_parameters",
    "include_protocols",
    "include_transports",
    "include_securities",
    "exclude_countries",
    "exclude_outbounds",
    "exclude_regex",
    "exclude_proxy_parameters",
    "exclude_protocols",
    "exclude_transports",
    "exclude_securities",
  ];
}

function defaultUrlTestSettings(name) {
  return {
    name: "",
    check_interval: "3m",
    tolerance: "50",
    testing_url: "https://www.gstatic.com/generate_204",
    idle_timeout: "30m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
    filter_mode: "disabled",
    detect_server_country: "flag_emoji",
  };
}

function urlTestChildDefaults() {
  return {
    check_interval: "3m",
    tolerance: "50",
    testing_url: "https://www.gstatic.com/generate_204",
    idle_timeout: "30m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
    filter_mode: "disabled",
    detect_server_country: "flag_emoji",
  };
}

function priorityGroupSettingsKeys() {
  return [
    "name",
    "health_url",
    "active_check_interval",
    "check_timeout",
    "recovery_check_interval",
    "pick_fastest",
    "switch_to_faster_same_priority",
    "fastest_check_interval",
    "interrupt_exist_connections",
    "pin_dashboard",
  ];
}

function defaultPriorityGroupSettings() {
  return {
    name: "",
    health_url: "https://www.gstatic.com/generate_204",
    active_check_interval: "5s",
    check_timeout: "2s",
    recovery_check_interval: "15s",
    pick_fastest: "0",
    switch_to_faster_same_priority: "0",
    fastest_check_interval: "3m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
  };
}

function priorityGroupChildDefaults() {
  return {
    health_url: "https://www.gstatic.com/generate_204",
    active_check_interval: "5s",
    check_timeout: "2s",
    recovery_check_interval: "15s",
    pick_fastest: "0",
    switch_to_faster_same_priority: "0",
    fastest_check_interval: "3m",
    interrupt_exist_connections: "1",
    pin_dashboard: "1",
  };
}

function priorityLevelSettingsKeys() {
  return [
    "name",
    "order",
    "direct",
    "filter_mode",
    "detect_server_country",
    "country",
    "server_name",
    "regex",
    "include_proxy_parameters",
    "include_protocols",
    "include_transports",
    "include_securities",
    "exclude_countries",
    "exclude_outbounds",
    "exclude_regex",
    "exclude_proxy_parameters",
    "exclude_protocols",
    "exclude_transports",
    "exclude_securities",
  ];
}

function defaultPriorityLevelSettings() {
  return {
    name: "",
    order: "0",
    direct: "0",
    filter_mode: "include",
    detect_server_country: "flag_emoji",
  };
}

// A named section for a group: sing-box tags it after the section name, and
// libuci names an anonymous section after its position in the file, so the
// tag (and the choice sing-box keeps for it) would change whenever a section
// before it is added or removed (UC-044).
function randomChildItemId(prefix) {
  for (let i = 0; i < 100; i += 1) {
    const value = Math.floor(Math.random() * 0xffffffff)
      .toString(16)
      .padStart(8, "0");
    const id = `${prefix}_${value}`;

    if (!uci.get(UCI_PACKAGE, id)) {
      return id;
    }
  }

  return `${prefix}_${Date.now().toString(16)}`;
}

function randomPriorityGroupId() {
  return randomChildItemId("pg");
}

function randomUrlTestId() {
  return randomChildItemId("ut");
}

function addSubscriptionUrlItemOptions(itemSection, options = {}) {
  const parentSectionForItem =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(
    form.Flag,
    "subscription_update_enabled",
    _("Subscription auto update"),
    _("Update this subscription automatically"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Value,
    "subscription_update_interval",
    _("Subscription update interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("subscription_update_enabled", "1");
  o.placeholder = "4h";
  o.validate = function (itemId, value) {
    return optionMapValue(this, itemId, "subscription_update_enabled") === "1"
      ? validateRequiredSingBoxDuration(value)
      : validateOptionalSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Flag,
    "download_via_proxy_enabled",
    _("Download subscription through a section"),
    _("Download subscriptions via the selected section"),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "download_via_proxy_section",
    _("Download through"),
  );
  o.depends("download_via_proxy_enabled", "1");
  o.load = function (itemId) {
    const sectionId = parentSectionForItem(itemId);
    const value =
      optionMapValue(this, itemId, "download_via_proxy_section") || "";
    return ensureActionProvidersAvailabilityLoaded().then(() => {
      refreshOptionChoices(this, subscriptionDownloadTargetChoices(sectionId));
      keepUnavailableChoice(this, value, describeUnavailableSection);
      return value;
    });
  };
  o.validate = function (itemId, value) {
    const sectionId = parentSectionForItem(itemId);
    if (optionMapValue(this, itemId, "download_via_proxy_enabled") !== "1") {
      return true;
    }
    if (!value) {
      return _("Select a section for downloading this subscription");
    }
    if (value === sectionId) {
      return _("Current section cannot download its own subscription");
    }
    return unavailableChoiceError(this, value) || true;
  };

  o = itemSection.option(
    form.Flag,
    "prefix_nodes",
    _("Add prefix to nodes"),
    _(
      "Automatically add text to the name of each server from this subscription for convenient filtering.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(form.Value, "node_prefix", _("Prefix text"));
  o.depends("prefix_nodes", "1");
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "include_urltest_groups",
    _("Import subscription URLTest groups"),
    _("Import URLTest groups returned by this subscription provider"),
  );
  o.default = "1";
  o.rmempty = false;
}

function addInterfaceItemOptions(itemSection) {
  let o = itemSection.option(
    form.Flag,
    "domain_resolver_enabled",
    _("Domain Resolver"),
    _("Enable built-in DNS resolver for domains handled by this section"),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "domain_resolver_dns_type",
    _("DNS protocol"),
    _("DNS protocol used by the resolver"),
  );
  o.depends("domain_resolver_enabled", "1");
  dnsTypeChoices().forEach((choice) => o.value(choice.value, choice.label));
  o.default = "udp";

  o = itemSection.option(
    form.Value,
    "domain_resolver_dns_server",
    _("DNS server"),
    _("DNS server used by the resolver"),
  );
  o.depends("domain_resolver_enabled", "1");
  o.default = "8.8.8.8";
  o.validate = function (itemId, value) {
    if (optionMapValue(this, itemId, "domain_resolver_enabled") !== "1") {
      return true;
    }
    const validation = main.validateDNSForProtocol(
      value,
      optionMapValue(this, itemId, "domain_resolver_dns_type") || "udp",
    );
    return validation.valid ? true : validation.message;
  };
}

function addUrlTestItemOptions(itemSection, options = {}) {
  const parentSectionForItem =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(
    form.Value,
    "name",
    _("Display name"),
    _("Name displayed on the dashboard"),
  );
  o.rmempty = false;
  o.load = function (itemId) {
    return (
      optionMapValue(this, itemId, "name") ||
      optionMapValue(this, itemId, "display_name") ||
      ""
    );
  };
  o.validate = function (_itemId, value) {
    return `${value || ""}`.trim() ? true : _("Enter a display name");
  };

  o = itemSection.option(
    form.Value,
    "check_interval",
    _("Check interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.default = "3m";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    "tolerance",
    _("Tolerance"),
    _(
      "Minimum latency difference in milliseconds that triggers switching to a faster server.",
    ),
  );
  o.default = "50";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateUrlTestTolerance(value);
  };

  o = itemSection.option(
    form.Value,
    "testing_url",
    _("Check URL"),
    _("URL used to test server latency"),
  );
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  urlTestUrlChoices().forEach((value) => o.value(value));
  o.validate = function (_itemId, value) {
    return validateUrlTestUrl(value);
  };

  o = itemSection.option(
    form.Value,
    "idle_timeout",
    _("Idle timeout"),
    _(
      "Stop checking when URLTest group is not used. Use sing-box duration format like 1d, 12h or 30m.",
    ),
  );
  o.default = "30m";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Flag,
    "interrupt_exist_connections",
    _("Interrupt connections"),
    _("Interrupt connections when URLTest switches the selected server"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "pin_dashboard",
    _("Pin on dashboard"),
    _("Keep URLTest before latency-sorted servers"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "filter_mode",
    _("Server filtering"),
    _("Allows limiting the list of servers for URLTest"),
  );
  urlTestFilterModeChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "disabled";

  o = itemSection.option(
    form.ListValue,
    "detect_server_country",
    _("Detect server country"),
  );
  o.depends("filter_mode", "exclude");
  o.depends("filter_mode", "include");
  o.depends("filter_mode", "mixed");
  serverCountryDetectionChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "flag_emoji";

  const includeProxyParameterOptions = {
    prefix: "include",
    toggleLabel: _("Include by proxy parameters"),
    toggleDescription: _(
      "Additionally filter servers by protocol, transport, and security. Add only servers matching the specified parameters.",
    ),
    dependencies: [{ filter_mode: "include" }, { filter_mode: "mixed" }],
    protocolDescription: _(
      "Test only servers with one of the selected protocols.",
    ),
    transportDescription: _(
      "Test only servers with one of the selected transports.",
    ),
    securityDescription: _(
      "Test only servers with one of the selected security types.",
    ),
  };
  const excludeProxyParameterOptions = {
    prefix: "exclude",
    toggleLabel: _("Exclude by proxy parameters"),
    toggleDescription: _(
      "Additionally exclude servers by protocol, transport, and security. Exclude only servers matching the specified parameters.",
    ),
    dependencies: [{ filter_mode: "exclude" }, { filter_mode: "mixed" }],
    protocolDescription: _(
      "Do not test servers with one of the selected protocols.",
    ),
    transportDescription: _(
      "Do not test servers with one of the selected transports.",
    ),
    securityDescription: _(
      "Do not test servers with one of the selected security types.",
    ),
  };

  [
    [
      "include_countries",
      _("Include countries"),
      _("Test servers only from the specified countries."),
      countryChoices(),
      validateCountryCode,
      ["include", "mixed"],
    ],
    [
      "include_outbounds",
      _("Include servers"),
      _("Test only selected servers."),
      null,
      null,
      ["include", "mixed"],
    ],
    [
      "include_regex",
      _("Include by regular expression"),
      _("Test servers whose names match the expression."),
      null,
      validateRegex,
      ["include", "mixed"],
    ],
    [
      "exclude_countries",
      _("Exclude countries"),
      _("Do not test servers from these countries."),
      countryChoices(),
      validateCountryCode,
      ["exclude", "mixed"],
    ],
    [
      "exclude_outbounds",
      _("Exclude servers"),
      _("Do not test specified servers."),
      null,
      null,
      ["exclude", "mixed"],
    ],
    [
      "exclude_regex",
      _("Exclude by regular expression"),
      _("Do not test servers whose names match the expression."),
      null,
      validateRegex,
      ["exclude", "mixed"],
    ],
  ].forEach(([key, label, description, choices, validator, modes]) => {
    const list = itemSection.option(form.DynamicList, key, label, description);
    modes.forEach((mode) => list.depends("filter_mode", mode));
    list.rmempty = true;
    if (choices) {
      choices.forEach((choice) => list.value(choice.value, choice.label));
      list.placeholder = _("-- Select --");
    }
    if (key.endsWith("_outbounds")) {
      list.load = function (itemId) {
        const sectionId = parentSectionForItem(itemId);
        const values = normalizeOptionValues(optionMapValue(this, itemId, key));

        return loadOutboundNameChoices(sectionId).then(() => {
          refreshOptionChoices(
            this,
            currentOutboundNameChoices(sectionId, values),
          );
          return values;
        });
      };
      list.placeholder = _("-- Select --");
      configureLiveDynamicListChoices(list, (itemId, values) =>
        currentOutboundNameChoices(parentSectionForItem(itemId), values),
      );
    }
    if (validator) {
      list.validate = function (_itemId, value) {
        return validator(null, value);
      };
    }
    if (key === "include_regex") {
      addProxyParameterFilterOptions(itemSection, includeProxyParameterOptions);
    } else if (key === "exclude_regex") {
      addProxyParameterFilterOptions(itemSection, excludeProxyParameterOptions);
    }
  });
}

function priorityLevelSettingsForValidation(groupId, levelId, option) {
  const store = childPendingSettingsStore(option, groupId);

  if (isExistingChildItem(groupId, levelId, "priority_level", "group")) {
    return readChildSettings(
      levelId,
      priorityLevelSettingsKeys(),
      defaultPriorityLevelSettings(),
    );
  }

  return Object.assign({}, store[levelId] || {});
}

function validatePriorityLevelItemsBeforeSave(groupId, values, option) {
  const normalizedValues = normalizeDynamicListItems(values);

  for (const value of normalizedValues) {
    const levelId = `${value || ""}`;
    const settings = priorityLevelSettingsForValidation(
      groupId,
      levelId,
      option,
    );

    if (!`${settings.name || ""}`.trim()) {
      return _("Enter a level name");
    }
  }

  return true;
}

function addPriorityLevelItemOptions(itemSection, options = {}) {
  const parentSectionForItem =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;

  let o = itemSection.option(
    form.Value,
    "name",
    _("Level name"),
    _("Name shown in the priority level list"),
  );
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return `${value || ""}`.trim() ? true : _("Enter a level name");
  };

  o = itemSection.option(
    form.Flag,
    "direct",
    _("Direct connection"),
    _("Traffic for this level goes directly."),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.ListValue,
    "filter_mode",
    _("Server filtering"),
    _(
      "All remaining servers means every server not already assigned to a higher-priority level.",
    ),
  );
  priorityLevelFilterModeChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "include";
  o.depends("direct", "0");

  o = itemSection.option(
    form.ListValue,
    "detect_server_country",
    _("Detect server country"),
  );
  ["exclude", "include", "mixed"].forEach((mode) =>
    o.depends({ direct: "0", filter_mode: mode }),
  );
  serverCountryDetectionChoices().forEach((choice) =>
    o.value(choice.value, choice.label),
  );
  o.default = "flag_emoji";

  const includeProxyParameterOptions = {
    prefix: "include",
    toggleLabel: _("Include by proxy parameters"),
    toggleDescription: _(
      "Additionally filter servers by protocol, transport, and security. Add only servers matching the specified parameters.",
    ),
    dependencies: [
      { direct: "0", filter_mode: "include" },
      { direct: "0", filter_mode: "mixed" },
    ],
    protocolDescription: _("Only servers with one of the selected protocols."),
    transportDescription: _(
      "Only servers with one of the selected transports.",
    ),
    securityDescription: _(
      "Only servers with one of the selected security types.",
    ),
  };
  const excludeProxyParameterOptions = {
    prefix: "exclude",
    toggleLabel: _("Exclude by proxy parameters"),
    toggleDescription: _(
      "Additionally exclude servers by protocol, transport, and security. Exclude only servers matching the specified parameters.",
    ),
    dependencies: [
      { direct: "0", filter_mode: "exclude" },
      { direct: "0", filter_mode: "mixed" },
    ],
    protocolDescription: _(
      "Exclude servers with one of the selected protocols from this level.",
    ),
    transportDescription: _(
      "Exclude servers with one of the selected transports from this level.",
    ),
    securityDescription: _(
      "Exclude servers with one of the selected security types from this level.",
    ),
  };

  [
    [
      "country",
      _("Include countries"),
      _("Only from the specified countries."),
      countryChoices(),
      validateCountryCode,
      ["include", "mixed"],
    ],
    [
      "server_name",
      _("Include servers"),
      _("Only the specified servers."),
      null,
      null,
      ["include", "mixed"],
    ],
    [
      "regex",
      _("Include by regular expression"),
      _("Only servers whose names match the expression."),
      null,
      validateRegex,
      ["include", "mixed"],
    ],
    [
      "exclude_countries",
      _("Exclude countries"),
      _("Remove servers from the specified countries from this level."),
      countryChoices(),
      validateCountryCode,
      ["exclude", "mixed"],
    ],
    [
      "exclude_outbounds",
      _("Exclude servers"),
      _("Remove the specified servers from this level."),
      null,
      null,
      ["exclude", "mixed"],
    ],
    [
      "exclude_regex",
      _("Exclude by regular expression"),
      _("Remove servers whose names match the expression from this level."),
      null,
      validateRegex,
      ["exclude", "mixed"],
    ],
  ].forEach(([key, label, description, choices, validator, modes]) => {
    const list = itemSection.option(form.DynamicList, key, label, description);
    modes.forEach((mode) => list.depends({ direct: "0", filter_mode: mode }));
    list.rmempty = true;
    if (choices) {
      choices.forEach((choice) => list.value(choice.value, choice.label));
      list.placeholder = _("-- Select --");
    }
    if (key === "server_name" || key === "exclude_outbounds") {
      list.load = function (itemId) {
        const sectionId = parentSectionForItem(itemId);
        const values = normalizeOptionValues(optionMapValue(this, itemId, key));

        return loadOutboundNameChoices(sectionId).then(() => {
          refreshOptionChoices(
            this,
            currentOutboundNameChoices(sectionId, values),
          );
          return values;
        });
      };
      list.placeholder = _("-- Select --");
      configureLiveDynamicListChoices(list, (itemId, values) =>
        currentOutboundNameChoices(parentSectionForItem(itemId), values),
      );
    }
    if (validator) {
      list.validate = function (_itemId, value) {
        return validator(null, value);
      };
    }
    if (key === "regex") {
      addProxyParameterFilterOptions(itemSection, includeProxyParameterOptions);
    } else if (key === "exclude_regex") {
      addProxyParameterFilterOptions(itemSection, excludeProxyParameterOptions);
    }
  });
}

function addPriorityGroupItemOptions(itemSection, options = {}) {
  const parentSectionForGroup =
    typeof options.parentSectionId === "function"
      ? options.parentSectionId
      : parentSectionIdForItem;
  const ownerId =
    typeof options.ownerId === "function" ? options.ownerId : () => "";

  let o = itemSection.option(
    form.Value,
    "name",
    _("Display name"),
    _("Name displayed on the dashboard"),
  );
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return `${value || ""}`.trim() ? true : _("Enter a display name");
  };

  o = itemSection.option(
    form.Value,
    "health_url",
    _("Check URL"),
    _("URL used to check whether a server is alive"),
  );
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  urlTestUrlChoices().forEach((value) => o.value(value));
  o.validate = function (_itemId, value) {
    return validateUrlTestUrl(value);
  };

  o = itemSection.option(
    form.Value,
    "active_check_interval",
    _("Check interval"),
    _("How often the currently selected server is checked"),
  );
  o.default = "5s";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    "check_timeout",
    _("Unavailability timeout"),
    _("Check timeout after which the server is considered dead"),
  );
  o.default = "2s";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Value,
    "recovery_check_interval",
    _("Higher-level check interval"),
    _(
      "How often higher priority levels are checked while a lower level is active",
    ),
  );
  o.default = "15s";
  o.rmempty = false;
  o.validate = function (_itemId, value) {
    return validateRequiredSingBoxDuration(value);
  };

  o = itemSection.option(
    form.Flag,
    "pick_fastest",
    _("Select the fastest node"),
    _(
      "When switching to another level, test every server and select the fastest instead of the first working one.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "switch_to_faster_same_priority",
    _("Automatically select the fastest node in the current level"),
    _(
      "Periodically check the current level and switch to a faster server even when the current one works.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = itemSection.option(
    form.Value,
    "fastest_check_interval",
    _("Faster server search interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("switch_to_faster_same_priority", "1");
  o.default = "3m";
  o.rmempty = false;
  o.validate = function (itemId, value) {
    return optionMapValue(this, itemId, "switch_to_faster_same_priority") ===
      "1"
      ? validateRequiredSingBoxDuration(value)
      : true;
  };

  o = itemSection.option(
    form.Flag,
    "interrupt_exist_connections",
    _("Interrupt connections"),
    _("Interrupt connections when priority failover switches server"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    form.Flag,
    "pin_dashboard",
    _("Pin on dashboard"),
    _("Keep Priority before latency-sorted servers"),
  );
  o.default = "1";
  o.rmempty = false;

  o = itemSection.option(
    ButtonAddSettingsDynamicList,
    "priority_level",
    _("Priority levels"),
    _("Top level has the highest priority; lower levels are used as fallback"),
  );
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add level");
  o.childType = "priority_level";
  o.ownerOption = "group";
  o.childOwnerId = ownerId;
  o.parentSectionId = parentSectionForGroup;
  o.childValueOption = "name";
  o.childDefaults = defaultPriorityLevelSettings();
  o.renderItemSettingsModal = showPriorityLevelSettingsModal;
  o.validateItemsOnSave = function (groupId, values) {
    return validatePriorityLevelItemsBeforeSave(groupId, values, this);
  };
  o.hasItemSettings = function (groupId, value) {
    const normalized = `${value || ""}`.trim();

    if (isExistingChildItem(groupId, normalized, "priority_level", "group")) {
      return true;
    }

    return normalized.length > 0;
  };
  o.inputValueForItem = function (groupId, value) {
    const inputValue = childItemInputValue(
      groupId,
      value,
      "priority_level",
      "name",
      "group",
    );
    const store = childPendingSettingsStore(this, groupId);
    return store[inputValue] && store[inputValue].name
      ? store[inputValue].name
      : inputValue;
  };
  o.stagedChildSettings = function (groupId, value) {
    const id = childItemInputValue(
      groupId,
      value,
      "priority_level",
      "name",
      "group",
    );
    const store = childPendingSettingsStore(this, groupId);
    return store[id] ? Object.assign({}, store[id]) : null;
  };
  o.clearStagedChildSettings = function (groupId) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[groupId];
    }
  };
  o.afterMaterializeChildItems = function (_groupId, itemIds) {
    itemIds.forEach((itemId, index) => {
      uci.set(UCI_PACKAGE, itemId, "order", `${index}`);
    });
  };
  o.renderListItemLabel = function (groupId, itemId) {
    return E(
      "span",
      { class: "fkp-dynlist-label" },
      this.inputValueForItem(groupId, itemId),
    );
  };
}

function settingValueEquals(left, right) {
  const normalize = (value) => {
    if (Array.isArray(value)) {
      return JSON.stringify(value.map((item) => `${item || ""}`));
    }

    return value === undefined || value === null ? "" : `${value}`;
  };

  return normalize(left) === normalize(right);
}

function readChildSettings(itemId, keys, defaults) {
  const result = Object.assign({}, defaults || {});

  keys.forEach((key) => {
    const value = uci.get(UCI_PACKAGE, itemId, key);
    if (value !== null && value !== undefined) {
      result[key] = Array.isArray(value) ? value.slice() : value;
    }
  });

  return result;
}

function changedSettings(base, next, keys) {
  const result = {};

  keys.forEach((key) => {
    if (!settingValueEquals(base ? base[key] : null, next ? next[key] : null)) {
      result[key] = next ? next[key] : null;
    }
  });

  return result;
}

function hasChangedSettings(settings) {
  return Object.keys(settings || {}).length > 0;
}

function childPendingSettingsStore(option, section_id) {
  if (!option.pendingChildSettings) {
    option.pendingChildSettings = {};
  }

  if (!option.pendingChildSettings[section_id]) {
    option.pendingChildSettings[section_id] = {};
  }

  return option.pendingChildSettings[section_id];
}

function pendingChildSettings(option, section_id, value, defaults) {
  value = `${value || ""}`.trim();
  const store = childPendingSettingsStore(option, section_id);

  if (!store[value]) {
    store[value] = Object.assign({}, defaults || {});
  }

  return store[value];
}

function renderStackedJsonSettingsModal(title, map, onSave) {
  const modal = document.querySelector("#modal_overlay > .modal.cbi-modal");
  const activeMap = modal ? modal.querySelector(".cbi-map:not(.hidden)") : null;
  const buttonRow = modal ? modal.querySelector("div.button-row") : null;
  const heading = modal ? modal.querySelector("h4") : null;

  if (!modal || !activeMap || !buttonRow || !heading) {
    return Promise.resolve();
  }

  return map.render().then((nodes) => {
    const titleNode = E("span", title ? ` » ${title}` : "");
    const originalButtonClass = buttonRow.getAttribute("class") || "";
    const originalButtonNodes = Array.from(buttonRow.childNodes);
    let closed = false;
    let saveButton;
    let validationSummary;

    const clearValidationSummary = () => {
      if (validationSummary && validationSummary.parentNode) {
        validationSummary.parentNode.removeChild(validationSummary);
      }
      validationSummary = null;
    };

    const showValidationSummary = (error) => {
      clearValidationSummary();

      const message = error?.message || "";
      validationSummary = E(
        "div",
        {
          class:
            "alert-message warning fkp-stacked-settings-validation-summary",
        },
        [
          E("strong", {}, _("Cannot save settings")),
          E("div", {}, _("Fix the highlighted fields and save again.")),
          message ? E("small", {}, message) : "",
        ],
      );
      buttonRow.parentNode.insertBefore(validationSummary, buttonRow);

      const invalidInput = nodes.querySelector(".cbi-input-invalid");
      if (invalidInput) {
        invalidInput.scrollIntoView({ block: "center", behavior: "smooth" });
        invalidInput.focus({ preventScroll: true });
      }
    };

    const restoreButtonRow = () => {
      buttonRow.textContent = "";
      originalButtonNodes.forEach((node) => buttonRow.appendChild(node));
      buttonRow.setAttribute("class", originalButtonClass);
    };

    const close = () => {
      if (closed) {
        return;
      }

      closed = true;
      clearValidationSummary();

      if (nodes.parentNode) {
        nodes.parentNode.removeChild(nodes);
      }
      if (titleNode.parentNode) {
        titleNode.parentNode.removeChild(titleNode);
      }

      activeMap.classList.remove("hidden");
      restoreButtonRow();
    };

    const save = () => {
      if (saveButton) {
        saveButton.disabled = true;
      }
      clearValidationSummary();

      return map
        .parse()
        .then(() => {
          onSave(cleanFormSectionData(map.data.get(map.config, "settings")));
          close();
        })
        .catch((error) => {
          if (saveButton) {
            saveButton.disabled = false;
          }
          showValidationSummary(error);
        });
    };

    buttonRow.textContent = "";
    buttonRow.append(
      E(
        "button",
        {
          class: "btn cbi-button",
          click: close,
        },
        _("Close"),
      ),
      " ",
      (saveButton = E(
        "button",
        {
          class: "btn cbi-button cbi-button-positive important",
          click: save,
        },
        _("Save"),
      )),
    );

    heading.appendChild(titleNode);
    activeMap.classList.add("hidden");
    activeMap.parentNode.insertBefore(nodes, activeMap.nextElementSibling);
  });
}

function showChildItemSettingsModal(section_id, itemValue, option, settings) {
  const value = `${itemValue || ""}`.trim();
  const existing = isExistingChildItem(
    section_id,
    value,
    settings.typeName,
    settings.ownerOption,
  );
  const inputValue = childItemInputValue(
    section_id,
    value,
    settings.typeName,
    settings.valueOption,
    settings.ownerOption,
  );
  const defaults =
    typeof settings.defaults === "function"
      ? settings.defaults(inputValue)
      : Object.assign({}, settings.defaults || {});
  const initialSettings = existing
    ? readChildSettings(value, settings.keys, defaults)
    : Object.assign(
        {},
        pendingChildSettings(option, section_id, inputValue, defaults),
      );
  const data = {
    settings: Object.assign({}, initialSettings),
  };
  const map = new form.JSONMap(data);
  const itemSection = map.section(form.NamedSection, "settings");
  itemSection.anonymous = true;
  itemSection.addremove = false;
  settings.addOptions(itemSection, {
    parentSectionId: () => section_id,
    ownerId: () => value || section_id,
  });

  return renderStackedJsonSettingsModal(
    settings.title(inputValue),
    map,
    (nextSettings) => {
      if (existing) {
        const diff = changedSettings(
          initialSettings,
          nextSettings,
          settings.keys,
        );
        if (hasChangedSettings(diff)) {
          applyChildItemSettings(value, diff);
        }
        if (typeof settings.afterSave === "function") {
          settings.afterSave(value, inputValue, nextSettings, existing);
        }
        return;
      }

      const nextInputValue =
        `${nextSettings[settings.valueOption] || inputValue || ""}`.trim();
      const store = childPendingSettingsStore(option, section_id);
      if (nextInputValue !== inputValue) {
        delete store[inputValue];
      }
      store[nextInputValue] = nextSettings;
      if (typeof settings.afterSave === "function") {
        settings.afterSave(value, nextInputValue, nextSettings, existing);
      }
    },
  );
}

function ruleSetIncludesSubnets(section_id, value) {
  const settings = readItemSettingsMap(section_id, RULE_SET_ITEM_SETTINGS_KEY);
  const itemSettings = settings && settings[value];

  if (
    itemSettings &&
    typeof itemSettings === "object" &&
    itemSettings.include_subnets != null
  ) {
    return itemSettingsFlag(itemSettings, "include_subnets", false);
  }

  return getConfigListValues(section_id, "rule_set_with_subnets").includes(
    value,
  );
}

function showSubscriptionUrlSettingsModal(_section_id, itemValue, option) {
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: "subscription_url",
    valueOption: "url",
    keys: subscriptionUrlSettingsKeys(),
    defaults: defaultSubscriptionUrlSettings(),
    addOptions: addSubscriptionUrlItemOptions,
    title: () => _("Subscription URL settings"),
  });
}

function showInterfaceSettingsModal(_section_id, itemValue, option) {
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: "section_interface",
    valueOption: "name",
    keys: interfaceSettingsKeys(),
    defaults: defaultInterfaceSettings(),
    addOptions: addInterfaceItemOptions,
    title: () => _("Network interface settings"),
  });
}

function showUrlTestSettingsModal(
  _section_id,
  itemValue,
  option,
  widget,
  itemNode,
  context = {},
) {
  return showChildItemSettingsModal(_section_id, itemValue, option, {
    typeName: "urltest",
    valueOption: "name",
    keys: urlTestSettingsKeys(),
    defaults: defaultUrlTestSettings,
    addOptions: addUrlTestItemOptions,
    title: (name) => {
      const normalized = `${name || ""}`.trim();
      return !normalized || /^urltest-[a-z0-9]+-\d+$/.test(normalized)
        ? _("URLTest settings")
        : `${_("URLTest settings")}: ${normalized}`;
    },
    afterSave: (itemId, inputValue, settings, existing) => {
      const displayName = `${settings.name || inputValue || ""}`.trim();

      if (existing) {
        uci.unset(UCI_PACKAGE, itemId, "id");
        uci.unset(UCI_PACKAGE, itemId, "display_name");
        updateDynamicListItemLabel(itemNode, displayName);
        return;
      }

      if (context.adding) {
        addDynamicListItem(widget, displayName, displayName);
      } else {
        updateDynamicListItemLabel(itemNode, displayName);
      }
    },
  });
}

function showPriorityLevelSettingsModal(
  groupId,
  itemValue,
  option,
  widget,
  itemNode,
  context = {},
) {
  return showChildItemSettingsModal(groupId, itemValue, option, {
    typeName: "priority_level",
    ownerOption: "group",
    valueOption: "name",
    keys: priorityLevelSettingsKeys(),
    defaults: defaultPriorityLevelSettings(),
    addOptions: (itemSection) =>
      addPriorityLevelItemOptions(itemSection, {
        parentSectionId: () => context.parentSectionId || "",
      }),
    title: (name) => {
      const normalized = `${name || ""}`.trim();
      return normalized
        ? `${_("Priority level settings")}: ${normalized}`
        : _("Priority level settings");
    },
    afterSave: (itemId, inputValue, settings, existing) => {
      const displayName = `${settings.name || inputValue || ""}`.trim();

      if (existing) {
        updateDynamicListItemLabel(itemNode, displayName);
        return;
      }

      if (context.adding) {
        addDynamicListItem(widget, displayName, displayName);
      } else {
        updateDynamicListItemLabel(itemNode, displayName);
      }
    },
  });
}

function createPriorityGroupItem(section_id, groupId, settings) {
  const created = uci.add(UCI_PACKAGE, "priority_group", groupId) || groupId;

  uci.set(UCI_PACKAGE, created, "section", section_id);
  Object.entries(priorityGroupChildDefaults()).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== "") {
      uci.set(UCI_PACKAGE, created, key, `${value}`);
    }
  });
  applyChildItemSettings(created, settings);

  return created;
}

function showPriorityGroupSettingsModal(
  section_id,
  itemValue,
  option,
  widget,
  itemNode,
  context = {},
) {
  const groupId = context.adding
    ? randomPriorityGroupId()
    : `${itemValue || ""}`.trim();

  if (!groupId) {
    return null;
  }

  return showChildItemSettingsModal(section_id, groupId, option, {
    typeName: "priority_group",
    valueOption: "name",
    keys: priorityGroupSettingsKeys(),
    defaults: defaultPriorityGroupSettings(),
    addOptions: addPriorityGroupItemOptions,
    title: (name) => {
      if (context.adding) {
        return _("Priority settings");
      }

      const normalized = `${name || ""}`.trim();
      return normalized
        ? `${_("Priority settings")}: ${normalized}`
        : _("Priority settings");
    },
    afterSave: (itemId, inputValue, settings, existing) => {
      const displayName = `${settings.name || inputValue || ""}`.trim();

      if (!existing) {
        const created = createPriorityGroupItem(section_id, groupId, settings);
        const store = childPendingSettingsStore(option, section_id);
        delete store[groupId];
        delete store[inputValue];
        delete store[displayName];
        addDynamicListItem(widget, created, displayName);
        return;
      }

      updateDynamicListItemLabel(itemNode, displayName);
    },
  });
}

function validateUrlTestItemsBeforeSave(section_id, values, option) {
  const store = childPendingSettingsStore(option, section_id);

  for (const value of normalizeDynamicListItems(values)) {
    const itemId = `${value || ""}`;
    let name = "";

    if (isExistingChildItem(section_id, itemId, "urltest")) {
      name =
        uci.get(UCI_PACKAGE, itemId, "name") ||
        uci.get(UCI_PACKAGE, itemId, "display_name") ||
        "";
    } else if (store[itemId]) {
      name = store[itemId].name || "";
    }

    if (!`${name || ""}`.trim()) {
      return _("Enter a display name");
    }
  }

  return true;
}

function validatePriorityGroupItemsBeforeSave(section_id, values) {
  for (const value of normalizeDynamicListItems(values)) {
    const groupId = `${value || ""}`.trim();

    if (!isExistingChildItem(section_id, groupId, "priority_group")) {
      return _("Open priority settings and enter a display name");
    }

    if (!`${uci.get(UCI_PACKAGE, groupId, "name") || ""}`.trim()) {
      return _("Enter a display name");
    }
  }

  return true;
}

function showOutboundJsonSettingsModal(
  _section_id,
  itemValue,
  _option,
  widget,
  itemNode,
  context = {},
) {
  const data = {
    settings: {
      outbound_json: `${itemValue || ""}`,
    },
  };
  const map = new form.JSONMap(data);
  const itemSection = map.section(form.NamedSection, "settings");
  itemSection.anonymous = true;
  itemSection.addremove = false;

  const jsonOption = itemSection.option(
    form.TextValue,
    "outbound_json",
    _("JSON outbound"),
    _("Enter a complete sing-box outbound object"),
  );
  jsonOption.rows = 12;
  jsonOption.wrap = "soft";
  jsonOption.textarea = true;
  jsonOption.modalonly = true;
  jsonOption.rmempty = false;
  jsonOption.validate = function (_itemId, value) {
    const usedTags =
      widget && widget.node
        ? Array.from(widget.node.querySelectorAll(".item"))
            .filter((item) => item !== itemNode)
            .map((item) =>
              outboundJsonDisplayTag(dynamicListItemCurrentValue(item, "")),
            )
            .filter(Boolean)
        : [];
    const validation = main.validateOutboundJson(`${value || ""}`, usedTags);
    return validation.valid ? true : validation.message;
  };
  configureTextareaOption(jsonOption);

  return renderStackedJsonSettingsModal(
    _("JSON outbound settings"),
    map,
    (settings) => {
      const value = `${settings.outbound_json || ""}`.trim();
      if (context.adding) {
        addDynamicListItem(widget, value);
        return;
      }

      setDynamicListItemValue(itemNode, value);
      updateDynamicListItemLabel(itemNode, outboundJsonDisplayTag(value));
      if (widget && widget.node) {
        widget.dispatchCbiDynlistChange(widget.node, value);
      }
    },
  );
}

function validateOutboundJsonItemsBeforeSave(_section_id, values) {
  const items = Array.isArray(values) ? values : values ? [values] : [];
  const tags = [];

  for (const value of items) {
    const validation = main.validateOutboundJson(`${value || ""}`, tags);
    if (!validation.valid) {
      const tag = outboundJsonDisplayTag(value);
      return tag ? `${tag}: ${validation.message}` : validation.message;
    }

    const tag = outboundJsonDisplayTag(value);
    tags.push(tag);
  }

  return true;
}

function showRuleSetSettingsModal(section_id, itemValue, option, widget) {
  const data = {
    settings: {
      include_subnets: ruleSetIncludesSubnets(section_id, itemValue)
        ? "1"
        : "0",
    },
  };
  const map = new form.JSONMap(data);
  const section = map.section(form.NamedSection, "settings");
  section.anonymous = true;
  section.addremove = false;

  const includeSubnets = section.option(
    form.Flag,
    "include_subnets",
    _("Include IP addresses and subnets"),
    _("Subnets from the list will be extracted and added to nftables"),
  );
  includeSubnets.default = "0";
  includeSubnets.rmempty = false;

  return renderStackedJsonSettingsModal(
    _("Rule set settings"),
    map,
    (settings) => {
      const value = settings.include_subnets === "1";
      const refs = uniqueDynamicListItems(
        widget && typeof widget.getValue === "function"
          ? widget.getValue()
          : getCustomRulesetReferences(section_id),
      );
      // Built-in rule sets #2 share rule_set_with_subnets but are not part
      // of this widget: keep them.
      const subnets = new Set(
        getConfigListValues(section_id, "rule_set_with_subnets").filter(
          (ref) => secondaryRulesetId(ref) || refs.includes(ref),
        ),
      );

      if (value) {
        subnets.add(itemValue);
      } else {
        subnets.delete(itemValue);
      }

      writeListOption(
        section_id,
        "rule_set",
        refs.filter((ref) => !subnets.has(ref)),
      );
      writeListOption(section_id, "rule_set_with_subnets", [...subnets]);
      if (option && typeof option.getUIElement === "function") {
        option.getUIElement(section_id).setValue(refs);
      }
    },
  );
}

function ensureActionProvidersAvailabilityLoaded() {
  if (actionProvidersAvailabilityState.loaded) {
    return Promise.resolve(actionProvidersAvailabilityState);
  }

  if (actionProvidersAvailabilityPromise) {
    return actionProvidersAvailabilityPromise;
  }

  if (actionProvidersAvailabilityLoader) {
    actionProvidersAvailabilityPromise = actionProvidersAvailabilityLoader()
      .then((capabilities) => {
        updateActionProvidersAvailabilityState({
          zapretInstalled: Boolean(capabilities?.zapretInstalled),
          zapret2Installed: Boolean(capabilities?.zapret2Installed),
          byedpiInstalled: Boolean(capabilities?.byedpiInstalled),
        });
        return actionProvidersAvailabilityState;
      })
      .catch(() => {
        actionProvidersAvailabilityLoader = null;
        actionProvidersAvailabilityPromise = null;
        return ensureActionProvidersAvailabilityLoaded();
      })
      .finally(() => {
        actionProvidersAvailabilityPromise = null;
      });

    return actionProvidersAvailabilityPromise;
  }

  actionProvidersAvailabilityPromise = Promise.allSettled([
    main.ForkopShellMethods.checkZapretRuntime(),
    main.ForkopShellMethods.checkZapret2Runtime(),
    main.ForkopShellMethods.checkByedpiRuntime(),
  ])
    .then(([zapretResult, zapret2Result, byedpiResult]) => {
      const zapret =
        zapretResult && zapretResult.status === "fulfilled"
          ? zapretResult.value
          : null;
      const zapret2 =
        zapret2Result && zapret2Result.status === "fulfilled"
          ? zapret2Result.value
          : null;
      const byedpi =
        byedpiResult && byedpiResult.status === "fulfilled"
          ? byedpiResult.value
          : null;

      actionProvidersAvailabilityState.loaded = true;
      actionProvidersAvailabilityState.zapretInstalled = Boolean(
        zapret && zapret.success && zapret.data && zapret.data.zapret_installed,
      );
      actionProvidersAvailabilityState.zapret2Installed = Boolean(
        zapret2 &&
          zapret2.success &&
          zapret2.data &&
          zapret2.data.zapret2_installed,
      );
      actionProvidersAvailabilityState.byedpiInstalled = Boolean(
        byedpi && byedpi.success && byedpi.data && byedpi.data.byedpi_installed,
      );
      return actionProvidersAvailabilityState;
    })
    .catch(() => {
      actionProvidersAvailabilityState.loaded = true;
      actionProvidersAvailabilityState.zapretInstalled = false;
      actionProvidersAvailabilityState.zapret2Installed = false;
      actionProvidersAvailabilityState.byedpiInstalled = false;
      return actionProvidersAvailabilityState;
    })
    .finally(() => {
      actionProvidersAvailabilityPromise = null;
    });

  return actionProvidersAvailabilityPromise;
}

function isZapretInstalledForUi() {
  return actionProvidersAvailabilityState.zapretInstalled;
}

function isZapret2InstalledForUi() {
  return actionProvidersAvailabilityState.zapret2Installed;
}

function isByedpiInstalledForUi() {
  return actionProvidersAvailabilityState.byedpiInstalled;
}

function getRuleConfiguredAction(section_id) {
  const action = uci.get(UCI_PACKAGE, section_id, "action");
  return action ? `${action}` : null;
}

function getRuleResolvedAction(section_id) {
  return getRuleConfiguredAction(section_id) || "connection";
}

function getActionOptionLabel(action) {
  switch (`${action}`) {
    case "block":
      return _("Block");
    case "bypass":
      return _("Bypass");
    case "connection":
      return _("Connection");
    case "dns":
      return "DNS";
    case "vpn":
      return "VPN";
    case "zapret":
      return "Zapret";
    case "zapret2":
      return "Zapret2";
    case "byedpi":
      return "ByeDPI";
    case "outbound":
      return _("JSON outbound");
    case "proxy":
    default:
      return _("Proxy");
  }
}

// DPI providers read as "DPI · <provider>", the same words Monitoring and
// Diagnostics use for the path of a connection.
function getRuleActionDisplayValue(section_id) {
  const action = getRuleResolvedAction(section_id);

  if (action === "zapret" || action === "zapret2" || action === "byedpi") {
    return `${_("DPI")} · ${getActionOptionLabel(action)}`;
  }

  return getActionOptionLabel(action);
}

function countConfigValues(section_id, keys) {
  return keys.reduce((total, key) => {
    const value = uci.get(UCI_PACKAGE, section_id, key);
    if (Array.isArray(value)) return total + value.length;
    return value ? total + main.parseValueList(`${value}`).length : total;
  }, 0);
}

// Grid summary: how much the rule matches, without opening the editor. It
// counts what the backend matches, legacy options included (UC-042).
function getRuleConditionsSummary(section_id) {
  const parts = [
    [
      _("Lists: %d"),
      countConfigValues(section_id, [
        "community_lists",
        "rule_set",
        "rule_set_with_subnets",
        "domain_ip_lists",
        "remote_domain_lists",
        "remote_subnet_lists",
      ]),
    ],
    [
      _("Domains: %d"),
      main.parseValueList(loadCombinedDomainText(section_id)).length,
    ],
    [_("IPs: %d"), backendConditionValues(section_id, "ip_cidr").values.length],
    [_("Ports: %d"), backendPortValues(section_id).length],
  ]
    .filter(([, count]) => count > 0)
    .map(([label, count]) => label.format(count));

  return parts.length ? parts.join(" · ") : "—";
}

function getRuleDevicesSummary(section_id) {
  const only = backendConditionValues(section_id, "source_ip_cidr").values
    .length;
  const except = backendConditionValues(section_id, "excluded_source_ip_cidr")
    .values.length;
  const forced = countConfigValues(section_id, ["fully_routed_ips"]);
  const parts = [
    only ? _("Only: %d").format(only) : "",
    except ? _("Except: %d").format(except) : "",
    forced ? _("All traffic: %d").format(forced) : "",
  ].filter(Boolean);

  return parts.length ? parts.join(" · ") : _("All devices");
}

function getRuleActionDisplayMarkup(section_id) {
  return getRuleActionDisplayValue(section_id);
}

function populateActionOptionValues(option, section_id) {
  delete option.keylist;
  delete option.vallist;

  option.value("connection", getActionOptionLabel("connection"));
  option.value("bypass", getActionOptionLabel("bypass"));
  option.value("block", getActionOptionLabel("block"));
  option.value("dns", "DNS");
  if (isZapretInstalledForUi()) {
    option.value("zapret", getActionOptionLabel("zapret"));
  }
  if (isZapret2InstalledForUi()) {
    option.value("zapret2", getActionOptionLabel("zapret2"));
  }
  if (isByedpiInstalledForUi()) {
    option.value("byedpi", getActionOptionLabel("byedpi"));
  }

  // A DPI rule whose provider is missing keeps its action (UC-008).
  const configured = section_id ? getRuleConfiguredAction(section_id) : null;
  keepUnavailableChoice(
    option,
    ["zapret", "zapret2", "byedpi"].includes(configured) ? configured : null,
    (action) => ({
      label: _("%s (not installed)").format(getActionOptionLabel(action)),
      message: _(
        "%s is not installed. Install it in Components or choose another action.",
      ).format(getActionOptionLabel(action)),
    }),
  );
}

function getConfigListValues(section_id, key) {
  return normalizeOptionValues(uci.get(UCI_PACKAGE, section_id, key));
}

// Rule conditions read the way the backend reads them for sing-box and nft
// (core/common.uc, config/rule.uc, routing/rule_conditions.uc), so the
// editor shows and keeps what the rule actually matches (UC-043).

// core/common.uc option(): a list reads as its items joined by a space.
function backendOptionText(value) {
  if (value === null || value === undefined) {
    return "";
  }

  return Array.isArray(value) ? value.join(" ") : `${value}`;
}

// core/common.uc bool_option().
function backendFlag(section_id, key) {
  return ["1", "true", "yes", "on"].includes(
    backendOptionText(uci.get(UCI_PACKAGE, section_id, key)),
  );
}

// config/rule.uc text_list_values(value, "comma-space"): comments cut at
// // or #, items separated by spaces, commas and line breaks.
function backendTextListValues(value) {
  const result = [];

  backendOptionText(value)
    .split("\n")
    .forEach((line) => {
      line
        .replace(/\s*\/\/[^\n]*$/, "")
        .replace(/\s*#[^\n]*$/, "")
        .replace(/[ ,]/g, "\n")
        .split("\n")
        .forEach((item) => {
          const normalized = item.replace(/\r/g, "").trim();
          if (normalized) {
            result.push(normalized);
          }
        });
    });

  return result;
}

// Text mode: the rule reads <key> from <key>_text and ignores the list.
function conditionTextMode(section_id, key) {
  return (
    backendFlag(section_id, `${key}_text_mode`) ||
    backendFlag(section_id, "conditions_text_mode")
  );
}

// routing/rule_conditions.uc legacy_condition_values(): where the backend
// takes the values of a condition from, and the values. `domain` as an
// option is the combined domain text, not a legacy exact domain.
function backendConditionValues(section_id, key) {
  const raw = uci.get(UCI_PACKAGE, section_id, key);
  const textValues = backendTextListValues(
    uci.get(UCI_PACKAGE, section_id, `${key}_text`),
  );

  if (conditionTextMode(section_id, key)) {
    return { source: "text", values: textValues };
  }
  if (Array.isArray(raw) && raw.length) {
    return { source: "list", values: raw.map((item) => `${item}`) };
  }

  const optionValues =
    Array.isArray(raw) || key === "domain" ? [] : backendTextListValues(raw);
  if (optionValues.length) {
    return { source: "option", values: optionValues };
  }

  return { source: textValues.length ? "text" : "none", values: textValues };
}

// config/rule.uc normalize_port_condition_value() accepts it.
function backendPortValue(value) {
  const number = (text) =>
    /^[0-9]+$/.test(text) && Number(text) >= 1 && Number(text) <= 65535
      ? Number(text)
      : null;
  const trimmed = `${value || ""}`.trim();
  const dash = trimmed.indexOf("-");

  if (dash < 0) {
    return number(trimmed) !== null;
  }

  const start = number(trimmed.slice(0, dash));
  const end = number(trimmed.slice(dash + 1));
  return start !== null && end !== null && start <= end;
}

// The generator and nft match `ports` and the port values of the legacy
// ports_text together.
function backendPortValues(section_id) {
  const seen = new Set();
  const result = [];
  const add = (value) => {
    const trimmed = `${value}`.trim();
    if (trimmed && !seen.has(trimmed)) {
      seen.add(trimmed);
      result.push(trimmed);
    }
  };

  getConfigListValues(section_id, "ports").forEach(add);
  backendTextListValues(uci.get(UCI_PACKAGE, section_id, "ports_text"))
    .filter(backendPortValue)
    .forEach(add);
  return result;
}

// Legacy rule settings (UC-042, UC-043, D-6 a). Earlier versions, the podkop
// migration and the CLI can leave conditions in forms the editor does not
// write: lists and *_text options the backend still reads, text mode
// switches, a legacy interface list, downloaded lists and podkop matchers the
// generator refuses. The rule modal lists them with what the backend does
// with them. On request it converts what has an exact equivalent into the
// options the editor writes, so that the generated sing-box configuration
// and the firewall sets stay the same; nothing is migrated silently.

// routing/rule_conditions.uc legacy_condition_values() keys, with their
// prefix in the combined domain text.
const LEGACY_TEXT_CONDITIONS = [
  ["domain", "full"],
  ["domain_keyword", "keyword"],
  ["domain_regex", "regex"],
  ["ip_cidr", ""],
  ["source_ip_cidr", ""],
  ["excluded_source_ip_cidr", ""],
];
// singbox/generator.uc unsupported_matcher_key().
const UNSUPPORTED_LEGACY_MATCHERS = [
  "subnet",
  "subnet_text",
  "local_domain_lists",
  "local_subnet_lists",
];
// config/connections.uc interfaces() and interface_domain_resolver_*().
const LEGACY_INTERFACE_OPTIONS = [
  "interfaces",
  "interface",
  "interface_settings",
  "domain_resolver_enabled",
  "domain_resolver_dns_type",
  "domain_resolver_dns_server",
];

// Downloaded lists match destinations the editor has no field for.
function hasRemoteRuleLists(section_id) {
  return ["remote_domain_lists", "remote_subnet_lists"].some(
    (key) =>
      normalizeOptionValues(uci.get(UCI_PACKAGE, section_id, key)).length,
  );
}

// The Device filter field is shown only with a destination condition; while
// it is hidden, a save of the rule drops what it holds (sourceIpOption.remove).
function hiddenDeviceFilterDropped(option, section_id) {
  const field = option.section.children.find(
    (child) => child.option === "source_ip_cidr",
  );

  return (
    Boolean(field) &&
    !field.isActive(section_id) &&
    !hasRemoteRuleLists(section_id)
  );
}

function hasStoredOption(section_id, key) {
  const value = uci.get(UCI_PACKAGE, section_id, key);
  return Array.isArray(value)
    ? value.length > 0
    : value !== null && value !== undefined && `${value}` !== "";
}

function displayOptionValue(value) {
  return (Array.isArray(value) ? value : `${value ?? ""}`.split("\n"))
    .map((item) => `${item}`.trim())
    .filter(Boolean)
    .join(", ");
}

// An item the combined text reads back as it is (config/rule.uc
// text_list_values(): spaces and commas separate items, // and # start a
// comment).
function isTextListItem(value) {
  const text = `${value}`;
  return /^[^\s,#]+$/.test(text) && !text.includes("//");
}

// nft reads a text mode switch with int() (config/rule.uc
// legacy_condition_csv_value()), sing-box with bool_option().
function textModeSwitchAgrees(section_id, key) {
  const text = backendOptionText(uci.get(UCI_PACKAGE, section_id, key));
  return backendFlag(section_id, key) === (Number.parseInt(text, 10) === 1);
}

// config/connections.uc bool_value(): ucode compares null, "", false and 0
// equal to "", so they read as unset; a list or an object is never true.
function connectionsBoolValue(value, fallback) {
  if ([null, undefined, "", false, 0].includes(value)) {
    return Boolean(fallback);
  }

  return (
    typeof value !== "object" && ["1", "true", "yes", "on"].includes(`${value}`)
  );
}

// config/connections.uc interface_domain_resolver_*() for an interface of the
// legacy list: its interface_settings entry, else the rule options. Null when
// an interface item cannot hold the same values.
function legacyInterfaceSettings(section_id, name) {
  let settings = {};
  try {
    const parsed = JSON.parse(
      backendOptionText(uci.get(UCI_PACKAGE, section_id, "interface_settings")),
    );
    const entry = parsed && !Array.isArray(parsed) ? parsed[name] : null;
    if (entry && typeof entry === "object" && !Array.isArray(entry)) {
      settings = entry;
    }
  } catch (_error) {
    settings = {};
  }

  const value = (key, fallback) => {
    const item = settings[key];
    return item === null || item === undefined ? fallback : item;
  };
  const enabled = value("domain_resolver_enabled", "");
  const result = {
    domain_resolver_enabled: connectionsBoolValue(
      enabled,
      connectionsBoolValue(
        uci.get(UCI_PACKAGE, section_id, "domain_resolver_enabled"),
        false,
      ),
    )
      ? "1"
      : "0",
    domain_resolver_dns_type: value(
      "domain_resolver_dns_type",
      backendOptionText(
        uci.get(UCI_PACKAGE, section_id, "domain_resolver_dns_type"),
      ) || "udp",
    ),
    domain_resolver_dns_server: value(
      "domain_resolver_dns_server",
      backendOptionText(
        uci.get(UCI_PACKAGE, section_id, "domain_resolver_dns_server"),
      ) || "8.8.8.8",
    ),
  };

  return [
    enabled,
    result.domain_resolver_dns_type,
    result.domain_resolver_dns_server,
  ].some((item) => typeof item === "object") ||
    result.domain_resolver_dns_type === "" ||
    result.domain_resolver_dns_server === ""
    ? null
    : Object.fromEntries(
        Object.entries(result).map(([key, item]) => [key, `${item}`]),
      );
}

// What the rule keeps in a legacy form, what the backend does with it, and
// the conversion: { changes: { option: value or null to remove }, items:
// interface items to add, unusedDevices: device options removed because the
// rule does not use them }. Null when the rule has nothing legacy.
// `devicesUnused`: the Device filter field is hidden, so a save drops what it
// holds (hiddenDeviceFilterDropped()).
function legacyRuleConditions(section_id, devicesUnused) {
  const findings = [];
  const blockers = [];
  const changes = {};
  const items = [];
  const unusedDevices = [];
  const raw = (key) => uci.get(UCI_PACKAGE, section_id, key);
  const has = (key) => hasStoredOption(section_id, key);
  const found = (key, effect) => {
    if (has(key)) {
      findings.push({ key, value: displayOptionValue(raw(key)), effect });
    }
  };
  const drop = (key) => {
    if (has(key)) {
      changes[key] = null;
    }
  };
  const cannotConvert = (key, value) =>
    blockers.push(
      _("%s: “%s” cannot be written in the current form unchanged").format(
        key,
        value,
      ),
    );
  const dns = backendOptionText(raw("action")) === "dns";
  const used = _("used by the rule");
  const noEffect = _("has no effect");
  const domainsAndDevicesOnly = _(
    "ignored: DNS rules match domains and devices only",
  );
  const domainItems = [];
  let domainLegacy = false;

  ["conditions_text_mode"]
    .concat(LEGACY_TEXT_CONDITIONS.map(([key]) => `${key}_text_mode`))
    .forEach((key) => {
      if (has(key) && !textModeSwitchAgrees(section_id, key)) {
        blockers.push(
          _("%s is “%s”: sing-box and the firewall read it differently").format(
            key,
            backendOptionText(raw(key)),
          ),
        );
      }
    });

  found(
    "conditions_text_mode",
    backendFlag(section_id, "conditions_text_mode")
      ? _("turns text mode on for domains, IPs and devices")
      : noEffect,
  );
  drop("conditions_text_mode");

  LEGACY_TEXT_CONDITIONS.forEach(([key, prefix]) => {
    const textKey = `${key}_text`;
    const modeKey = `${key}_text_mode`;
    const value = raw(key);
    // `option domain` (the combined text), `option ip_cidr` and the device
    // lists are what the editor writes.
    const legacyValue =
      key === "domain" || key === "ip_cidr"
        ? Array.isArray(value) && value.length > 0
        : Boolean(prefix) && has(key);
    const textMode = conditionTextMode(section_id, key);
    const valueIgnored =
      textMode && (key === "domain" ? legacyValue : has(key));

    // A DNS rule keeps destination IPs in any form, unused.
    if (dns && key === "ip_cidr") {
      [key, textKey, modeKey].forEach((item) => {
        found(item, domainsAndDevicesOnly);
        drop(item);
      });
      return;
    }

    if (!legacyValue && !valueIgnored && !has(textKey) && !has(modeKey)) {
      return;
    }

    const current = backendConditionValues(section_id, key);
    if (textMode) {
      found(textKey, _("used by the rule: text mode is on"));
      if (valueIgnored) {
        found(key, _("ignored: text mode reads %s instead").format(textKey));
      }
    } else {
      if (legacyValue) {
        found(key, used);
      }
      found(
        textKey,
        ["list", "option"].includes(current.source)
          ? _("ignored: %s is used instead").format(key)
          : used,
      );
    }
    found(
      modeKey,
      backendFlag(section_id, modeKey) ? _("turns text mode on") : noEffect,
    );
    if (key === "source_ip_cidr" && devicesUnused) {
      // sing-box and nft match devices only together with a destination
      // condition; the rule has none, so its devices go instead of moving
      // to a field the save would clear.
      [key, textKey, modeKey].filter(has).forEach((item) => {
        unusedDevices.push(item);
        drop(item);
      });
      return;
    }
    drop(textKey);
    drop(modeKey);

    const values = current.values.map((item) => `${item}`);
    const source = current.source === "text" ? textKey : key;
    if (prefix) {
      // Legacy exact, keyword and regex conditions become full:, keyword:
      // and regex: items of the combined text, in the generator's order.
      domainLegacy = true;
      values.forEach((item) => {
        if (
          !isTextListItem(item) ||
          item.toLowerCase().startsWith(`${prefix}:`)
        ) {
          cannotConvert(source, item);
        }
        domainItems.push(`${prefix}:${item}`);
      });
      drop(key);
      return;
    }

    if (key === "ip_cidr") {
      let text = "";
      if (current.source === "text") {
        text = backendOptionText(raw(textKey));
      } else if (current.source === "list") {
        values
          .filter((item) => !isTextListItem(item))
          .forEach((item) => {
            cannotConvert(key, item);
          });
        text = values.join("\n");
      } else if (current.source === "option") {
        text = `${value}`;
      }

      if (Array.isArray(value) || text !== backendOptionText(value)) {
        const analysis = analyzeIpCidrText(text);
        if (!analysis.valid) {
          blockers.push(`${key}: ${analysis.message.replace(/\n/g, "; ")}`);
        }
        changes[key] = text || null;
      }
      return;
    }

    // Device lists: the editor keeps them as lists.
    if (["text", "none"].includes(current.source)) {
      if (values.length) {
        changes[key] = values;
      } else {
        drop(key);
      }
    }
  });

  ["domain_suffix", "domain_suffix_text"].forEach((key) => {
    domainLegacy = domainLegacy || has(key);
    found(key, used);
  });
  domainLegacy = domainLegacy || has("domain_suffix_text_mode");
  found("domain_suffix_text_mode", noEffect);

  if (domainLegacy) {
    // routing/rule_conditions.uc combined_domain_source_values(): the
    // combined text, domain_suffix_text, then the domain_suffix items.
    const suffixValue = raw("domain_suffix");
    const suffixItems = (
      Array.isArray(suffixValue)
        ? suffixValue.map((item) => `${item}`)
        : `${suffixValue ?? ""}`.trim().split(" ")
    ).filter((item) => item !== "");
    suffixItems
      .filter((item) => !isTextListItem(item))
      .forEach((item) => cannotConvert("domain_suffix", item));

    const domainValue = raw("domain");
    const text = [
      ...domainItems,
      ...(typeof domainValue === "string" && domainValue ? [domainValue] : []),
      ...(has("domain_suffix_text")
        ? [backendOptionText(raw("domain_suffix_text"))]
        : []),
      ...suffixItems,
    ].join("\n");
    const analysis = analyzeDomainSuffixText(text);
    if (!analysis.valid) {
      blockers.push(`domain: ${analysis.message.replace(/\n/g, "; ")}`);
    }
    if (Array.isArray(domainValue) || text !== `${domainValue ?? ""}`) {
      changes.domain = text || null;
    } else {
      delete changes.domain;
    }
    ["domain_suffix", "domain_suffix_text", "domain_suffix_text_mode"].forEach(
      drop,
    );
  }

  if (dns) {
    ["ports", "ports_text"].forEach((key) => {
      found(key, domainsAndDevicesOnly);
      drop(key);
    });
  } else if (has("ports_text")) {
    found("ports_text", _("used by the rule together with %s").format("ports"));
    // singbox/generator.uc add_port_matchers(): the ports items, then the
    // ports of ports_text, each value once.
    const portsValue = raw("ports");
    const listItems = Array.isArray(portsValue)
      ? portsValue.map((item) => `${item}`)
      : `${portsValue ?? ""}`.trim().split(" ");
    const seen = new Set();
    const ports = [];
    listItems
      .concat(backendTextListValues(raw("ports_text")).filter(backendPortValue))
      .forEach((item) => {
        const trimmed = item.trim();
        if (trimmed && !seen.has(trimmed)) {
          seen.add(trimmed);
          ports.push(trimmed);
        }
      });
    if (!ports.length) {
      drop("ports");
    } else if (
      !Array.isArray(portsValue) ||
      !stringArraysEqual(portsValue, ports)
    ) {
      changes.ports = ports;
    }
    drop("ports_text");
  }

  found("fully_routed_ips_text", _("ignored: the backend does not read it"));
  drop("fully_routed_ips_text");

  if (has("interfaces") || has("interface")) {
    const interfacesValue = raw("interfaces");
    const names = Array.isArray(interfacesValue)
      ? interfacesValue.map((item) => `${item}`)
      : [`${has("interfaces") ? interfacesValue : raw("interface")}`];
    const connection = isConnectionRuleSection(
      uci.get(UCI_PACKAGE, section_id),
    );
    const withItems =
      getChildItemIds(section_id, "section_interface").length > 0;
    let effect = _(
      "used by the rule; the Network Interface field does not show it",
    );
    if (!connection) {
      effect = _("ignored: only Connection rules use interfaces");
    } else if (withItems) {
      effect = _("ignored: the rule has interface items");
    }

    LEGACY_INTERFACE_OPTIONS.forEach((key) =>
      found(
        key,
        key === "interface" && has("interfaces")
          ? _("ignored: %s is used instead").format("interfaces")
          : effect,
      ),
    );
    if (connection && !withItems) {
      const seen = new Set();
      names.forEach((name) => {
        const settings = legacyInterfaceSettings(section_id, name);
        if (!name.trim() || seen.has(name) || !settings) {
          cannotConvert("interfaces", name);
        }
        seen.add(name);
        items.push({ name, settings });
      });
    }
    LEGACY_INTERFACE_OPTIONS.forEach(drop);
  }

  found(
    "remote_domain_lists",
    _("downloaded by the list update; the rule matches the domains in them"),
  );
  found(
    "remote_subnet_lists",
    dns
      ? _("ignored: DNS rules match domains only")
      : _(
          "downloaded by the list update; the rule matches the addresses in them",
        ),
  );

  const unsupported = UNSUPPORTED_LEGACY_MATCHERS.filter(has);
  unsupported.forEach((key) =>
    found(
      key,
      _(
        "no longer supported: the configuration cannot be applied while the rule is enabled",
      ),
    ),
  );

  if (!findings.length) {
    return null;
  }

  const conversion =
    Object.keys(changes).length || items.length
      ? { changes, items, unusedDevices }
      : null;
  return {
    findings,
    blockers: conversion ? blockers : [],
    conversion,
    unsupported,
    remote: ["remote_domain_lists", "remote_subnet_lists"].some(has),
  };
}

// What a conversion sets, adds and removes, as the preview lists it.
function legacyConversionPreview(conversion) {
  const lines = [];
  const removed = [];

  Object.entries(conversion.changes).forEach(([key, value]) => {
    if (value === null) {
      removed.push(key);
    } else {
      lines.push(_("set %s: %s").format(key, displayOptionValue(value)));
    }
  });
  conversion.items.forEach(({ name, settings }) => {
    lines.push(
      settings.domain_resolver_enabled === "1"
        ? _("add the interface item %s with the DNS resolver %s %s").format(
            name,
            settings.domain_resolver_dns_type,
            settings.domain_resolver_dns_server,
          )
        : _("add the interface item %s").format(name),
    );
  });
  if (conversion.unusedDevices.length) {
    lines.push(
      _(
        "%s: not moved to the Device filter, the rule has no destination condition and does not use it",
      ).format(conversion.unusedDevices.join(", ")),
    );
  }
  if (removed.length) {
    lines.push(_("remove %s").format(removed.join(", ")));
  }

  return lines;
}

// Staged like any other edit of the rule: Save keeps it, Dismiss restores
// the rule and drops the added items. Returns the ids of the added items.
function applyLegacyConditionConversion(section_id, conversion) {
  Object.entries(conversion.changes).forEach(([key, value]) => {
    if (value === null) {
      uci.unset(UCI_PACKAGE, section_id, key);
    } else {
      uci.set(UCI_PACKAGE, section_id, key, value);
    }
  });
  return conversion.items.map(({ name, settings }) => {
    const itemId = uci.add(UCI_PACKAGE, "section_interface");
    uci.set(UCI_PACKAGE, itemId, "section", section_id);
    uci.set(UCI_PACKAGE, itemId, "name", name);
    Object.entries(settings).forEach(([key, value]) => {
      uci.set(UCI_PACKAGE, itemId, key, value);
    });
    return itemId;
  });
}

function renderLegacyConditionsNotice(option, section_id) {
  const node = E("div", { class: "alert-message warning fkp-legacy-settings" });

  // A role that may not change the configuration learns only that legacy
  // settings exist: downloaded list URLs may carry credentials.
  if (option.map.readonly) {
    node.append(
      E(
        "p",
        {},
        _(
          "This rule keeps settings in a legacy form from an earlier version. An administrator can review and convert them.",
        ),
      ),
    );
    return node;
  }

  // In an array LuCI adds a line as a text node, not as HTML: the lines
  // carry UCI values.
  const listItems = (lines) =>
    E(
      "ul",
      {},
      lines.map((line) => E("li", {}, [line])),
    );
  const actionButton = (label, className, click) =>
    E(
      "button",
      {
        type: "button",
        class: ["btn", "cbi-button", className].filter(Boolean).join(" "),
        click,
      },
      label,
    );

  const render = (message) => {
    const state = legacyRuleConditions(section_id);
    const actions = E("div", { class: "fkp-legacy-settings__actions" });
    const confirm = (question, lines, note, label, className, apply) => {
      actions.textContent = "";
      actions.append(
        E("p", {}, question),
        lines.length ? listItems(lines) : "",
        note ? E("p", {}, note) : "",
        E("div", { class: "fkp-legacy-settings__buttons" }, [
          actionButton(_("Cancel"), "", () => render(message)),
          " ",
          actionButton(label, className, apply),
        ]),
      );
    };

    node.textContent = "";
    if (message) {
      node.append(E("p", {}, message));
    }
    if (!state) {
      return;
    }

    node.append(
      E(
        "p",
        {},
        _(
          "This rule keeps settings in a legacy form, from an earlier version, the podkop migration or the command line. The fields show what the rule matches; the legacy options stay as they are until you convert or remove them.",
        ),
      ),
      E(
        "ul",
        {},
        state.findings.map(({ key, value, effect }) =>
          E("li", {}, [
            E("code", {}, key),
            value ? ` = ${value}` : "",
            ` — ${effect}`,
          ]),
        ),
      ),
    );
    if (state.remote) {
      node.append(
        E(
          "p",
          {},
          _(
            "The editor has no field for downloaded lists: they cannot be converted and stay as they are.",
          ),
        ),
      );
    }
    if (state.blockers.length) {
      node.append(
        E(
          "p",
          {},
          _(
            "The legacy conditions cannot be converted without changing what the rule matches:",
          ),
        ),
        listItems(state.blockers),
      );
    }

    if (state.conversion && !state.blockers.length) {
      actions.append(
        actionButton(_("Convert…"), "cbi-button-action", () => {
          // What the save keeps depends on the form as it is now (a field
          // hidden by its dependencies drops its option).
          const current = legacyRuleConditions(
            section_id,
            hiddenDeviceFilterDropped(option, section_id),
          );
          if (!current || !current.conversion || current.blockers.length) {
            render(message);
            return;
          }

          const { conversion } = current;
          confirm(
            _(
              "Convert the legacy settings of this rule? When you save the rule:",
            ),
            legacyConversionPreview(conversion),
            _(
              "The rule matches the same traffic as before. Closing the window without saving discards the conversion.",
            ),
            _("Convert"),
            "cbi-button-action",
            () => {
              const itemIds = applyLegacyConditionConversion(
                section_id,
                conversion,
              );
              // The Network Interface field lists the items the legacy
              // list became, so that saving or editing it keeps them, and
              // after them what was added there in this window; an
              // interface added there again is the converted item.
              const interfaces = option.section.children.find(
                (child) => child.option === "interfaces",
              );
              const widget =
                itemIds.length && interfaces
                  ? interfaces.getUIElement(section_id)
                  : null;
              if (widget) {
                const converted = new Set(
                  conversion.items.map(({ name }) => name),
                );
                widget.setValue(
                  itemIds.concat(
                    normalizeDynamicListItems(widget.getValue()).filter(
                      (value) =>
                        !converted.has(
                          childItemInputValue(
                            section_id,
                            value,
                            "section_interface",
                            "name",
                          ).trim(),
                        ),
                    ),
                  ),
                );
              }
              render(
                _(
                  "The legacy settings are converted. Save the rule to keep the change.",
                ),
              );
            },
          );
        }),
        " ",
      );
    }
    if (state.unsupported.length) {
      const { unsupported } = state;
      actions.append(
        actionButton(_("Remove…"), "cbi-button-negative", () =>
          confirm(
            _(
              "Remove %s from this rule? When you save the rule, it matches without them and the configuration can be applied again. Nothing else in the rule changes.",
            ).format(unsupported.join(", ")),
            [],
            "",
            _("Remove"),
            "cbi-button-negative",
            () => {
              unsupported.forEach((key) =>
                uci.unset(UCI_PACKAGE, section_id, key),
              );
              render(
                _(
                  "The unsupported settings are removed. Save the rule to keep the change.",
                ),
              );
            },
          ),
        ),
      );
    }
    node.append(actions);
  };

  render("");
  return node;
}

function stringArraysEqual(left, right) {
  left = normalizeDynamicListItems(left);
  right = normalizeDynamicListItems(right);

  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function writeListOption(section_id, key, values) {
  const normalized = normalizeOptionValues(values);

  if (stringArraysEqual(getConfigListValues(section_id, key), normalized)) {
    return;
  }

  if (normalized.length) {
    uci.set(UCI_PACKAGE, section_id, key, normalized);
  } else {
    uci.unset(UCI_PACKAGE, section_id, key);
  }
}

function makeDeviceOptionsExclusive(...options) {
  let changing = false;
  const widgets = options.map(() => ({}));

  options.forEach((option, index) => {
    const originalWrite = option.write;
    if (typeof originalWrite !== "function") {
      return;
    }

    option.write = function (section_id, value) {
      const widget = widgets[index][section_id];
      const liveValue =
        widget && typeof widget.getValue === "function"
          ? widget.getValue()
          : value;
      return originalWrite.call(this, section_id, liveValue);
    };
  });

  function removeMatches(section_id, value, optionIndex) {
    if (changing) {
      return;
    }

    const selected = new Set(normalizeOptionValues(value));
    if (!selected.size) {
      return;
    }

    changing = true;
    try {
      widgets.forEach((optionWidgets, index) => {
        if (index === optionIndex) {
          return;
        }
        const widget = optionWidgets[section_id];
        if (!widget) {
          return;
        }
        const current = normalizeOptionValues(widget.getValue());
        const filtered = current.filter((item) => !selected.has(item));
        if (!stringArraysEqual(current, filtered)) {
          widget.setValue(filtered);
        }
      });
    } finally {
      changing = false;
    }
  }

  options.forEach((option, index) => {
    option.onDeviceWidgetReady = function (section_id, widget) {
      widgets[index][section_id] = widget;
    };
    option.onDeviceListChange = function (section_id, value) {
      removeMatches(section_id, value, index);
    };
  });
}

function childOwnerOption(ownerOption) {
  return ownerOption || "section";
}

function childItemOrder(item) {
  const value = item ? item.order : null;
  const parsed = Number.parseInt(value == null ? "0" : `${value}`, 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

function getChildItemIds(section_id, typeName, ownerOption) {
  const ownerKey = childOwnerOption(ownerOption);
  const items = uci
    .sections(UCI_PACKAGE, typeName)
    .filter((item) => item[ownerKey] === section_id);

  if (typeName === "priority_level") {
    items.sort((a, b) => {
      const orderDiff = childItemOrder(a) - childItemOrder(b);
      if (orderDiff !== 0) {
        return orderDiff;
      }

      return `${a[".name"] || ""}`.localeCompare(`${b[".name"] || ""}`);
    });
  }

  return items.map((item) => item[".name"]).filter(Boolean);
}

function childItemValue(itemId, valueOption, fallback) {
  if (!valueOption) {
    return itemId;
  }

  const value = uci.get(UCI_PACKAGE, itemId, valueOption);
  return value == null || value === "" ? fallback || itemId : `${value}`;
}

function childItemInputValue(
  section_id,
  value,
  typeName,
  valueOption,
  ownerOption,
) {
  const itemId = `${value || ""}`;

  if (isExistingChildItem(section_id, itemId, typeName, ownerOption)) {
    return childItemValue(itemId, valueOption, itemId);
  }

  return itemId;
}

function isExistingChildItem(section_id, itemId, typeName, ownerOption) {
  const ownerKey = childOwnerOption(ownerOption);

  return Boolean(
    itemId &&
      uci.get(UCI_PACKAGE, itemId, ".type") === typeName &&
      uci.get(UCI_PACKAGE, itemId, ownerKey) === section_id,
  );
}

function findChildItemForInput(section_id, options, inputValue) {
  const rawValue = `${inputValue || ""}`.trim();

  if (
    isExistingChildItem(
      section_id,
      rawValue,
      options.typeName,
      options.ownerOption,
    )
  ) {
    return rawValue;
  }

  if (options.valueOption) {
    return getChildItemIds(
      section_id,
      options.typeName,
      options.ownerOption,
    ).find(
      (itemId) =>
        childItemValue(itemId, options.valueOption, itemId) === rawValue,
    );
  }

  return null;
}

function createChildItem(section_id, options, inputValue) {
  const rawValue = `${inputValue || ""}`.trim();
  const existing = findChildItemForInput(section_id, options, rawValue);

  if (existing) {
    return {
      value: existing,
      text: options.valueOption
        ? childItemValue(existing, options.valueOption, existing)
        : existing,
      created: false,
    };
  }

  const requestedId =
    typeof options.createId === "function"
      ? `${options.createId(rawValue, section_id) || ""}`.trim()
      : "";
  const itemId =
    (requestedId && uci.add(UCI_PACKAGE, options.typeName, requestedId)) ||
    requestedId ||
    uci.add(UCI_PACKAGE, options.typeName);

  uci.set(
    UCI_PACKAGE,
    itemId,
    childOwnerOption(options.ownerOption),
    section_id,
  );

  if (options.valueOption) {
    uci.set(UCI_PACKAGE, itemId, options.valueOption, rawValue);
  }

  if (options.defaults && typeof options.defaults === "object") {
    Object.entries(options.defaults).forEach(([key, value]) => {
      value =
        typeof value === "function"
          ? value(rawValue, section_id, itemId)
          : value;
      if (value !== undefined && value !== null && value !== "") {
        uci.set(UCI_PACKAGE, itemId, key, `${value}`);
      }
    });
  }

  return {
    value: itemId,
    text: options.valueOption ? rawValue : itemId,
    created: true,
  };
}

function applyChildItemSettings(itemId, settings) {
  Object.entries(settings || {}).forEach(([key, value]) => {
    if (!key || key.charAt(0) === ".") {
      return;
    }

    if (value === undefined || value === null || value === "") {
      uci.unset(UCI_PACKAGE, itemId, key);
    } else if (Array.isArray(value)) {
      uci.set(
        UCI_PACKAGE,
        itemId,
        key,
        value
          .map((item) => `${item || ""}`.trim())
          .filter((item) => item.length),
      );
    } else {
      uci.set(UCI_PACKAGE, itemId, key, `${value}`);
    }
  });
}

function materializeChildItems(section_id, options, inputValue) {
  const result = [];
  const seen = new Set();

  normalizeDynamicListItems(inputValue).forEach((value) => {
    const createdItem = createChildItem(section_id, options, value);
    const itemId = createdItem.value;
    const stagedSettings =
      createdItem.created && typeof options.stagedSettings === "function"
        ? options.stagedSettings(value, itemId, createdItem.created)
        : null;

    if (stagedSettings) {
      applyChildItemSettings(itemId, stagedSettings);
    }

    if (itemId && !seen.has(itemId)) {
      seen.add(itemId);
      result.push(itemId);
    }
  });

  return result;
}

function cleanupPriorityLevelsForGroup(groupId) {
  getChildItemIds(groupId, "priority_level", "group").forEach((levelId) => {
    uci.remove(UCI_PACKAGE, levelId);
  });
}

function cleanupRemovedChildItems(
  section_id,
  typeName,
  keepValues,
  ownerOption,
) {
  const keep = new Set(normalizeDynamicListItems(keepValues));

  getChildItemIds(section_id, typeName, ownerOption).forEach((itemId) => {
    if (!keep.has(itemId)) {
      if (typeName === "priority_group") {
        cleanupPriorityLevelsForGroup(itemId);
      }
      uci.remove(UCI_PACKAGE, itemId);
    }
  });
}

// The dashboard keeps its URLTest settings for a rule in urltest_override
// sections (rule, tag). They live and die with the rule: a later rule with
// the same name must not inherit them (UC-151).
function cleanupRuleUrlTestOverrides(section_id) {
  uci.sections(UCI_PACKAGE, "urltest_override").forEach((item) => {
    if (`${item.rule || ""}` === section_id) {
      uci.remove(UCI_PACKAGE, item[".name"]);
    }
  });
}

function parentSectionIdForItem(itemId) {
  return uci.get(UCI_PACKAGE, itemId, "section") || "";
}

function refreshOptionChoices(option, choices) {
  delete option.keylist;
  delete option.vallist;

  (choices || []).forEach((choice) => {
    if (typeof choice === "object") {
      option.value(choice.value, choice.label);
    } else {
      option.value(choice);
    }
  });
}

function validateRegex(_section_id, value) {
  if (!value || !value.length) {
    return true;
  }

  try {
    new RegExp(value);
    return true;
  } catch (_error) {
    return _("Invalid regular expression");
  }
}

function validateKeyword(_section_id, value) {
  if (!value || !value.length) {
    return true;
  }

  if (/[,\s]/.test(value)) {
    return _("Keyword must not contain spaces or commas");
  }

  return true;
}

function isSingBoxDuration(value) {
  return /^(?=.*[1-9])([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

function writeOptionalDurationOption(section_id, key, value) {
  const normalized = value ? `${value}`.trim() : "";
  const disabledKey = `${key}_disabled`;

  if (normalized.length) {
    uci.set(UCI_PACKAGE, section_id, key, normalized);
    uci.unset(UCI_PACKAGE, section_id, disabledKey);
  } else {
    uci.unset(UCI_PACKAGE, section_id, key);
    uci.set(UCI_PACKAGE, section_id, disabledKey, "1");
  }
}

function validateOptionalSingBoxDuration(value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return true;
  }

  if (isSingBoxDuration(normalized)) {
    return true;
  }

  return _("Use sing-box duration format like 1d, 12h or 30m");
}

function validateRequiredSingBoxDuration(value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return _("Use sing-box duration format like 1d, 12h or 30m");
  }

  if (isSingBoxDuration(normalized)) {
    return true;
  }

  return _("Use sing-box duration format like 1d, 12h or 30m");
}

function parseSubscriptionUrlEntry(value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return { valid: true, url: "" };
  }

  if (normalized.includes("|")) {
    return {
      valid: false,
      message: _("Configure User-Agent in the item settings"),
    };
  }

  return { valid: true, url: normalized };
}

function validateSubscriptionUrlEntry(_section_id, value) {
  if (!value || value.length === 0) {
    return true;
  }

  const parsed = parseSubscriptionUrlEntry(value);
  if (!parsed.valid) {
    return parsed.message;
  }

  const validation = main.validateUrl(parsed.url, ["https:"]);
  if (!validation.valid) {
    return validation.message;
  }

  return true;
}

function getDuplicateTextListErrors(values, normalizeValue, duplicateMessage) {
  const seen = new Set();
  const duplicates = [];

  values.forEach((item) => {
    const normalized = normalizeValue ? normalizeValue(item) : item;

    if (seen.has(normalized)) {
      if (!duplicates.includes(item)) {
        duplicates.push(item);
      }
      return;
    }

    seen.add(normalized);
  });

  return duplicates.map((item) => `${item}: ${duplicateMessage}`);
}

function getValidationHeaderText() {
  return _("Validation errors:");
}

function getDuplicateValueText() {
  return _("Duplicate value");
}

function escapeHtml(value) {
  return `${value}`
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function ensureAnnotatedTextareaStyles() {
  if (
    typeof document === "undefined" ||
    !document.head ||
    document.getElementById(ANNOTATED_TEXTAREA_STYLE_ID)
  ) {
    return;
  }

  document.head.insertAdjacentHTML(
    "beforeend",
    `<style id="${ANNOTATED_TEXTAREA_STYLE_ID}">
      .fkp-annotated-textarea {
        position: relative;
      }

      .fkp-annotated-textarea > textarea {
        position: relative;
        z-index: 1;
        background: transparent !important;
      }

      .fkp-annotated-textarea__overlay {
        position: absolute;
        inset: 0;
        z-index: 0;
        pointer-events: none;
        overflow: hidden;
        box-sizing: border-box;
        color: transparent;
        white-space: pre-wrap;
        word-break: break-word;
        overflow-wrap: break-word;
      }

      .fkp-annotated-textarea__invalid {
        color: transparent;
        text-decoration-line: underline;
        text-decoration-style: wavy;
        text-decoration-color: var(--error-color-medium, #d44);
        text-decoration-thickness: 1.5px;
        text-underline-offset: 2px;
        text-decoration-skip-ink: none;
      }
    </style>`,
  );
}

function applyTextareaInputAttributes(textarea) {
  textarea.setAttribute("spellcheck", "false");
  textarea.setAttribute("autocomplete", "off");
  textarea.setAttribute("autocorrect", "off");
  textarea.setAttribute("autocapitalize", "off");
  textarea.setAttribute("data-gramm", "false");
  textarea.setAttribute("data-gramm_editor", "false");
  textarea.setAttribute("data-enable-grammarly", "false");
  textarea.style.resize = "vertical";
  textarea.style.maxWidth = "100%";

  const getRowsMinHeight = () => {
    const rows = Number.parseInt(textarea.getAttribute("rows") || "0", 10);
    if (!rows || typeof window === "undefined") {
      return 0;
    }

    const style = window.getComputedStyle(textarea);
    const fontSize = Number.parseFloat(style.fontSize) || 16;
    const lineHeight =
      Number.parseFloat(style.lineHeight) || Math.ceil(fontSize * 1.2);
    const verticalPadding =
      (Number.parseFloat(style.paddingTop) || 0) +
      (Number.parseFloat(style.paddingBottom) || 0);
    const verticalBorder =
      (Number.parseFloat(style.borderTopWidth) || 0) +
      (Number.parseFloat(style.borderBottomWidth) || 0);

    return Math.ceil(rows * lineHeight + verticalPadding + verticalBorder);
  };

  const applyMinHeight = () => {
    const storedMinHeight = Number.parseFloat(
      textarea.getAttribute("data-fkp-default-min-height") || "0",
    );
    const nextMinHeight = Math.max(
      storedMinHeight,
      textarea.offsetHeight,
      getRowsMinHeight(),
    );

    if (nextMinHeight > 0) {
      if (storedMinHeight <= 0) {
        textarea.setAttribute(
          "data-fkp-default-min-height",
          `${nextMinHeight}`,
        );
      }

      textarea.style.minHeight = `${nextMinHeight}px`;
      return true;
    }

    return false;
  };

  if (
    !applyMinHeight() &&
    typeof window !== "undefined" &&
    typeof window.requestAnimationFrame === "function"
  ) {
    window.requestAnimationFrame(() => {
      if (!applyMinHeight()) {
        window.setTimeout(applyMinHeight, 0);
      }
    });
  }

  textarea.addEventListener("focus", applyMinHeight);
  textarea.addEventListener("pointerdown", applyMinHeight);
}

function syncAnnotatedTextareaOverlay(textarea, wrapper, overlay) {
  if (
    typeof window === "undefined" ||
    !textarea ||
    !wrapper ||
    !overlay ||
    typeof window.getComputedStyle !== "function"
  ) {
    return;
  }

  const style = window.getComputedStyle(textarea);

  wrapper.style.backgroundColor = style.backgroundColor;
  wrapper.style.borderRadius = style.borderRadius;

  overlay.style.font = style.font;
  overlay.style.lineHeight = style.lineHeight;
  overlay.style.letterSpacing = style.letterSpacing;
  overlay.style.paddingTop = style.paddingTop;
  overlay.style.paddingRight = style.paddingRight;
  overlay.style.paddingBottom = style.paddingBottom;
  overlay.style.paddingLeft = style.paddingLeft;
  overlay.style.borderTopWidth = style.borderTopWidth;
  overlay.style.borderRightWidth = style.borderRightWidth;
  overlay.style.borderBottomWidth = style.borderBottomWidth;
  overlay.style.borderLeftWidth = style.borderLeftWidth;
  overlay.style.borderStyle = "solid";
  overlay.style.borderColor = "transparent";
  overlay.style.textAlign = style.textAlign;
  overlay.style.direction = style.direction;
  overlay.style.tabSize = style.tabSize;
  overlay.style.textIndent = style.textIndent;
  overlay.style.textTransform = style.textTransform;
  overlay.style.boxSizing = style.boxSizing;
  overlay.style.scrollPaddingTop = style.scrollPaddingTop;

  overlay.scrollTop = textarea.scrollTop;
  overlay.scrollLeft = textarea.scrollLeft;
}

function createAnnotationKey(annotation) {
  return `${annotation.start}:${annotation.end}`;
}

function addAnnotationIssue(annotationMap, annotation, message) {
  const key = createAnnotationKey(annotation);
  const existing = annotationMap.get(key);
  if (existing) {
    if (!existing.messages.includes(message)) {
      existing.messages.push(message);
    }
    return;
  }

  annotationMap.set(key, {
    start: annotation.start,
    end: annotation.end,
    messages: [message],
  });
}

function finalizeAnnotations(annotationMap) {
  return Array.from(annotationMap.values())
    .map((annotation) => ({
      start: annotation.start,
      end: annotation.end,
      message: annotation.messages.join("; "),
    }))
    .sort((left, right) => left.start - right.start || left.end - right.end);
}

function renderAnnotatedTextareaOverlay(value, annotations) {
  const text = value ? `${value}` : "";
  const normalizedAnnotations = Array.isArray(annotations) ? annotations : [];

  if (!text.length) {
    return "&#8203;";
  }

  if (!normalizedAnnotations.length) {
    return `${escapeHtml(text)}${text.endsWith("\n") ? "\n " : ""}`;
  }

  let cursor = 0;
  let html = "";

  normalizedAnnotations.forEach((annotation) => {
    if (
      annotation.start < cursor ||
      annotation.start >= annotation.end ||
      annotation.start < 0
    ) {
      return;
    }

    html += escapeHtml(text.slice(cursor, annotation.start));
    html += `<span class="fkp-annotated-textarea__invalid">${escapeHtml(
      text.slice(annotation.start, annotation.end),
    )}</span>`;
    cursor = annotation.end;
  });

  html += escapeHtml(text.slice(cursor));

  if (text.endsWith("\n")) {
    html += "\n ";
  }

  return html;
}

function attachAnnotatedTextarea(textarea, analyzer) {
  if (!textarea || typeof analyzer !== "function") {
    return;
  }

  ensureAnnotatedTextareaStyles();

  if (textarea.__forkopAnnotatedTextareaController) {
    textarea.__forkopAnnotatedTextareaController.analyzer = analyzer;
    textarea.__forkopAnnotatedTextareaController.update();
    return;
  }

  const wrapper = textarea.parentNode;
  if (!wrapper) {
    return;
  }

  wrapper.classList.add("fkp-annotated-textarea");

  const overlay = document.createElement("div");
  overlay.className = "fkp-annotated-textarea__overlay";
  overlay.setAttribute("aria-hidden", "true");
  wrapper.insertBefore(overlay, textarea.nextSibling);

  const controller = {
    analyzer,
    textarea,
    wrapper,
    overlay,
    update() {
      const analysis = this.analyzer(this.textarea.value);
      this.overlay.innerHTML = renderAnnotatedTextareaOverlay(
        this.textarea.value,
        analysis.annotations,
      );
      syncAnnotatedTextareaOverlay(this.textarea, this.wrapper, this.overlay);
    },
  };

  textarea.__forkopAnnotatedTextareaController = controller;

  const updateAnnotatedTextarea = () => controller.update();
  textarea.addEventListener("input", updateAnnotatedTextarea);
  textarea.addEventListener("change", updateAnnotatedTextarea);
  textarea.addEventListener("scroll", updateAnnotatedTextarea, {
    passive: true,
  });
  textarea.addEventListener("keyup", updateAnnotatedTextarea);

  if (typeof ResizeObserver === "function") {
    const resizeObserver = new ResizeObserver(() => controller.update());
    resizeObserver.observe(textarea);
    controller.resizeObserver = resizeObserver;
  }

  controller.update();
}

function refreshAnnotatedTextareaValidation(option, section_id, textarea) {
  if (option && typeof option.triggerValidation === "function") {
    option.triggerValidation(section_id);
  }

  if (
    textarea &&
    textarea.__forkopAnnotatedTextareaController &&
    typeof textarea.__forkopAnnotatedTextareaController.update === "function"
  ) {
    textarea.__forkopAnnotatedTextareaController.update();
  }
}

function attachNfqwsRemoteValidation(option, section_id, textarea) {
  if (!textarea || textarea.__forkopNfqwsRemoteValidationAttached) {
    return;
  }

  textarea.__forkopNfqwsRemoteValidationAttached = true;
  textarea.__forkopNfqwsRemoteValidationRequestId = 0;
  textarea.__forkopNfqwsRemoteValidationTimer = null;

  const runValidation = () => {
    const value = textarea.value;
    const localAnalysis = buildNfqwsLocalAnalysis(value);
    if (!localAnalysis.valid) {
      refreshAnnotatedTextareaValidation(option, section_id, textarea);
      return;
    }

    const requestId =
      (textarea.__forkopNfqwsRemoteValidationRequestId || 0) + 1;
    textarea.__forkopNfqwsRemoteValidationRequestId = requestId;

    validateNfqwsStrategyRemotely(value).then(() => {
      if (textarea.__forkopNfqwsRemoteValidationRequestId !== requestId) {
        return;
      }

      refreshAnnotatedTextareaValidation(option, section_id, textarea);
    });
  };

  const scheduleValidation = (delay = NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS) => {
    if (textarea.__forkopNfqwsRemoteValidationTimer) {
      window.clearTimeout(textarea.__forkopNfqwsRemoteValidationTimer);
    }

    textarea.__forkopNfqwsRemoteValidationTimer = window.setTimeout(() => {
      textarea.__forkopNfqwsRemoteValidationTimer = null;
      runValidation();
    }, delay);
  };

  textarea.addEventListener("input", () => scheduleValidation());
  textarea.addEventListener("change", () => scheduleValidation(0));
  textarea.addEventListener("blur", () => scheduleValidation(0));

  scheduleValidation(0);
}

function attachNfqws2RemoteValidation(option, section_id, textarea) {
  if (!textarea || textarea.__forkopNfqws2RemoteValidationAttached) {
    return;
  }

  textarea.__forkopNfqws2RemoteValidationAttached = true;
  textarea.__forkopNfqws2RemoteValidationRequestId = 0;
  textarea.__forkopNfqws2RemoteValidationTimer = null;

  const runValidation = () => {
    const value = textarea.value;
    const localAnalysis = buildNfqws2LocalAnalysis(value);
    if (!localAnalysis.valid) {
      refreshAnnotatedTextareaValidation(option, section_id, textarea);
      return;
    }

    const requestId =
      (textarea.__forkopNfqws2RemoteValidationRequestId || 0) + 1;
    textarea.__forkopNfqws2RemoteValidationRequestId = requestId;

    validateNfqws2StrategyRemotely(value).then(() => {
      if (textarea.__forkopNfqws2RemoteValidationRequestId !== requestId) {
        return;
      }

      refreshAnnotatedTextareaValidation(option, section_id, textarea);
    });
  };

  const scheduleValidation = (delay = NFQWS_REMOTE_VALIDATION_DEBOUNCE_MS) => {
    if (textarea.__forkopNfqws2RemoteValidationTimer) {
      window.clearTimeout(textarea.__forkopNfqws2RemoteValidationTimer);
    }

    textarea.__forkopNfqws2RemoteValidationTimer = window.setTimeout(() => {
      textarea.__forkopNfqws2RemoteValidationTimer = null;
      runValidation();
    }, delay);
  };

  textarea.addEventListener("input", () => scheduleValidation());
  textarea.addEventListener("change", () => scheduleValidation(0));
  textarea.addEventListener("blur", () => scheduleValidation(0));

  scheduleValidation(0);
}

function parseCommentAwareListTokens(value) {
  const text = value ? `${value}` : "";
  const tokens = [];
  const lines = text.split(/\r\n|\r|\n/);
  const newlines = text.match(/\r\n|\r|\n/g) || [];
  let offset = 0;

  lines.forEach((line, index) => {
    const hashIndex = line.indexOf("#");
    const slashIndex = line.indexOf("//");
    let commentIndex = -1;

    if (hashIndex >= 0 && slashIndex >= 0) {
      commentIndex = Math.min(hashIndex, slashIndex);
    } else if (hashIndex >= 0) {
      commentIndex = hashIndex;
    } else if (slashIndex >= 0) {
      commentIndex = slashIndex;
    }

    const source = commentIndex >= 0 ? line.slice(0, commentIndex) : line;
    const matcher = /[^,\s]+/g;
    let match;

    while ((match = matcher.exec(source)) !== null) {
      tokens.push({
        value: match[0],
        start: offset + match.index,
        end: offset + match.index + match[0].length,
      });
    }

    offset += line.length + (newlines[index] ? newlines[index].length : 0);
  });

  return tokens;
}

function analyzeTextListValue(value, validateItem, emptyMessage, options = {}) {
  const text = value ? `${value}` : "";
  if (!text.length) {
    return { valid: true, message: "", annotations: [] };
  }

  const tokens = parseCommentAwareListTokens(text);
  if (!tokens.length) {
    return { valid: false, message: emptyMessage, annotations: [] };
  }

  const duplicateMessage = options.duplicateMessage || getDuplicateValueText();
  const annotationMap = new Map();
  const errors = [];
  const seen = new Set();

  tokens.forEach((token) => {
    if (typeof validateItem === "function") {
      const validation = validateItem(token.value);
      if (!validation.valid) {
        errors.push(`${token.value}: ${validation.message}`);
        addAnnotationIssue(annotationMap, token, validation.message);
      }
    }

    const normalized = options.normalizeDuplicateValue
      ? options.normalizeDuplicateValue(token.value)
      : token.value;

    if (!normalized) {
      return;
    }

    if (seen.has(normalized)) {
      errors.push(`${token.value}: ${duplicateMessage}`);
      addAnnotationIssue(annotationMap, token, duplicateMessage);
      return;
    }

    seen.add(normalized);
  });

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function analyzeDomainSuffixText(value) {
  const validateDomainCondition = (domain) => {
    const normalized = `${domain || ""}`.trim();
    if (normalized.includes("/")) {
      return { valid: false, message: _("Invalid domain address") };
    }

    return main.validateDomain(normalized, true);
  };

  return analyzeTextListValue(
    value,
    (item) => {
      const colonIndex = item.indexOf(":");
      const prefix = colonIndex > 0 ? item.slice(0, colonIndex) : "";
      const body = colonIndex > 0 ? item.slice(colonIndex + 1) : item;

      if (!prefix) {
        return validateDomainCondition(body);
      }

      if (!["full", "keyword", "regex"].includes(prefix)) {
        return {
          valid: false,
          message: _("Allowed domain prefixes are full:, keyword:, and regex:"),
        };
      }

      if (!body.length) {
        return { valid: false, message: _("Value cannot be empty") };
      }

      if (prefix === "full") {
        return validateDomainCondition(body);
      }

      if (prefix === "keyword") {
        const validation = validateKeyword(null, body);
        return validation === true
          ? { valid: true, message: _("Valid") }
          : { valid: false, message: validation };
      }

      if (/[,\s]/.test(body)) {
        return {
          valid: false,
          message: _("Regular expression must not contain spaces or commas"),
        };
      }

      const validation = validateRegex(null, body);
      return validation === true
        ? { valid: true, message: _("Valid") }
        : { valid: false, message: validation };
    },
    _("At least one valid domain must be specified."),
    {
      normalizeDuplicateValue: (item) => `${item}`.toLowerCase(),
    },
  );
}

function domainValuesWithPrefix(section_id, key, prefix) {
  return getConfigListValues(section_id, key).map((value) =>
    prefix ? `${prefix}:${value}` : value,
  );
}

function domainTextValuesWithPrefix(section_id, key, prefix) {
  const legacyText = uci.get(UCI_PACKAGE, section_id, `${key}_text`);
  if (!legacyText) {
    return [];
  }

  return main
    .parseValueList(legacyText)
    .map((value) => (prefix ? `${prefix}:${value}` : value));
}

function uniqueDomainTextValues(values) {
  const seen = new Set();

  return values.filter((value) => {
    const key = `${value}`.toLowerCase();
    if (!key || seen.has(key)) {
      return false;
    }

    seen.add(key);
    return true;
  });
}

function appendUniqueDomainTextValues(textValue, values) {
  const originalText = typeof textValue === "string" ? textValue : "";
  const seen = new Set(
    main.parseValueList(originalText).map((value) => `${value}`.toLowerCase()),
  );
  const additions = uniqueDomainTextValues(values).filter((value) => {
    const key = `${value}`.toLowerCase();
    if (!key || seen.has(key)) {
      return false;
    }

    seen.add(key);
    return true;
  });

  if (!additions.length) {
    return originalText;
  }

  const base = originalText.replace(/\s+$/, "");
  return [base, ...additions].filter(Boolean).join("\n");
}

// The legacy exact (`list domain` or domain_text), keyword and regex
// conditions the backend uses (routing/rule_conditions.uc: text mode reads
// the *_text option, otherwise a list shadows it); in the combined text they
// are full:, keyword: and regex:.
function legacyDomainConditionValues(section_id, key, prefix) {
  return normalizeOptionValues(
    backendConditionValues(section_id, key).values,
  ).map((item) =>
    /^(full|keyword|regex):/.test(item) ? item : `${prefix}:${item}`,
  );
}

function legacyExactDomainValues(section_id) {
  return legacyDomainConditionValues(section_id, "domain", "full");
}

function loadCombinedDomainText(section_id) {
  const domainValue = uci.get(UCI_PACKAGE, section_id, "domain");
  const textValue =
    (typeof domainValue === "string" ? domainValue : "") ||
    uci.get(UCI_PACKAGE, section_id, "domain_suffix_text");
  const values = [
    ...legacyExactDomainValues(section_id),
    ...domainValuesWithPrefix(section_id, "domain_suffix", ""),
    ...legacyDomainConditionValues(section_id, "domain_keyword", "keyword"),
    ...legacyDomainConditionValues(section_id, "domain_regex", "regex"),
    ...domainTextValuesWithPrefix(section_id, "domain_suffix", ""),
  ];

  return appendUniqueDomainTextValues(textValue, values);
}

function analyzeIpCidrText(value) {
  return analyzeTextListValue(
    value,
    (item) => main.validateSubnet(item),
    _("At least one valid IP or subnet must be specified."),
    {
      normalizeDuplicateValue: (item) => `${item}`.trim(),
    },
  );
}

function validatePortCondition(_section_id, value) {
  const normalized = value ? `${value}`.trim() : "";

  if (!normalized.length) {
    return true;
  }

  const match = normalized.match(/^(\d+)(?:-(\d+))?$/);
  if (!match) {
    return _("Invalid port or range. Use 80 or 1000-2000");
  }

  const start = Number.parseInt(match[1], 10);
  const end = match[2] ? Number.parseInt(match[2], 10) : start;

  if (start < 1 || start > 65535 || end < 1 || end > 65535) {
    return _("Port must be between 1 and 65535");
  }

  if (start > end) {
    return _("Port range start must be less than or equal to end");
  }

  return true;
}

function getNfqwsOptionArgumentMode(option) {
  if (NFQWS_REQUIRED_ARG_OPTIONS.has(option)) {
    return "required";
  }

  if (NFQWS_OPTIONAL_ARG_OPTIONS.has(option)) {
    return "optional";
  }

  if (NFQWS_NO_ARG_OPTIONS.has(option)) {
    return "none";
  }

  return "unknown";
}

function getNfqws2OptionArgumentMode(option) {
  if (NFQWS2_REQUIRED_ARG_OPTIONS.has(option)) {
    return "required";
  }

  if (NFQWS2_OPTIONAL_ARG_OPTIONS.has(option)) {
    return "optional";
  }

  if (NFQWS2_NO_ARG_OPTIONS.has(option)) {
    return "none";
  }

  return "unknown";
}

function normalizeNfqwsStrategyWhitespace(value) {
  return value ? `${value}`.replace(/\s+/g, " ").trim() : "";
}

function parseNfqwsRuntimeTokens(value) {
  const text = value ? `${value}` : "";
  const tokens = [];
  const matcher = /\S+/g;
  let match;

  while ((match = matcher.exec(text)) !== null) {
    tokens.push({
      value: match[0],
      start: match.index,
      end: match.index + match[0].length,
    });
  }

  return tokens;
}
function normalizeNfqwsStrategyValue(value) {
  const normalized = normalizeNfqwsStrategyWhitespace(value);
  if (!normalized.length) {
    return "";
  }

  return normalized === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT
    ? ZAPRET_DEFAULT_NFQWS_OPT
    : normalized;
}

function getCachedNfqwsRemoteValidation(value) {
  const normalized = normalizeNfqwsStrategyValue(value);
  return normalized.length
    ? nfqwsRemoteValidationCache.get(normalized) ||
        nfqwsRemoteValidationUnavailable.get(normalized) ||
        null
    : null;
}

function cacheNfqwsRemoteValidation(value, result) {
  const normalized = normalizeNfqwsStrategyValue(value);
  if (!normalized.length) {
    return result;
  }

  const cached = {
    valid: result && result.valid === true,
    message: result && result.message ? `${result.message}` : "",
    needle: result && result.needle ? `${result.needle}` : "",
    needles:
      result && Array.isArray(result.needles)
        ? result.needles.filter(Boolean).map((item) => `${item}`)
        : result && result.needle
          ? [`${result.needle}`]
          : [],
  };

  nfqwsRemoteValidationCache.set(normalized, cached);
  return cached;
}

function buildNfqwsRemoteValidationFallback(error) {
  const message =
    error && error.message
      ? `${error.message}`
      : _("Unable to validate the NFQWS strategy through the backend parser.");

  return {
    valid: false,
    message: _(
      "Backend validation unavailable: %s. Save again to retry.",
    ).format(message.replace(/[.\s]+$/, "")),
    needle: "",
    needles: [],
  };
}

function validateNfqwsStrategyRemotely(value) {
  const normalized = normalizeNfqwsStrategyValue(value);

  if (!normalized.length) {
    return Promise.resolve({
      valid: true,
      message: "",
      needle: "",
      needles: [],
    });
  }

  if (nfqwsRemoteValidationCache.has(normalized)) {
    return Promise.resolve(nfqwsRemoteValidationCache.get(normalized));
  }

  if (nfqwsRemoteValidationInflight.has(normalized)) {
    return nfqwsRemoteValidationInflight.get(normalized);
  }

  const validationTask = fs
    .exec(NFQWS_VALIDATION_COMMAND, [
      "validate_nfqws_strategy_json",
      normalized,
    ])
    .then((result) => {
      const payload = JSON.parse(
        (result && result.stdout ? result.stdout : "{}").trim() || "{}",
      );
      if (typeof payload.valid !== "boolean") {
        throw new Error();
      }
      nfqwsRemoteValidationUnavailable.delete(normalized);
      return cacheNfqwsRemoteValidation(normalized, {
        valid: payload.valid === true,
        message: payload.message || "",
        needle: payload.needle || "",
        needles: Array.isArray(payload.needles)
          ? payload.needles.filter(Boolean)
          : payload.needle
            ? [payload.needle]
            : [],
      });
    })
    // A failed call is not a verdict: it is not cached, so the next
    // validation or Save asks the backend again (UC-040). Until then the
    // field says the check is unavailable.
    .catch((error) => {
      const fallback = buildNfqwsRemoteValidationFallback(error);
      nfqwsRemoteValidationUnavailable.set(normalized, fallback);
      return fallback;
    })
    .finally(() => {
      nfqwsRemoteValidationInflight.delete(normalized);
    });

  nfqwsRemoteValidationInflight.set(normalized, validationTask);
  return validationTask;
}

function getNfqwsForbiddenTokenInfo(token, index) {
  const configFileMessage = _(
    "External nfqws config files bypass Forkop queue management and explicit validation.",
  );
  const hostSelectionMessage = _(
    "Resource selection by hostname inside nfqws is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const ipSelectionMessage = _(
    "Resource selection by IP or CIDR inside nfqws is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const placeholderMessage = _(
    "Zapret hostlist templates are not supported here because Forkop does not expand them for per-rule NFQWS strategies.",
  );
  const queueMessage = _(
    "The NFQUEUE number is assigned by Forkop for each rule and must not be overridden here.",
  );
  const fwmarkMessage = _(
    "The desync fwmark is managed by Forkop for loop prevention and must not be overridden here.",
  );
  const daemonMessage = _(
    "Forkop manages the nfqws process lifecycle itself, so daemon mode is not allowed here.",
  );
  const dryRunMessage = _(
    "This field must start a working nfqws strategy; --dry-run exits immediately and is not allowed here.",
  );
  const versionMessage = _(
    "This field must start a working nfqws strategy; --version exits immediately and is not allowed here.",
  );

  if (index === 0 && (token.startsWith("@") || token.startsWith("$"))) {
    return {
      reason: configFileMessage,
      captureNextValue: false,
    };
  }

  if (token === "<HOSTLIST>" || token === "<HOSTLIST_NOAUTO>") {
    return {
      reason: placeholderMessage,
      captureNextValue: false,
    };
  }

  if (
    token === "--hostlist" ||
    token.startsWith("--hostlist=") ||
    token === "--hostlist-domains" ||
    token.startsWith("--hostlist-domains=") ||
    token === "--hostlist-exclude" ||
    token.startsWith("--hostlist-exclude=") ||
    token === "--hostlist-exclude-domains" ||
    token.startsWith("--hostlist-exclude-domains=") ||
    token === "--hostlist-auto" ||
    token.startsWith("--hostlist-auto=") ||
    token === "--hostlist-auto-fail-threshold" ||
    token.startsWith("--hostlist-auto-fail-threshold=") ||
    token === "--hostlist-auto-fail-time" ||
    token.startsWith("--hostlist-auto-fail-time=") ||
    token === "--hostlist-auto-retrans-threshold" ||
    token.startsWith("--hostlist-auto-retrans-threshold=") ||
    token === "--hostlist-auto-debug" ||
    token.startsWith("--hostlist-auto-debug=")
  ) {
    return {
      reason: hostSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--ipset" ||
    token.startsWith("--ipset=") ||
    token === "--ipset-ip" ||
    token.startsWith("--ipset-ip=") ||
    token === "--ipset-exclude" ||
    token.startsWith("--ipset-exclude=") ||
    token === "--ipset-exclude-ip" ||
    token.startsWith("--ipset-exclude-ip=")
  ) {
    return {
      reason: ipSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--qnum" || token.startsWith("--qnum=")) {
    return {
      reason: queueMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--dpi-desync-fwmark" ||
    token.startsWith("--dpi-desync-fwmark=")
  ) {
    return {
      reason: fwmarkMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--daemon") {
    return {
      reason: daemonMessage,
      captureNextValue: false,
    };
  }

  if (token === "--dry-run") {
    return {
      reason: dryRunMessage,
      captureNextValue: false,
    };
  }

  if (token === "--version") {
    return {
      reason: versionMessage,
      captureNextValue: false,
    };
  }

  return null;
}

function buildNfqwsLocalAnalysis(value) {
  const text = value ? `${value}` : "";
  if (!text.trim().length) {
    return {
      valid: false,
      message: _("NFQWS strategy cannot be empty"),
      annotations: [],
    };
  }

  if (text.trim() === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT) {
    return { valid: true, message: "", annotations: [] };
  }

  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();
  const errors = [];

  for (let index = 0; index < tokens.length; ) {
    const token = tokens[index];
    const bareToken = token.value.includes("=")
      ? token.value.slice(0, token.value.indexOf("="))
      : token.value;
    const nextToken = tokens[index + 1] || null;

    const forbidden = getNfqwsForbiddenTokenInfo(token.value, index);
    if (forbidden) {
      addAnnotationIssue(annotationMap, token, forbidden.reason);

      let displayToken = token.value;

      if (
        forbidden.captureNextValue &&
        nextToken &&
        !nextToken.value.startsWith("--")
      ) {
        addAnnotationIssue(annotationMap, nextToken, forbidden.reason);
        displayToken = `${displayToken} ${nextToken.value}`;
        index += 2;
      } else {
        index += 1;
      }

      errors.push(`${displayToken}: ${forbidden.reason}`);
      continue;
    }

    if (!token.value.startsWith("--")) {
      const reason = _(
        "Unexpected standalone token. Use explicit flags such as --name or --name=value.",
      );
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    const mode = getNfqwsOptionArgumentMode(bareToken);
    if (mode === "unknown") {
      const reason = _("Unknown NFQWS flag.");
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    if (mode === "none") {
      if (token.value.includes("=")) {
        const reason = _("This flag does not accept a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
      }

      index += 1;
      continue;
    }

    if (mode === "optional") {
      if (
        nextToken &&
        !token.value.includes("=") &&
        !nextToken.value.startsWith("--")
      ) {
        const reason = _(
          "Optional values must be attached with '=' here; a separate token would be ignored by nfqws.",
        );
        addAnnotationIssue(annotationMap, token, reason);
        addAnnotationIssue(annotationMap, nextToken, reason);
        errors.push(`${token.value} ${nextToken.value}: ${reason}`);
        index += 2;
      } else {
        index += 1;
      }

      continue;
    }

    if (!token.value.includes("=")) {
      if (!nextToken || nextToken.value.startsWith("--")) {
        const reason = _("This option requires a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
        index += 1;
        continue;
      }

      index += 2;
      continue;
    }

    index += 1;
  }

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function addNfqwsRemoteValidationNeedleAnnotations(
  annotationMap,
  tokens,
  remoteValidation,
  needle,
) {
  if (!needle.length) {
    return;
  }

  let matched = false;

  tokens.forEach((token) => {
    const tokenValue = token.value || "";
    const optionMatch =
      needle.startsWith("--") &&
      (tokenValue === needle || tokenValue.startsWith(`${needle}=`));
    const valueMatch =
      tokenValue === needle ||
      tokenValue.endsWith(`=${needle}`) ||
      (!needle.startsWith("--") && tokenValue.includes(`=${needle},`)) ||
      (!needle.startsWith("--") && tokenValue.endsWith(`=${needle}`));

    if (optionMatch || valueMatch) {
      addAnnotationIssue(annotationMap, token, remoteValidation.message);
      matched = true;
    }
  });

  if (matched) {
    return;
  }

  if (needle.startsWith("--")) {
    tokens
      .filter((token) => token.value && token.value.startsWith(needle))
      .forEach((token) =>
        addAnnotationIssue(annotationMap, token, remoteValidation.message),
      );
  }
}

function addNfqwsRemoteValidationAnnotations(
  annotationMap,
  tokens,
  remoteValidation,
) {
  const needles =
    remoteValidation &&
    Array.isArray(remoteValidation.needles) &&
    remoteValidation.needles.length
      ? remoteValidation.needles.map((needle) => `${needle}`)
      : remoteValidation && remoteValidation.needle
        ? [`${remoteValidation.needle}`]
        : [];

  needles.forEach((needle) =>
    addNfqwsRemoteValidationNeedleAnnotations(
      annotationMap,
      tokens,
      remoteValidation,
      needle,
    ),
  );
}

function analyzeNfqwsStrategy(value) {
  const localAnalysis = buildNfqwsLocalAnalysis(value);
  if (!localAnalysis.valid) {
    return localAnalysis;
  }

  const remoteValidation = getCachedNfqwsRemoteValidation(value);
  if (!remoteValidation || remoteValidation.valid) {
    return localAnalysis;
  }

  const text = value ? `${value}` : "";
  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();

  localAnalysis.annotations.forEach((annotation) =>
    addAnnotationIssue(annotationMap, annotation, annotation.message),
  );
  addNfqwsRemoteValidationAnnotations(annotationMap, tokens, remoteValidation);

  return {
    valid: false,
    message: [getValidationHeaderText(), remoteValidation.message].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function normalizeNfqws2StrategyValue(value) {
  const normalized = normalizeNfqwsStrategyWhitespace(value);
  return normalized.length ? normalized : ZAPRET2_DEFAULT_NFQWS2_OPT;
}

function getCachedNfqws2RemoteValidation(value) {
  const normalized = normalizeNfqws2StrategyValue(value);
  return normalized.length
    ? nfqws2RemoteValidationCache.get(normalized) ||
        nfqws2RemoteValidationUnavailable.get(normalized) ||
        null
    : null;
}

function cacheNfqws2RemoteValidation(value, result) {
  const normalized = normalizeNfqws2StrategyValue(value);
  if (!normalized.length) {
    return result;
  }

  const cached = {
    valid: result && result.valid === true,
    message: result && result.message ? `${result.message}` : "",
    needle: result && result.needle ? `${result.needle}` : "",
    needles:
      result && Array.isArray(result.needles)
        ? result.needles.filter(Boolean).map((item) => `${item}`)
        : result && result.needle
          ? [`${result.needle}`]
          : [],
  };

  nfqws2RemoteValidationCache.set(normalized, cached);
  return cached;
}

function buildNfqws2RemoteValidationFallback(error) {
  const message =
    error && error.message
      ? `${error.message}`
      : _("Unable to validate the NFQWS2 strategy through the backend parser.");

  return {
    valid: false,
    message: _(
      "Backend validation unavailable: %s. Save again to retry.",
    ).format(message.replace(/[.\s]+$/, "")),
    needle: "",
    needles: [],
  };
}

function validateNfqws2StrategyRemotely(value) {
  const normalized = normalizeNfqws2StrategyValue(value);

  if (!normalized.length) {
    return Promise.resolve({
      valid: true,
      message: "",
      needle: "",
      needles: [],
    });
  }

  if (nfqws2RemoteValidationCache.has(normalized)) {
    return Promise.resolve(nfqws2RemoteValidationCache.get(normalized));
  }

  if (nfqws2RemoteValidationInflight.has(normalized)) {
    return nfqws2RemoteValidationInflight.get(normalized);
  }

  const validationTask = fs
    .exec(NFQWS_VALIDATION_COMMAND, [
      "validate_nfqws2_strategy_json",
      normalized,
    ])
    .then((result) => {
      const payload = JSON.parse(
        (result && result.stdout ? result.stdout : "{}").trim() || "{}",
      );
      if (typeof payload.valid !== "boolean") {
        throw new Error();
      }
      nfqws2RemoteValidationUnavailable.delete(normalized);
      return cacheNfqws2RemoteValidation(normalized, {
        valid: payload.valid === true,
        message: payload.message || "",
        needle: payload.needle || "",
        needles: Array.isArray(payload.needles)
          ? payload.needles.filter(Boolean)
          : payload.needle
            ? [payload.needle]
            : [],
      });
    })
    // A failed call is not a verdict: it is not cached, so the next
    // validation or Save asks the backend again (UC-040). Until then the
    // field says the check is unavailable.
    .catch((error) => {
      const fallback = buildNfqws2RemoteValidationFallback(error);
      nfqws2RemoteValidationUnavailable.set(normalized, fallback);
      return fallback;
    })
    .finally(() => {
      nfqws2RemoteValidationInflight.delete(normalized);
    });

  nfqws2RemoteValidationInflight.set(normalized, validationTask);
  return validationTask;
}

function getNfqws2ForbiddenTokenInfo(token, index, nextToken) {
  const configFileMessage = _(
    "External nfqws2 config files bypass Forkop queue management and explicit validation.",
  );
  const hostSelectionMessage = _(
    "Resource selection by hostname inside nfqws2 is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const ipSelectionMessage = _(
    "Resource selection by IP or CIDR inside nfqws2 is not supported here; sing-box selects resources before NFQUEUE.",
  );
  const placeholderMessage = _(
    "Zapret2 hostlist templates are not supported here because Forkop does not expand them for per-rule NFQWS2 strategies.",
  );
  const queueMessage = _(
    "The NFQUEUE number is assigned by Forkop for each rule and must not be overridden here.",
  );
  const fwmarkMessage = _(
    "The desync fwmark is managed by Forkop for loop prevention and must not be overridden here.",
  );
  const fuzzMessage = _(
    "Fuzzing is not supported here because Forkop needs deterministic runtime validation.",
  );
  const interceptMessage = _(
    "Disabling interception is incompatible with action=zapret2 because Forkop sends matched traffic through NFQUEUE.",
  );
  const daemonMessage = _(
    "Forkop manages the nfqws2 process lifecycle itself, so daemon mode is not allowed here.",
  );
  const dryRunMessage = _(
    "This field must start a working nfqws2 strategy; --dry-run exits immediately and is not allowed here.",
  );
  const versionMessage = _(
    "This field must start a working nfqws2 strategy; --version exits immediately and is not allowed here.",
  );

  if (index === 0 && (token.startsWith("@") || token.startsWith("$"))) {
    return {
      reason: configFileMessage,
      captureNextValue: false,
    };
  }

  if (token === "<HOSTLIST>" || token === "<HOSTLIST_NOAUTO>") {
    return {
      reason: placeholderMessage,
      captureNextValue: false,
    };
  }

  if (
    token === "--hostlist" ||
    token.startsWith("--hostlist=") ||
    token === "--hostlist-domains" ||
    token.startsWith("--hostlist-domains=") ||
    token === "--hostlist-exclude" ||
    token.startsWith("--hostlist-exclude=") ||
    token === "--hostlist-exclude-domains" ||
    token.startsWith("--hostlist-exclude-domains=") ||
    token === "--hostlist-auto" ||
    token.startsWith("--hostlist-auto=") ||
    token === "--hostlist-auto-fail-threshold" ||
    token.startsWith("--hostlist-auto-fail-threshold=") ||
    token === "--hostlist-auto-fail-time" ||
    token.startsWith("--hostlist-auto-fail-time=") ||
    token === "--hostlist-auto-retrans-threshold" ||
    token.startsWith("--hostlist-auto-retrans-threshold=") ||
    token === "--hostlist-auto-debug" ||
    token.startsWith("--hostlist-auto-debug=") ||
    token === "--hostlist-auto-retrans-reset" ||
    token.startsWith("--hostlist-auto-retrans-reset=")
  ) {
    return {
      reason: hostSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--ipset" ||
    token.startsWith("--ipset=") ||
    token === "--ipset-ip" ||
    token.startsWith("--ipset-ip=") ||
    token === "--ipset-exclude" ||
    token.startsWith("--ipset-exclude=") ||
    token === "--ipset-exclude-ip" ||
    token.startsWith("--ipset-exclude-ip=")
  ) {
    return {
      reason: ipSelectionMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--qnum" || token.startsWith("--qnum=")) {
    return {
      reason: queueMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--fwmark" ||
    token.startsWith("--fwmark=") ||
    token === "--dpi-desync-fwmark" ||
    token.startsWith("--dpi-desync-fwmark=")
  ) {
    return {
      reason: fwmarkMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (token === "--fuzz" || token.startsWith("--fuzz=")) {
    return {
      reason: fuzzMessage,
      captureNextValue: !token.includes("="),
    };
  }

  if (
    token === "--intercept=0" ||
    token === "--intercept=false" ||
    token === "--intercept=no" ||
    (token === "--intercept" && nextToken && nextToken.value === "0")
  ) {
    return {
      reason: interceptMessage,
      captureNextValue: token === "--intercept",
    };
  }

  if (token === "--daemon") {
    return {
      reason: daemonMessage,
      captureNextValue: false,
    };
  }

  if (token === "--dry-run") {
    return {
      reason: dryRunMessage,
      captureNextValue: false,
    };
  }

  if (token === "--version") {
    return {
      reason: versionMessage,
      captureNextValue: false,
    };
  }

  return null;
}

function buildNfqws2LocalAnalysis(value) {
  const text = value ? `${value}` : "";
  if (!text.trim().length) {
    return {
      valid: false,
      message: _("NFQWS2 strategy cannot be empty"),
      annotations: [],
    };
  }

  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();
  const errors = [];

  for (let index = 0; index < tokens.length; ) {
    const token = tokens[index];
    const bareToken = token.value.includes("=")
      ? token.value.slice(0, token.value.indexOf("="))
      : token.value;
    const nextToken = tokens[index + 1] || null;

    const forbidden = getNfqws2ForbiddenTokenInfo(
      token.value,
      index,
      nextToken,
    );
    if (forbidden) {
      addAnnotationIssue(annotationMap, token, forbidden.reason);

      let displayToken = token.value;

      if (
        forbidden.captureNextValue &&
        nextToken &&
        !nextToken.value.startsWith("--")
      ) {
        addAnnotationIssue(annotationMap, nextToken, forbidden.reason);
        displayToken = `${displayToken} ${nextToken.value}`;
        index += 2;
      } else {
        index += 1;
      }

      errors.push(`${displayToken}: ${forbidden.reason}`);
      continue;
    }

    if (!token.value.startsWith("--")) {
      const reason = _(
        "Unexpected standalone token. Use explicit flags such as --name or --name=value.",
      );
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    const mode = getNfqws2OptionArgumentMode(bareToken);
    if (mode === "unknown") {
      const reason = _("Unknown NFQWS2 flag.");
      addAnnotationIssue(annotationMap, token, reason);
      errors.push(`${token.value}: ${reason}`);
      index += 1;
      continue;
    }

    if (mode === "none") {
      if (token.value.includes("=")) {
        const reason = _("This flag does not accept a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
      }

      index += 1;
      continue;
    }

    if (mode === "optional") {
      if (
        nextToken &&
        !token.value.includes("=") &&
        !nextToken.value.startsWith("--")
      ) {
        const reason = _(
          "Optional values must be attached with '=' here; a separate token would be ignored by nfqws2.",
        );
        addAnnotationIssue(annotationMap, token, reason);
        addAnnotationIssue(annotationMap, nextToken, reason);
        errors.push(`${token.value} ${nextToken.value}: ${reason}`);
        index += 2;
      } else {
        index += 1;
      }

      continue;
    }

    if (!token.value.includes("=")) {
      if (!nextToken || nextToken.value.startsWith("--")) {
        const reason = _("This option requires a value.");
        addAnnotationIssue(annotationMap, token, reason);
        errors.push(`${token.value}: ${reason}`);
        index += 1;
        continue;
      }

      index += 2;
      continue;
    }

    index += 1;
  }

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function analyzeNfqws2Strategy(value) {
  const localAnalysis = buildNfqws2LocalAnalysis(value);
  if (!localAnalysis.valid) {
    return localAnalysis;
  }

  const remoteValidation = getCachedNfqws2RemoteValidation(value);
  if (!remoteValidation || remoteValidation.valid) {
    return localAnalysis;
  }

  const text = value ? `${value}` : "";
  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();

  localAnalysis.annotations.forEach((annotation) =>
    addAnnotationIssue(annotationMap, annotation, annotation.message),
  );
  addNfqwsRemoteValidationAnnotations(annotationMap, tokens, remoteValidation);

  return {
    valid: false,
    message: [getValidationHeaderText(), remoteValidation.message].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function normalizeByedpiStrategyWhitespace(value) {
  return value ? `${value}`.replace(/\s+/g, " ").trim() : "";
}

function normalizeByedpiStrategyValue(value) {
  const normalized = normalizeByedpiStrategyWhitespace(value);
  return normalized.length ? normalized : BYEDPI_DEFAULT_CMD_OPTS;
}

function getCachedByedpiRemoteValidation(value) {
  const normalized = normalizeByedpiStrategyValue(value);
  return normalized.length
    ? byedpiRemoteValidationCache.get(normalized) ||
        byedpiRemoteValidationUnavailable.get(normalized) ||
        null
    : null;
}

function cacheByedpiRemoteValidation(value, result) {
  const normalized = normalizeByedpiStrategyValue(value);
  if (!normalized.length) {
    return result;
  }

  const cached = {
    valid: result && result.valid === true,
    message: result && result.message ? `${result.message}` : "",
    needle: result && result.needle ? `${result.needle}` : "",
    needles:
      result && Array.isArray(result.needles)
        ? result.needles.filter(Boolean).map((item) => `${item}`)
        : result && result.needle
          ? [`${result.needle}`]
          : [],
  };

  byedpiRemoteValidationCache.set(normalized, cached);
  return cached;
}

function buildByedpiRemoteValidationFallback(error) {
  const message =
    error && error.message
      ? `${error.message}`
      : _("Unable to validate the ByeDPI strategy through the backend parser.");

  return {
    valid: false,
    message: _(
      "Backend validation unavailable: %s. Save again to retry.",
    ).format(message.replace(/[.\s]+$/, "")),
    needle: "",
    needles: [],
  };
}

function validateByedpiStrategyRemotely(value) {
  const normalized = normalizeByedpiStrategyValue(value);

  if (!normalized.length) {
    return Promise.resolve({
      valid: true,
      message: "",
      needle: "",
      needles: [],
    });
  }

  if (byedpiRemoteValidationCache.has(normalized)) {
    return Promise.resolve(byedpiRemoteValidationCache.get(normalized));
  }

  if (byedpiRemoteValidationInflight.has(normalized)) {
    return byedpiRemoteValidationInflight.get(normalized);
  }

  const validationTask = fs
    .exec(NFQWS_VALIDATION_COMMAND, [
      "validate_byedpi_strategy_json",
      normalized,
    ])
    .then((result) => {
      const payload = JSON.parse(
        (result && result.stdout ? result.stdout : "{}").trim() || "{}",
      );
      if (typeof payload.valid !== "boolean") {
        throw new Error();
      }
      byedpiRemoteValidationUnavailable.delete(normalized);
      return cacheByedpiRemoteValidation(normalized, {
        valid: payload.valid === true,
        message: payload.message || "",
        needle: payload.needle || "",
        needles: Array.isArray(payload.needles)
          ? payload.needles.filter(Boolean)
          : payload.needle
            ? [payload.needle]
            : [],
      });
    })
    // A failed call is not a verdict: it is not cached, so the next
    // validation or Save asks the backend again (UC-040). Until then the
    // field says the check is unavailable.
    .catch((error) => {
      const fallback = buildByedpiRemoteValidationFallback(error);
      byedpiRemoteValidationUnavailable.set(normalized, fallback);
      return fallback;
    })
    .finally(() => {
      byedpiRemoteValidationInflight.delete(normalized);
    });

  byedpiRemoteValidationInflight.set(normalized, validationTask);
  return validationTask;
}

function getByedpiShortOptionName(token) {
  return token.length > 2 ? token.slice(0, 2) : token;
}

function byedpiTokenLooksLikeOption(token) {
  return /^--.+/.test(token) || /^-[A-Za-z].*/.test(token);
}

function getByedpiControlledTokenInfo(token) {
  const listenMessage = _(
    "ByeDPI listen address and port are assigned by Forkop and must not be set in the strategy.",
  );
  const transparentMessage = _(
    "Transparent proxy mode is incompatible with action=byedpi because Forkop connects to ciadpi through SOCKS.",
  );
  const daemonMessage = _(
    "Forkop manages the ciadpi process lifecycle itself, so daemon mode is not allowed here.",
  );
  const pidfileMessage = _(
    "Forkop manages ciadpi pid files itself, so pidfile options are not allowed here.",
  );
  const exitMessage = _(
    "This field must start a working ciadpi strategy; help/version options exit immediately and are not allowed here.",
  );

  if (
    token === "--ip" ||
    token.startsWith("--ip=") ||
    token === "-i" ||
    /^-i.+/.test(token) ||
    token === "--port" ||
    token.startsWith("--port=") ||
    token === "-p" ||
    /^-p.+/.test(token)
  ) {
    return {
      reason: listenMessage,
      captureNextValue:
        token === "--ip" ||
        token === "-i" ||
        token === "--port" ||
        token === "-p",
    };
  }

  if (token === "--transparent" || token === "-E" || /^-E.+/.test(token)) {
    return {
      reason: transparentMessage,
      captureNextValue: false,
    };
  }

  if (token === "--daemon" || token === "-D" || /^-D.+/.test(token)) {
    return {
      reason: daemonMessage,
      captureNextValue: false,
    };
  }

  if (
    token === "--pidfile" ||
    token.startsWith("--pidfile=") ||
    token === "-w" ||
    /^-w.+/.test(token)
  ) {
    return {
      reason: pidfileMessage,
      captureNextValue: token === "--pidfile" || token === "-w",
    };
  }

  if (
    token === "--help" ||
    token === "-h" ||
    /^-h.+/.test(token) ||
    token === "--version" ||
    token === "-v" ||
    /^-v.+/.test(token)
  ) {
    return {
      reason: exitMessage,
      captureNextValue: false,
    };
  }

  return null;
}

function validateByedpiStrategyToken(token, nextToken) {
  const controlled = getByedpiControlledTokenInfo(token);
  if (controlled) {
    return {
      valid: false,
      reason: controlled.reason,
      captureNextValue: controlled.captureNextValue,
    };
  }

  if (/^--[^=]+=/.test(token)) {
    const base = token.split("=", 1)[0];
    const value = token.slice(base.length + 1);

    if (BYEDPI_LONG_VALUE_OPTIONS.has(base)) {
      return value.length
        ? { valid: true, consumeNext: false }
        : {
            valid: false,
            reason: _("ByeDPI option requires a value: %s").format(base),
            captureNextValue: false,
          };
    }

    if (BYEDPI_LONG_FLAG_OPTIONS.has(base)) {
      return {
        valid: false,
        reason: _("ByeDPI option does not accept a value: %s").format(base),
        captureNextValue: false,
      };
    }

    return {
      valid: false,
      reason: _("Unknown ByeDPI option: %s").format(base),
      captureNextValue: false,
    };
  }

  if (/^--.+/.test(token)) {
    if (BYEDPI_LONG_VALUE_OPTIONS.has(token)) {
      return nextToken && !byedpiTokenLooksLikeOption(nextToken)
        ? { valid: true, consumeNext: true }
        : {
            valid: false,
            reason: _("ByeDPI option requires a value: %s").format(token),
            captureNextValue: false,
          };
    }

    if (BYEDPI_LONG_FLAG_OPTIONS.has(token)) {
      return { valid: true, consumeNext: false };
    }

    return {
      valid: false,
      reason: _("Unknown ByeDPI option: %s").format(token),
      captureNextValue: false,
    };
  }

  if (/^-./.test(token)) {
    if (token === "-") {
      return {
        valid: false,
        reason: _("Unexpected ByeDPI strategy argument: %s").format(token),
        captureNextValue: false,
      };
    }

    const short = getByedpiShortOptionName(token);
    const compactValue = token.slice(short.length);

    if (BYEDPI_SHORT_VALUE_OPTIONS.has(short)) {
      if (token === short) {
        return nextToken && !byedpiTokenLooksLikeOption(nextToken)
          ? { valid: true, consumeNext: true }
          : {
              valid: false,
              reason: _("ByeDPI option requires a value: %s").format(short),
              captureNextValue: false,
            };
      }

      return compactValue.length
        ? { valid: true, consumeNext: false }
        : {
            valid: false,
            reason: _("ByeDPI option requires a value: %s").format(short),
            captureNextValue: false,
          };
    }

    if (BYEDPI_SHORT_FLAG_OPTIONS.has(short)) {
      return token === short
        ? { valid: true, consumeNext: false }
        : {
            valid: false,
            reason: _(
              "ByeDPI option does not accept a compact value: %s",
            ).format(short),
            captureNextValue: false,
          };
    }

    return {
      valid: false,
      reason: _("Unknown ByeDPI option: %s").format(short),
      captureNextValue: false,
    };
  }

  return {
    valid: false,
    reason: _("Unexpected ByeDPI strategy argument: %s").format(token),
    captureNextValue: false,
  };
}

function buildByedpiLocalAnalysis(value) {
  const text = value ? `${value}` : "";
  if (!text.trim().length) {
    return {
      valid: false,
      message: _("ByeDPI strategy cannot be empty"),
      annotations: [],
    };
  }

  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();
  const errors = [];

  for (let index = 0; index < tokens.length; ) {
    const token = tokens[index];
    const nextToken = tokens[index + 1] || null;
    const tokenValidation = validateByedpiStrategyToken(
      token.value,
      nextToken ? nextToken.value : null,
    );

    if (tokenValidation.valid) {
      index += tokenValidation.consumeNext ? 2 : 1;
      continue;
    }

    addAnnotationIssue(annotationMap, token, tokenValidation.reason);
    let displayToken = token.value;

    if (
      tokenValidation.captureNextValue &&
      nextToken &&
      !nextToken.value.startsWith("-")
    ) {
      addAnnotationIssue(annotationMap, nextToken, tokenValidation.reason);
      displayToken = `${displayToken} ${nextToken.value}`;
      index += 2;
    } else {
      index += 1;
    }

    errors.push(`${displayToken}: ${tokenValidation.reason}`);
  }

  if (!errors.length) {
    return { valid: true, message: "", annotations: [] };
  }

  return {
    valid: false,
    message: [getValidationHeaderText(), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function analyzeByedpiStrategy(value) {
  const localAnalysis = buildByedpiLocalAnalysis(value);
  if (!localAnalysis.valid) {
    return localAnalysis;
  }

  const remoteValidation = getCachedByedpiRemoteValidation(value);
  if (!remoteValidation || remoteValidation.valid) {
    return localAnalysis;
  }

  const text = value ? `${value}` : "";
  const tokens = parseNfqwsRuntimeTokens(text);
  const annotationMap = new Map();

  localAnalysis.annotations.forEach((annotation) =>
    addAnnotationIssue(annotationMap, annotation, annotation.message),
  );
  addNfqwsRemoteValidationAnnotations(annotationMap, tokens, remoteValidation);

  return {
    valid: false,
    message: [getValidationHeaderText(), remoteValidation.message].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
  };
}

function configureTextareaOption(option, analyzer, remoteValidationAttacher) {
  const originalRenderWidget = option.renderWidget;

  option.renderWidget = function (section_id, option_index, cfgvalue) {
    const node = originalRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    const textarea =
      node && typeof node.querySelector === "function"
        ? node.querySelector("textarea")
        : node;

    if (textarea) {
      applyTextareaInputAttributes(textarea);
      textarea.addEventListener("input", () => {
        node.dispatchEvent(new CustomEvent("widget-change", { bubbles: true }));
      });
      if (typeof analyzer === "function") {
        attachAnnotatedTextarea(textarea, analyzer);
      }
      // The ACL grants the backend parser only with write access: for a
      // read-only session, which cannot save, the call fails and the field
      // would ask to save again.
      if (
        typeof remoteValidationAttacher === "function" &&
        !(this.readonly != null ? this.readonly : this.map.readonly)
      ) {
        remoteValidationAttacher(this, section_id, textarea);
      }
    }

    return node;
  };
}

function getOptionTextarea(option, section_id) {
  const field =
    typeof option.map.findElement === "function"
      ? option.map.findElement("data-field", option.cbid(section_id))
      : null;

  if (field && typeof field.querySelector === "function") {
    return field.querySelector("textarea");
  }

  const elem =
    typeof option.getUIElement === "function"
      ? option.getUIElement(section_id)
      : null;
  const node = elem && elem.node ? elem.node : null;

  if (node && node.nodeName === "TEXTAREA") {
    return node;
  }

  return node && typeof node.querySelector === "function"
    ? node.querySelector("textarea")
    : null;
}

function invalidOptionError(option, section_id, message) {
  const title = option.stripTags(option.title).trim();
  const error = message || option.getValidationError(section_id) || "";

  return new TypeError(
    `${_('Option "%s" contains an invalid input value.').format(title || option.option)} ${error}`,
  );
}

function rejectInvalidOption(option, section_id, message) {
  return Promise.reject(invalidOptionError(option, section_id, message));
}

function parseStrategyWithRemoteValidation(section_id, config) {
  const active = this.isActive(section_id);

  if (active) {
    if (typeof this.triggerValidation === "function") {
      this.triggerValidation(section_id);
    }

    if (!this.isValid(section_id)) {
      return rejectInvalidOption(
        this,
        section_id,
        this.getValidationError(section_id),
      );
    }

    const cval = this.cfgvalue(section_id);
    const fval = this.formvalue(section_id);
    const cvalString = cval == null ? "" : `${cval}`;
    const fvalString = fval == null ? "" : `${fval}`;
    const shouldWrite = this.forcewrite || cvalString !== fvalString;

    if (!shouldWrite) {
      return Promise.resolve();
    }

    return config.remoteValidate(fvalString).then((result) => {
      const textarea = getOptionTextarea(this, section_id);

      if (textarea) {
        refreshAnnotatedTextareaValidation(this, section_id, textarea);
      }

      if (typeof this.triggerValidation === "function") {
        this.triggerValidation(section_id);
      }

      if (!result || result.valid !== true) {
        return rejectInvalidOption(
          this,
          section_id,
          result && result.message ? result.message : config.invalidMessage,
        );
      }

      return Promise.resolve(this.write(section_id, fvalString));
    });
  }

  if (!this.retain) {
    return Promise.resolve(this.remove(section_id));
  }

  return Promise.resolve();
}

// A failed backend check is shown on the strategy field until the next Save,
// which asks the backend again instead of refusing on the old failure.
function forgetUnavailableStrategyValidations() {
  nfqwsRemoteValidationUnavailable.clear();
  nfqws2RemoteValidationUnavailable.clear();
  byedpiRemoteValidationUnavailable.clear();
}

// The backend check of a changed strategy runs inside parse, after the other
// options of the rule have been written or removed; the rule modal runs it
// before anything is written (refuseInvalidModalSave). A passed check is
// cached, so parse does not ask the backend again.
function checkStrategyBeforeSave(section_id, config) {
  const cval = this.cfgvalue(section_id);
  const fval = this.formvalue(section_id);
  const fvalString = fval == null ? "" : `${fval}`;

  if (!this.forcewrite && (cval == null ? "" : `${cval}`) === fvalString) {
    return true;
  }

  return config.remoteValidate(fvalString).then((result) => {
    const textarea = getOptionTextarea(this, section_id);

    if (textarea) {
      refreshAnnotatedTextareaValidation(this, section_id, textarea);
    }

    if (typeof this.triggerValidation === "function") {
      this.triggerValidation(section_id);
    }

    return result && result.valid === true
      ? true
      : (result && result.message) || config.invalidMessage;
  });
}

function nfqwsStrategyValidation() {
  return {
    remoteValidate: validateNfqwsStrategyRemotely,
    invalidMessage: _(
      "Unable to validate the NFQWS strategy through the backend parser.",
    ),
  };
}

function nfqws2StrategyValidation() {
  return {
    remoteValidate: validateNfqws2StrategyRemotely,
    invalidMessage: _(
      "Unable to validate the NFQWS2 strategy through the backend parser.",
    ),
  };
}

function parseNfqwsStrategyOnSave(section_id) {
  return parseStrategyWithRemoteValidation.call(
    this,
    section_id,
    nfqwsStrategyValidation(),
  );
}

function parseNfqws2StrategyOnSave(section_id) {
  return parseStrategyWithRemoteValidation.call(
    this,
    section_id,
    nfqws2StrategyValidation(),
  );
}

function addDynamicConditionField(section, config) {
  const o = section.taboption(
    "match",
    form.DynamicList,
    config.key,
    config.label,
    config.description,
  );

  o.modalonly = true;
  if (config.placeholder) {
    o.placeholder = config.placeholder;
  }
  if (config.dynamicValidate) {
    o.validate = config.dynamicValidate;
  }

  o.load = function (section_id) {
    if (typeof config.load === "function") {
      return config.load(section_id);
    }

    const values = getConfigListValues(section_id, config.key);
    if (values.length) {
      return values;
    }

    const legacyText = uci.get(UCI_PACKAGE, section_id, `${config.key}_text`);
    return legacyText ? main.parseValueList(legacyText) : [];
  };

  o.write = function (section_id, value) {
    writeListOption(section_id, config.key, value);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text`);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text_mode`);
  };

  // A field the user cleared drops the values it showed, the legacy text
  // included; a hidden field drops the list only.
  o.remove = function (section_id) {
    if (!this.isActive(section_id)) {
      uci.unset(UCI_PACKAGE, section_id, config.key);
    } else if (normalizeOptionValues(this.cfgvalue(section_id)).length) {
      this.write(section_id, []);
    }
  };

  return o;
}

function addLocalDeviceSubnetDynamicField(section, config) {
  const o = section.taboption(
    "devices",
    form.DynamicList,
    config.key,
    config.label,
    config.description,
  );

  o.modalonly = true;
  o.placeholder = _("Device or IP");
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);
    return validation.valid ? true : validation.message;
  };
  o.load = function (section_id) {
    // fully_routed_ips has no legacy text form: the backend reads the list only.
    if (!config.legacyText) {
      return getConfigListValues(section_id, config.key);
    }

    // conditions_text_mode also keeps the other conditions in *_text
    // options, so a list written here would not be read: read-only until
    // the rule is converted.
    this.readonly = backendFlag(section_id, "conditions_text_mode")
      ? true
      : null;

    const current = backendConditionValues(section_id, config.key);
    return current.source === "list"
      ? getConfigListValues(section_id, config.key)
      : current.values;
  };
  o.write = function (section_id, value) {
    writeListOption(section_id, config.key, value);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text`);
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text_mode`);
  };
  // A field the user cleared drops the values it showed wherever they are
  // stored; a field that showed nothing, or a read-only one, changes
  // nothing. A hidden field drops the list only.
  o.remove = function (section_id) {
    if (!this.isActive(section_id)) {
      uci.unset(UCI_PACKAGE, section_id, config.key);
      return;
    }

    if (
      this.readonly === true ||
      !normalizeOptionValues(this.cfgvalue(section_id)).length
    ) {
      return;
    }

    this.write(section_id, []);
  };
  o.renderWidget = function (section_id, _option_index, cfgvalue) {
    return localDevices.createLocalDeviceDynamicListWidget(
      this,
      section_id,
      cfgvalue,
    );
  };

  return o;
}

function addTextConditionField(section, config) {
  const optionName = config.optionName || `${config.key}_text`;
  const legacyTextOptionName =
    config.legacyTextOptionName || `${config.key}_text`;
  const o = section.taboption(
    "match",
    form.TextValue,
    optionName,
    config.label,
    config.description,
  );

  o.rows = 8;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  const validateText = config.textAnalyze
    ? function (_section_id, value) {
        const analysis = config.textAnalyze(value);
        return analysis.valid ? true : analysis.message;
      }
    : config.textValidate;
  if (validateText) {
    // The field may show legacy values it cannot hold as they are (a
    // keyword with a space, a regex with a comma, a value the backend
    // ignores). Left unchanged it is not written (form.js parse()), so it
    // does not refuse the save of the rule; editing it asks to fix them.
    o.validate = function (section_id, value) {
      if (
        this.showsLegacyText?.[section_id] &&
        `${value ?? ""}` === `${this.cfgvalue(section_id) ?? ""}`
      ) {
        return true;
      }

      return validateText.apply(this, arguments);
    };
  }
  configureTextareaOption(o, config.textAnalyze);

  const loadTextConditionValue = function (section_id) {
    if (typeof config.loadText === "function") {
      return config.loadText(section_id);
    }

    // conditions_text_mode also keeps the other conditions in *_text
    // options, so this option would not be read: read-only until the rule
    // is converted.
    this.readonly =
      config.lockedByConditionsTextMode &&
      backendFlag(section_id, "conditions_text_mode")
        ? true
        : null;

    // Text mode reads the legacy text and ignores the option.
    if (conditionTextMode(section_id, config.key)) {
      return valuesToText(
        uci.get(UCI_PACKAGE, section_id, legacyTextOptionName),
      );
    }

    const textValue =
      uci.get(UCI_PACKAGE, section_id, optionName) ||
      uci.get(UCI_PACKAGE, section_id, legacyTextOptionName);
    if (textValue) {
      return valuesToText(textValue);
    }

    return valuesToText(uci.get(UCI_PACKAGE, section_id, config.key));
  };

  o.load = function (section_id) {
    const text = loadTextConditionValue.call(this, section_id);
    const stored = uci.get(UCI_PACKAGE, section_id, optionName);

    this.showsLegacyText = Object.assign({}, this.showsLegacyText, {
      [section_id]: text !== (typeof stored === "string" ? stored : ""),
    });
    return text;
  };

  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized.length) {
      uci.set(UCI_PACKAGE, section_id, optionName, normalized);
    } else {
      uci.unset(UCI_PACKAGE, section_id, optionName);
    }

    if (config.key !== optionName) {
      uci.unset(UCI_PACKAGE, section_id, config.key);
    }
    if (legacyTextOptionName !== optionName) {
      uci.unset(UCI_PACKAGE, section_id, legacyTextOptionName);
    }
    uci.unset(UCI_PACKAGE, section_id, `${config.key}_text_mode`);

    if (typeof config.afterWrite === "function") {
      config.afterWrite(section_id);
    }
  };

  // A field the user cleared drops the values it showed wherever they are
  // stored; a field that showed nothing, or a read-only one, changes
  // nothing. A hidden field drops its option only.
  o.remove = function (section_id) {
    if (!this.isActive(section_id)) {
      uci.unset(UCI_PACKAGE, section_id, optionName);
    } else if (
      this.readonly !== true &&
      `${this.cfgvalue(section_id) || ""}`.trim()
    ) {
      this.write(section_id, "");
    }
  };

  return o;
}

function loadRulesetValues(option) {
  delete option.keylist;
  delete option.vallist;

  Object.keys(main.DOMAIN_LIST_OPTIONS).forEach((key) => {
    option.value(key, main.domainListLabel(key));
  });
}

function isBuiltinRulesetValue(value) {
  return Object.prototype.hasOwnProperty.call(main.DOMAIN_LIST_OPTIONS, value);
}

// A rule set that is already in the list has nothing to offer in the
// suggestions below it, and on a long service list the entries that are still
// available get lost among the ones that are not.
function hideSelectedRulesetChoices(option, choices) {
  option.renderWidget = function (section_id, _option_index, cfgvalue) {
    const values = L.toArray(cfgvalue != null ? cfgvalue : this.default);
    const labels = Object.fromEntries(
      choices.map(({ value, label }) => [value, label]),
    );
    const widget = new ui.DynamicList(values, labels, {
      id: this.cbid(section_id),
      sort: this.keylist,
      allowduplicates: false,
      optional: this.optional || this.rmempty,
      datatype: this.datatype,
      placeholder: this.placeholder,
      validate: L.bind(this.validate, this, section_id),
      disabled: this.readonly != null ? this.readonly : this.map.readonly,
    });
    const node = widget.render();
    const refreshChoices = () => {
      const selected = new Set(L.toArray(widget.getValue()));
      const available = choices.filter(({ value }) => !selected.has(value));
      widget.clearChoices();
      widget.addChoices(
        available.map(({ value }) => value),
        labels,
      );
    };
    node.addEventListener("cbi-dynlist-change", refreshChoices);
    refreshChoices();
    return node;
  };
}

const SECONDARY_RULESET_MIRROR_PREFIX =
  "https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/";
const LEGACY_SECONDARY_RULESET_MIRROR_PREFIX =
  "https://mirror.51343.ru/forkop/lists/b4geoip-forkop/srs/";
const SECONDARY_RULESET_RAW_PREFIX =
  "https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/";
const SECONDARY_RULESET_CDN_PREFIX =
  "https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/srs/";

function secondaryRulesetUrl(value) {
  return `${SECONDARY_RULESET_MIRROR_PREFIX}${value}.srs`;
}

function secondaryRulesetId(reference) {
  const value = `${reference || ""}`;
  const prefix = [
    SECONDARY_RULESET_MIRROR_PREFIX,
    LEGACY_SECONDARY_RULESET_MIRROR_PREFIX,
    SECONDARY_RULESET_RAW_PREFIX,
    SECONDARY_RULESET_CDN_PREFIX,
  ].find((candidate) => value.startsWith(candidate));
  if (!prefix || !value.endsWith(".srs")) return "";
  const id = value.slice(prefix.length, -4);
  return Object.prototype.hasOwnProperty.call(
    main.SECONDARY_RULESET_OPTIONS || {},
    id,
  )
    ? id
    : "";
}

function getSecondaryRulesetReferences(section_id) {
  return uniqueDynamicListItems(
    getConfigListValues(section_id, "rule_set_with_subnets")
      .map(secondaryRulesetId)
      .filter(Boolean),
  );
}

// Built-in rule sets #2 match IP addresses, which a DNS rule cannot use, and
// the backend rejects such a rule. Values the rule already has stay visible
// for DNS and block that action until the user removes them, so they are
// neither dropped nor kept silently (UC-046).
function hasSecondaryRulesetsForDns(option, section_id) {
  if (!getSecondaryRulesetReferences(section_id).length) {
    return false;
  }

  const found =
    option.map && typeof option.map.lookupOption === "function"
      ? option.map.lookupOption("secondary_rule_sets", section_id)
      : null;
  const value = found ? found[0].formvalue(found[1]) : null;

  return value == null || normalizeDynamicListItems(value).length > 0;
}

function normalizeReferenceForExtensionCheck(value) {
  return `${value || ""}`.split(/[?#]/, 1)[0].toLowerCase();
}

function hasAllowedReferenceExtension(value, extensions) {
  const normalized = normalizeReferenceForExtensionCheck(value);
  return extensions.some((extension) => normalized.endsWith(extension));
}

function validateFileReference(value, extensions, errorMessage, options = {}) {
  if (!value || value.length === 0) {
    return true;
  }

  if (value.startsWith("http://") || value.startsWith("https://")) {
    const validation = main.validateUrl(value);
    if (
      validation.valid &&
      (options.allowRemoteWithoutExtension ||
        hasAllowedReferenceExtension(value, extensions))
    ) {
      return true;
    }

    return errorMessage;
  }

  if (value.startsWith("/")) {
    const validation = main.validatePath(value);
    if (validation.valid && hasAllowedReferenceExtension(value, extensions)) {
      return true;
    }

    return errorMessage;
  }

  return errorMessage;
}

function validateCustomRulesetReference(value) {
  return validateFileReference(
    value,
    [".srs", ".json"],
    _("Rule set must be an HTTP(S) URL or a local .srs / .json path"),
    { allowRemoteWithoutExtension: true },
  );
}

function validatePlainListReference(value) {
  return validateFileReference(
    value,
    [".lst"],
    _("List must be an HTTP(S) URL or a local .lst path"),
    { allowRemoteWithoutExtension: true },
  );
}

function getRulesetReferences(section_id) {
  return getConfigListValues(section_id, "rule_set");
}

function getBuiltInRulesetReferences(section_id) {
  const values = getConfigListValues(section_id, "community_lists").filter(
    (value) => isBuiltinRulesetValue(value),
  );

  return values.filter(
    (value, index, values) =>
      isBuiltinRulesetValue(value) && values.indexOf(value) === index,
  );
}

function getCustomRulesetReferences(section_id) {
  return uniqueDynamicListItems([
    ...getRulesetReferences(section_id).filter(
      (value) => !isBuiltinRulesetValue(value),
    ),
    ...getConfigListValues(section_id, "rule_set_with_subnets").filter(
      (value) => !secondaryRulesetId(value),
    ),
  ]);
}

function writeBuiltInRulesetReferences(section_id, values) {
  const refs = normalizeDynamicListItems(values).filter((value) =>
    isBuiltinRulesetValue(value),
  );
  writeListOption(section_id, "community_lists", refs);
}

function writeSecondaryRulesetReferences(section_id, values) {
  const custom = getConfigListValues(
    section_id,
    "rule_set_with_subnets",
  ).filter((value) => !secondaryRulesetId(value));
  const builtins = normalizeDynamicListItems(values)
    .filter((value) =>
      Object.prototype.hasOwnProperty.call(
        main.SECONDARY_RULESET_OPTIONS || {},
        value,
      ),
    )
    .map(secondaryRulesetUrl);
  writeListOption(section_id, "rule_set_with_subnets", [
    ...custom,
    ...builtins,
  ]);
}

function writeCustomRulesetReferences(section_id, values) {
  const refs = uniqueDynamicListItems(values);
  if (getRuleResolvedAction(section_id) === "dns") {
    writeDnsRulesetReferences(section_id, refs);
    return;
  }
  const secondaryRefs = getConfigListValues(
    section_id,
    "rule_set_with_subnets",
  ).filter((value) => secondaryRulesetId(value));
  const subnetRefs = getConfigListValues(
    section_id,
    "rule_set_with_subnets",
  ).filter((value) => !secondaryRulesetId(value) && refs.includes(value));
  const subnetRefSet = new Set(subnetRefs);

  writeListOption(
    section_id,
    "rule_set",
    refs.filter((value) => !subnetRefSet.has(value)),
  );
  writeListOption(section_id, "rule_set_with_subnets", [
    ...secondaryRefs,
    ...subnetRefs,
  ]);
  uci.unset(UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
}

function writeDnsRulesetReferences(section_id, values) {
  writeListOption(section_id, "rule_set", uniqueDynamicListItems(values));
  // Hidden Built-in rule sets #2 are not the DNS widget's to drop (UC-046).
  writeListOption(
    section_id,
    "rule_set_with_subnets",
    getConfigListValues(section_id, "rule_set_with_subnets").filter((value) =>
      secondaryRulesetId(value),
    ),
  );
  uci.unset(UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
}

function createSectionContent(section) {
  let o;

  // The rule editor walks through steps: what the rule is, where traffic
  // goes, what it matches, which devices it covers, and rare options.
  section.tab("basic", _("Basics"));
  section.tab("target", _("Where to"));
  section.tab("match", _("What"));
  section.tab("devices", _("For whom"));
  section.tab("advanced", _("Advanced"));

  o = section.taboption("basic", form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "6rem";

  o = section.taboption(
    "basic",
    form.DummyValue,
    "_action_display",
    _("Action"),
  );
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (section_id) {
    return getRuleActionDisplayMarkup(section_id);
  };
  o.textvalue = function (section_id) {
    return getRuleActionDisplayValue(section_id);
  };
  o.width = "8rem";

  o = section.taboption(
    "basic",
    form.DummyValue,
    "_conditions_summary",
    _("Conditions"),
  );
  o.modalonly = false;
  o.cfgvalue = function (section_id) {
    return getRuleConditionsSummary(section_id);
  };
  o.textvalue = o.cfgvalue;

  o = section.taboption(
    "basic",
    form.DummyValue,
    "_devices_summary",
    _("Devices"),
  );
  o.modalonly = false;
  o.cfgvalue = function (section_id) {
    return getRuleDevicesSummary(section_id);
  };
  o.textvalue = o.cfgvalue;

  o = section.taboption(
    "basic",
    form.Value,
    "label",
    _("Section name"),
    _("Visible name of this section"),
  );
  o.rmempty = false;
  o.modalonly = true;
  o.load = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };

  o = section.taboption(
    "basic",
    form.ListValue,
    "action",
    _("Action"),
    _("What Forkop should do when this section matches"),
  );
  populateActionOptionValues(o);
  o.default = "connection";
  o.rmempty = false;
  o.modalonly = true;
  o.cfgvalue = function (section_id) {
    return getRuleConfiguredAction(section_id);
  };
  o.load = function (section_id) {
    return ensureActionProvidersAvailabilityLoaded().then(() => {
      populateActionOptionValues(this, section_id);
      return this.cfgvalue(section_id);
    });
  };
  o.validate = function (section_id, value) {
    const unavailable = unavailableChoiceError(this, value);
    if (unavailable) {
      return unavailable;
    }
    if (value === "dns" && hasSecondaryRulesetsForDns(this, section_id)) {
      return _(
        "Built-in rule sets #2 are not supported for DNS rules. Remove them on the What tab or choose another action.",
      );
    }
    return true;
  };

  o = section.taboption(
    "target",
    form.ListValue,
    "_dns_preset",
    _("DNS provider"),
    _(
      "A preset fills the DNS protocol and server below. Select Custom DNS to enter your own values.",
    ),
  );
  o.depends("action", "dns");
  o.value("custom", _("Custom DNS"));
  o.value("cloudflare", _("Cloudflare (DoH)"));
  o.value("google", _("Google Public DNS (DoH)"));
  o.value("quad9", _("Quad9 (DoH, malware blocking)"));
  o.value("adguard", _("AdGuard DNS (DoH, ad blocking)"));
  o.value("yandex", _("Yandex DNS (UDP, unencrypted)"));
  o.value("yandex_doh", _("Yandex DNS (DoH)"));
  o.value("yandex_dot", _("Yandex DNS (DoT, port 853)"));
  o.default = "custom";
  o.modalonly = true;
  // This is a form-only shortcut. The existing dns_type/dns_server fields
  // remain the only values saved to UCI and consumed by sing-box.
  o.cfgvalue = function (section_id) {
    return main.dnsRulePresetId(
      optionMapValue(this, section_id, "dns_type") || "udp",
      optionMapValue(this, section_id, "dns_server") || "",
    );
  };
  o.write = function () {};
  o.remove = function () {};
  const dnsPresetOption = o;
  let dnsTypeOption;
  let dnsServerOption;
  let applyingDnsPreset = false;
  o.onchange = function (_event, section_id) {
    if (applyingDnsPreset) return;
    const preset = main.dnsRulePresetById(this.formvalue(section_id));
    if (!preset) return;
    const serverWidget = dnsServerOption.getUIElement(section_id);
    const typeWidget = dnsTypeOption.getUIElement(section_id);
    if (!serverWidget || !typeWidget) return;
    applyingDnsPreset = true;
    try {
      serverWidget.setValue(preset.server);
      typeWidget.setValue(preset.protocol);
    } finally {
      applyingDnsPreset = false;
    }
  };
  function syncDnsPreset(section_id) {
    if (applyingDnsPreset) return;
    const widget = dnsPresetOption.getUIElement(section_id);
    if (!widget) return;
    const presetId = main.dnsRulePresetId(
      dnsTypeOption.formvalue(section_id) || "udp",
      dnsServerOption.formvalue(section_id) || "",
    );
    if (widget.getValue() === presetId) return;
    applyingDnsPreset = true;
    try {
      widget.setValue(presetId);
    } finally {
      applyingDnsPreset = false;
    }
  }

  o = section.taboption(
    "target",
    form.ListValue,
    "dns_type",
    _("DNS protocol"),
    _("DNS protocol used by the resolver"),
  );
  o.depends("action", "dns");
  dnsTypeChoices().forEach((choice) => o.value(choice.value, choice.label));
  o.default = "udp";
  o.rmempty = false;
  o.modalonly = true;
  o.onchange = function (_event, section_id) {
    syncDnsPreset(section_id);
  };
  dnsTypeOption = o;

  o = section.taboption(
    "target",
    form.Value,
    "dns_server",
    _("DNS server"),
    _("DNS server used by the resolver"),
  );
  o.depends("action", "dns");
  o.rmempty = false;
  o.modalonly = true;
  o.onchange = function (_event, section_id) {
    syncDnsPreset(section_id);
  };
  o.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) {
      return _("DNS server address cannot be empty");
    }
    const validation = main.validateDNSForProtocol(
      normalized,
      optionMapValue(this, _section_id, "dns_type") || "udp",
    );
    return validation.valid ? true : _("Enter a valid DNS server address");
  };
  dnsServerOption = o;

  o = section.taboption(
    "target",
    form.Flag,
    "dns_detour_enabled",
    _("DNS through section"),
    _("Route requests to this DNS server through another section."),
  );
  o.depends("action", "dns");
  o.default = "0";
  o.rmempty = false;
  o.modalonly = true;

  o = section.taboption(
    "target",
    form.ListValue,
    "dns_detour_section",
    _("DNS requests through section"),
  );
  o.depends({ action: "dns", dns_detour_enabled: "1" });
  o.rmempty = false;
  o.modalonly = true;
  o.load = function (section_id) {
    const value = uci.get(UCI_PACKAGE, section_id, "dns_detour_section") || "";
    // DPI sections are offered while their provider is installed: build the
    // list once availability is known, as the action list does.
    return ensureActionProvidersAvailabilityLoaded().then(() => {
      refreshDnsDetourSectionOptionValues(this, section_id);
      keepUnavailableChoice(this, value, describeUnavailableSection);
      return value;
    });
  };
  o.validate = function (_section_id, value) {
    if (!value) {
      return _("Select a section");
    }
    return unavailableChoiceError(this, value) || true;
  };

  o = section.taboption(
    "target",
    form.TextValue,
    "nfqws_opt",
    _("NFQWS Strategy"),
  );
  o.depends("action", "zapret");
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.load = function (section_id) {
    const value = uci.get(UCI_PACKAGE, section_id, "nfqws_opt");
    if (!value || value === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT) {
      return ZAPRET_DEFAULT_NFQWS_OPT;
    }

    return value;
  };
  o.write = function (section_id, value) {
    const normalized = normalizeNfqwsStrategyValue(value);
    const nextValue =
      !normalized.length || normalized === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT
        ? ZAPRET_DEFAULT_NFQWS_OPT
        : normalized;

    return validateNfqwsStrategyRemotely(nextValue).then((result) => {
      if (!result || result.valid !== true) {
        throw new TypeError(
          result && result.message
            ? result.message
            : _(
                "Unable to validate the NFQWS strategy through the backend parser.",
              ),
        );
      }

      uci.set(UCI_PACKAGE, section_id, "nfqws_opt", nextValue);
    });
  };
  o.validate = function (_section_id, value) {
    const analysis = analyzeNfqwsStrategy(value);
    return analysis.valid ? true : analysis.message;
  };
  o.parse = parseNfqwsStrategyOnSave;
  o.checkBeforeSave = function (section_id) {
    return checkStrategyBeforeSave.call(
      this,
      section_id,
      nfqwsStrategyValidation(),
    );
  };
  configureTextareaOption(o, analyzeNfqwsStrategy, attachNfqwsRemoteValidation);

  o = section.taboption(
    "target",
    form.TextValue,
    "nfqws2_opt",
    _("NFQWS2 Strategy"),
  );
  o.depends("action", "zapret2");
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.load = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "nfqws2_opt") ||
      ZAPRET2_DEFAULT_NFQWS2_OPT
    );
  };
  o.write = function (section_id, value) {
    const normalized = normalizeNfqws2StrategyValue(value);

    return validateNfqws2StrategyRemotely(normalized).then((result) => {
      if (!result || result.valid !== true) {
        throw new TypeError(
          result && result.message
            ? result.message
            : _("Invalid NFQWS2 strategy"),
        );
      }

      uci.set(UCI_PACKAGE, section_id, "nfqws2_opt", normalized);
    });
  };
  o.validate = function (_section_id, value) {
    const analysis = analyzeNfqws2Strategy(value);
    return analysis.valid ? true : analysis.message;
  };
  o.parse = parseNfqws2StrategyOnSave;
  o.checkBeforeSave = function (section_id) {
    return checkStrategyBeforeSave.call(
      this,
      section_id,
      nfqws2StrategyValidation(),
    );
  };
  configureTextareaOption(
    o,
    analyzeNfqws2Strategy,
    attachNfqws2RemoteValidation,
  );

  o = section.taboption(
    "target",
    form.TextValue,
    "byedpi_cmd_opts",
    _("ByeDPI Strategy"),
  );
  o.depends("action", "byedpi");
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.load = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "byedpi_cmd_opts") ||
      BYEDPI_DEFAULT_CMD_OPTS
    );
  };
  o.write = function (section_id, value) {
    const normalized = normalizeByedpiStrategyValue(value);

    return validateByedpiStrategyRemotely(normalized).then((result) => {
      if (!result || result.valid !== true) {
        throw new TypeError(
          result && result.message
            ? result.message
            : _("Invalid ByeDPI strategy"),
        );
      }

      uci.set(UCI_PACKAGE, section_id, "byedpi_cmd_opts", normalized);
    });
  };
  o.validate = function (_section_id, value) {
    const analysis = analyzeByedpiStrategy(value);
    return analysis.valid ? true : analysis.message;
  };
  o.checkBeforeSave = function (section_id) {
    return checkStrategyBeforeSave.call(this, section_id, {
      remoteValidate: validateByedpiStrategyRemotely,
      invalidMessage: _("Invalid ByeDPI strategy"),
    });
  };
  configureTextareaOption(o, analyzeByedpiStrategy);

  o = section.taboption(
    "target",
    form.DynamicList,
    "selector_proxy_links",
    _("Connection URL"),
    _(
      "vless://, vmess://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links",
    ),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);
    return validation.valid ? true : validation.message;
  };
  o.onchange = function (_event, section_id) {
    refreshDashboardFilterChoiceWidgets(section_id);
  };
  outboundNameSourceOptions.set("selector_proxy_links", o);

  o = section.taboption(
    "target",
    SettingsDynamicList,
    "subscription_url",
    _("Subscription URL"),
    _("Enter the subscription URL"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.childType = "subscription_url";
  o.childValueOption = "url";
  o.childDefaults = subscriptionUrlChildDefaults();
  o.renderItemSettingsModal = showSubscriptionUrlSettingsModal;
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (isExistingChildItem(section_id, normalized, "subscription_url")) {
      return true;
    }

    return this.validate(section_id, normalized) === true;
  };
  o.stagedChildSettings = function (section_id, value) {
    const inputValue = childItemInputValue(
      section_id,
      value,
      "subscription_url",
      "url",
    );
    const store = childPendingSettingsStore(this, section_id);
    return store[inputValue] ? Object.assign({}, store[inputValue]) : null;
  };
  o.clearStagedChildSettings = function (section_id) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[section_id];
    }
  };
  o.renderListItemLabel = function (section_id, itemId) {
    return childItemInputValue(section_id, itemId, "subscription_url", "url");
  };
  o.validate = validateSubscriptionUrlEntry;
  o.validate = function (section_id, value) {
    return validateSubscriptionUrlEntry(
      section_id,
      childItemInputValue(section_id, value, "subscription_url", "url"),
    );
  };

  o = section.taboption(
    "target",
    InterfaceSettingsDynamicList,
    "interfaces",
    _("Network Interface"),
    _("Select network interface for VPN connection"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.placeholder = _("Select a network interface");
  o.childType = "section_interface";
  o.childValueOption = "name";
  o.childDefaults = defaultInterfaceSettings();
  o.renderItemSettingsModal = showInterfaceSettingsModal;
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (isExistingChildItem(section_id, normalized, "section_interface")) {
      return true;
    }

    return this.validate(section_id, normalized) === true;
  };
  o.stagedChildSettings = function (section_id, value) {
    const inputValue = childItemInputValue(
      section_id,
      value,
      "section_interface",
      "name",
    );
    const store = childPendingSettingsStore(this, section_id);
    return store[inputValue] ? Object.assign({}, store[inputValue]) : null;
  };
  o.clearStagedChildSettings = function (section_id) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[section_id];
    }
  };
  o.onListChange = refreshDashboardFilterChoiceWidgets;
  outboundNameSourceOptions.set("interfaces", o);

  o = section.taboption(
    "target",
    ButtonAddSettingsDynamicList,
    "outbound_jsons",
    _("JSON outbound"),
    _("Custom outbound configurations in JSON format"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add JSON outbound");
  o.renderItemSettingsModal = showOutboundJsonSettingsModal;
  o.renderListItemLabel = function (_section_id, value) {
    return outboundJsonListItemLabel(value);
  };
  o.validateItemsOnSave = validateOutboundJsonItemsBeforeSave;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateOutboundJson(value);
    return validation.valid ? true : validation.message;
  };
  o.onListChange = refreshDashboardFilterChoiceWidgets;
  outboundNameSourceOptions.set("outbound_jsons", o);

  o = section.taboption(
    "target",
    ButtonAddSettingsDynamicList,
    "urltest",
    _("URLTest"),
    _("Server group for automatic lowest-latency selection"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add URLTest");
  o.childType = "urltest";
  o.childValueOption = "name";
  o.childDefaults = urlTestChildDefaults();
  o.createId = () => randomUrlTestId();
  o.renderItemSettingsModal = showUrlTestSettingsModal;
  o.validateItemsOnSave = function (section_id, values) {
    return validateUrlTestItemsBeforeSave(section_id, values, this);
  };
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();

    if (isExistingChildItem(section_id, normalized, "urltest")) {
      return true;
    }

    return normalized.length > 0;
  };
  o.inputValueForItem = function (section_id, value) {
    const inputValue = childItemInputValue(
      section_id,
      value,
      "urltest",
      "name",
    );
    const store = childPendingSettingsStore(this, section_id);
    return store[inputValue] && store[inputValue].name
      ? store[inputValue].name
      : inputValue;
  };
  o.stagedChildSettings = function (section_id, value) {
    const id = childItemInputValue(section_id, value, "urltest", "name");
    const store = childPendingSettingsStore(this, section_id);
    return store[id] ? Object.assign({}, store[id]) : null;
  };
  o.clearStagedChildSettings = function (section_id) {
    if (this.pendingChildSettings) {
      delete this.pendingChildSettings[section_id];
    }
  };
  o.renderListItemLabel = function (section_id, itemId) {
    return E(
      "span",
      { class: "fkp-dynlist-label" },
      this.inputValueForItem(section_id, itemId),
    );
  };
  o.onListChange = refreshDashboardFilterChoiceWidgets;
  sectionGroupSourceOptions.set("urltest", o);

  o = section.taboption(
    "target",
    ButtonAddSettingsDynamicList,
    "priority_group",
    _("Priority"),
    _("Server group for priority failover"),
  );
  o.depends("action", "connection");
  o.rmempty = true;
  o.modalonly = true;
  o.addButtonLabel = _("+ Add priority");
  o.childType = "priority_group";
  o.childValueOption = "name";
  o.childDefaults = priorityGroupChildDefaults();
  o.createId = () => randomPriorityGroupId();
  o.renderItemSettingsModal = showPriorityGroupSettingsModal;
  o.validateItemsOnSave = validatePriorityGroupItemsBeforeSave;
  o.hasItemSettings = function (section_id, value) {
    const normalized = `${value || ""}`.trim();

    if (isExistingChildItem(section_id, normalized, "priority_group")) {
      return true;
    }

    return normalized.length > 0;
  };
  o.inputValueForItem = function (section_id, value) {
    return childItemInputValue(section_id, value, "priority_group", "name");
  };
  o.renderListItemLabel = function (section_id, itemId) {
    return E(
      "span",
      { class: "fkp-dynlist-label" },
      this.inputValueForItem(section_id, itemId),
    );
  };
  o.onListChange = refreshDashboardFilterChoiceWidgets;
  sectionGroupSourceOptions.set("priority_group", o);

  o = section.taboption(
    "target",
    form.Flag,
    "outbound_detour_enabled",
    _("Cascade connection"),
    _(
      "Use another section as an intermediate hop to connect to servers in this section. Does not apply to network interfaces or JSON outbounds.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "__internal_hidden__");
  // Never shown, but still read by the backend: keep the stored value when
  // the rule is saved (LuCI removes inactive options without retain).
  o.retain = true;
  o.modalonly = true;
  o.parse = parseOutboundDetourOption(o.parse);
  o.load = loadOutboundDetourOption(o.load);
  o.write = function (section_id, value) {
    if (value === "1") {
      const currentValue =
        uci.get(UCI_PACKAGE, section_id, "outbound_detour_section") || "";
      const targetSections = getOutboundDetourTargetSections(section_id);
      const currentIsValid = targetSections.some(
        (targetSection) => getUciSectionName(targetSection) === currentValue,
      );
      const selectedValue = currentIsValid
        ? currentValue
        : getDefaultOutboundDetourSection(section_id);

      if (selectedValue) {
        uci.set(
          UCI_PACKAGE,
          section_id,
          "outbound_detour_section",
          selectedValue,
        );
      }
    }

    return form.Flag.prototype.write.apply(this, arguments);
  };

  o = section.taboption(
    "target",
    form.ListValue,
    "outbound_detour_section",
    _("Connect through"),
    _("Select a transit section"),
  );
  o.rmempty = false;
  o.depends({ action: "__internal_hidden__", outbound_detour_enabled: "1" });
  o.retain = true;
  o.modalonly = true;
  o.parse = parseOutboundDetourOption(o.parse);
  o.load = loadOutboundDetourOption(function (section_id) {
    refreshOutboundDetourSectionOptionValues(this, section_id);
    return Promise.resolve(
      uci.get(UCI_PACKAGE, section_id, "outbound_detour_section") || "",
    );
  });
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Select an intermediate section");
    }
    if (value === section_id) {
      return _("Current section cannot be used as its own transit section");
    }
    return true;
  };

  // What the two hidden options above hold, and a way to clear them.
  o = section.taboption(
    "basic",
    form.DummyValue,
    "_hidden_cascade",
    _("Cascade connection"),
  );
  o.modalonly = true;
  o.load = function (section_id) {
    this.cascadeStates = this.cascadeStates || {};
    this.cascadeStates[section_id] = hiddenCascadeState(section_id);
    return Promise.resolve(null);
  };
  o.checkDepends = function (section_id) {
    return Boolean(this.cascadeStates && this.cascadeStates[section_id]);
  };
  o.renderWidget = function (section_id) {
    return renderHiddenCascadeNotice(this, section_id);
  };

  // Saving a Connection rule with another action drops its cascade
  // (parseOutboundDetourOption): the modal says so before Save (D-22 b).
  o = section.taboption(
    "basic",
    form.DummyValue,
    "_cascade_action_warning",
    _("Cascade connection"),
  );
  o.modalonly = true;
  o.load = loadOutboundDetourOption(function () {
    return Promise.resolve(null);
  });
  o.checkDepends = function (section_id) {
    const loaded = this.loadedRuleActions?.[section_id];

    return (
      !this.map.readonly &&
      loaded !== undefined &&
      isOutboundDetourRuleAction(loaded) &&
      !isOutboundDetourRuleAction(
        this.section.formvalue(section_id, "action"),
      ) &&
      hiddenCascadeState(section_id) !== null
    );
  };
  o.renderWidget = function (section_id) {
    const state = hiddenCascadeState(section_id);

    // In an array LuCI adds the text as a text node: the label is a UCI
    // value.
    return E(
      "div",
      { class: "alert-message warning fkp-legacy-settings" },
      E("p", {}, [
        state && state.enabled
          ? _(
              "With another action the rule cannot use its cascade setting: saving the rule removes it, and its servers no longer connect through the rule “%s”.",
            ).format(state.targetLabel)
          : _(
              "With another action the rule cannot use its cascade setting: saving the rule removes the switched-off cascade setting.",
            ),
      ]),
    );
  };

  o = section.taboption(
    "target",
    form.Flag,
    "sort_by_latency",
    _("Sort by latency"),
    _("Sorts servers in this section by lowest latency in the dashboard."),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "__internal_hidden__");
  o.retain = true;
  o.modalonly = true;

  o = section.taboption(
    "advanced",
    form.Flag,
    "mixed_proxy_enabled",
    _("Enable Mixed Proxy"),
    _("Expose this section as a local HTTP+SOCKS proxy"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "connection");
  o.depends("action", "proxy");
  o.depends("action", "outbound");
  o.depends("action", "vpn");
  o.depends("action", "byedpi");
  o.depends("action", "zapret");
  o.depends("action", "zapret2");
  o.modalonly = true;

  o = section.taboption(
    "advanced",
    form.Value,
    "mixed_proxy_port",
    _("Mixed Proxy Port"),
    _("Port for the local mixed proxy of this section"),
  );
  o.rmempty = false;
  o.depends({ action: "connection", mixed_proxy_enabled: "1" });
  o.depends({ action: "proxy", mixed_proxy_enabled: "1" });
  o.depends({ action: "outbound", mixed_proxy_enabled: "1" });
  o.depends({ action: "vpn", mixed_proxy_enabled: "1" });
  o.depends({ action: "byedpi", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret2", mixed_proxy_enabled: "1" });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return _("Port cannot be empty");
    }

    const parsed = Number(value);
    if (/^[0-9]+$/.test(value) && parsed >= 1 && parsed <= 65535) {
      return true;
    }

    return _("Invalid port number. Must be between 1 and 65535");
  };

  o = section.taboption(
    "advanced",
    form.Flag,
    "mixed_proxy_auth_enabled",
    _("Enable Mixed Proxy Authentication"),
    _("Require a username and password for the local mixed proxy"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends({ action: "connection", mixed_proxy_enabled: "1" });
  o.depends({ action: "proxy", mixed_proxy_enabled: "1" });
  o.depends({ action: "outbound", mixed_proxy_enabled: "1" });
  o.depends({ action: "vpn", mixed_proxy_enabled: "1" });
  o.depends({ action: "byedpi", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret", mixed_proxy_enabled: "1" });
  o.depends({ action: "zapret2", mixed_proxy_enabled: "1" });
  o.modalonly = true;

  o = section.taboption(
    "advanced",
    form.Value,
    "mixed_proxy_username",
    _("Mixed Proxy Username"),
  );
  o.rmempty = false;
  o.depends({
    action: "connection",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "proxy",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "outbound",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "vpn",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "byedpi",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret2",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return _("Username cannot be empty");
    }

    return true;
  };

  o = section.taboption(
    "advanced",
    form.Value,
    "mixed_proxy_password",
    _("Mixed Proxy Password"),
  );
  o.password = true;
  o.rmempty = false;
  o.depends({
    action: "connection",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "proxy",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "outbound",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "vpn",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "byedpi",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.depends({
    action: "zapret2",
    mixed_proxy_enabled: "1",
    mixed_proxy_auth_enabled: "1",
  });
  o.modalonly = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return _("Password cannot be empty");
    }

    return true;
  };

  o = section.taboption(
    "advanced",
    form.Flag,
    "resolve_real_ip_for_routing",
    _("Resolve real IP for routing"),
    _(
      "Resolve domain names before routing so sing-box can use real destination IPs.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("action", "__internal_hidden__");
  o.retain = true;
  o.modalonly = true;
  o.cfgvalue = function (section_id) {
    const value = uci.get(
      UCI_PACKAGE,
      section_id,
      "resolve_real_ip_for_routing",
    );
    if (value !== null && value !== undefined && value !== "") {
      return value;
    }

    return getRuleResolvedAction(section_id) === "byedpi" ? "1" : "0";
  };

  addTextConditionField(section, {
    key: "domain_suffix",
    optionName: "domain",
    legacyTextOptionName: "domain_suffix_text",
    label: _("Domains"),
    description: _(
      "The rule applies to the domain and all its subdomains. Use full:, keyword:, or regex: prefixes for exact match, keyword match, or regular expression.",
    ),
    textAnalyze: analyzeDomainSuffixText,
    loadText: loadCombinedDomainText,
    afterWrite: function (section_id) {
      [
        "domain_suffix",
        "domain_suffix_text",
        "domain_suffix_text_mode",
        "domain_keyword",
        "domain_regex",
        "domain_text",
        "domain_keyword_text",
        "domain_regex_text",
        "domain_text_mode",
        "domain_keyword_text_mode",
        "domain_regex_text_mode",
      ].forEach((key) => {
        uci.unset(UCI_PACKAGE, section_id, key);
      });
    },
  });

  const ipConditionOption = addTextConditionField(section, {
    key: "ip_cidr",
    optionName: "ip_cidr",
    legacyTextOptionName: "ip_cidr_text",
    lockedByConditionsTextMode: true,
    label: _("IPs"),
    description: _("Match destination IPs or subnets"),
    textAnalyze: analyzeIpCidrText,
  });
  dependsOnRoutingAction(ipConditionOption);
  keepHiddenForDnsRule(ipConditionOption);

  const builtInRulesetOption = section.taboption(
    "match",
    form.DynamicList,
    "community_lists",
    _("Built-in rule sets"),
    _("Select a predefined domain list"),
  );
  builtInRulesetOption.modalonly = true;
  builtInRulesetOption.placeholder = _("Service list");
  builtInRulesetOption.load = function (section_id) {
    loadRulesetValues(this);
    return getBuiltInRulesetReferences(section_id);
  };
  builtInRulesetOption.write = function (section_id, values) {
    writeBuiltInRulesetReferences(section_id, values);
  };
  builtInRulesetOption.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "community_lists");
  };

  const secondaryRulesetOption = section.taboption(
    "match",
    form.DynamicList,
    "secondary_rule_sets",
    `${_("Built-in rule sets")} #2`,
    _("Select a predefined IP rule set from b4geoip-forkop"),
  );
  secondaryRulesetOption.modalonly = true;
  // DNS rules match domains only: the widget is hidden for them. Values the
  // rule already has stay visible for DNS so they can be removed, and the
  // action refuses DNS until they are (UC-046).
  secondaryRulesetOption.retain = true;
  dependsOnRoutingAction(secondaryRulesetOption);
  const secondaryRulesetRoutingDepends = secondaryRulesetOption.checkDepends;
  secondaryRulesetOption.checkDepends = function (section_id) {
    return (
      secondaryRulesetRoutingDepends.call(this, section_id) ||
      (getSecondaryRulesetReferences(section_id).length > 0 &&
        this.map.isDependencySatisfied(
          [{ action: "dns" }],
          this.map.config,
          section_id,
        ))
    );
  };
  secondaryRulesetOption.placeholder = _("Service list");
  secondaryRulesetOption.load = function (section_id) {
    refreshOptionChoices(
      this,
      Object.entries(main.SECONDARY_RULESET_OPTIONS || {}).map(
        ([value, label]) => ({ value, label }),
      ),
    );
    return getSecondaryRulesetReferences(section_id);
  };
  secondaryRulesetOption.write = function (section_id, values) {
    writeSecondaryRulesetReferences(section_id, values);
  };
  secondaryRulesetOption.remove = function (section_id) {
    writeSecondaryRulesetReferences(section_id, []);
  };

  hideSelectedRulesetChoices(
    builtInRulesetOption,
    Object.entries(main.DOMAIN_LIST_OPTIONS).map(([value, label]) => ({
      value,
      label: _(label),
    })),
  );
  hideSelectedRulesetChoices(
    secondaryRulesetOption,
    Object.entries(main.SECONDARY_RULESET_OPTIONS || {}).map(
      ([value, label]) => ({ value, label: _(label) }),
    ),
  );

  const ruleSetOption = section.taboption(
    "match",
    SettingsDynamicList,
    "rule_set",
    _("Rule sets"),
    _(
      "Add URLs or local paths to .srs / .json lists. Subnets are ignored by default.",
    ),
  );
  ruleSetOption.modalonly = true;
  // Both widgets map to rule_set, so neither inactive view may erase shared storage.
  ruleSetOption.retain = true;
  dependsOnRoutingAction(ruleSetOption);
  ruleSetOption.renderItemSettingsModal = showRuleSetSettingsModal;
  ruleSetOption.load = function (section_id) {
    return getCustomRulesetReferences(section_id);
  };
  ruleSetOption.write = function (section_id, value) {
    writeCustomRulesetReferences(section_id, value);
  };
  ruleSetOption.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "rule_set");
    writeListOption(
      section_id,
      "rule_set_with_subnets",
      getConfigListValues(section_id, "rule_set_with_subnets").filter((value) =>
        secondaryRulesetId(value),
      ),
    );
    uci.unset(UCI_PACKAGE, section_id, RULE_SET_ITEM_SETTINGS_KEY);
  };
  ruleSetOption.validate = function (section_id, value) {
    return validateCustomRulesetReference(value);
  };

  const dnsRuleSetOption = section.taboption(
    "match",
    form.DynamicList,
    "_dns_rule_set",
    _("Rule sets"),
    _(
      "Add URLs or local paths to .srs / .json lists. Only domain rules are supported.",
    ),
  );
  dnsRuleSetOption.depends("action", "dns");
  dnsRuleSetOption.modalonly = true;
  dnsRuleSetOption.retain = true;
  dnsRuleSetOption.load = function (section_id) {
    return getCustomRulesetReferences(section_id);
  };
  dnsRuleSetOption.write = function (section_id, value) {
    writeDnsRulesetReferences(section_id, value);
  };
  dnsRuleSetOption.remove = function (section_id) {
    writeDnsRulesetReferences(section_id, []);
  };
  dnsRuleSetOption.validate = function (_section_id, value) {
    return validateCustomRulesetReference(value);
  };

  const domainIpListsOption = section.taboption(
    "match",
    form.DynamicList,
    "domain_ip_lists",
    _("Domain and IP lists"),
    _("Add URLs or local paths to .lst lists containing domains and subnets."),
  );
  domainIpListsOption.modalonly = true;
  // Both widgets map to domain_ip_lists, so neither inactive view may erase shared storage.
  domainIpListsOption.retain = true;
  dependsOnRoutingAction(domainIpListsOption);
  domainIpListsOption.load = function (section_id) {
    return getConfigListValues(section_id, "domain_ip_lists");
  };
  domainIpListsOption.write = function (section_id, value) {
    writeListOption(section_id, "domain_ip_lists", value);
  };
  domainIpListsOption.validate = function (_section_id, value) {
    return validatePlainListReference(value);
  };

  const dnsDomainListsOption = section.taboption(
    "match",
    form.DynamicList,
    "_dns_domain_ip_lists",
    _("Domain lists"),
    _(
      "Add URLs or local paths to .lst lists containing domains. IP entries are ignored.",
    ),
  );
  dnsDomainListsOption.depends("action", "dns");
  dnsDomainListsOption.modalonly = true;
  dnsDomainListsOption.retain = true;
  dnsDomainListsOption.load = function (section_id) {
    return getConfigListValues(section_id, "domain_ip_lists");
  };
  dnsDomainListsOption.write = function (section_id, value) {
    writeListOption(section_id, "domain_ip_lists", value);
  };
  dnsDomainListsOption.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "domain_ip_lists");
  };
  dnsDomainListsOption.validate = function (_section_id, value) {
    return validatePlainListReference(value);
  };

  const sourceIpOption = addLocalDeviceSubnetDynamicField(section, {
    key: "source_ip_cidr",
    legacyText: true,
    label: _("Device filter"),
    description: _(
      "Apply section rules only to the specified local IP addresses",
    ),
  });
  dependsOnRuleConditions(sourceIpOption);
  // The backend also matches legacy remote_domain_lists/remote_subnet_lists,
  // which have no widget: while they are set, a hidden device filter must not
  // be erased on save, or a per-device rule would silently apply to every
  // device. Without any destination condition the filter is dropped.
  const removeSourceIp = sourceIpOption.remove;
  sourceIpOption.remove = function (section_id) {
    if (!this.isActive(section_id) && hasRemoteRuleLists(section_id)) {
      return;
    }
    removeSourceIp.call(this, section_id);
  };

  const fullyRoutedOption = addLocalDeviceSubnetDynamicField(section, {
    key: "fully_routed_ips",
    label: _("Forced device routing"),
    description: _(
      "All traffic from these IP addresses will be routed through the section unconditionally, ignoring all other conditions.",
    ),
  });
  dependsOnRoutingAction(fullyRoutedOption);
  fullyRoutedOption.depends("action", "dns");

  const excludedSourcesOption = addLocalDeviceSubnetDynamicField(section, {
    key: "excluded_source_ip_cidr",
    legacyText: true,
    label: _("Exclude devices"),
    description: _(
      "Do not apply this section to the specified local IP addresses; matching continues with the next section.",
    ),
  });
  dependsOnRoutingAction(excludedSourcesOption);
  excludedSourcesOption.depends("action", "dns");
  makeDeviceOptionsExclusive(
    sourceIpOption,
    fullyRoutedOption,
    excludedSourcesOption,
  );

  const portsOption = addDynamicConditionField(section, {
    key: "ports",
    label: _("Ports"),
    description: _("Match destination ports. Use a single port or a range"),
    dynamicValidate: validatePortCondition,
    load: backendPortValues,
  });
  dependsOnRoutingAction(portsOption);
  keepHiddenForDnsRule(portsOption);

  // Legacy forms of the rule's settings, what they do, and their explicit
  // conversion or removal (D-6 a). Last of the Basics step.
  o = section.taboption(
    "basic",
    form.DummyValue,
    "_legacy_conditions",
    _("Legacy settings"),
  );
  o.modalonly = true;
  o.load = function (section_id) {
    this.legacyStates = Object.assign({}, this.legacyStates, {
      [section_id]: legacyRuleConditions(section_id),
    });
    return Promise.resolve(null);
  };
  o.checkDepends = function (section_id) {
    return Boolean(this.legacyStates && this.legacyStates[section_id]);
  };
  o.renderWidget = function (section_id) {
    return renderLegacyConditionsNotice(this, section_id);
  };
}

function loadSectionTableOptions(sectionRef) {
  const sectionIds = sectionRef.cfgsections();
  const tasks = [];

  for (let i = 0; i < sectionIds.length; i += 1) {
    const sectionId = sectionIds[i];

    for (let j = 0; j < sectionRef.children.length; j += 1) {
      const option = sectionRef.children[j];

      if (option.disable || option.modalonly) {
        continue;
      }

      tasks.push(
        Promise.resolve(option.load.call(option, sectionId)).then((value) => {
          option.cfgvalue(sectionId, value);
        }),
      );
    }
  }

  return Promise.all(tasks);
}

// LuCI parses every option of the rule modal even when one of them is
// invalid, and a refused save keeps what the other options wrote or removed:
// a rule switched to DNS and back would lose its ports and links, and after
// Dismiss the next Save & Apply would send them. Refuse the save before
// anything is written while an active option is invalid, and while a check
// that parse would run only after other writes refuses: the items of a list
// (checkBeforeSave of SettingsDynamicList) or the backend check of a changed
// DPI strategy.
function inspectModalBeforeSave(modalMap) {
  const checks = [];

  for (const modalSection of modalMap.children) {
    for (const section_id of modalSection.cfgsections()) {
      for (const option of modalSection.children) {
        if (!option.isActive(section_id)) {
          continue;
        }

        if (
          typeof option.checkBeforeSave === "function" &&
          typeof option.triggerValidation === "function"
        ) {
          option.triggerValidation(section_id);
        }

        if (!option.isValid(section_id)) {
          return { invalid: { option, section_id }, checks };
        }

        if (typeof option.checkBeforeSave === "function") {
          checks.push({ option, section_id });
        }
      }
    }
  }

  return { invalid: null, checks };
}

// What the checks were run on: the value and the active state of every
// option of the modal.
function modalFormState(modalMap) {
  const state = [];

  for (const modalSection of modalMap.children) {
    for (const section_id of modalSection.cfgsections()) {
      for (const option of modalSection.children) {
        state.push([
          option.option,
          section_id,
          option.isActive(section_id),
          option.formvalue(section_id),
        ]);
      }
    }
  }

  return JSON.stringify(state);
}

// LuCI drops the refusal of a modal Save, and the items of a list are
// checked only on Save: no field shows such a refusal, so the modal does.
function clearModalSaveRefusal(modalMap) {
  const node = modalMap.forkopSaveRefusal;

  if (node && node.parentNode) {
    node.parentNode.removeChild(node);
  }
  delete modalMap.forkopSaveRefusal;
}

function showModalSaveRefusal(modalMap, error) {
  clearModalSaveRefusal(modalMap);

  if (!modalMap.root || typeof modalMap.root.appendChild !== "function") {
    return;
  }

  modalMap.forkopSaveRefusal = E(
    "div",
    { class: "alert-message warning fkp-rule-save-refusal" },
    [
      E("strong", {}, [_("Cannot save the rule")]),
      E("div", {}, [error.message]),
    ],
  );
  modalMap.root.appendChild(modalMap.forkopSaveRefusal);
}

function refuseInvalidModalSave(modalMap) {
  const parse = modalMap.parse;

  modalMap.parse = function (...args) {
    clearModalSaveRefusal(this);
    forgetUnavailableStrategyValidations();

    const { invalid, checks } = inspectModalBeforeSave(this);

    if (invalid) {
      return rejectInvalidOption(invalid.option, invalid.section_id);
    }

    const checkedState = modalFormState(this);

    return Promise.all(
      checks.map(({ option, section_id }) =>
        option.checkBeforeSave(section_id),
      ),
    ).then((results) => {
      // LuCI keeps the modal editable, and Dismiss working, while the
      // checks run. A dismissed modal saves nothing, and a form edited
      // meanwhile is checked again as it is now: parse writes what it holds.
      // Only an edit changes the state, so without one this runs once more.
      if (this.forkopModalDismissed) {
        return Promise.reject(
          new Error(
            _(
              "The rule window was closed before the save finished. Nothing was saved.",
            ),
          ),
        );
      }

      this.checkDepends();

      if (modalFormState(this) !== checkedState) {
        return this.parse(...args);
      }

      const index = results.findIndex((result) => result !== true);

      if (index >= 0) {
        const { option, section_id } = checks[index];
        const error = invalidOptionError(option, section_id, results[index]);

        // A strategy field shows its backend verdict itself.
        if (option.isValid(section_id)) {
          showModalSaveRefusal(this, error);
        }

        return Promise.reject(error);
      }

      const recheck = inspectModalBeforeSave(this);

      if (recheck.invalid) {
        return rejectInvalidOption(
          recheck.invalid.option,
          recheck.invalid.section_id,
        );
      }

      return parse.apply(this, args);
    });
  };
}

// The item settings modals stacked on the rule modal (subscription source,
// interface, URLTest, priority and its levels, rule set) write their Save
// into uci at once, and the rule modal map shares the page's uci state.
// LuCI's Dismiss only removes a rule that Add created, so these edits stayed
// staged for the next Save & Apply although the rule was never saved. The
// rule modal keeps the staged state it was opened on, and Dismiss puts it
// back (UC-045). uci.js stages edits in creates/changes/deletes and merges
// them into values in place on a whole-section uci.get(), so all are kept.
const STAGED_UCI_STATE_KEYS = [
  "values",
  "creates",
  "changes",
  "deletes",
  "reorder",
];

function captureStagedUciState() {
  const state = uci.state;

  if (
    !state ||
    STAGED_UCI_STATE_KEYS.some(
      (key) => !state[key] || typeof state[key] !== "object",
    ) ||
    !state.values[UCI_PACKAGE]
  ) {
    return null;
  }

  const snapshot = {};
  STAGED_UCI_STATE_KEYS.forEach((key) => {
    const value = state[key][UCI_PACKAGE];
    snapshot[key] =
      value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  });
  return snapshot;
}

function restoreStagedUciState(snapshot) {
  if (!snapshot) {
    return;
  }

  STAGED_UCI_STATE_KEYS.forEach((key) => {
    if (snapshot[key] === undefined) {
      delete uci.state[key][UCI_PACKAGE];
    } else {
      uci.state[key][UCI_PACKAGE] = snapshot[key];
    }
  });
}

function configureSectionSection(sectionRef, options = {}) {
  setActionProvidersAvailabilityLoader(options.loadActionProvidersAvailability);

  const addModalOptions = sectionRef.addModalOptions;
  sectionRef.addModalOptions = function (modalSection) {
    modalSection.map.forkopStagedUciState = captureStagedUciState();
    refuseInvalidModalSave(modalSection.map);
    return addModalOptions.apply(this, arguments);
  };

  // handleModalSave() closes the modal through handleModalCancel(..., true)
  // after uci.save() sent the edits; only Dismiss restores.
  const handleModalCancel = sectionRef.handleModalCancel;
  sectionRef.handleModalCancel = function (modalMap, _ev, isSaving) {
    if (modalMap) {
      if (!isSaving) {
        // A Save still waiting for its checks must not write afterwards.
        modalMap.forkopModalDismissed = true;
        restoreStagedUciState(modalMap.forkopStagedUciState);
      }
      delete modalMap.forkopStagedUciState;
    }
    return handleModalCancel.apply(this, arguments);
  };

  const handleRemove = sectionRef.handleRemove;
  sectionRef.handleRemove = function (section_id) {
    // LuCI saves the whole page silently after a removal. When another field
    // refuses that save (e.g. a Settings select on this rule or on an
    // unavailable section), the row stays, but the removal and the cleanup
    // of its child items would stay staged: the next rule modal Save sends
    // the whole package through uci.save(), past that check. Put the staged
    // state back and say why instead of doing nothing visible.
    const staged = captureStagedUciState();

    cleanupRemovedChildItems(section_id, "subscription_url", []);
    cleanupRemovedChildItems(section_id, "section_interface", []);
    cleanupRemovedChildItems(section_id, "urltest", []);
    cleanupRemovedChildItems(section_id, "priority_group", []);
    cleanupRuleUrlTestOverrides(section_id);
    return Promise.resolve(handleRemove.apply(this, arguments)).catch(
      (error) => {
        restoreStagedUciState(staged);
        ui.addNotification(
          null,
          E(
            "p",
            {},
            _(
              "The rule was not removed because the page could not be saved: %s",
            ).format(error?.message || error),
          ),
          "error",
        );
      },
    );
  };

  sectionRef.load = function () {
    // The table renders only non-modal fields; the cloned Add/Edit modal loads
    // action/provider details when the user opens it.
    return loadSectionTableOptions(this);
  };
}

const EntryPoint = {
  configureSectionSection,
  createSectionContent,
  setActionProvidersAvailabilityLoader,
};

return baseclass.extend(EntryPoint);
