"use strict";
"require baseclass";
"require form";
"require view.forkop.main as main";

function createHistoryContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.HistoryTab.initController();
    return main.HistoryTab.render();
  };
}

const EntryPoint = {
  createHistoryContent,
};

return baseclass.extend(EntryPoint);
