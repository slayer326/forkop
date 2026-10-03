"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.forkop.main as main";
"require view.forkop.local_devices as localDevices";

function createDiagnosticContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    // The device list feeds "Check a site": without it the check still runs,
    // but the client it is run for cannot be picked.
    main.DiagnosticTab.initController({
      loadLocalDeviceChoices: localDevices.loadLocalDeviceChoices,
    });
    return main.DiagnosticTab.render();
  };
}

const EntryPoint = {
  createDiagnosticContent,
};

return baseclass.extend(EntryPoint);
