import { afterEach, describe, expect, it, vi } from 'vitest';

import { Forkop } from '../../../../types';
import { createPriorityMembersState } from '../../priorityMembersState';
import { renderSections } from '../renderSections';

vi.mock('../../../../../icons', () => ({
  renderLoaderCircleIcon24: () => '',
  renderInfoIcon24: () => '',
  renderRotateCcwIcon24: () => '',
  renderCopyIcon24: () => '',
}));
vi.mock('../../../../../helpers', () => ({ svgEl: () => '' }));

afterEach(() => vi.unstubAllGlobals());

describe('Priority member disclosure', () => {
  it('offers member selection, individual probes and Auto without a duplicate card button', () => {
    type Node = {
      tag: string;
      attrs: Record<string, unknown>;
      children: unknown[];
    };
    vi.stubGlobal(
      'E',
      (
        tag: string,
        attrs: Record<string, unknown> = {},
        children: unknown = [],
      ) => ({
        tag,
        attrs: attrs || {},
        children: Array.isArray(children) ? children : [children],
        addEventListener: () => {},
      }),
    );
    const find = (node: unknown, predicate: (n: Node) => boolean): Node[] => {
      if (!node || typeof node !== 'object') return [];
      const n = node as Node;
      return [
        ...(predicate(n) ? [n] : []),
        ...(n.children || []).flatMap((c) => find(c, predicate)),
      ];
    };
    const text = (node: unknown): string =>
      typeof node === 'string'
        ? node
        : node && typeof node === 'object'
          ? ((node as Node).children || []).map(text).join('')
          : '';
    const choose = vi.fn(),
      probe = vi.fn();
    const render = (readonly: boolean) =>
      renderSections({
        loading: false,
        failed: false,
        readonly,
        section: {
          code: 'main-out',
          sectionName: 'main',
          displayName: 'Main',
          withTagSelect: true,
          outbounds: [
            {
              code: 'priority',
              type: 'Priority',
              displayName: 'Priority',
              selected: true,
              latency: 12,
              priorityInfo: {
                code: 'priority',
                displayName: 'Priority',
                outbounds: [
                  {
                    code: 'a',
                    displayName: 'Node A',
                    type: 'wireguard',
                    latency: 12,
                    selected: true,
                    levelIndex: 0,
                    levelName: 'Primary',
                  },
                  {
                    code: 'b',
                    displayName: 'Node B',
                    type: 'vless',
                    latency: 80,
                    selected: false,
                    levelIndex: 1,
                    levelName: 'Fallback',
                  },
                ],
              },
            },
          ],
        },
        onChooseOutbound: choose,
        onTestLatency: probe,
        onShowUrlTestInfo: () => {},
        onShowPriorityInfo: () => {},
        onUpdateSubscription: () => {},
        latencyFetching: false,
        subscriptionUpdating: false,
        isPriorityMembersExpanded: () => true,
        onPriorityMembersToggle: () => {},
      });
    const tree = render(false);
    const event = { stopPropagation: vi.fn(), preventDefault: vi.fn() };
    const member = find(
      tree,
      (n) => n.tag === 'button' && text(n) === 'Node B',
    )[0];
    (member.attrs.click as (e: unknown) => void)(event);
    expect(choose).toHaveBeenLastCalledWith(
      'main',
      'priority',
      'b',
      'priority-manual',
    );
    const automatic = find(
      tree,
      (n) => n.tag === 'button' && text(n) === 'Auto',
    )[0];
    (automatic.attrs.click as (e: unknown) => void)(event);
    expect(choose).toHaveBeenLastCalledWith(
      'main',
      'priority',
      'priority',
      'priority-auto',
    );
    const individual = find(
      tree,
      (n) => n.attrs.title === 'Test this node latency',
    );
    expect(individual).toHaveLength(2);
    (individual[1].attrs.click as (e: unknown) => void)(event);
    expect(probe).toHaveBeenLastCalledWith(['b']);
    expect(
      find(tree, (n) => n.tag === 'button' && text(n) === 'Select node'),
    ).toHaveLength(0);
    const readonly = render(true);
    expect(
      find(
        readonly,
        (n) =>
          n.tag === 'button' && ['Node A', 'Node B', 'Auto'].includes(text(n)),
      ),
    ).toHaveLength(0);
    expect(
      find(readonly, (n) => n.attrs.title === 'Test this node latency'),
    ).toHaveLength(0);
  });

  it('starts collapsed and retains toggles across dashboard card replacements', () => {
    const state = createPriorityMembersState();
    const priority: Forkop.Outbound = {
      code: 'priority',
      displayName: 'Priority',
      latency: 30,
      type: 'Priority',
      selected: true,
      priorityInfo: {
        code: 'priority',
        displayName: 'Priority',
        selectedName: 'Node A',
        outbounds: [
          {
            code: 'node-a',
            displayName: 'Node A',
            latency: 30,
            selected: true,
            type: 'VLESS',
            levelIndex: 0,
            levelName: 'Primary',
          },
        ],
      },
    };
    let detailsAttributes: Record<string, unknown> = {};
    let details: {
      open: boolean;
      listeners: Record<string, () => void>;
    };
    vi.stubGlobal('E', (tag: string, attributes: Record<string, unknown>) => {
      if (tag === 'details') {
        detailsAttributes = attributes;
        details = {
          // Model LuCI's boolean HTML attribute semantics.
          open: attributes.open != null,
          listeners: {},
        };
        return Object.assign(details, {
          addEventListener: (name: string, callback: () => void) => {
            details.listeners[name] = callback;
          },
        });
      }
      return { tag, attributes };
    });
    const render = () => {
      renderSections({
        loading: false,
        failed: false,
        section: {
          code: 'proxy',
          sectionName: 'main',
          displayName: 'Main',
          outbounds: [priority],
          withTagSelect: true,
        },
        onTestLatency: () => {},
        onChooseOutbound: () => {},
        onShowUrlTestInfo: () => {},
        onShowPriorityInfo: () => {},
        onUpdateSubscription: () => {},
        latencyFetching: false,
        subscriptionUpdating: false,
        isPriorityMembersExpanded: (outbound) =>
          state.isExpanded('main', outbound.code),
        onPriorityMembersToggle: (outbound, open) =>
          state.setExpanded('main', outbound.code, open),
      });
    };
    const toggle = (open: boolean) => {
      details.open = open;
      details.listeners.toggle();
    };

    render();
    // LuCI E() must omit this boolean attribute, not write open="false".
    expect(detailsAttributes.open).toBeUndefined();
    expect(details!.open).toBe(false);
    expect(details!.listeners.toggle).toBeTypeOf('function');
    expect(detailsAttributes.ontoggle).toBeUndefined();

    toggle(true);
    render();
    expect(detailsAttributes.open).toBe(true);
    render();
    expect(detailsAttributes.open).toBe(true);

    toggle(false);
    render();
    expect(detailsAttributes.open).toBeUndefined();

    const stopPropagation = vi.fn();
    (detailsAttributes.click as (event: Event) => void)({
      stopPropagation,
    } as unknown as Event);
    expect(stopPropagation).toHaveBeenCalledOnce();
  });

  it('keeps group states independent across sections and ambiguous names', () => {
    const state = createPriorityMembersState();
    state.setExpanded('main', 'priority', true);
    expect(state.isExpanded('other', 'priority')).toBe(false);
    expect(state.isExpanded('main', 'other')).toBe(false);

    state.setExpanded('main:extra', 'priority', true);
    expect(state.isExpanded('main', 'extra:priority')).toBe(false);
    state.setExpanded('main', 'priority', false);
    expect(state.isExpanded('main', 'priority')).toBe(false);
    expect(state.isExpanded('main:extra', 'priority')).toBe(true);
  });
});
