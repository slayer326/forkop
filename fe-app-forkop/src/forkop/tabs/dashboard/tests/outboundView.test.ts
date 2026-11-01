import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../../icons', () => ({
  renderLoaderCircleIcon24: () => 'loader-svg',
  renderInfoIcon24: () => 'svg',
  renderCopyIcon24: () => 'copy-svg',
  renderRotateCcwIcon24: () => 'retest-svg',
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

import {
  arrangeOutbounds,
  getVisibleLinks,
  loadOutboundView,
  OutboundViewOptions,
  saveOutboundView,
} from '../outboundView';
import { renderSections } from '../partials/renderSections';
import type { Forkop } from '../../../types';

function node(
  code: string,
  latency: number,
  extra: Partial<Forkop.Outbound> = {},
): Forkop.Outbound {
  return {
    code,
    displayName: code.toUpperCase(),
    latency,
    type: 'vless',
    selected: false,
    link: `vless://${code}@example.com:443#${code}`,
    ...extra,
  };
}

const auto = node('auto', 120, {
  type: 'URLTest',
  link: undefined,
  urlTestInfo: {
    code: 'auto',
    displayName: 'Auto',
    outbounds: [],
  } as unknown as Forkop.UrlTestInfo,
});

function outbounds() {
  return [
    auto,
    node('slow', 900),
    node('dead', 0),
    node('fast', 200),
    node('chosen', 0, { selected: true }),
    node('mid', 450),
  ];
}

const codes = (items: Forkop.Outbound[]) => items.map((item) => item.code);

describe('arranging the node grid', () => {
  it('keeps the order the dashboard gave by default', () => {
    const result = arrangeOutbounds(outbounds(), {
      sortByLatency: false,
      hideWithoutLatency: false,
    });
    expect(codes(result.outbounds)).toEqual(codes(outbounds()));
    expect(result.hidden).toBe(0);
  });

  it('sorts servers by latency, untested last, groups first', () => {
    const result = arrangeOutbounds(outbounds(), {
      sortByLatency: true,
      hideWithoutLatency: false,
    });
    expect(codes(result.outbounds)).toEqual([
      'auto',
      'fast',
      'mid',
      'slow',
      'dead',
      'chosen',
    ]);
  });

  it('hides servers without latency but never the group or the chosen one', () => {
    const result = arrangeOutbounds(outbounds(), {
      sortByLatency: false,
      hideWithoutLatency: true,
    });
    expect(codes(result.outbounds)).toEqual([
      'auto',
      'slow',
      'fast',
      'chosen',
      'mid',
    ]);
    expect(result.hidden).toBe(1);
  });

  it('copies the links of the servers shown, in their order', () => {
    const { outbounds: shown } = arrangeOutbounds(outbounds(), {
      sortByLatency: true,
      hideWithoutLatency: true,
    });
    expect(getVisibleLinks(shown)).toEqual([
      'vless://fast@example.com:443#fast',
      'vless://mid@example.com:443#mid',
      'vless://slow@example.com:443#slow',
      'vless://chosen@example.com:443#chosen',
    ]);
  });
});

describe('remembering the grid view', () => {
  function memoryStorage(initial: Record<string, string> = {}) {
    const items = { ...initial };
    return {
      items,
      getItem: (key: string) => items[key] ?? null,
      setItem: (key: string, value: string) => {
        items[key] = value;
      },
    };
  }

  it('keeps each section apart', () => {
    const storage = memoryStorage();
    saveOutboundView(storage, 'main', {
      sortByLatency: true,
      hideWithoutLatency: false,
    });
    expect(loadOutboundView(storage, 'main')).toEqual({
      sortByLatency: true,
      hideWithoutLatency: false,
    });
    expect(loadOutboundView(storage, 'other')).toEqual({
      sortByLatency: false,
      hideWithoutLatency: false,
    });
  });

  it('falls back to the plain view on broken or blocked storage', () => {
    expect(
      loadOutboundView(
        memoryStorage({ 'forkop.dashboard.outboundView': '{oops' }),
        'main',
      ),
    ).toEqual({ sortByLatency: false, hideWithoutLatency: false });
    expect(() =>
      saveOutboundView(
        {
          getItem: () => null,
          setItem: () => {
            throw new Error('QuotaExceededError');
          },
        },
        'main',
        { sortByLatency: true, hideWithoutLatency: true },
      ),
    ).not.toThrow();
  });
});

