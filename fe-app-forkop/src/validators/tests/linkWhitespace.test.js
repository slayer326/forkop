import { describe, it, expect } from 'vitest';
import { validateProxyUrl } from '../validateProxyUrl';
import { hasWhitespaceOutsideName } from '../linkWhitespace';

// Links without a display name; each case appends one after '#'.
const links = [
  ['shadowsocks', 'ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388'],
  [
    'vless',
    'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:443?type=tcp&encryption=none&security=none',
  ],
  [
    'trojan grpc',
    'trojan://pass@example.com:443?type=grpc&serviceName=svc&security=tls&sni=example.com',
  ],
  ['socks5', 'socks5://user:pass@example.com:1080'],
  ['hysteria2', 'hysteria2://pass@example.com:443/?sni=example.com'],
];

describe('link display names', () => {
  describe.each(links)('%s', (_desc, link) => {
    it('accepts spaces in the name after #', () => {
      expect(validateProxyUrl(`${link}#Germany Berlin 01`).valid).toBe(true);
    });

    it('still rejects control characters in the name', () => {
      expect(validateProxyUrl(`${link}#Germany\tBerlin`).valid).toBe(false);
    });

    it('still rejects spaces before the name', () => {
      const spaced = link.replace('example.com', 'exam ple.com');
      expect(validateProxyUrl(`${spaced}#Berlin`).valid).toBe(false);
    });
  });
});

describe('hasWhitespaceOutsideName', () => {
  it('ignores spaces after the first #', () => {
    expect(hasWhitespaceOutsideName('trojan://p@h:1#a b # c')).toBe(false);
  });

  it('finds spaces in the query', () => {
    expect(hasWhitespaceOutsideName('trojan://p@h:1?sni= h#a')).toBe(true);
  });

  it('finds control characters anywhere', () => {
    expect(hasWhitespaceOutsideName('trojan://p@h:1#a\nb')).toBe(true);
  });
});
