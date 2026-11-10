"use strict";
"require baseclass";
"require rpc";
"require ui";

const callCapabilities = rpc.declare({
  object: "forkop-warp",
  method: "capabilities",
  expect: {},
});
const callStart = rpc.declare({
  object: "forkop-warp",
  method: "start",
  params: [
    "action",
    "kind",
    "name",
    "profile",
    "ipv6",
    "via_proxy",
    "accept_terms",
  ],
  expect: {},
});
const callJob = rpc.declare({
  object: "forkop-warp",
  method: "job",
  params: ["id"],
  expect: {},
});
const callAck = rpc.declare({
  object: "forkop-warp",
  method: "ack",
  params: ["id"],
  expect: {},
});
const callStatus = rpc.declare({
  object: "forkop-warp",
  method: "status",
  params: ["name"],
  expect: {},
});

async function finishJob(started) {
  if (!started.success || !started.job_id)
    throw new Error(started.message || _("Cannot start WARP operation"));
  for (let attempt = 0; attempt < 240; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 1000));
    const result = await callJob(started.job_id);
    if (result.pending) continue;
    await callAck(started.job_id);
    if (!result.success)
      throw new Error(result.message || _("WARP operation failed"));
    return result;
  }
  throw new Error(
    _("WARP operation is still running. Check the interface before retrying."),
  );
}

function checkbox(label) {
  const input = E("input", { type: "checkbox" });
  return {
    input,
    node: E("label", { style: "display:block;margin:10px 0" }, [
      input,
      " ",
      label,
    ]),
  };
}

