import { describe, expect, it } from 'vitest';

import {
  describeStatus,
  eventOutcomeView,
  provenanceLabel,
  statusLabel,
  statusTone,
  toEventOutcome,
  toSemantic,
  type SemanticStatus,
  type StatusDomain,
} from '../status';

// Every raw value the backend or the current UI produces today.
const RAW_VALUES: Record<StatusDomain, Record<string, SemanticStatus>> = {
  health: {
    ok: 'healthy',
    warning: 'warning',
    error: 'error',
    transitioning: 'busy',
    recovered: 'warning',
    unknown: 'unknown',
  },
  check: {
    success: 'healthy',
    warning: 'warning',
    error: 'error',
    loading: 'busy',
    skipped: 'not_checked',
    unsupported: 'unsupported',
  },
  connectivity: {
    ok: 'healthy',
    timeout: 'warning',
    error: 'error',
    idle: 'not_checked',
    running: 'busy',
    invalid: 'error',
  },
  service: {
    'running & enabled': 'healthy',
    'running but disabled': 'healthy',
    'stopped but enabled': 'error',
    'stopped & disabled': 'off',
    starting: 'busy',
    stopping: 'busy',
    restarting: 'busy',
    reloading: 'busy',
  },
  availability: {
    running: 'healthy',
    stopped: 'off',
    loading: 'busy',
    unavailable: 'unknown',
  },
  component: {
    latest: 'healthy',
    outdated: 'warning',
    dev: 'warning',
    recovered: 'warning',
    '': 'not_checked',
  },
  snapshot: {
    created: 'healthy',
    existing: 'healthy',
    deleted: 'healthy',
    success: 'healthy',
    confirmed: 'healthy',
    no_change: 'healthy',
    recovered: 'warning',
    stale: 'warning',
    busy: 'busy',
    failed: 'error',
    needs_attention: 'needs_attention',
  },
};

describe('toSemantic', () => {
  for (const [domain, values] of Object.entries(RAW_VALUES)) {
    for (const [raw, expected] of Object.entries(values)) {
      it(`${domain}: ${raw || '(empty)'} → ${expected}`, () => {
        expect(toSemantic(domain as StatusDomain, raw)).toBe(expected);
      });
    }
  }

  it('maps unknown raw values and null to unknown, never to healthy', () => {
    expect(toSemantic('health', 'bogus')).toBe('unknown');
    expect(toSemantic('check', null)).toBe('unknown');
    expect(toSemantic('snapshot', undefined)).toBe('unknown');
  });

  it('treats a missing component check as not checked', () => {
    expect(toSemantic('component', undefined)).toBe('not_checked');
  });
});

describe('labels and tones', () => {
  const all: SemanticStatus[] = [
    'healthy',
    'warning',
    'error',
    'needs_attention',
    'busy',
    'not_checked',
    'unsupported',
    'off',
    'unknown',
  ];

  it('gives every semantic status a label and a tone', () => {
    for (const status of all) {
      expect(statusLabel(status)).toBeTruthy();
      expect(statusTone(status)).toBeTruthy();
    }
  });

  it('colours needs_attention as an error and not-applicable states as muted', () => {
    expect(statusTone('needs_attention')).toBe('error');
    expect(statusTone('unsupported')).toBe('muted');
    expect(statusTone('off')).toBe('muted');
    expect(statusTone('not_checked')).toBe('neutral');
  });

  it('keeps contextual labels for results that are more than a state', () => {
    expect(describeStatus('health', 'recovered')).toEqual({
      status: 'warning',
      label: 'Recovered',
      tone: 'warning',
    });
    expect(describeStatus('check', 'loading').label).toBe('Checking…');
    expect(describeStatus('health', 'ok').label).toBe('Healthy');
    // Stopped by the user is not a failure (D-15).
    expect(describeStatus('health', 'stopped')).toEqual({
      status: 'off',
      label: 'Stopped by user',
      tone: 'muted',
    });
    // Nor is Forkop not started since boot (D-15).
    expect(describeStatus('health', 'not_started')).toEqual({
      status: 'off',
      label: 'Not started',
      tone: 'muted',
    });
  });
});

describe('event outcomes', () => {
  it('maps recorded event statuses to outcomes', () => {
    expect(toEventOutcome('success')).toBe('succeeded');
    expect(toEventOutcome('recovered')).toBe('recovered');
    expect(toEventOutcome('failure')).toBe('failed');
    expect(toEventOutcome('needs_attention')).toBe('needs_attention');
    expect(toEventOutcome('rolled_back')).toBe('rolled_back');
    expect(toEventOutcome('stale')).toBe('cancelled');
    expect(toEventOutcome('not_started')).toBe('not_started');
    expect(toEventOutcome('???')).toBe('unknown');
  });

  it('never shows an unknown outcome as a success', () => {
    expect(eventOutcomeView('unknown').tone).toBe('neutral');
    // A restore while Forkop was stopped by the user was not verified.
    expect(eventOutcomeView('not_started')).toEqual({
      label: 'Saved, service stopped',
      tone: 'warning',
    });
    expect(eventOutcomeView('needs_attention').tone).toBe('error');
    expect(eventOutcomeView('rolled_back').tone).toBe('warning');
  });
});

describe('provenance', () => {
  it('labels every provenance', () => {
    expect(provenanceLabel('observed')).toBe('Observed');
    expect(provenanceLabel('configured')).toBe('From configuration');
    expect(provenanceLabel('simulated')).toBe('Calculated');
    expect(provenanceLabel('unknown')).toBe('Not determined');
  });
});
