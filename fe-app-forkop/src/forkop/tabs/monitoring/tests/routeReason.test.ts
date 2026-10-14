import { describe, expect, it } from 'vitest';
import { formatRouteReason } from '../routeReason';
import { customRulesetLabel, customRulesetTag } from '../rulesetLabels';

describe('route reason', () => {
  it('explains unconditional device routes with and without exclusions', () => {
    for (const conditions of [
      'inbound=[tproxy-in tproxy6-in] source_ip_cidr=192.168.90.201/32',
      'and(inbound=[tproxy-in tproxy6-in] source_ip_cidr=192.168.90.201/32 !(source_ip_cidr=192.168.90.239/32))',
    ]) {
      expect(
        formatRouteReason(`${conditions} => route(VPN-out)`, '', (value) =>
          value === 'All traffic from device'
            ? 'Весь трафик устройства'
            : value,
        ),
      ).toBe('Весь трафик устройства · 192.168.90.201');
    }
    expect(
      formatRouteReason(
        'inbound=tproxy-in source_ip_cidr=[192.168.1.0/24 fd00::2/128] => route(VPN-out)',
      ),
    ).toBe('All traffic from device · 192.168.1.0/24, fd00::2');
  });

  it('does not label conditional, inverted, or abbreviated rules as all device traffic', () => {
    for (const conditions of [
      'and(inbound=tproxy-in source_ip_cidr=192.168.1.2/32 domain_suffix=example.org !(source_ip_cidr=192.168.1.3/32))',
      'or(inbound=tproxy-in source_ip_cidr=192.168.1.2/32 domain_suffix=example.org)',
      '!(inbound=tproxy-in source_ip_cidr=192.168.1.2/32)',
      'inbound=tproxy-in source_ip_cidr=[192.168.1.2/32...]',
      'inbound=tproxy-in source_ip_cidr=192.168.1.2/32 port=443',
      'inbound=socks-in source_ip_cidr=192.168.1.2/32',
    ]) {
      expect(
        formatRouteReason(`${conditions} => route(VPN-out)`),
      ).not.toContain('All traffic from device');
    }
  });

  it('names the matching built-in list, including hyphenated sections', () => {
    expect(
      formatRouteReason(
        'inbound=tproxy-in rule_set=my-vpn-discord-community-ruleset => route(my-vpn-out)',
      ),
    ).toBe('Discord');
  });

  it('does not guess which member of a legacy combined rule matched', () => {
    expect(
      formatRouteReason(
        'rule_set=[VPN-discord-community-ruleset VPN-telegram-community-ruleset] => route(VPN-out)',
      ),
    ).toBe('One of: Discord, Telegram');
  });

  it('preserves inline conditions and custom rule-set identifiers', () => {
    expect(
      formatRouteReason('domain_suffix=example.org => route(VPN-out)'),
    ).toBe('domain_suffix=example.org');
    expect(
      formatRouteReason('rule_set=inline-custom-123-ruleset => route(VPN-out)'),
    ).toBe('inline-custom-123-ruleset');
  });

  it('shows the custom list filename without exposing URL credentials', () => {
    const reference = 'https://example.org/lists/twitch.srs?token=secret';
    const tag = customRulesetTag(reference);
    expect(
      formatRouteReason(
        `rule_set=${tag} => route(VPN-out)`,
        '',
        undefined,
        undefined,
        { [tag]: customRulesetLabel(reference) },
      ),
    ).toBe('Twitch');
    expect(customRulesetLabel('/etc/lists/custom.json')).toBe('Custom');
    expect(customRulesetLabel('https://example.org/?token=secret')).toBe(
      'Custom list',
    );
    expect(
      formatRouteReason(
        'rule_set=custom',
        'domain_suffix=ttvnw.net',
        undefined,
        undefined,
        { custom: 'Twitch' },
      ),
    ).toBe('Twitch');
  });

  it('distinguishes absent metadata from a reported default route', () => {
    expect(formatRouteReason()).toBe('Not available');
    expect(formatRouteReason('final')).toBe('Default route');
  });

  it('uses a concise fallback when an exact match cannot be proven', () => {
    const rule =
      'inbound=test-in domain_suffix=[bhvr.com deadbydaylight.com] domain_regex=^gamelift-ping\\.[a-z0-9-]+\\.api\\.aws$ ip_cidr=[18.184.209.26 127.0.0.1] => route(DBD-out)';
    const metadata = {
      host: 'valorant.secure.dyn.riotcdn.net',
      destinationIP: '',
    };
    expect(formatRouteReason(rule, '', undefined, metadata)).toBe(
      'Exact match unavailable',
    );
    expect(
      formatRouteReason(
        rule,
        '',
        (text) =>
          text === 'Exact match unavailable'
            ? 'Точное совпадение недоступно'
            : text,
        metadata,
      ),
    ).toBe('Точное совпадение недоступно');
    expect(
      formatRouteReason(rule, '', undefined, {
        ...metadata,
        destinationIP: '127.0.0.1',
      }),
    ).toBe('ip_cidr=127.0.0.1');
  });
});