return baseclass.extend({
  open: function (onCreated) {
    const name = E("input", {
      type: "text",
      maxlength: 13,
      value: `fkw${Date.now().toString(36).slice(-6)}`,
      class: "cbi-input-text",
    });
    const kind = E("select", { class: "cbi-input-select" }, [
      E("option", { value: "wireguard" }, "WireGuard"),
      E("option", { value: "amneziawg" }, "AmneziaWG"),
    ]);
    const profile = E("textarea", {
      rows: 10,
      style: "width:100%;font-family:monospace",
      autocomplete: "off",
      spellcheck: "false",
      "aria-label": _("WARP profile"),
    });
    const file = E("input", {
      type: "file",
      accept: ".conf,.txt",
      change: async function () {
        try {
          const selected = this.files && this.files[0];
          if (!selected) return;
          if (selected.size > 32768)
            throw new Error(_("Profile file must not exceed 32 KiB"));
          profile.value = await selected.text();
        } catch (error) {
          show(error.message || String(error), true);
        }
        this.value = "";
      },
    });
    const ipv6 = checkbox(_("Use IPv6 addresses from the profile"));
    const viaProxy = checkbox(
      _("Register through the configured list-download section"),
    );
    const terms = checkbox(
      E("span", {}, [
        _("I accept Cloudflare terms for profile registration"),
        " ",
        E(
          "a",
          {
            href: "https://www.cloudflare.com/application/terms/",
            target: "_blank",
            rel: "noopener noreferrer",
          },
          _("Terms"),
        ),
      ]),
    );
    const message = E("p", { role: "status", style: "overflow-wrap:anywhere" });
    const availability = E("p", {}, _("Checking tunnel components…"));
    const buttons = [];
    let busy = false;
    const fields = [
      name,
      kind,
      profile,
      file,
      ipv6.input,
      viaProxy.input,
      terms.input,
    ];
    function show(text, error) {
      message.textContent = text;
      message.style.color = error ? "var(--error-color, #f66)" : "";
    }
    async function refresh() {
      const caps = await callCapabilities();
      if (!caps.success)
        throw new Error(
          _(
            "WARP service is unavailable. Reload LuCI after updating the package.",
          ),
        );
      availability.textContent = `${_("Tunnel components")}: WireGuard ${caps.wireguard ? "✓" : "—"}, AmneziaWG ${caps.amneziawg ? "✓" : "—"}. ${_("Package manager")}: ${caps.package_manager || "—"}`;
    }
    function button(label, operation) {
      const element = E(
        "button",
        {
          type: "button",
          class: "btn cbi-button",
          click: async function () {
            if (busy) return;
            busy = true;
            buttons.forEach((item) => {
              item.disabled = true;
            });
            fields.forEach((item) => {
              item.disabled = true;
            });
            show(_("Working…"), false);
            try {
              await operation();
            } catch (error) {
              show(error.message || String(error), true);
            } finally {
              busy = false;
              buttons.forEach((item) => {
                item.disabled = false;
              });
              fields.forEach((item) => {
                item.disabled = false;
              });
            }
          },
        },
        label,
      );
      buttons.push(element);
      return element;
    }
    async function run(action) {
      return finishJob(
        await callStart(
          action,
          kind.value,
          name.value.trim(),
          action === "import" ? profile.value : "",
          ipv6.input.checked,
          viaProxy.input.checked,
          terms.input.checked,
        ),
      );
    }
    const prepare = button(_("Prepare tunnel components"), async () => {
      await run("prepare");
      await refresh();
      show(_("Tunnel components are ready"), false);
    });
    const generate = button(_("Generate WARP profile"), async () => {
      if (!terms.input.checked)
        throw new Error(
          _("Accept Cloudflare terms before generating a profile"),
        );
      const result = await run("generate");
      profile.value = result.profile;
      show(_("Profile generated. Create the interface to use it."), false);
    });
    const create = button(_("Create and add to section"), async () => {
      if (!profile.value.trim())
        throw new Error(_("Paste or generate a WARP profile first"));
      const result = await run("import");
      await onCreated(result.interface);
      show(
        _(
          "Interface created. Save the section, apply Forkop settings and verify the handshake.",
        ),
        false,
      );
    });
    const check = button(_("Check handshake"), async () => {
      const result = await callStatus(name.value.trim());
      if (!result.success)
        throw new Error(result.message || _("Cannot check WARP interface"));
      show(
        result.handshake_observed
          ? _("Last handshake: %s").format(
              new Date(result.last_handshake * 1000).toLocaleString(),
            )
          : _(
              "No handshake observed yet. Save the section and send traffic through the tunnel.",
            ),
        false,
      );
    });
    const close = button(_("Close"), async () => {
      profile.value = "";
      ui.hideModal();
    });
    ui.showModal(_("Cloudflare WARP"), [
      E(
        "p",
        {},
        _(
          "WARP uses a separate OpenWrt interface. The current sing-box core is preserved. DNS and the default route are managed by your existing Forkop settings.",
        ),
      ),
      availability,
      E("label", { style: "display:block;margin:8px 0" }, [
        _("Tunnel type"),
        " ",
        kind,
      ]),
      E("label", { style: "display:block;margin:8px 0" }, [
        _("New interface name"),
        " ",
        name,
      ]),
      E(
        "p",
        {},
        _(
          "AmneziaWG requires packages matching this firmware. A plain profile uses compatible one-sided junk packets; existing obfuscation fields are preserved.",
        ),
      ),
      prepare,
      E(
        "p",
        {},
        _(
          "Paste a WireGuard configuration or generate a new WARP profile. DNS and executable hooks from imported files are not applied.",
        ),
      ),
      profile,
      E("label", { style: "display:block;margin:8px 0" }, [
        _("Import profile file"),
        " ",
        file,
      ]),
      ipv6.node,
      viaProxy.node,
      terms.node,
      E("div", { style: "display:flex;gap:8px;flex-wrap:wrap;margin:12px 0" }, [
        generate,
        create,
        check,
      ]),
      message,
      E("div", { class: "right" }, [close]),
    ]);
    refresh().catch((error) => show(error.message || String(error), true));
  },
});
