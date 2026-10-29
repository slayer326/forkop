// Route/owner cases of tests/routing_resolve.sh. Each case: sing-box route
// rules, DNS answer (FakeIP or real) and target host.
const yt = { action: 'route', inbound: 'tproxy-in', domain_suffix: ['youtube.com'], outbound: 'youtube-out' };
const main = (extra) => ({ action: 'route', inbound: 'tproxy-in', outbound: 'main-out', ...extra });
module.exports = [
  ['rule_owner', [yt]],
  ['first_match_connection', [main({ domain_suffix: ['youtube.com'] }), yt]],
  ['reject', [{ action: 'reject', inbound: 'tproxy-in', domain_suffix: ['youtube.com'] }, yt]],
  ['final', []],
  ['rule_set_before_owner', [main({ rule_set: ['remote-list'] }), yt]],
  ['rule_set_with_domain_hit', [main({ rule_set: ['remote-list'], domain_suffix: ['youtube.com'] }), yt]],
  ['domain_regex', [main({ domain_regex: ['.*tube.*'] }), yt]],
  ['logical', [{ type: 'logical', mode: 'and', rules: [], action: 'route', outbound: 'main-out' }, yt]],
  ['unknown_field', [main({ geosite: ['google'] }), yt]],
  ['source_scoped', [main({ domain_suffix: ['youtube.com'], source_ip_cidr: ['192.168.1.2/32'] }), yt]],
  ['fakeip_skips_ip_cidr', [main({ ip_cidr: ['142.250.0.0/16'] }), yt]],
  ['real_address_ip_cidr', [main({ ip_cidr: ['142.250.0.0/16'] }), yt], { dns: '142.250.1.1' }],
  ['resolve_above_owner_fakeip', [{ action: 'resolve', inbound: 'tproxy-in', domain_suffix: ['youtube.com'] }, yt]],
  ['resolve_above_owner_real', [{ action: 'resolve', inbound: 'tproxy-in', domain_suffix: ['youtube.com'] }, yt], { dns: '142.250.1.1' }],
  ['udp_only_rule', [main({ network: 'udp', domain_suffix: ['youtube.com'] }), yt]],
  ['port_80_rule', [main({ port: [80], domain_suffix: ['youtube.com'] }), yt]],
  ['port_range_rule', [main({ port_range: ['400:500'], domain_suffix: ['youtube.com'] }), yt]],
  ['quic_reject', [{ action: 'reject', inbound: 'tproxy-in', protocol: 'quic' }, yt]],
  ['tls_protocol', [main({ protocol: ['tls'] }), yt]],
  ['other_inbound', [{ inbound: ['dns-in'], action: 'hijack-dns' }, main({ inbound: ['mixed-in'], domain_suffix: ['youtube.com'] }), yt]],
  ['sniff_skipped', [{ action: 'sniff', inbound: 'tproxy-in' }, yt]],
  ['second_rule', [{ ...yt, outbound: 'discord-out' }]],
  ['singbox_config_missing', null],
  ['suffix_subdomain_only_apex', [{ ...yt, domain_suffix: ['.youtube.com'] }], { host: 'youtube.com' }],
  ['suffix_subdomain_only_sub', [{ ...yt, domain_suffix: ['.youtube.com'] }]],
  ['keyword', [{ ...yt, domain_suffix: undefined, domain_keyword: ['tube'] }]],
  ['exact_domain_other_host', [{ ...yt, domain_suffix: undefined, domain: ['youtube.com'] }]],
  ['case_insensitive', [{ ...yt, domain_suffix: ['YouTube.COM'] }], { host: 'WWW.YouTube.com' }],
];
