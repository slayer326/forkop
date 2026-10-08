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

  it('does not suggest Xbox DNS but preserves old entries as custom values', () => {
    for (const id of ['xbox', 'xbox_doh', 'xbox_dot']) {
      expect(dnsRulePresetById(id)).toBeUndefined();
    }
    expect(dnsRulePresetId('udp', '111.88.96.54')).toBe('custom');
    expect(dnsRulePresetId('doh', 'xbox-dns.ru/dns-query')).toBe('custom');
    expect(dnsRulePresetId('dot', 'xbox-dns.ru')).toBe('custom');
    for (const address of ['111.88.96.54', '111.88.96.55']) {
      expect(DNS_SERVER_OPTIONS).not.toHaveProperty(address);
      expect(BOOTSTRAP_DNS_SERVER_OPTIONS).not.toHaveProperty(address);
    }
  });

  it('matches saved presets despite harmless casing or surrounding spaces', () => {
    expect(dnsRulePresetId(' DOH ', ' DNS.GOOGLE/dns-query ')).toBe('google');
  });
});
