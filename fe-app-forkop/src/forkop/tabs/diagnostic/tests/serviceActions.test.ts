import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../../partials', () => ({
  renderButton: ({
    text,
    disabled,
    onClick,
  }: {
    text: string;
    disabled: boolean;
    onClick: () => void;
  }) => ({ text, disabled, onClick }),
}));

(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown>,
  children: unknown[],
) => ({ tag, attrs, children });
(globalThis as unknown as { _: unknown })._ = (value: string) => value;

import { renderServiceActions } from '../partials/renderServiceActions';

const click = vi.fn();
const action = (visible: boolean, disabled = false) => ({
  visible,
  disabled,
  loading: false,
  onClick: click,
});

describe('diagnostic service controls', () => {
  it('offers start and autostart while stopped', () => {
    const view = renderServiceActions({
      start: action(true),
      restart: action(false),
      stop: action(false),
      autostart: { ...action(true), enabled: false },
    }) as unknown as { children: { text: string; disabled: boolean }[] };

    expect(view.children.map((button) => button.text)).toEqual([
      'Start Forkop X',
      'Enable autostart',
    ]);
  });

  it('offers restart, stop and autostart while running', () => {
    const view = renderServiceActions({
      start: action(false),
      restart: action(true),
      stop: action(true),
      autostart: { ...action(true), enabled: true },
    }) as unknown as { children: { text: string; disabled: boolean }[] };

    expect(view.children.map((button) => button.text)).toEqual([
      'Restart Forkop X',
      'Stop Forkop X…',
      'Disable autostart',
    ]);
  });

  it('keeps controls disabled during another service action', () => {
    const view = renderServiceActions({
      start: action(false),
      restart: action(true, true),
      stop: action(true, true),
      autostart: { ...action(true, true), enabled: true },
    }) as unknown as { children: { disabled: boolean }[] };

    expect(view.children.every((button) => button.disabled)).toBe(true);
  });
});
