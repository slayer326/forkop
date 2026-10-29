import { isReadonlyMode } from './accessMode.service';
import { logger } from './logger.service';

export const FORKOP_CLI = '/usr/bin/forkop';

// rpcd hands the caller's environment to file.exec children, so the read
// role may run the CLI only through this wrapper, which clears it (UC-001).
export const FORKOP_READONLY_CLI = '/usr/libexec/forkop-ro';

// Mirror of the "read" exec grants of the luci-app-forkop ACL group
// (luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json); a test
// keeps both lists identical. A read-only session only ever issues these
// commands, so rendering a page cannot start a mutation or trip the ACL.
export const READONLY_EXEC_PATTERNS = [
  '/usr/libexec/forkop-ro get_status',
  '/usr/libexec/forkop-ro get_sing_box_status',
  '/usr/libexec/forkop-ro get_system_info',
  '/usr/libexec/forkop-ro get_ui_capabilities',
  '/usr/libexec/forkop-ro get_ui_state',
  '/usr/libexec/forkop-ro get_health_status',
  '/usr/libexec/forkop-ro get_history',
  '/usr/libexec/forkop-ro route_trace *',
  '/usr/libexec/forkop-ro config_snapshot_list',
  '/usr/libexec/forkop-ro config_snapshot_diff *',
  '/usr/libexec/forkop-ro connectivity_test *',
  '/usr/libexec/forkop-ro get_readonly_config_sections',
  '/usr/libexec/forkop-ro get_dashboard_runtime_metadata',
  '/usr/libexec/forkop-ro show_version',
  '/usr/libexec/forkop-ro check_nft_rules',
  '/usr/libexec/forkop-ro check_sing_box',
  '/usr/libexec/forkop-ro check_logs',
  '/usr/libexec/forkop-ro check_fakeip',
  '/usr/libexec/forkop-ro check_dns_available',
  '/usr/libexec/forkop-ro clash_api get_proxies',
  '/usr/libexec/forkop-ro clash_api get_connections',
  '/usr/libexec/forkop-ro service_action_status *',
  '/usr/libexec/forkop-ro latency_test_status *',
  '/usr/libexec/forkop-ro component_action_status *',
  '/usr/libexec/forkop-ro subscription_update_status *',
  '/usr/libexec/forkop-ro component_update_check_cache',
  '/usr/libexec/forkop-ro global_check masked',
  '/usr/libexec/forkop-ro show_sing_box_config masked',
];

// stderr of a command refused locally in a read-only session.
export const READONLY_REFUSED = 'forkop: not available in read-only mode';

const compiled = READONLY_EXEC_PATTERNS.map(
  (pattern) =>
    new RegExp(
      `^${pattern
        .split('*')
        .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
        .join('.*')}$`,
    ),
);

// rpcd matches "command arg1 arg2 ..." against the ACL globs.
export function isReadonlyCommandAllowed(command: string, args: string[]) {
  const invocation = [command, ...args].join(' ');
  return compiled.some((pattern) => pattern.test(invocation));
}

// A read-only session reaches the CLI through the wrapper; administrators
// keep calling it directly.
export function resolveReadonlyCommand(command: string) {
  return isReadonlyMode() && command === FORKOP_CLI
    ? FORKOP_READONLY_CLI
    : command;
}

const reported = new Set<string>();

export function shouldRefuseCommand(command: string, args: string[]) {
  if (!isReadonlyMode() || isReadonlyCommandAllowed(command, args)) {
    return false;
  }

  const key = [command, args[0] ?? ''].join(' ');
  if (!reported.has(key)) {
    reported.add(key);
    logger.warn('[READONLY]', `refused ${key}`);
  }
  return true;
}
