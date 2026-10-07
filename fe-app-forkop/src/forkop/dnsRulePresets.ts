export type DnsRulePreset = {
  id: string;
  protocol: 'doh' | 'dot' | 'udp';
  server: string;
};

// LuCI stores only dns_type and dns_server. The picker is a convenience for
// filling those existing fields, not another source of configuration truth.
export const DNS_RULE_PRESETS: readonly DnsRulePreset[] = [
  {
    id: 'cloudflare',
    protocol: 'doh',
    server: 'cloudflare-dns.com/dns-query',
  },
  { id: 'google', protocol: 'doh', server: 'dns.google/dns-query' },
  { id: 'quad9', protocol: 'doh', server: 'dns.quad9.net/dns-query' },
  {
    id: 'adguard',
    protocol: 'doh',
    server: 'dns.adguard-dns.com/dns-query',
  },
  { id: 'yandex', protocol: 'udp', server: '77.88.8.8' },
  {
    id: 'yandex_doh',
    protocol: 'doh',
    server: 'common.dot.dns.yandex.net/dns-query',
  },
  {
    id: 'yandex_dot',
    protocol: 'dot',
    server: 'common.dot.dns.yandex.net',
  },
  { id: 'xbox', protocol: 'udp', server: '111.88.96.54' },
  {
    id: 'xbox_doh',
    protocol: 'doh',
    server: 'xbox-dns.ru/dns-query',
  },
  { id: 'xbox_dot', protocol: 'dot', server: 'xbox-dns.ru' },
];

export function dnsRulePresetById(id: string): DnsRulePreset | undefined {
  return DNS_RULE_PRESETS.find((preset) => preset.id === id);
}

export function dnsRulePresetId(protocol: string, server: string): string {
  const normalizedProtocol = protocol.trim().toLowerCase();
  const normalizedServer = server.trim().toLowerCase();
  return (
    DNS_RULE_PRESETS.find(
      (preset) =>
        preset.protocol === normalizedProtocol &&
        preset.server === normalizedServer,
    )?.id || 'custom'
  );
}
