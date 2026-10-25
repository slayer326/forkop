type SingBoxVariantFields = {
  sing_box_version?: string;
  sing_box_extended?: number;
  sing_box_tiny?: number;
  sing_box_compressed?: number;
  sing_box_tailscale?: number;
  sing_box_podkop_engine?: number;
  sing_box_podkop_engine_full?: number;
};

export function isExtendedSingBoxVersion(version?: string) {
  return String(version || '').includes('extended');
}

// podkop-engine reports <sing-box version>-pdk-r<revision>.
export function isPodkopEngineSingBoxVersion(version?: string) {
  return String(version || '').includes('-pdk-');
}

function isVersionPlaceholder(version?: string) {
  const normalized = String(version || '')
    .trim()
    .toLowerCase();

  if (
    !normalized ||
    normalized === 'loading' ||
    normalized === 'unknown' ||
    normalized === 'not installed'
  ) {
    return true;
  }

  return (
    (typeof _ === 'function' && normalized === _('unknown').toLowerCase()) ||
    (typeof _ === 'function' && normalized === _('Not installed').toLowerCase())
  );
}

export function formatSingBoxVersion(value: SingBoxVariantFields) {
  const version = String(value.sing_box_version || '');

  if (!version || version === 'not installed') {
    return _('Not installed');
  }

  if (isVersionPlaceholder(version)) {
    return version;
  }

  const normalizedValue = normalizeSingBoxVariantFields(value);
  let variant = '';

  if (
    normalizedValue.sing_box_extended &&
    normalizedValue.sing_box_compressed
  ) {
    variant = _('compressed');
  } else if (normalizedValue.sing_box_podkop_engine_full) {
    variant = 'podkop-engine-full';
  } else if (normalizedValue.sing_box_podkop_engine) {
    variant = 'podkop-engine';
  } else if (normalizedValue.sing_box_tiny) {
    variant = _('tiny');
  }

  return variant ? `${version} (${variant})` : version;
}

export function normalizeSingBoxVariantFields<T extends SingBoxVariantFields>(
  value: T,
): T {
  const versionExtended = isExtendedSingBoxVersion(value.sing_box_version);
  const singBoxExtended = Boolean(value.sing_box_extended) || versionExtended;
  const podkopEngine =
    !singBoxExtended &&
    (Boolean(value.sing_box_podkop_engine) ||
      isPodkopEngineSingBoxVersion(value.sing_box_version));

  return {
    ...value,
    sing_box_extended: singBoxExtended ? 1 : 0,
    sing_box_tiny:
      singBoxExtended || podkopEngine ? 0 : value.sing_box_tiny ? 1 : 0,
    sing_box_podkop_engine: podkopEngine ? 1 : 0,
    sing_box_podkop_engine_full:
      podkopEngine && value.sing_box_podkop_engine_full ? 1 : 0,
    sing_box_compressed: singBoxExtended && value.sing_box_compressed ? 1 : 0,
    sing_box_tailscale: singBoxExtended || value.sing_box_tailscale ? 1 : 0,
  } as T;
}
