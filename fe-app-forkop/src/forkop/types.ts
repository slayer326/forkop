// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace ClashAPI {
  interface ProxyHistoryEntry {
    time: string;
    delay: number;
  }

  export interface ProxyBase {
    type: string;
    name: string;
    udp: boolean;
    history: ProxyHistoryEntry[];
    now?: string;
    all?: string[];
  }

  export interface Proxies {
    proxies: Record<string, ProxyBase>;
  }
}

// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace Forkop {
  export type HealthLevel =
    | 'ok'
    | 'warning'
    | 'error'
    | 'transitioning'
    | 'recovered'
    // Forkop stopped by the user (diagnostics/health.uc; D-15).
    | 'stopped'
    // Forkop not started since boot (diagnostics/health.uc; D-15).
    | 'not_started'
    | 'unknown';

  export interface HealthStatus {
    overall: HealthLevel;
    service: { forkop: HealthLevel; sing_box: HealthLevel };
    dns: { status: HealthLevel; configured?: boolean };
    lists: { status: HealthLevel };
    // runtime: a guard that a failed lifecycle transition kept (only a
    // restart removes it); restore: the guard of a snapshot restore
    // (diagnostics/health.uc, UC-019).
    guard: { active: boolean; runtime?: boolean; restore?: boolean };
    recovery: {
      pending: boolean;
      last_event: { kind: string; status: string; timestamp: number } | null;
      // What ends the guard that is left: a restart, a restore of a
      // snapshot, or nothing yet while a change still holds its own guard.
      action?: 'restart' | 'restore' | 'wait' | null;
    };
    package_recovery: { pending: boolean };
    last_reload: { kind?: string; status: string; timestamp: number } | null;
    recent_activity: Array<{ kind: string; status: string; timestamp: number }>;
  }

  export interface RouteTraceStage {
    value?: string | null;
    address?: string | null;
    provenance: 'observed' | 'configured' | 'simulated' | 'unknown';
    context?: string;
    // Why a stage is not determined, or what decided it (route_trace).
    reason?: string | null;
    section?: string;
  }
  export interface RouteTrace {
    target: RouteTraceStage & {
      source: string;
      source_applied: boolean;
      protocol: string;
      port: string;
    };
    dns: RouteTraceStage;
    rule: RouteTraceStage;
    action: RouteTraceStage;
    outbound: RouteTraceStage;
    interface: RouteTraceStage;
    runtime: RouteTraceStage;
  }
  export interface SnapshotMetadata {
    id: string;
    created_at: number;
    kind: 'manual' | 'automatic';
    reason: string;
    forkop_version: string;
    is_lkg?: boolean;
  }

  export interface HistoryEvent {
    kind: string;
    status: string;
    timestamp: number;
  }

  export interface HistoryResult {
    // false: no journal on flash yet, events come from runtime memory.
    persistent: boolean;
    events: HistoryEvent[];
  }
  // `section` is a section name or, for an anonymous section, libuci's
  // @type[n]. null: the option is not set on that side; '***' is a value
  // that exists but is hidden (D-2).
  export interface SnapshotChange {
    section: string;
    option: string;
    kind?: 'list';
    before: string | string[] | null;
    after: string | string[] | null;
  }
  // The last entry of a diff longer than the backend lists: `total` changed
  // options, of which only the entries before it are listed (UC-062).
  export interface SnapshotDiffTruncation {
    truncated: true;
    total: number;
  }
  export type SnapshotDiffEntry = SnapshotChange | SnapshotDiffTruncation;
  export interface SnapshotResult {
    status:
      | 'created'
      | 'existing'
      | 'success'
      | 'recovered'
      | 'needs_attention'
      | 'failed'
      | 'deleted'
      | 'busy'
      // config/snapshots.uc: a concurrent change, nothing to restore, and
      // the last-known-good confirmation.
      | 'stale'
      | 'no_change'
      | 'confirmed'
      // A restore while Forkop is stopped by the user: the configuration is
      // replaced and validated, the runtime is not started (D-15).
      | 'restored_not_started';
    snapshot?: SnapshotMetadata;
    changes?: SnapshotDiffEntry[];
    reason?: string;
    // "stopped": an explicit stop held the runtime down; nothing was
    // reloaded or started.
    runtime?: 'stopped';
    // The fail-closed guard of the restore after an unfinished one.
    guard?: 'active' | 'inactive';
    // An edit committed during the transaction was kept: the id of the
    // "Concurrent edit" snapshot that holds it, null when none could be
    // saved (the edit then lives in the configuration only).
    saved_snapshot?: string | null;
  }
  export interface ConnectivityResult {
    host: string;
    type: 'DNS' | 'TCP' | 'HTTP' | 'HTTPS';
    port: number | null;
    status: 'ok' | 'timeout' | 'error';
    error:
      | 'timeout'
      | 'nxdomain'
      | 'no_answer'
      | 'dns_failed'
      | 'connect_failed'
      | 'tls_failed'
      | 'no_response'
      | 'tool_missing'
      | 'failed'
      | null;
    latency_ms: number;
    origin: 'router';
    http_code?: number;
    address?: string;
  }
  // Available commands:
  // start                   Start forkop service
  // stop                    Stop forkop service
  // reload                  Reload forkop configuration
  // restart                 Restart forkop service
  // enable                  Enable forkop autostart
  // disable                 Disable forkop autostart
  // uninstall               Remove forkop files installed outside opkg/apk
  // main                    Run main forkop process
  // list_update             Update domain lists
  // check_proxy             Check proxy connectivity
  // check_nft               Check NFT rules
  // check_nft_rules         Check NFT rules status
  // check_sing_box          Check sing-box installation and status
  // check_logs              Show forkop logs from system journal
  // check_sing_box_logs     Show sing-box logs
  // check_fakeip            Test sing-box FakeIP DNS
  // clash_api               Clash API interface for managing proxies and groups
  // show_config             Display current forkop configuration
  // show_version            Show forkop version
  // show_sing_box_config    Show sing-box configuration
  // show_sing_box_version   Show sing-box version
  // get_status              Get forkop service status
  // get_sing_box_status     Get sing-box service status
  // get_ui_capabilities     Get lightweight UI capabilities
  // check_dns_available     Check DNS server availability
  // global_check            Run global system check

  export enum AvailableMethods {
    CHECK_DNS_AVAILABLE = 'check_dns_available',
    CHECK_FAKEIP = 'check_fakeip',
    CHECK_NFT_RULES = 'check_nft_rules',
    GET_STATUS = 'get_status',
    GET_SUBSCRIPTION_METADATA = 'get_subscription_metadata',
    CHECK_SING_BOX = 'check_sing_box',
    GET_SING_BOX_STATUS = 'get_sing_box_status',
    CLASH_API = 'clash_api',
    ENABLE = 'enable',
    DISABLE = 'disable',
    GLOBAL_CHECK = 'global_check',
    SUPPORT_REPORT = 'support_report',
    SHOW_SING_BOX_CONFIG = 'show_sing_box_config',
    CHECK_LOGS = 'check_logs',
    GET_SYSTEM_INFO = 'get_system_info',
    GET_UI_CAPABILITIES = 'get_ui_capabilities',
    GET_UI_STATE = 'get_ui_state',
    GET_HEALTH_STATUS = 'get_health_status',
    GET_HISTORY = 'get_history',
    ROUTE_TRACE = 'route_trace',
    CONFIG_SNAPSHOT_CREATE = 'config_snapshot_create',
    CONFIG_SNAPSHOT_LIST = 'config_snapshot_list',
    CONFIG_SNAPSHOT_DIFF = 'config_snapshot_diff',
    CONFIG_SNAPSHOT_RESTORE = 'config_snapshot_restore',
    CONFIG_SNAPSHOT_DELETE = 'config_snapshot_delete',
    CONNECTIVITY_TEST = 'connectivity_test',
    GET_READONLY_CONFIG_SECTIONS = 'get_readonly_config_sections',
    GET_DASHBOARD_RUNTIME_METADATA = 'get_dashboard_runtime_metadata',
    SERVICE_ACTION_ASYNC = 'service_action_async',
    SERVICE_ACTION_STATUS = 'service_action_status',
    LATENCY_TEST_ASYNC = 'latency_test_async',
    LATENCY_TEST_STATUS = 'latency_test_status',
    UI_ACTION_ACK = 'ui_action_ack',
    COMPONENT_ACTION_ASYNC = 'component_action_async',
    COMPONENT_ACTION_STATUS = 'component_action_status',
    COMPONENT_UPDATE_CHECK_CACHE = 'component_update_check_cache',
    SUBSCRIPTION_UPDATE_ASYNC = 'subscription_update_async',
    SUBSCRIPTION_UPDATE_STATUS = 'subscription_update_status',
  }

  export enum AvailableClashAPIMethods {
    GET_PROXIES = 'get_proxies',
    GET_CONNECTIONS = 'get_connections',
    GET_PROXY_LATENCY = 'get_proxy_latency',
    GET_PROXY_LATENCIES = 'get_proxy_latencies',
    GET_GROUP_LATENCY = 'get_group_latency',
    SET_GROUP_PROXY = 'set_group_proxy',
    CLOSE_CONNECTION = 'close_connection',
    CLOSE_ALL_CONNECTIONS = 'close_all_connections',
  }

  export interface Outbound {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    description?: string;
    selected: boolean;
    country?: string;
    runtimeAvailable?: boolean;
    urlTestInfo?: UrlTestInfo;
    priorityInfo?: PriorityInfo;
  }

  export interface UrlTestMember {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    selected: boolean;
    country?: string;
  }

  export interface UrlTestInfo {
    code: string;
    sectionName?: string;
    displayName: string;
    selectedCode?: string;
    selectedName?: string;
    url?: string;
    interval?: string;
    tolerance?: string | number;
    idleTimeout?: string;
    interruptExistConnections?: boolean;
    outbounds: UrlTestMember[];
  }

  export interface PriorityMember extends UrlTestMember {
    levelIndex: number;
    levelName: string;
    levelId?: string;
  }

  export interface PriorityInfo {
    code: string;
    displayName: string;
    selectedCode?: string;
    selectedName?: string;
    healthUrl?: string;
    activeCheckInterval?: string;
    checkTimeout?: string;
    recoveryCheckInterval?: string;
    pickFastest?: boolean;
    switchToFasterSamePriority?: boolean;
    fastestCheckInterval?: string;
    interruptExistConnections?: boolean;
    outbounds: PriorityMember[];
  }

  export interface OutboundGroup {
    withTagSelect: boolean;
    code: string;
    sectionName: string;
    displayName: string;
    action?: ConfigSection['action'];
    latencyTestCode?: string;
    latencyTestCodes?: string[];
    latencyTestTimeout?: string;
    proxyConfigType?: ProxyConfigType;
    subscriptionSourceCount?: number;
    subscriptionMetadata?: SubscriptionMetadata[];
    outbounds: Outbound[];
  }

  export interface LatencyActionProgress {
    completed: number;
    total: number;
    failed?: number;
  }

  interface SubscriptionTraffic {
    upload?: number;
    download?: number;
    used?: number;
    total?: number;
    remaining?: number;
    isUnlimited?: boolean;
  }

  export interface SubscriptionMetadata {
    version?: number;
    title?: string;
    traffic?: SubscriptionTraffic;
    expire?: number;
    refillDate?: number;
    webPageUrl?: string;
    supportUrl?: string;
    announce?: string;
    announceUrl?: string;
    fileName?: string;
    serverDescription?: string;
    sourceIndex?: number;
    sourceSection?: string;
  }

  type RuleAction =
    | 'connection'
    | 'proxy'
    | 'outbound'
    | 'vpn'
    | 'bypass'
    | 'block';
  type LegacyConnectionType = 'proxy' | 'vpn' | 'block' | 'exclusion';
  type ProxyConfigType =
    | 'urltest'
    | 'selector'
    | 'url'
    | 'outbound'
    | 'interface'
    | 'subscription';

  export interface ConfigSection {
    '.name': string;
    '.type':
      | 'settings'
      | 'rule'
      | 'node'
      | 'ruleset'
      | 'section'
      | 'server'
      | 'subscription_url'
      | 'section_interface'
      | 'urltest'
      | 'priority_group'
      | 'priority_level';
    label?: string;
    enabled?: string;
    action?: RuleAction;
    connection_type?: LegacyConnectionType;
    proxy_config_type?: ProxyConfigType;
    node?: string;
    rule_set?: string[];
    rule_set_with_subnets?: string[];
    domain_ip_lists?: string[];
    ports?: string[];
    update_interval?: string;
    proxy_string?: string;
    cmd_opts?: string;
    selector_proxy_links?: string[];
    subscription_urls?: string[];
    interfaces?: string[];
    outbound_jsons?: string[];
    subscription_url_settings?: string;
    urltests?: string[];
    urltest_settings?: string;
    priority_groups?: string[];
    priority_group_settings?: string;
    urltest_proxy_links?: string[];
    subscription_url?: string;
    subscription_user_agent?: string;
    subscription_update_enabled?: '0' | '1';
    subscription_update_interval?: string;
    subscription_update_interval_disabled?: '0' | '1';
    urltest_enabled?: '0' | '1';
    sort_by_latency?: '0' | '1';
    urltest_check_interval_disabled?: '0' | '1';
    detect_server_country?: '0' | '1' | 'flag_emoji' | 'country_is';
    urltest_filter_mode?: 'disabled' | 'exclude' | 'include' | 'mixed';
    urltest_hide_filtered_outbounds?: '0' | '1';
    urltest_exclude_countries?: string[];
    urltest_exclude_outbounds?: string[];
    urltest_exclude_regex?: string[];
    urltest_include_countries?: string[];
    urltest_include_outbounds?: string[];
    urltest_include_regex?: string[];
    outbound_json?: string;
    interface?: string;
    section?: string;
    id?: string;
    url?: string;
    name?: string;
    display_name?: string;
    check_interval?: string;
    tolerance?: string;
    testing_url?: string;
    idle_timeout?: string;
    interrupt_exist_connections?: '0' | '1';
    pin_dashboard?: '0' | '1';
    filter_mode?: 'disabled' | 'exclude' | 'include' | 'mixed';
    include_countries?: string[];
    include_outbounds?: string[];
    include_regex?: string[];
    exclude_countries?: string[];
    exclude_outbounds?: string[];
    exclude_regex?: string[];
    group?: string;
    order?: string;
    direct?: '0' | '1';
    health_url?: string;
    active_check_interval?: string;
    check_timeout?: string;
    recovery_check_interval?: string;
    pick_fastest?: '0' | '1';
    switch_to_faster_same_priority?: '0' | '1';
    fastest_check_interval?: string;
    country?: string[];
    server_name?: string[];
    regex?: string[];
    outbound_detour_enabled?: '0' | '1';
    outbound_detour_section?: string;
    download_via_proxy_enabled?: '0' | '1';
    download_via_proxy_section?: string;
    auto_user_agent?: '0' | '1';
    user_agent?: string;
    auto_hwid?: '0' | '1';
    hwid?: string;
    show_dashboard_metadata?: '0' | '1';
    prefix_nodes?: '0' | '1';
    node_prefix?: string;
    include_urltest_groups?: '0' | '1';
    hide_urltest_group_outbounds?: '0' | '1';
    hide_detour_outbounds?: '0' | '1';
    yacd_secret_key?: string;
    config_path?: string;
  }

  export interface MethodSuccessResponse<T> {
    success: true;
    data: T;
  }

  export interface MethodFailureResponse {
    success: false;
    error: string;
  }

  export type MethodResponse<T> =
    | MethodSuccessResponse<T>
    | MethodFailureResponse;

  export interface DnsCheckResult {
    dns_type: 'udp' | 'doh' | 'dot' | 'doq';
    dns_server: string;
    dns_server_index: number;
    dns_server_count: number;
    dns_status: 0 | 1;
    dns_on_router: 0 | 1;
    bootstrap_dns_server: string;
    bootstrap_dns_server_index: number;
    bootstrap_dns_server_count: number;
    bootstrap_dns_status: 0 | 1;
    bootstrap_dns_required: 0 | 1;
    dhcp_config_status: 0 | 1;
    dont_touch_dhcp: 0 | 1;
  }

  export interface NftRulesCheckResult {
    table_exist: 0 | 1;
    rules_mangle_exist: 0 | 1;
    rules_mangle_counters: 0 | 1;
    rules_mangle_output_exist: 0 | 1;
    rules_mangle_output_counters: 0 | 1;
    rules_proxy_exist: 0 | 1;
    rules_proxy_counters: 0 | 1;
    rules_other_mark_exist: 0 | 1;
  }

  export interface SingBoxCheckResult {
    sing_box_installed: 0 | 1;
    sing_box_version_ok: 0 | 1;
    sing_box_service_exist: 0 | 1;
    sing_box_autostart_disabled: 0 | 1;
    sing_box_process_running: 0 | 1;
    sing_box_ports_listening: 0 | 1;
  }

  export interface FakeIPCheckResult {
    fakeip: boolean;
    IP: string;
  }

  export interface GetStatus {
    running: number;
    enabled: number;
    status: string;
    dns_configured?: number;
    // 1 while an explicit stop holds Forkop down (D-15): not a failure.
    stopped_by_user?: number;
    // 1 while Forkop is down and nobody started it since boot (D-15): not a
    // failure either. Down with both 0: it failed after an explicit start.
    not_started?: number;
    restart_blocked?: number;
    stop_available?: number;
  }

  export interface GetOutboundMetadata {
    names?: Record<string, string>;
    countries?: Record<string, string>;
    descriptions?: Record<string, string>;
  }

  export interface GetSingBoxStatus {
    running: number;
    enabled: number;
    status: string;
  }

  export interface GetSystemInfo {
    forkop_version: string;
    forkop_latest_version: string;
    luci_app_version: string;
    sing_box_version: string;
    sing_box_extended: 0 | 1;
    sing_box_tiny: 0 | 1;
    sing_box_compressed: 0 | 1;
    sing_box_tailscale: 0 | 1;
    sing_box_podkop_engine?: 0 | 1;
    sing_box_podkop_engine_full?: 0 | 1;
    zapret_manager_installed: 0 | 1;
    packet_steering_mode: string;
    direct_proxy_enabled: 0 | 1;
    direct_proxy_address: string;
    direct_proxy_port: string;
    torrserver_running: 0 | 1;
    torrserver_direct_available: 0 | 1;
    torrserver_direct_enabled: 0 | 1;
    torrserver_direct_active: 0 | 1;
    openwrt_version: string;
    device_model: string;
    generated_at?: number;
  }

  export interface GetUiCapabilities {
    sing_box_extended: 0 | 1;
    sing_box_tiny: 0 | 1;
    sing_box_compressed: 0 | 1;
    sing_box_tailscale: 0 | 1;
    sing_box_podkop_engine?: 0 | 1;
    sing_box_podkop_engine_full?: 0 | 1;
  }

  export type ServiceAction = 'start' | 'stop' | 'restart' | 'reload';

  export interface UiActionStartResult {
    success: boolean;
    job_id: string;
    message: string;
  }

  export interface UiActionState {
    success: boolean;
    running?: boolean;
    kind?: string;
    message?: string;
    pid?: string | null;
    started_at?: number;
    updated_at?: number | null;
    exit_code?: number | null;
    job_id?: string;
  }

  export interface ServiceActionState extends UiActionState {
    kind: 'service';
    action: ServiceAction;
    source?: string;
    // A reload that did not run (service/ui.uc): init.d only queued it
    // behind another operation, or skipped it because Forkop X is stopped.
    outcome?: 'queued' | 'stopped';
  }

  export interface LatencyActionState extends UiActionState {
    kind: 'latency';
    latency_type: 'group' | 'proxy' | 'proxy_list';
    section: string;
    tag: string;
    progress?: LatencyActionProgress;
  }

  export interface UiState {
    service: {
      forkop: GetStatus;
      sing_box: GetSingBoxStatus;
    };
    capabilities: GetUiCapabilities;
    actions: {
      service: ServiceActionState[];
      latency: LatencyActionState[];
      component: ComponentActionResult[];
      subscription: SubscriptionUpdateJobState[];
    };
  }

  export type ComponentName =
    | 'forkop'
    | 'sing_box'
    | 'zapret_manager'
    | 'packet_steering'
    | 'direct_proxy'
    | 'torrserver_direct';

  export type ComponentAction =
    | 'check_update'
    | 'install'
    | 'remove'
    | 'install_extended'
    | 'install_extended_compressed'
    | 'install_tiny'
    | 'install_stable'
    | 'install_podkop_engine'
    | 'install_podkop_engine_full'
    | 'enable'
    | 'disable'
    | 'restore';

  export interface ComponentActionResult {
    success: boolean;
    running?: boolean;
    kind?: 'component';
    job_id?: string;
    component: ComponentName;
    action: ComponentAction;
    message: string;
    current_version: string;
    latest_version: string;
    release_url?: string;
    changed: boolean;
    status?: 'latest' | 'outdated' | 'dev' | 'recovered' | '';
    pid?: string | null;
    started_at?: number;
    updated_at?: number | null;
    exit_code?: number | null;
  }

  export interface ComponentUpdateCheckCache {
    enabled: boolean;
    results: ComponentActionResult[];
  }

  export type ComponentActionStartResult = UiActionStartResult;

  export type SubscriptionUpdateStartResult = UiActionStartResult;

  export interface SubscriptionUpdateJobState extends UiActionState {
    kind?: 'subscription';
    success: boolean;
    running?: boolean;
    message?: string;
    section?: string;
    source_index?: string;
    pid?: string | null;
    started_at?: number;
    exit_code?: number | null;
    updated_at?: number | null;
  }

  export interface GetClashApiProxyLatency {
    delay: number;
    message?: string;
  }

  export interface GetClashApiProxyLatencies {
    success: boolean;
    count: number;
    failed: boolean;
  }

  export type GetClashApiGroupLatency = Record<string, number>;
}
