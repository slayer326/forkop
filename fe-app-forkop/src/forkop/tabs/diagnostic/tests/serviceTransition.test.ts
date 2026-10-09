import { describe, expect, it } from 'vitest';
import {
  serviceActionErrorText,
  getAvailableActionsDisabledState,
  hasComponentActionLoading,
  hasLocalMutatingServiceActionLoading,
  isServiceTransitionStatus,
  shouldDisableDiagnosticRunAction,
  shouldResetDiagnosticsChecks,
  shouldSkipServicesInfoAutoRefresh,
  shouldShowRestartAction,
  shouldShowStartAction,
  shouldShowStopAction,
} from '../serviceTransition';

const idleActions = {
  restart: { loading: false },
  start: { loading: false },
  stop: { loading: false },
  enable: { loading: false },
  disable: { loading: false },
};

describe('diagnostic service transitions', () => {
  it('treats service transition status as a UI transition', () => {
    expect(isServiceTransitionStatus('starting')).toBe(true);
    expect(isServiceTransitionStatus('reloading')).toBe(true);
    expect(isServiceTransitionStatus('running & enabled')).toBe(false);
  });

  it('detects only local button loading as local mutation', () => {
    expect(hasLocalMutatingServiceActionLoading(idleActions)).toBe(false);
    expect(
      hasLocalMutatingServiceActionLoading({
        ...idleActions,
        start: { loading: true },
      }),
    ).toBe(true);
  });

  it('does not let backend transition status block polling forever', () => {
    expect(
      shouldSkipServicesInfoAutoRefresh({
        force: false,
        localMutatingActionLoading: false,
      }),
    ).toBe(false);
  });

  it('does not reset diagnostics checks while a run is active', () => {
    expect(
      shouldResetDiagnosticsChecks({
        resetChecks: true,
        diagnosticsRunLoading: true,
      }),
    ).toBe(false);
    expect(
      shouldResetDiagnosticsChecks({
        resetChecks: true,
        diagnosticsRunLoading: false,
      }),
    ).toBe(true);
    expect(
      shouldResetDiagnosticsChecks({
        resetChecks: false,
        diagnosticsRunLoading: false,
      }),
    ).toBe(false);
  });

  it('still lets local button actions suppress non-forced polling', () => {
    expect(
      shouldSkipServicesInfoAutoRefresh({
        force: false,
        localMutatingActionLoading: true,
      }),
    ).toBe(true);
    expect(
      shouldSkipServicesInfoAutoRefresh({
        force: true,
        localMutatingActionLoading: true,
      }),
    ).toBe(false);
  });

  it('allows diagnostics even when service state or provider info is unavailable', () => {
    expect(
      shouldDisableDiagnosticRunAction({
        mutatingServiceActionLoading: false,
      }),
    ).toBe(false);
    expect(
      shouldDisableDiagnosticRunAction({
        mutatingServiceActionLoading: true,
      }),
    ).toBe(true);
  });

  it('detects running component actions', () => {
    expect(
      hasComponentActionLoading({
        forkopCheck: { loading: false },
        zapretInstall: { loading: true },
      }),
    ).toBe(true);
  });

  it('blocks mutating available actions while component actions are running', () => {
    expect(
      getAvailableActionsDisabledState({
        servicesInfoLoading: false,
        mutatingServiceActionLoading: false,
        componentActionLoading: true,
      }),
    ).toEqual({
      serviceControlsDisabled: true,
      utilityActionsDisabled: true,
      viewLogsDisabled: false,
    });
  });

  it('keeps logs available during service-only mutations', () => {
    expect(
      getAvailableActionsDisabledState({
        servicesInfoLoading: false,
        mutatingServiceActionLoading: true,
        componentActionLoading: false,
      }),
    ).toEqual({
      serviceControlsDisabled: true,
      utilityActionsDisabled: true,
      viewLogsDisabled: false,
    });
  });
});

describe('service action errors', () => {
  it('names the failure and keeps the backend detail', () => {
    expect(serviceActionErrorText(new Error(' init failed '))).toBe(
      'Service action failed: init failed',
    );
    expect(serviceActionErrorText(new Error(''))).toBe('Service action failed');
    expect(serviceActionErrorText('x')).toBe('Service action failed');
  });

  it('withholds restart while sing-box ownership is unclear', () => {
    expect(
      shouldShowRestartAction({
        forkopRunning: true,
        restartBlocked: true,
        restartLoading: false,
        startLoading: false,
        stopLoading: false,
      }),
    ).toBe(false);
    // A restart already under way still shows its progress.
    expect(
      shouldShowRestartAction({
        forkopRunning: true,
        restartBlocked: true,
        restartLoading: true,
        startLoading: false,
        stopLoading: false,
      }),
    ).toBe(true);
  });

  it('offers stop, not start, while a stray runtime is still up', () => {
    // Forkop reports unhealthy, but something is still intercepting traffic.
    expect(
      shouldShowStopAction({
        forkopRunning: false,
        restartLoading: false,
        startLoading: false,
        stopAvailable: true,
        stopLoading: false,
      }),
    ).toBe(true);
    expect(
      shouldShowStartAction({
        forkopRunning: false,
        restartLoading: false,
        startLoading: false,
        stopAvailable: true,
        stopLoading: false,
      }),
    ).toBe(false);
  });
});