function render(
  readonly: boolean,
  viewOptions: OutboundViewOptions = {
    sortByLatency: false,
    hideWithoutLatency: false,
  },
  extra: { latencyFetching?: boolean; latencyTestingTag?: string } = {},
) {
  const handlers = {
    onTestLatency: vi.fn(),
    onChooseOutbound: vi.fn(),
    onViewOptionsChange: vi.fn(),
    onCopyLinks: vi.fn(),
  };
  const section: Forkop.OutboundGroup = {
    withTagSelect: true,
    code: 'main-out',
    sectionName: 'main',
    displayName: 'Main',
    outbounds: outbounds(),
  };
  const tree = renderSections({
    loading: false,
    failed: false,
    section,
    ...handlers,
    onShowUrlTestInfo: vi.fn(),
    onShowPriorityInfo: vi.fn(),
    onUpdateSubscription: vi.fn(),
    latencyFetching: extra.latencyFetching ?? false,
    latencyTestingTag: extra.latencyTestingTag,
    subscriptionUpdating: false,
    isPriorityMembersExpanded: () => false,
    onPriorityMembersToggle: vi.fn(),
    readonly,
    viewOptions,
  });
  return { tree, handlers };
}

const click = (button: FakeNode) =>
  (button.attrs.click as (event: unknown) => void)({
    preventDefault: () => {},
    stopPropagation: () => {},
  });
const buttonsLabelled = (tree: unknown, label: string) =>
  find(tree, (n) => n.tag === 'button' && n.attrs['aria-label'] === label);
const cardNames = (tree: unknown) =>
  find(tree, (n) => n.tag === 'b').map((n) => text(n).trim());

describe('the node grid controls', () => {
  it('tests one server from its own card without choosing it', () => {
    const { tree, handlers } = render(false);
    const tests = buttonsLabelled(tree, 'Test this node latency');

    // Every server, but not the URLTest group card.
    expect(tests).toHaveLength(5);
    click(tests[0]);
    expect(handlers.onTestLatency).toHaveBeenCalledWith(['slow']);
    expect(handlers.onChooseOutbound).not.toHaveBeenCalled();
  });

  it('shows which card started the running test and blocks the others', () => {
    const { tree } = render(false, undefined, {
      latencyFetching: true,
      latencyTestingTag: 'fast',
    });
    const tests = buttonsLabelled(tree, 'Test this node latency');

    expect(tests.every((button) => button.attrs.disabled === true)).toBe(true);
    expect(tests.map((button) => text(button).trim())).toEqual([
      'retest-svg',
      'retest-svg',
      'loader-svg',
      'retest-svg',
      'retest-svg',
    ]);
  });

  it('copies one link or all links shown', () => {
    const { tree, handlers } = render(false, {
      sortByLatency: true,
      hideWithoutLatency: true,
    });

    click(buttonsLabelled(tree, 'Copy proxy link')[0]);
    expect(handlers.onCopyLinks).toHaveBeenLastCalledWith([
      'vless://fast@example.com:443#fast',
    ]);

    const copyAll = find(
      tree,
      (n) => n.tag === 'button' && text(n).includes('Copy links'),
    );
    expect(text(copyAll[0])).toContain('(4)');
    click(copyAll[0]);
    expect(handlers.onCopyLinks).toHaveBeenLastCalledWith([
      'vless://fast@example.com:443#fast',
      'vless://mid@example.com:443#mid',
      'vless://slow@example.com:443#slow',
      'vless://chosen@example.com:443#chosen',
    ]);
  });

  it('sorts and hides through toggles and says how many are hidden', () => {
    const plain = render(false);
    const sortToggle = find(
      plain.tree,
      (n) => n.tag === 'button' && text(n).includes('Sort by latency'),
    )[0];
    expect(sortToggle.attrs['aria-pressed']).toBe('false');
    click(sortToggle);
    expect(plain.handlers.onViewOptionsChange).toHaveBeenCalledWith({
      sortByLatency: true,
      hideWithoutLatency: false,
    });

    const arranged = render(false, {
      sortByLatency: true,
      hideWithoutLatency: true,
    });
    expect(cardNames(arranged.tree)).toEqual([
      'AUTO',
      'FAST',
      'MID',
      'SLOW',
      'CHOSEN',
    ]);
    expect(text(arranged.tree)).toContain('Hidden without latency: 1');
  });

  it('lets a read-only session arrange the grid but not test or copy', () => {
    const { tree, handlers } = render(true, {
      sortByLatency: true,
      hideWithoutLatency: false,
    });
    // The URLTest details button is informational and stays.
    const buttons = find(
      tree,
      (n) => n.tag === 'button' && n.attrs['aria-label'] !== 'URLTest details',
    );

    expect(buttons.map((button) => text(button).trim())).toEqual([
      'Sort by latency',
      'Hide without latency',
    ]);
    expect(cardNames(tree)[1]).toBe('FAST');
    expect(handlers.onCopyLinks).not.toHaveBeenCalled();
  });
});
