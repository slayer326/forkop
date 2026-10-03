"use strict";
"require baseclass";
"require uci";
"require view.forkop.main as main";

// Start-up of the Forkop X view (admin/services/forkop): access mode,
// provider capabilities and the background services. The features are tabs of
// that one view, so this runs once for all of them.

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;

const uiCapabilities = {
  loaded: false,
  singBoxExtended: false,
  singBoxTiny: false,
  singBoxTailscale: true,
  zapretInstalled: false,
  zapret2Installed: false,
  byedpiInstalled: false,
};
let uiCapabilitiesPromise = null;
let coreStarted = false;

function applyUiCapabilities() {
  if (typeof window !== "undefined") {
    window.dispatchEvent(
      new CustomEvent(main.FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
        detail: {
          zapretInstalled: uiCapabilities.zapretInstalled,
          zapret2Installed: uiCapabilities.zapret2Installed,
          byedpiInstalled: uiCapabilities.byedpiInstalled,
        },
      }),
    );
  }

  if (main.store && typeof main.store.set === "function") {
    const currentSystemInfo = main.store.get().diagnosticsSystemInfo;
    main.store.set({
      diagnosticsSystemInfo: {
        ...currentSystemInfo,
        providerInfoLoaded: true,
        sing_box_extended: uiCapabilities.singBoxExtended ? 1 : 0,
        sing_box_tiny: uiCapabilities.singBoxTiny ? 1 : 0,
        sing_box_tailscale: uiCapabilities.singBoxTailscale ? 1 : 0,
        zapret_installed: uiCapabilities.zapretInstalled ? 1 : 0,
        zapret2_installed: uiCapabilities.zapret2Installed ? 1 : 0,
        byedpi_installed: uiCapabilities.byedpiInstalled ? 1 : 0,
        zapret_version: uiCapabilities.zapretInstalled
          ? currentSystemInfo.zapret_version
          : "not installed",
        zapret2_version: uiCapabilities.zapret2Installed
          ? currentSystemInfo.zapret2_version
          : "not installed",
        byedpi_version: uiCapabilities.byedpiInstalled
          ? currentSystemInfo.byedpi_version
          : "not installed",
      },
    });
  }
}

function updateUiCapabilities(data) {
  uiCapabilities.loaded = true;
  uiCapabilities.singBoxExtended = Boolean(
    Number(data?.sing_box_extended) === 1,
  );
  uiCapabilities.singBoxTiny = Boolean(Number(data?.sing_box_tiny) === 1);
  uiCapabilities.singBoxTailscale =
    typeof data?.sing_box_tailscale === "undefined"
      ? true
      : Boolean(Number(data.sing_box_tailscale) === 1);
  uiCapabilities.zapretInstalled = Boolean(
    Number(data?.zapret_installed) === 1,
  );
  uiCapabilities.zapret2Installed = Boolean(
    Number(data?.zapret2_installed) === 1,
  );
  uiCapabilities.byedpiInstalled = Boolean(
    Number(data?.byedpi_installed) === 1,
  );
  applyUiCapabilities();

  return uiCapabilities;
}

// Components installs and removes providers after the page has loaded; the
// Settings page reads availability from uiCapabilities, so follow both the
// availability event and the store refresh (UC-152).
function refreshProviderCapabilities(next) {
  ["zapretInstalled", "zapret2Installed", "byedpiInstalled"].forEach((key) => {
    if (typeof next?.[key] !== "undefined") {
      uiCapabilities[key] = Boolean(next[key]);
    }
  });
}

if (
  typeof window !== "undefined" &&
  typeof window.addEventListener === "function"
) {
  window.addEventListener(
    main.FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT,
    (event) => refreshProviderCapabilities(event.detail),
  );
}

if (main.store && typeof main.store.subscribe === "function") {
  main.store.subscribe((next, _prev, diff) => {
    const systemInfo = next?.diagnosticsSystemInfo;
    if (
      (!diff || diff.diagnosticsSystemInfo) &&
      systemInfo?.providerInfoLoaded
    ) {
      refreshProviderCapabilities({
        zapretInstalled: Number(systemInfo.zapret_installed) === 1,
        zapret2Installed: Number(systemInfo.zapret2_installed) === 1,
        byedpiInstalled: Number(systemInfo.byedpi_installed) === 1,
      });
    }
  });
}

