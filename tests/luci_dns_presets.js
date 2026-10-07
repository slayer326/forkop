const assert = require("node:assert/strict");
const { createEnvironment } = require("./helpers/luci_form_harness.js");

function rule(values) {
  return {
    ".name": "rule",
    ".type": "section",
    ".anonymous": false,
    enabled: "1",
    action: "dns",
    domain: "example.net",
    dns_detour_enabled: "0",
    ...values,
  };
}

async function select(modal, value) {
  modal.option("_dns_preset").getUIElement("rule").setValue(value);
  modal.map.checkDepends();
}

(async () => {
  for (const version of ["24.10", "25.12"]) {
    const original = rule({ dns_type: "udp", dns_server: "77.88.8.8" });
    const env = createEnvironment({ version, config: { rule: original } });
    const modal = await env.openRule("rule");
    assert.equal(modal.option("_dns_preset").formvalue("rule"), "yandex");
    assert.equal(modal.active("dns_type"), false);
    assert.equal(modal.active("dns_server"), false);
    await select(modal, "xbox_doh");
    assert.equal(modal.active("dns_type"), false);
    assert.equal(modal.active("dns_server"), false);
    await modal.save();
    assert.equal(env.uci.data.rule.dns_type, "doh");
    assert.equal(env.uci.data.rule.dns_server, "xbox-dns.ru/dns-query");
    assert.equal(env.uci.data.rule._dns_preset, undefined);

    const reopened = await env.openRule("rule");
    assert.equal(reopened.option("_dns_preset").formvalue("rule"), "xbox_doh");
    await reopened.save();
    assert.equal(env.uci.data.rule.dns_server, "xbox-dns.ru/dns-query");

    const custom = await env.openRule("rule");
    await select(custom, "custom");
    assert.equal(custom.active("dns_type"), true);
    assert.equal(custom.active("dns_server"), true);
    custom.option("dns_type").getUIElement("rule").setValue("doq");
    custom
      .option("dns_server")
      .getUIElement("rule")
      .setValue("dns.example.test");
    await custom.save();
    assert.equal(env.uci.data.rule.dns_type, "doq");
    assert.equal(env.uci.data.rule.dns_server, "dns.example.test");

    const otherAction = await env.openRule("rule");
    otherAction.option("action").getUIElement("rule").setValue("block");
    await otherAction.save();
    assert.equal(env.uci.data.rule.dns_type, undefined);
    assert.equal(env.uci.data.rule.dns_server, undefined);

    const wan = {
      ".name": "wan",
      ".type": "section_interface",
      ".anonymous": false,
      section: "rule",
      name: "wan",
      domain_resolver_enabled: "1",
      domain_resolver_dns_type: "udp",
      domain_resolver_dns_server: "8.8.8.8",
    };
    const interfaceEnv = createEnvironment({
      version,
      config: { rule: rule({ action: "connection" }), wan },
    });
    const interfaceRule = await interfaceEnv.openRule("rule");
    const interfaceModal = await interfaceRule.openItemSettings(
      "interfaces",
      "wan",
    );
    interfaceModal.setValue("_domain_dns_preset", "xbox_dot");
    interfaceModal.map.checkDepends();
    const interfaceOptions = interfaceModal.map.children[0].children;
    const field = (name) =>
      interfaceOptions.find((option) => option.option === name);
    assert.equal(field("domain_resolver_dns_type").isActive("wan"), false);
    assert.equal(field("domain_resolver_dns_server").isActive("wan"), false);
    await interfaceModal.save();
    assert.equal(interfaceEnv.uci.data.wan.domain_resolver_dns_type, "dot");
    assert.equal(
      interfaceEnv.uci.data.wan.domain_resolver_dns_server,
      "xbox-dns.ru",
    );
  }
})().then(
  () => console.log("DNS preset LuCI round trips passed"),
  (error) => {
    console.error(error);
    process.exitCode = 1;
  },
);
