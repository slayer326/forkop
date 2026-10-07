import { describe, expect, it } from 'vitest';
import {
  DNS_RULE_PRESETS,
  dnsRulePresetById,
  dnsRulePresetId,
} from '../dnsRulePresets.js';
import { validateDNSForProtocol } from '../../validators/validateDns.js';
import {
  BOOTSTRAP_DNS_SERVER_OPTIONS,
  DNS_SERVER_OPTIONS,
} from '../../constants.js';

describe('DNS rule presets', () => {
  it('uses distinct, valid protocol and server pairs', () => {
    expect(new Set(DNS_RULE_PRESETS.map((preset) => preset.id)).size).toBe(
      DNS_RULE_PRESETS.length,
    );
    for (const preset of DNS_RULE_PRESETS) {
      expect(validateDNSForProtocol(preset.server, preset.protocol).valid).toBe(
        true,
      );
      expect(dnsRulePresetById(preset.id)).toEqual(preset);
      expect(dnsRulePresetId(preset.protocol, preset.server)).toBe(preset.id);
    }
  });

  it('keeps existing custom DNS rules custom without changing their values', () => {
    expect(dnsRulePresetId('doh', 'private.example/dns-query')).toBe('custom');
    expect(dnsRulePresetId('doq', 'dns.adguard-dns.com')).toBe('custom');
    expect(dnsRulePresetId('doh', '77.88.8.8')).toBe('custom');
    expect(dnsRulePresetById('custom')).toBeUndefined();
  });

  it('offers encrypted Yandex DNS without changing its existing UDP preset', () => {
    expect(dnsRulePresetById('yandex')).toEqual({
      id: 'yandex',
      protocol: 'udp',
      server: '77.88.8.8',
    });
    expect(dnsRulePresetById('yandex_doh')).toEqual({
      id: 'yandex_doh',
      protocol: 'doh',
      server: 'common.dot.dns.yandex.net/dns-query',
    });
    expect(dnsRulePresetById('yandex_dot')).toEqual({
      id: 'yandex_dot',
      protocol: 'dot',
      server: 'common.dot.dns.yandex.net',
    });
  });

  it('offers only the Xbox DNS protocols documented by its operator', () => {
    expect(dnsRulePresetById('xbox')).toEqual({
      id: 'xbox',
      protocol: 'udp',
      server: '111.88.96.54',
    });
    expect(dnsRulePresetById('xbox_doh')).toEqual({
      id: 'xbox_doh',
      protocol: 'doh',
      server: 'xbox-dns.ru/dns-query',
    });
    expect(dnsRulePresetById('xbox_dot')).toEqual({
      id: 'xbox_dot',
      protocol: 'dot',
      server: 'xbox-dns.ru',
    });
    expect(dnsRulePresetById('xbox_doq')).toBeUndefined();
    expect(DNS_SERVER_OPTIONS).toHaveProperty('111.88.96.54');
    expect(DNS_SERVER_OPTIONS).toHaveProperty('111.88.96.55');
    // The global list has a separate protocol selector; encrypted endpoints
    // must not appear as one-click suggestions while it is still on UDP.
    expect(DNS_SERVER_OPTIONS).not.toHaveProperty('xbox-dns.ru/dns-query');
    expect(DNS_SERVER_OPTIONS).not.toHaveProperty('xbox-dns.ru');
    expect(BOOTSTRAP_DNS_SERVER_OPTIONS).toHaveProperty('111.88.96.54');
    expect(BOOTSTRAP_DNS_SERVER_OPTIONS).toHaveProperty('111.88.96.55');
    expect(BOOTSTRAP_DNS_SERVER_OPTIONS).not.toHaveProperty('xbox-dns.ru');
  });

  it('matches saved presets despite harmless casing or surrounding spaces', () => {
    expect(dnsRulePresetId(' DOH ', ' DNS.GOOGLE/dns-query ')).toBe('google');
  });
});
