export const FORKOP_UCI_PACKAGE = 'forkop';
export const FORKOP_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
export const FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT =
  'forkop:action-providers-availability';
export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';
export const IP_CHECK_DOMAIN = 'ip.podkop.fyi';
export const DEFAULT_LATENCY_TEST_URL = 'https://www.gstatic.com/generate_204';
export const LATENCY_TEST_URL_OPTIONS = [
  DEFAULT_LATENCY_TEST_URL,
  'https://cp.cloudflare.com/generate_204',
  'https://captive.apple.com',
  'https://connectivity-check.ubuntu.com',
];

export const DOMAIN_LIST_OPTIONS = {
  russia_inside: 'Russia inside',
  russia_outside: 'Russia outside',
  ukraine_inside: 'Ukraine',
  geoblock: 'Geo Block',
  block: 'Block',
  porn: 'Porn',
  news: 'News',
  anime: 'Anime',
  youtube: 'Youtube',
  discord: 'Discord',
  meta: 'Meta',
  twitter: 'Twitter (X)',
  hdrezka: 'HDRezka',
  tiktok: 'Tik-Tok',
  telegram: 'Telegram',
  cloudflare: 'Cloudflare',
  google_ai: 'Google AI',
  google_play: 'Google Play',
  hodca: 'H.O.D.C.A',
  roblox: 'Roblox',
  ads_hagezi_pro: 'Ads (Hagezi Pro)',
  supercell: 'Supercell',
  github: 'GitHub',
  hetzner: 'Hetzner ASN',
  ovh: 'OVH ASN',
  digitalocean: 'Digital Ocean ASN',
  cloudfront: 'CloudFront ASN',
};

// The shown name of a built-in list: descriptive names are translated,
// service and brand names are kept.
export function domainListLabel(key: string) {
  switch (key) {
    case 'russia_inside':
      return _('Russia: blocked inside');
    case 'russia_outside':
      return _('Russia: blocked from outside');
    case 'ukraine_inside':
      return _('Ukraine');
    case 'geoblock':
      return _('Geo-blocked services');
    case 'block':
      return _('Block list');
    case 'porn':
      return _('Adult sites');
    case 'news':
      return _('News');
    case 'anime':
      return _('Anime');
    case 'ads_hagezi_pro':
      return _('Ads (Hagezi Pro)');
    default:
      return (
        DOMAIN_LIST_OPTIONS[key as keyof typeof DOMAIN_LIST_OPTIONS] ?? key
      );
  }
}

export const SECONDARY_RULESET_OPTIONS = {
  blizzard: 'Blizzard',
  bungie: 'Bungie',
  ccp: 'CCP',
  electronicarts: 'Electronic Arts',
  epicgames: 'Epic Games',
  nintendo: 'Nintendo',
  riot: 'Riot Games',
  roblox: 'Roblox',
  sony: 'Sony',
  taketwo: 'Take-Two',
  ubisoft: 'Ubisoft',
  valve: 'Valve',
  wargaming: 'Wargaming',
  xbox: 'Xbox',
  adobe: 'Adobe',
  anthropic: 'Anthropic',
  apple: 'Apple',
  google: 'Google',
  twitch: 'Twitch',
};

export const DNS_SERVER_OPTIONS = {
  '77.88.8.8': '77.88.8.8 (Yandex DNS)',
  '111.88.96.54': '111.88.96.54 (Xbox DNS)',
  '111.88.96.55': '111.88.96.55 (Xbox DNS backup)',
  'xbox-dns.ru/dns-query': 'xbox-dns.ru/dns-query (Xbox DNS DoH)',
  'xbox-dns.ru': 'xbox-dns.ru (Xbox DNS DoT)',
  '1.1.1.1': '1.1.1.1 (Cloudflare)',
  '8.8.8.8': '8.8.8.8 (Google)',
  '9.9.9.9': '9.9.9.9 (Quad9)',
  'dns.adguard-dns.com': 'dns.adguard-dns.com (AdGuard Default)',
  'unfiltered.adguard-dns.com':
    'unfiltered.adguard-dns.com (AdGuard Unfiltered)',
  'family.adguard-dns.com': 'family.adguard-dns.com (AdGuard Family)',
};
export const BOOTSTRAP_DNS_SERVER_OPTIONS = {
  '77.88.8.8': '77.88.8.8 (Yandex DNS)',
  '77.88.8.1': '77.88.8.1 (Yandex DNS)',
  '111.88.96.54': '111.88.96.54 (Xbox DNS)',
  '111.88.96.55': '111.88.96.55 (Xbox DNS backup)',
  '1.1.1.1': '1.1.1.1 (Cloudflare DNS)',
  '1.0.0.1': '1.0.0.1 (Cloudflare DNS)',
  '8.8.8.8': '8.8.8.8 (Google DNS)',
  '8.8.4.4': '8.8.4.4 (Google DNS)',
  '9.9.9.9': '9.9.9.9 (Quad9 DNS)',
  '9.9.9.11': '9.9.9.11 (Quad9 DNS)',
};

export const COMMAND_TIMEOUT = 10000; // 10 seconds
