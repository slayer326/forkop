import { describe, expect, it } from 'vitest';
import {
  DNS_RULE_PRESETS,
  dnsRulePresetById,
  dnsRulePresetId,
} from '../dnsRulePresets.js';
import { validateDNSForProtocol } from '../../validators/validateDns.js';

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

  it('matches saved presets despite harmless casing or surrounding spaces', () => {
    expect(dnsRulePresetId(' DOH ', ' DNS.GOOGLE/dns-query ')).toBe('google');
  });
});
