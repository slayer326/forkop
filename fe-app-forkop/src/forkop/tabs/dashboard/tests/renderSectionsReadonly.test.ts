import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../../icons', () => ({
  renderLoaderCircleIcon24: () => 'svg',
  renderInfoIcon24: () => 'svg',
}));
vi.mock('../../../../helpers', () => ({
  svgEl: () => 'svg',
}));

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
}

(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown> = {},
  children: unknown = [],
): FakeNode => ({
  tag,
  attrs: attrs || {},
  children: Array.isArray(children) ? children : [children],
});

function find(
  node: unknown,
  predicate: (node: FakeNode) => boolean,
): FakeNode[] {
  if (!node || typeof node !== 'object') return [];
  const fake = node as FakeNode;
  return [
    ...(predicate(fake) ? [fake] : []),
    ...(fake.children || []).flatMap((child) => find(child, predicate)),
  ];
}

function text(node: unknown): string {
  if (typeof node === 'string') return node;
  if (!node || typeof node !== 'object') return '';
  return ((node as FakeNode).children || []).map(text).join(' ');
}

import { renderSections } from '../partials/renderSections';
import type { Forkop } from '../../../types';

function render(readonly: boolean) {
  const handlers = {
    onTestLatency: vi.fn(),
    onChooseOutbound: vi.fn(),
    onUpdateSubscription: vi.fn(),
  };
  const section: Forkop.OutboundGroup = {
    withTagSelect: true,
    code: 'main-out',
    sectionName: 'main',
    displayName: 'Main',
    subscriptionSourceCount: 1,
    outbounds: [
      {
        code: 'a',
        displayName: 'A',
        latency: 40,
        type: 'vless',
        selected: true,
      },
      {
        code: 'b',
        displayName: 'B',
        latency: 90,
        type: 'vless',
        selected: false,
      },
    ],
  };
  const node = renderSections({
    loading: false,
    failed: false,
    section,
    ...handlers,
    onShowUrlTestInfo: vi.fn(),
    onShowPriorityInfo: vi.fn(),
    latencyFetching: false,
    subscriptionUpdating: false,
    isPriorityMembersExpanded: () => false,
    onPriorityMembersToggle: vi.fn(),
    readonly,
  });
  return { node, handlers };
}

describe('dashboard sections in a read-only session', () => {
  it('renders no runtime controls', () => {
    const { node } = render(true);

    expect(find(node, (n) => n.tag === 'button')).toHaveLength(0);
    expect(text(node)).not.toContain('Test latency');
    expect(text(node)).not.toContain('Update subscriptions');
  });

  it('shows nodes but does not let them be selected', () => {
    const { node, handlers } = render(true);
    const tiles = find(node, (n) =>
      String(n.attrs.class || '').includes('outbound-grid__item '),
    );

    for (const tile of find(node, (n) => typeof n.attrs.click === 'function')) {
      (tile.attrs.click as () => void)();
    }
    expect(handlers.onChooseOutbound).not.toHaveBeenCalled();
    expect(
      tiles.some((tile) => String(tile.attrs.class).includes('--selectable')),
    ).toBe(false);
    expect(
      tiles.some((tile) => String(tile.attrs.class).includes('--disabled')),
    ).toBe(false);
  });

  it('keeps the controls for administrators', () => {
    const { node, handlers } = render(false);

    expect(text(node)).toContain('Test latency');
    expect(text(node)).toContain('Update all subscriptions');
    const selectable = find(node, (n) =>
      String(n.attrs.class || '').includes('--selectable'),
    );
    (selectable[0].attrs.click as () => void)();
    expect(handlers.onChooseOutbound).toHaveBeenCalledWith(
      'main',
      'main-out',
      'b',
    );
  });
});
