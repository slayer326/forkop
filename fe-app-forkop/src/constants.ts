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

// Curated per-game domain/IP lists from YOZH3G/ru-gaming-blocklist, offered as
// suggestions of the "Domain and IP lists" field. The values are plain remote
// list URLs, so the backend needs no preset table of its own. Games already
// covered by the built-in rule sets above (Battle.net, EA, Epic, Riot,
// Roblox, Steam, Ubisoft) and the auxiliary Cloudflare/AWS profile are
// deliberately not duplicated here.
const RU_GAMING_BLOCKLIST =
  'https://raw.githubusercontent.com/YOZH3G/ru-gaming-blocklist/main/games';

export const REMOTE_GAME_LIST_OPTIONS = {
  [`${RU_GAMING_BLOCKLIST}/ApexLegends_RocketLeague.txt`]:
    'Apex Legends / Rocket League',
  [`${RU_GAMING_BLOCKLIST}/Arknights.txt`]: 'Arknights',
  [`${RU_GAMING_BLOCKLIST}/ArmaReforger.txt`]: 'Arma Reforger',
  [`${RU_GAMING_BLOCKLIST}/Battlefield6.txt`]: 'Battlefield 6',
  [`${RU_GAMING_BLOCKLIST}/BlueArchive.txt`]: 'Blue Archive',
  [`${RU_GAMING_BLOCKLIST}/CallOfDuty.txt`]: 'Call of Duty',
  [`${RU_GAMING_BLOCKLIST}/CompanyOfHeroes2.txt`]: 'Company of Heroes 2',
  [`${RU_GAMING_BLOCKLIST}/Darktide.txt`]: 'Warhammer 40,000: Darktide',
  [`${RU_GAMING_BLOCKLIST}/DeadByDaylight.txt`]: 'Dead by Daylight',
  [`${RU_GAMING_BLOCKLIST}/Fallout76_AWS.txt`]: 'Fallout 76',
  [`${RU_GAMING_BLOCKLIST}/GearsOfWar.txt`]: 'Gears of War',
  [`${RU_GAMING_BLOCKLIST}/GooseGooseDuck.txt`]: 'Goose Goose Duck',
  [`${RU_GAMING_BLOCKLIST}/MagicTheGathering.txt`]: 'Magic: The Gathering Arena',
  [`${RU_GAMING_BLOCKLIST}/Minecraft_Extra.txt`]: 'Minecraft',
  [`${RU_GAMING_BLOCKLIST}/MortalKombat1.txt`]: 'Mortal Kombat 1',
  [`${RU_GAMING_BLOCKLIST}/MortalKombat11.txt`]: 'Mortal Kombat 11',
  [`${RU_GAMING_BLOCKLIST}/OutlastTrials.txt`]: 'The Outlast Trials',
  [`${RU_GAMING_BLOCKLIST}/PhotonEngine.txt`]: 'Photon Engine',
  [`${RU_GAMING_BLOCKLIST}/StreetFighter6.txt`]: 'Street Fighter 6',
  [`${RU_GAMING_BLOCKLIST}/VRChat.txt`]: 'VRChat',
  [`${RU_GAMING_BLOCKLIST}/Wardogs.txt`]: 'WARDOGS',
  [`${RU_GAMING_BLOCKLIST}/Warframe.txt`]: 'Warframe',
  [`${RU_GAMING_BLOCKLIST}/WutheringWaves.txt`]: 'Wuthering Waves',
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
