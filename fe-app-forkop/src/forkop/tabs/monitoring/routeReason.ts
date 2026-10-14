import { matchedConditions, type MatchMetadata } from './matchedConditions';

const BUILT_IN_LISTS = [
  'russia_inside',
  'russia_outside',
  'ukraine_inside',
  'ads_hagezi_pro',
  'google_play',
  'google_ai',
  'digitalocean',
  'cloudflare',
  'cloudfront',
  'geoblock',
  'telegram',
  'discord',
  'youtube',
  'twitter',
  'github',
  'supercell',
  'hetzner',
  'roblox',
  'hdrezka',
  'tiktok',
  'anime',
  'hodca',
  'meta',
  'news',
  'porn',
  'block',
  'ovh',
];

function builtInListLabel(name: string): string {
  if (name === 'google_ai') return 'Google AI';
  if (name === 'github') return 'GitHub';
  if (name === 'geoblock') return 'Geo Block';
  return name.replace(/_/g, ' ').replace(/^./, (char) => char.toUpperCase());
}

function deviceRouteReason(rule: string): string | undefined {
  const conditions = rule.replace(/\s*=>\s*.*$/, '').trim();
  // Only the generated unconditional source rule, optionally wrapped with
  // device exclusions. Other logical/device filters must retain their meaning.
  const atom =
    'inbound=(?:\\[tproxy-in tproxy6-in\\]|tproxy-in|tproxy6-in) source_ip_cidr=(\\[[^\\]]+\\]|[\\da-fA-F:./]+)';
  const plain = conditions.match(new RegExp(`^${atom}$`));
  const logical = conditions.match(
    new RegExp(
      `^and\\(${atom} !\\(source_ip_cidr=(?:\\[[^\\]]+\\]|[\\da-fA-F:./]+)\\)\\)$`,
    ),
  );
  const source = (plain || logical)?.[1];
  if (!source || /\.\.\.|…/.test(source)) return;
  return source
    .replace(/^\[|\]$/g, '')
    .split(/\s+/)
    .map((value) => value.replace(value.includes(':') ? /\/128$/ : /\/32$/, ''))
    .join(', ');
}

export function formatRouteReason(
  rule = '',
  payload = '',
  translate: (value: string) => string = (value) => value,
  metadata?: MatchMetadata,
  rulesetLabels: Record<string, string> = {},
): string {
  const text = rule.trim();
  if (!text) return translate('Not available');
  if (/^(?:final|match|default)$/i.test(text))
    return translate('Default route');

  const devices = deviceRouteReason(text);
  if (devices) return `${translate('All traffic from device')} · ${devices}`;

  const tags = [...text.matchAll(/rule_set=(?:\[([^\]]*)\]|([^\s)]+))/g)]
    .flatMap((match) => (match[1] || match[2]).split(/[\s,]+/))
    .filter(Boolean);
  if (tags.length) {
    const labels = [...new Set(tags)].map((tag) => {
      if (rulesetLabels[tag]) return rulesetLabels[tag];
      if (tag.match(/-(.+)-community-ruleset$/)) {
        // Section names can contain hyphens; known built-in list suffixes are
        // unambiguous, unlike arbitrary remote rule-set identifiers.
        const service = BUILT_IN_LISTS.find((name) =>
          tag.endsWith(`-${name}-community-ruleset`),
        );
        if (service) return builtInListLabel(service);
      }
      if (tag.endsWith('-community-subnets-lists-ruleset'))
        return translate('Built-in subnets');
      return tag;
    });
    return labels.length === 1
      ? labels[0]
      : `${translate('One of')}: ${labels.join(', ')}`;
  }

  // Keep the actual conditions for inline, device and logical rules. Do not
  // infer a list from the destination hostname or selected outbound.
  const conditions = text.replace(/\s*=>\s*.*$/, '').trim();
  const matched = metadata && matchedConditions(text, metadata);
  if (matched) return matched;
  if (
    metadata &&
    !payload &&
    /\b(?:domain|domain_suffix|domain_keyword|domain_regex|ip_cidr)=/.test(
      conditions,
    )
  )
    return translate('Exact match unavailable');
  return payload ? `${conditions}: ${payload}` : conditions;
}
