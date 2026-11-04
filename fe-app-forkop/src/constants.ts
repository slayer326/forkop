export const FORKOP_UCI_PACKAGE = 'forkop';
export const FORKOP_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
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

// Curated per-game rule sets, converted from YOZH3G/ru-gaming-blocklist by the
// game-rulesets CI workflow into sing-box source rule sets and served from the
// game-rulesets branch via jsDelivr (see SECONDARY_GAME_RULESET_CDN_PREFIX in
// section.js). Games already covered by the vendor rule sets above
// (Battle.net, EA, Epic, Riot, Roblox, Steam, Ubisoft) and the auxiliary
// Cloudflare/AWS profile are deliberately not duplicated here.
export const SECONDARY_GAME_RULESET_OPTIONS = {
  apexlegends_rocketleague: 'Apex Legends / Rocket League',
  arknights: 'Arknights',
  armareforger: 'Arma Reforger',
  battlefield6: 'Battlefield 6',
  bluearchive: 'Blue Archive',
  callofduty: 'Call of Duty',
  companyofheroes2: 'Company of Heroes 2',
  darktide: 'Warhammer 40,000: Darktide',
  deadbydaylight: 'Dead by Daylight',
  fallout76_aws: 'Fallout 76',
  gearsofwar: 'Gears of War',
  goosegooseduck: 'Goose Goose Duck',
  magicthegathering: 'Magic: The Gathering Arena',
  minecraft_extra: 'Minecraft',
  mortalkombat1: 'Mortal Kombat 1',
  mortalkombat11: 'Mortal Kombat 11',
  outlasttrials: 'The Outlast Trials',
  photonengine: 'Photon Engine',
  streetfighter6: 'Street Fighter 6',
  vrchat: 'VRChat',
  wardogs: 'WARDOGS',
  warframe: 'Warframe',
  wutheringwaves: 'Wuthering Waves',
};

export const DNS_SERVER_OPTIONS = {
  '77.88.8.8': '77.88.8.8 (Yandex DNS)',
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
  '1.1.1.1': '1.1.1.1 (Cloudflare DNS)',
  '1.0.0.1': '1.0.0.1 (Cloudflare DNS)',
  '8.8.8.8': '8.8.8.8 (Google DNS)',
  '8.8.4.4': '8.8.4.4 (Google DNS)',
  '9.9.9.9': '9.9.9.9 (Quad9 DNS)',
  '9.9.9.11': '9.9.9.11 (Quad9 DNS)',
};

export const COMMAND_TIMEOUT = 10000; // 10 seconds
