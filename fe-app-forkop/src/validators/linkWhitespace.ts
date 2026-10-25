// The fragment after '#' is a display name, not part of the connection
// address, and the backend drops it before parsing the link. Spaces are
// permitted there; whitespace in credentials, host and transport parameters,
// and control characters anywhere in the link are still rejected.
export function hasWhitespaceOutsideName(url: string): boolean {
  return /\s/.test(url.split('#', 1)[0]) || /\p{Cc}/u.test(url);
}
