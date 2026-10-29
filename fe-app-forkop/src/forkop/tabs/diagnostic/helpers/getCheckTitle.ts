// Whole phrases, so every language can order the words itself.
export function getCheckTitle(name: string) {
  switch (name) {
    case 'DNS':
      return _('DNS checks');
    case 'Sing-box':
      return _('sing-box checks');
    case 'Nftables':
      return _('nftables checks');
    case 'Outbounds':
      return _('Outbound checks');
    case 'FakeIP':
      return _('FakeIP checks');
    default:
      return name;
  }
}
