import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Forkop } from '../../types';
import { executeShellCommand } from '../../../helpers';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';

const SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS = 15000;
const SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS = 1500;
const UI_ACTION_RPC_TIMEOUT_MS = 15000;
const UI_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const SERVICE_ACTION_POLL_INTERVAL_MS = 1000;
const LATENCY_TEST_TIMEOUT_MS = 30 * 1000;
const LATENCY_TEST_POLL_INTERVAL_MS = 1000;
const COMPONENT_ACTION_RPC_TIMEOUT_MS = 15000;
const COMPONENT_ACTION_POLL_INTERVAL_MS = 1500;
const COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS = 15000;
const COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS = 30000;
const COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const COMPONENT_ACTION_STATE_DIR = '/var/run/forkop/component-actions';
const GET_UI_STATE_RPC_TIMEOUT_MS = 3000;
const SUPPORT_REPORT_RPC_TIMEOUT_MS = 60000;
// Up to 16 targets, one DNS lookup (2 s timeout) each.
const AUTOTUNE_GROUPS_RPC_TIMEOUT_MS = 45000;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function translate(message: string) {
  return typeof _ === 'function' ? _(message) : message;
}

function localizeServiceActionMessage(message?: string) {
  switch (message) {
    case 'Forkop X is busy updating data or applying settings. Wait for the operation to finish, then try restarting again.':
      return _(
        'Forkop X is busy updating data or applying settings. Wait for the operation to finish, then try restarting again.',
      );
    case 'Service restart failed':
      return _('Service restart failed');
    case 'Another service action is already running':
      return _('Another service action is already running');
    default:
      return message;
  }
}

function parseJsonObjectOutput<T>(output: string): T | null {
  if (!output) {
    return null;
  }

  try {
    return JSON.parse(output) as T;
  } catch (_error) {
    const jsonMatch = output.match(/(\{[\s\S]*\})\s*$/);

    if (!jsonMatch) {
      return null;
    }

    try {
      return JSON.parse(jsonMatch[1]) as T;
    } catch (_jsonError) {
      return null;
    }
  }
}

function parseComponentActionOutput(output: string) {
  return parseJsonObjectOutput<Forkop.ComponentActionResult>(output);
}

function parseComponentActionResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseComponentActionOutput(response.stdout);
}

function parseComponentActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  const parsedResponse = parseComponentActionResult(response);

  if (!parsedResponse) {
    return null;
  }

  return parsedResponse as unknown as Forkop.ComponentActionStartResult;
}

function parseSubscriptionUpdateStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Forkop.SubscriptionUpdateStartResult>(
    response.stdout,
  );
}

function parseSubscriptionUpdateJobState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Forkop.SubscriptionUpdateJobState>(
    response.stdout,
  );
}

function parseUiActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Forkop.UiActionStartResult>(response.stdout);
}

function parseServiceActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Forkop.ServiceActionState>(response.stdout);
}

function parseLatencyActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Forkop.LatencyActionState>(response.stdout);
}

function isComponentActionJobId(jobId: string) {
  return /^[A-Za-z0-9._-]+$/.test(jobId) && jobId !== '.' && jobId !== '..';
}

async function readComponentActionState(jobId: string) {
  if (!isComponentActionJobId(jobId)) {
    return null;
  }

  try {
    return parseComponentActionOutput(
      await fs.read(`${COMPONENT_ACTION_STATE_DIR}/${jobId}.json`),
    );
  } catch (_error) {
    return null;
  }
}

async function readForkopVersion() {
  const response = await executeShellCommand({
    command: '/usr/bin/forkop',
    args: ['show_version'],
    timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
  });

  if ((response.code ?? 0) !== 0 || !response.stdout) {
    return '';
  }

  return response.stdout.trim();
}

async function isComponentActionStillRunning(
  jobId: string,
  component: Forkop.ComponentName,
  action: Forkop.ComponentAction,
) {
  const response = await callBaseMethod<Forkop.UiState>(
    Forkop.AvailableMethods.GET_UI_STATE,
    [],
    '/usr/bin/forkop',
    { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
  );

  return (
    response.success &&
    response.data.actions.component.some(
      (state) =>
        state.job_id === jobId &&
        state.component === component &&
        state.action === action &&
        state.running === true,
    )
  );
}

function componentActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: Pick<Forkop.ComponentActionResult, 'message'> | null,
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || _('Failed to execute'),
  } as Forkop.MethodFailureResponse;
}

function uiActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: { message?: string } | null,
  fallback: string = _('Failed to execute'),
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || fallback,
  } as Forkop.MethodFailureResponse;
}

function createTransientRpcGraceTracker(graceMs: number) {
  let failureStartedAt = 0;

  return {
    reset() {
      failureStartedAt = 0;
    },
    shouldContinue(error?: string) {
      if (!isTransientRpcError(error)) {
        failureStartedAt = 0;
        return false;
      }

      if (!failureStartedAt) {
        failureStartedAt = Date.now();
      }

      return Date.now() - failureStartedAt < graceMs;
    },
  };
}

export const ForkopShellMethods = {
  checkDNSAvailable: async () =>
    callBaseMethod<Forkop.DnsCheckResult>(
      Forkop.AvailableMethods.CHECK_DNS_AVAILABLE,
    ),
  checkFakeIP: async () =>
    callBaseMethod<Forkop.FakeIPCheckResult>(
      Forkop.AvailableMethods.CHECK_FAKEIP,
    ),
  checkNftRules: async () =>
    callBaseMethod<Forkop.NftRulesCheckResult>(
      Forkop.AvailableMethods.CHECK_NFT_RULES,
    ),
  checkZapretRuntime: async () =>
    callBaseMethod<Forkop.ZapretCheckResult>(
      Forkop.AvailableMethods.CHECK_ZAPRET_RUNTIME,
    ),
  checkZapret2Runtime: async () =>
    callBaseMethod<Forkop.Zapret2CheckResult>(
      Forkop.AvailableMethods.CHECK_ZAPRET2_RUNTIME,
    ),
  checkByedpiRuntime: async () =>
    callBaseMethod<Forkop.ByedpiCheckResult>(
      Forkop.AvailableMethods.CHECK_BYEDPI_RUNTIME,
    ),
  getStatus: async () =>
    callBaseMethod<Forkop.GetStatus>(Forkop.AvailableMethods.GET_STATUS),
  getReadonlyConfigSections: async () =>
    callBaseMethod<Forkop.ConfigSection[]>(
      Forkop.AvailableMethods.GET_READONLY_CONFIG_SECTIONS,
    ),
  getDashboardRuntimeMetadata: async () =>
    callBaseMethod<{ urltestGroups: Record<string, unknown> }>(
      Forkop.AvailableMethods.GET_DASHBOARD_RUNTIME_METADATA,
    ),
  getSubscriptionMetadata: async (section: string) =>
    callBaseMethod<Forkop.SubscriptionMetadata | Forkop.SubscriptionMetadata[]>(
      Forkop.AvailableMethods.GET_SUBSCRIPTION_METADATA,
      [section],
    ),
  checkSingBox: async () =>
    callBaseMethod<Forkop.SingBoxCheckResult>(
      Forkop.AvailableMethods.CHECK_SING_BOX,
    ),
  getSingBoxStatus: async () =>
    callBaseMethod<Forkop.GetSingBoxStatus>(
      Forkop.AvailableMethods.GET_SING_BOX_STATUS,
    ),
  getZapretStatus: async () =>
    callBaseMethod<Forkop.GetZapretStatus>(
      Forkop.AvailableMethods.GET_ZAPRET_STATUS,
    ),
  getZapret2Status: async () =>
    callBaseMethod<Forkop.GetZapret2Status>(
      Forkop.AvailableMethods.GET_ZAPRET2_STATUS,
    ),
  getByedpiStatus: async () =>
    callBaseMethod<Forkop.GetByedpiStatus>(
      Forkop.AvailableMethods.GET_BYEDPI_STATUS,
    ),
  getClashApiProxies: async () =>
    callBaseMethod<ClashAPI.Proxies>(Forkop.AvailableMethods.CLASH_API, [
      Forkop.AvailableClashAPIMethods.GET_PROXIES,
    ]),
  getClashApiConnections: async () =>
    callBaseMethod<unknown>(Forkop.AvailableMethods.CLASH_API, [
      Forkop.AvailableClashAPIMethods.GET_CONNECTIONS,
    ]),
  getClashApiProxyLatency: async (tag: string, timeout = '5000') =>
    callBaseMethod<Forkop.GetClashApiProxyLatency>(
      Forkop.AvailableMethods.CLASH_API,
      [Forkop.AvailableClashAPIMethods.GET_PROXY_LATENCY, tag, timeout],
    ),
  getClashApiProxyLatencies: async (tags: string[]) =>
    callBaseMethod<Forkop.GetClashApiProxyLatencies>(
      Forkop.AvailableMethods.CLASH_API,
      [
        Forkop.AvailableClashAPIMethods.GET_PROXY_LATENCIES,
        JSON.stringify(tags),
        '5000',
      ],
    ),
  getClashApiGroupLatency: async (tag: string) =>
    callBaseMethod<Forkop.GetClashApiGroupLatency>(
      Forkop.AvailableMethods.CLASH_API,
      [Forkop.AvailableClashAPIMethods.GET_GROUP_LATENCY, tag, '10000'],
    ),
  setClashApiGroupProxy: async (group: string, proxy: string) =>
    callBaseMethod<unknown>(Forkop.AvailableMethods.CLASH_API, [
      Forkop.AvailableClashAPIMethods.SET_GROUP_PROXY,
      group,
      proxy,
    ]),
  closeClashApiConnection: async (connectionId: string) =>
    callBaseMethod<unknown>(Forkop.AvailableMethods.CLASH_API, [
      Forkop.AvailableClashAPIMethods.CLOSE_CONNECTION,
      connectionId,
    ]),
  closeAllClashApiConnections: async () =>
    callBaseMethod<unknown>(Forkop.AvailableMethods.CLASH_API, [
      Forkop.AvailableClashAPIMethods.CLOSE_ALL_CONNECTIONS,
    ]),
  enable: async () =>
    callBaseMethod<unknown>(
      Forkop.AvailableMethods.ENABLE,
      [],
      '/etc/init.d/forkop',
    ),
  disable: async () =>
    callBaseMethod<unknown>(
      Forkop.AvailableMethods.DISABLE,
      [],
      '/etc/init.d/forkop',
    ),
  globalCheck: async (masked = true) =>
    callBaseMethod<unknown>(Forkop.AvailableMethods.GLOBAL_CHECK, [
      masked ? 'masked' : 'raw',
    ]),
  supportReport: async () =>
    callBaseMethod<unknown>(
      Forkop.AvailableMethods.SUPPORT_REPORT,
      [],
      '/usr/bin/forkop',
      { timeout: SUPPORT_REPORT_RPC_TIMEOUT_MS },
    ),
  showSingBoxConfig: async (masked = true) =>
    callBaseMethod<unknown>(Forkop.AvailableMethods.SHOW_SING_BOX_CONFIG, [
      masked ? 'masked' : 'raw',
    ]),
  checkLogs: async () =>
    callBaseMethod<unknown>(Forkop.AvailableMethods.CHECK_LOGS),
  getSystemInfo: async () =>
    callBaseMethod<Forkop.GetSystemInfo>(
      Forkop.AvailableMethods.GET_SYSTEM_INFO,
    ),
  getUiCapabilities: async () =>
    callBaseMethod<Forkop.GetUiCapabilities>(
      Forkop.AvailableMethods.GET_UI_CAPABILITIES,
    ),
  getUiState: async () =>
    callBaseMethod<Forkop.UiState>(
      Forkop.AvailableMethods.GET_UI_STATE,
      [],
      '/usr/bin/forkop',
      { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
    ),
  getHealthStatus: async () =>
    callBaseMethod<Forkop.HealthStatus>(
      Forkop.AvailableMethods.GET_HEALTH_STATUS,
    ),
  getHistory: async () =>
    callBaseMethod<Forkop.HistoryResult>(Forkop.AvailableMethods.GET_HISTORY),
  // Autotune commands exit non-zero with a structured result (failed,
  // refused, busy); keep it instead of a bare failure.
  autotuneStatus: async () =>
    callBaseMethod<Forkop.AutotuneStatus>(
      Forkop.AvailableMethods.AUTOTUNE_STATUS,
      [],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  // Resolves every target through the router DNS.
  autotuneGroups: async () =>
    callBaseMethod<Forkop.AutotuneGroups>(
      Forkop.AvailableMethods.AUTOTUNE_GROUPS,
      [],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true, timeout: AUTOTUNE_GROUPS_RPC_TIMEOUT_MS },
    ),
  autotunePolicySet: async (option: string, value: string) =>
    callBaseMethod<Forkop.AutotuneMutationResult>(
      Forkop.AvailableMethods.AUTOTUNE_POLICY_SET,
      [option, value],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  // A host target, or with an empty host a rule-list target: the sing-box
  // rule set tag, how many domains are measured, pinned domains.
  autotuneTargetSet: async (
    id: string,
    host: string,
    enabled: boolean,
    resolver: string,
    list?: { ruleSet: string; sample: string; pins: string[] },
  ) =>
    callBaseMethod<Forkop.AutotuneMutationResult>(
      Forkop.AvailableMethods.AUTOTUNE_TARGET_SET,
      [
        id,
        host,
        enabled ? '1' : '0',
        resolver,
        ...(list ? [list.ruleSet, list.sample, list.pins.join(',')] : []),
      ],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  autotuneListDomains: async (ruleSet: string) =>
    callBaseMethod<Forkop.AutotuneListDomains>(
      Forkop.AvailableMethods.AUTOTUNE_LIST_DOMAINS,
      [ruleSet],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  autotuneTargetRemove: async (id: string) =>
    callBaseMethod<Forkop.AutotuneMutationResult>(
      Forkop.AvailableMethods.AUTOTUNE_TARGET_REMOVE,
      [id],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  autotuneRunAsync: async (scope: string) =>
    callBaseMethod<Forkop.AutotuneMutationResult>(
      Forkop.AvailableMethods.AUTOTUNE_RUN_ASYNC,
      [scope],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  // Only the group is sent: the backend derives the candidate itself.
  autotuneApplyAsync: async (group: string) =>
    callBaseMethod<Forkop.AutotuneMutationResult>(
      Forkop.AvailableMethods.AUTOTUNE_APPLY_ASYNC,
      [group],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  // Restores the snapshot taken before the apply and reloads the service,
  // like a snapshot restore.
  autotuneRollback: async () =>
    callBaseMethod<Forkop.AutotuneRollbackResult>(
      Forkop.AvailableMethods.AUTOTUNE_ROLLBACK,
      [],
      '/usr/bin/forkop',
      { timeout: 120000, allowNonZeroWithStdout: true },
    ),
  autotuneRunStatus: async (job: string) =>
    callBaseMethod<Forkop.AutotuneJobStatus>(
      Forkop.AvailableMethods.AUTOTUNE_RUN_STATUS,
      [job],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  routeTrace: async (
    target: string,
    source: string,
    protocol: string,
    port: string,
  ) =>
    // An invalid target exits non-zero with {"error":"invalid_input"}.
    callBaseMethod<Forkop.RouteTrace>(
      Forkop.AvailableMethods.ROUTE_TRACE,
      [target, source, protocol, port],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  // Snapshot mutations print a structured result (busy, failed, ...) even
  // when they exit non-zero; keep it instead of a bare failure.
  snapshotCreate: async (kind: 'manual' | 'automatic' = 'manual') =>
    callBaseMethod<Forkop.SnapshotResult>(
      Forkop.AvailableMethods.CONFIG_SNAPSHOT_CREATE,
      [kind],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  snapshotList: async () =>
    callBaseMethod<Forkop.SnapshotMetadata[]>(
      Forkop.AvailableMethods.CONFIG_SNAPSHOT_LIST,
    ),
  snapshotDiff: async (id: string) =>
    callBaseMethod<Forkop.SnapshotDiffEntry[]>(
      Forkop.AvailableMethods.CONFIG_SNAPSHOT_DIFF,
      [id],
    ),
  snapshotRestore: async (id: string) =>
    callBaseMethod<Forkop.SnapshotResult>(
      Forkop.AvailableMethods.CONFIG_SNAPSHOT_RESTORE,
      [id],
      '/usr/bin/forkop',
      { timeout: 120000, allowNonZeroWithStdout: true },
    ),
  snapshotDelete: async (id: string) =>
    callBaseMethod<Forkop.SnapshotResult>(
      Forkop.AvailableMethods.CONFIG_SNAPSHOT_DELETE,
      [id],
      '/usr/bin/forkop',
      { allowNonZeroWithStdout: true },
    ),
  connectivityTest: async (host: string, type: string, port: string) =>
    callBaseMethod<Forkop.ConnectivityResult>(
      Forkop.AvailableMethods.CONNECTIVITY_TEST,
      [host, type, port],
      '/usr/bin/forkop',
      { timeout: 10000 },
    ),
  validateDpiStrategy: async (
    provider: 'zapret' | 'zapret2' | 'byedpi',
    strategy: string,
  ) =>
    callBaseMethod<unknown>(
      provider === 'zapret'
        ? Forkop.AvailableMethods.VALIDATE_NFQWS_STRATEGY_JSON
        : provider === 'zapret2'
          ? Forkop.AvailableMethods.VALIDATE_NFQWS2_STRATEGY_JSON
          : Forkop.AvailableMethods.VALIDATE_BYEDPI_STRATEGY_JSON,
      [strategy],
    ),
  serviceActionStart: async (action: Forkop.ServiceAction) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.SERVICE_ACTION_ASYNC, action],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (parsedResponse) {
      parsedResponse.message = localizeServiceActionMessage(
        parsedResponse.message,
      );
    }

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.UiActionStartResult>;
  },
  saveUrlTestOverride: async (
    section: string,
    tag: string,
    url: string,
    interval: string,
    tolerance: string,
    idleTimeout: string,
    interrupt: boolean,
  ) =>
    executeShellCommand({
      command: '/usr/bin/forkop',
      args: [
        'urltest_override_save',
        section,
        tag,
        url,
        interval,
        tolerance,
        idleTimeout,
        interrupt ? '1' : '0',
      ],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    }),
  resetUrlTestOverride: async (section: string, tag: string) =>
    executeShellCommand({
      command: '/usr/bin/forkop',
      args: ['urltest_override_reset', section, tag],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    }),
  serviceActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.SERVICE_ACTION_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseServiceActionState(response);

    if (parsedResponse) {
      parsedResponse.message = localizeServiceActionMessage(
        parsedResponse.message,
      );
    }

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.ServiceActionState>;
  },
  waitServiceActionJob: async (jobId: string) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    // The backend owns the operation lifetime. A manual restart can validly
    // spend more than two minutes fetching several lists before it performs
    // the single runtime transition; timing out in the browser would re-enable
    // controls while that restart was still going to happen.
    while (true) {
      await sleep(SERVICE_ACTION_POLL_INTERVAL_MS);

      const response = await ForkopShellMethods.serviceActionStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }
  },
  latencyTestStart: async (
    latencyType: Forkop.LatencyActionState['latency_type'],
    section: string,
    tag: string,
    timeout?: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [
        Forkop.AvailableMethods.LATENCY_TEST_ASYNC,
        latencyType,
        section,
        tag,
        ...(timeout ? [timeout] : []),
      ],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.UiActionStartResult>;
  },
  latencyTestStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.LATENCY_TEST_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseLatencyActionState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.LatencyActionState>;
  },
  waitLatencyTestJob: async (jobId: string, startedAt = Date.now()) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (Date.now() - startedAt < LATENCY_TEST_TIMEOUT_MS) {
      await sleep(LATENCY_TEST_POLL_INTERVAL_MS);

      const response = await ForkopShellMethods.latencyTestStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Forkop.MethodFailureResponse;
  },
  uiActionAck: async (
    kind: 'service' | 'latency' | 'component' | 'subscription',
    jobId: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.UI_ACTION_ACK, kind, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse?.success) {
      return uiActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.UiActionStartResult>;
  },
  componentActionStart: async (
    component: Forkop.ComponentName,
    action: Forkop.ComponentAction,
    version?: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [
        Forkop.AvailableMethods.COMPONENT_ACTION_ASYNC,
        component,
        action,
        ...(version ? [version] : []),
      ],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.ComponentActionStartResult>;
  },
  componentActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.ComponentActionResult>;
  },
  componentUpdateCheckCache: async () =>
    callBaseMethod<Forkop.ComponentUpdateCheckCache>(
      Forkop.AvailableMethods.COMPONENT_UPDATE_CHECK_CACHE,
    ),
  waitComponentActionJob: async (
    jobId: string,
    component: Forkop.ComponentName,
    action: Forkop.ComponentAction,
    expectedLatestVersion?: string,
  ) => {
    let selfUpdateVersionMatchedAt = 0;
    let lastStatusRefreshAt = 0;
    const transientRpc = createTransientRpcGraceTracker(
      COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (true) {
      await sleep(COMPONENT_ACTION_POLL_INTERVAL_MS);

      const stateResponse = await readComponentActionState(jobId);

      if (stateResponse) {
        if (!stateResponse.running) {
          transientRpc.reset();
          return {
            success: true,
            data: stateResponse,
          } as Forkop.MethodSuccessResponse<Forkop.ComponentActionResult>;
        }

        if (
          Date.now() - lastStatusRefreshAt <
          COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS
        ) {
          continue;
        }
      }

      lastStatusRefreshAt = Date.now();
      const statusResponse = await executeShellCommand({
        command: '/usr/bin/forkop',
        args: [Forkop.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
        timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
      });
      const parsedResponse = parseComponentActionResult(statusResponse);

      if ((statusResponse.code ?? 0) !== 0 || !parsedResponse) {
        if (stateResponse?.running) {
          transientRpc.reset();
          continue;
        }

        if (await isComponentActionStillRunning(jobId, component, action)) {
          transientRpc.reset();
          continue;
        }

        const failure = componentActionFailure(statusResponse, parsedResponse);

        if (transientRpc.shouldContinue(failure.error)) {
          continue;
        }

        if (component === 'forkop' && action === 'install') {
          const installedVersion = expectedLatestVersion
            ? await readForkopVersion()
            : '';

          if (
            expectedLatestVersion &&
            installedVersion === expectedLatestVersion
          ) {
            if (!selfUpdateVersionMatchedAt) {
              selfUpdateVersionMatchedAt = Date.now();
            }

            if (
              Date.now() - selfUpdateVersionMatchedAt >=
              COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS
            ) {
              return {
                success: true,
                data: {
                  success: true,
                  component,
                  action,
                  message: translate('Forkop has been installed'),
                  current_version: installedVersion,
                  latest_version: expectedLatestVersion,
                  changed: true,
                  status: 'latest',
                },
              } as Forkop.MethodSuccessResponse<Forkop.ComponentActionResult>;
            }
          }

          continue;
        }

        return failure;
      }

      transientRpc.reset();
      if (parsedResponse.running) {
        continue;
      }

      return {
        success: true,
        data: parsedResponse,
      } as Forkop.MethodSuccessResponse<Forkop.ComponentActionResult>;
    }
  },
  subscriptionUpdateStart: async (section?: string, sourceIndex?: number) => {
    const startArgs = [
      Forkop.AvailableMethods.SUBSCRIPTION_UPDATE_ASYNC,
      ...(section ? [section] : []),
      ...(section && sourceIndex !== undefined ? [String(sourceIndex)] : []),
    ];
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: startArgs,
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return {
        success: false,
        error:
          parsedResponse?.message ||
          response.stderr ||
          _('Subscription update failed'),
      } as Forkop.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.SubscriptionUpdateStartResult>;
  },
  subscriptionUpdateStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: [Forkop.AvailableMethods.SUBSCRIPTION_UPDATE_STATUS, jobId],
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateJobState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return {
        success: false,
        error: response.stderr || _('Subscription update failed'),
      } as Forkop.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Forkop.MethodSuccessResponse<Forkop.SubscriptionUpdateJobState>;
  },
  waitSubscriptionUpdateJob: async (jobId: string) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (true) {
      await sleep(SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS);

      const response = await ForkopShellMethods.subscriptionUpdateStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }
  },
};