function applyUiState(data) {
  const result = updateUiCapabilities(data?.capabilities || data || {});

  if (typeof main.applyUiStateToStore === "function" && data?.service) {
    main.applyUiStateToStore(data);
  } else if (
    main.store &&
    typeof main.store.set === "function" &&
    data?.service
  ) {
    main.store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: {
          singbox: Number(data.service.sing_box?.running) || 0,
          forkopRunning: Number(data.service.forkop?.running) || 0,
          forkopEnabled: Number(data.service.forkop?.enabled) || 0,
          forkopStatus: data.service.forkop?.status || "",
        },
      },
    });
  }

  return result;
}

function loadFallbackUiCapabilities() {
  return Promise.allSettled([
    main.ForkopShellMethods.checkZapretRuntime(),
    main.ForkopShellMethods.checkZapret2Runtime(),
    main.ForkopShellMethods.checkByedpiRuntime(),
  ]).then(
    ([zapretRuntimeResult, zapret2RuntimeResult, byedpiRuntimeResult]) => {
      const zapretRuntime =
        zapretRuntimeResult.status === "fulfilled"
          ? zapretRuntimeResult.value
          : null;
      const zapret2Runtime =
        zapret2RuntimeResult.status === "fulfilled"
          ? zapret2RuntimeResult.value
          : null;
      const byedpiRuntime =
        byedpiRuntimeResult.status === "fulfilled"
          ? byedpiRuntimeResult.value
          : null;
      return updateUiCapabilities({
        zapret_installed:
          zapretRuntime?.success &&
          Number(zapretRuntime.data?.zapret_installed) === 1
            ? 1
            : 0,
        zapret2_installed:
          zapret2Runtime?.success &&
          Number(zapret2Runtime.data?.zapret2_installed) === 1
            ? 1
            : 0,
        byedpi_installed:
          byedpiRuntime?.success &&
          Number(byedpiRuntime.data?.byedpi_installed) === 1
            ? 1
            : 0,
      });
    },
  );
}

function loadUiCapabilities() {
  if (uiCapabilities.loaded) {
    return Promise.resolve(uiCapabilities);
  }

  if (uiCapabilitiesPromise) {
    return uiCapabilitiesPromise;
  }

  uiCapabilitiesPromise = main.ForkopShellMethods.getUiCapabilities()
    .then((response) => {
      if (!response?.success) {
        throw new Error("UI capabilities request failed");
      }

      return updateUiCapabilities(response.data);
    })
    .catch((error) => {
      console.warn("Failed to load Forkop UI capabilities", error);
      return main.ForkopShellMethods.getUiState()
        .then((response) => {
          if (!response?.success) {
            throw new Error("UI state request failed");
          }

          return applyUiState(response.data);
        })
        .catch((fallbackError) => {
          console.warn("Failed to load Forkop UI state", fallbackError);
          return loadFallbackUiCapabilities();
        });
    })
    .finally(() => {
      uiCapabilitiesPromise = null;
    });

  return uiCapabilitiesPromise;
}

// A session that cannot read the Forkop UCI package only has the read-only
// ACL group. Decided before any page content renders.
// Only the write level of luci-app-forkop grants /usr/bin/forkop; the read
// level runs the CLI through /usr/libexec/forkop-ro. A role may still read
// the Forkop UCI package (luci-app-forkop-admin), so LuCI's view permission
// decides first.
function detectAccess() {
  const writable =
    typeof L !== "undefined" && typeof L.hasViewPermission === "function"
      ? L.hasViewPermission()
      : null;
  if (writable === false) {
    main.setReadonlyMode?.(true);
    return Promise.resolve(true);
  }

  return uci
    .load(UCI_PACKAGE)
    .then(() => false)
    .catch(() => {
      main.setReadonlyMode?.(true);
      return true;
    });
}

// `pageId` is the controller id the page hosts (dashboard, diagnostic,
// monitoring); pages without a single controller pass null.
function startPage(pageId) {
  main.injectGlobalStyles();
  main.setForkopPage?.(pageId);
  const capabilities = loadUiCapabilities().catch(() => null);

  if (!coreStarted) {
    coreStarted = true;
    main.coreService({
      waitForLogWatcherStart: loadUiCapabilities,
      logWatcherStartDelayMs: 5000,
    });
  }

  return capabilities;
}

const EntryPoint = {
  uiCapabilities,
  loadUiCapabilities,
  detectAccess,
  startPage,
};

return baseclass.extend(EntryPoint);
