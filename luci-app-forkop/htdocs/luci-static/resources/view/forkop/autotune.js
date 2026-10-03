"use strict";
"require baseclass";
"require form";
"require view.forkop.main as main";

function createAutotuneContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.AutotuneTab.initController();
    return main.AutotuneTab.render();
  };
}

const EntryPoint = {
  createAutotuneContent,
};

return baseclass.extend(EntryPoint);
