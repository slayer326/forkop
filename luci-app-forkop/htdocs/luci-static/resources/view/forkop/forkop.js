"use strict";
"require view";
"require form";
"require view.forkop.main as main";
"require view.forkop.shell as shell";
"require view.forkop.configform as configform";
"require view.forkop.settings as settings";
"require view.forkop.section as section";
"require view.forkop.dashboard as dashboard";
"require view.forkop.monitoring as monitoring";
"require view.forkop.diagnostic as diagnostic";
"require view.forkop.updates as updates";
"require view.forkop.history as history";
"require view.forkop.autotune as autotune";

// Forkop X is one LuCI view with tabs, not a page per feature. The tab
// controllers decide whether to poll by asking isActiveLuciTab(), which reads
// the CBI tab in the DOM unless a standalone page registered itself - so this
// page registers none, and each controller runs only while its own tab is in
// front. The section type is what CBI writes as data-tab, so it has to be the
// id the controller asks about: dashboard, diagnostic, monitoring, updates,
// history, autotune. The dashboard controller renders the overview summary,
// so its tab is the one titled "Overview".
function mountTab(map, type, title, mount) {
  const section = map.section(form.TypedSection, type, title);
  section.anonymous = true;
  section.addremove = false;
  section.cfgsections = function () {
    return [type];
  };
  mount(section);
  return section;
}

// The tabs that read state and never write it. A session that cannot read the
// Forkop configuration is offered these and nothing else: the rules and the
// settings are the two that write, and their ACL is the administrator's.
function mountReadOnlyTabs(map) {
  mountTab(map, "dashboard", _("Overview"), dashboard.createDashboardContent);
  mountTab(
    map,
    "diagnostic",
    _("Diagnostics"),
    diagnostic.createDiagnosticContent,
  );
  mountTab(
    map,
    "monitoring",
    _("Monitoring"),
    monitoring.createMonitoringContent,
  );
  mountTab(
    map,
    "history",
    _("History and recovery"),
    history.createHistoryContent,
  );
  mountTab(map, "autotune", _("DPI autotune"), autotune.createAutotuneContent);
}

const EntryPoint = {
  load() {
    // No page id: this view hosts every tab, so tab activity is the CBI tab's.
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage(null).then(() => readonly));
  },

  async render(readonly) {
    if (readonly) {
      // LuCI adds the page footer after render(): with no handlers left it
      // offers this session no Save, Apply or Reset button at all, rather
      // than three disabled ones.
      this.handleSave = null;
      this.handleSaveApply = null;
      this.handleReset = null;

      const readonlyMap = new form.JSONMap(
        {
          dashboard: {},
          diagnostic: {},
          monitoring: {},
          history: {},
          autotune: {},
        },
        _("Forkop X Settings"),
      );
      readonlyMap.readonly = true;
      readonlyMap.tabbed = true;
      mountReadOnlyTabs(readonlyMap);
      return readonlyMap.render();
    }

    // createMap keeps the snapshot taken before every Save & Apply, so the
    // History tab has something to restore from.
    const forkopMap = configform.createMap(_("Forkop X Settings"), null);
    forkopMap.tabbed = true;

    const rulesSection = forkopMap.section(
      form.GridSection,
      "section",
      _("Sections"),
      _("Drag rows to change priority. The rule at the top is checked first."),
    );
    configform.configureGridSection(
      rulesSection,
      "section",
      _("Section"),
      _("Add a section"),
    );
    section.configureSectionSection(rulesSection, {
      loadActionProvidersAvailability: shell.loadUiCapabilities,
    });
    section.createSectionContent(rulesSection);

    // One Settings tab, as before: the four groups are laid out one after
    // another on it, so they are given the same section rather than one tab
    // each. Four tabs here would be four more entries in the row above.
    const settingsSection = forkopMap.section(
      form.TypedSection,
      "settings",
      _("Settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    settingsSection.cfgsections = function () {
      return ["settings"];
    };
    settings.createSettingsContent(
      {
        dns: settingsSection,
        network: settingsSection,
        lists: settingsSection,
        service: settingsSection,
      },
      shell.uiCapabilities,
    );

    mountTab(
      forkopMap,
      "diagnostic",
      _("Diagnostics"),
      diagnostic.createDiagnosticContent,
    );
    mountTab(
      forkopMap,
      "dashboard",
      _("Overview"),
      dashboard.createDashboardContent,
    );
    mountTab(
      forkopMap,
      "monitoring",
      _("Monitoring"),
      monitoring.createMonitoringContent,
    );
    mountTab(
      forkopMap,
      "history",
      _("History and recovery"),
      history.createHistoryContent,
    );
    mountTab(
      forkopMap,
      "autotune",
      _("DPI autotune"),
      autotune.createAutotuneContent,
    );
    mountTab(
      forkopMap,
      "updates",
      _("Components"),
      updates.createUpdatesContent,
    );

    return forkopMap.render();
  },
};

return view.extend(EntryPoint);
