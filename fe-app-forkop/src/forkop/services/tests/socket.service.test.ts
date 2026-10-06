import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { socket } from '../socket.service';
import { logger } from '../logger.service';

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static instances: FakeWebSocket[] = [];

  readyState = FakeWebSocket.CONNECTING;
  private listeners = new Map<string, Array<(event: Event) => void>>();

  constructor(_url: string) {
    FakeWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: (event: Event) => void) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  emit(type: string) {
    for (const listener of this.listeners.get(type) || []) {
      listener(new Event(type));
    }
  }

  close() {}
  send() {}
}

describe('socket service', () => {
  beforeEach(() => {
    socket.resetAll();
    FakeWebSocket.instances = [];
    vi.stubGlobal('WebSocket', FakeWebSocket);
  });

  afterEach(() => {
    socket.resetAll();
    vi.unstubAllGlobals();
  });

  it('keeps the initial subscriber when the first connection fails', () => {
    const onError = vi.fn();

    socket.subscribe('ws://router.test', vi.fn(), onError);
    FakeWebSocket.instances[0].emit('error');

    expect(onError).toHaveBeenCalledOnce();
  });

  it('does not report an intentional disconnect as a socket failure', () => {
    const onError = vi.fn();
    const warning = vi
      .spyOn(logger, 'warn')
      .mockImplementation(() => undefined);

    socket.subscribe('ws://router.test/connections', vi.fn(), onError);
    const ws = FakeWebSocket.instances[0];
    socket.disconnect('ws://router.test/connections');
    ws.emit('close');

    expect(onError).not.toHaveBeenCalled();
    expect(warning).not.toHaveBeenCalled();
    warning.mockRestore();
  });

  it('does not report a full reset as a socket failure', () => {
    const onError = vi.fn();
    const warning = vi
      .spyOn(logger, 'warn')
      .mockImplementation(() => undefined);

    socket.subscribe('ws://router.test/traffic', vi.fn(), onError);
    const ws = FakeWebSocket.instances[0];
    socket.resetAll();
    ws.emit('close');

    expect(onError).not.toHaveBeenCalled();
    expect(warning).not.toHaveBeenCalled();
    warning.mockRestore();
  });

  it('still reports an unexpected disconnect to the subscriber', () => {
    const onError = vi.fn();
    const warning = vi
      .spyOn(logger, 'warn')
      .mockImplementation(() => undefined);

    socket.subscribe('ws://router.test/connections', vi.fn(), onError);
    FakeWebSocket.instances[0].emit('close');

    expect(onError).toHaveBeenCalledWith('Connection closed');
    expect(warning).toHaveBeenCalledOnce();
    warning.mockRestore();
  });

  // UC-036: the Clash secret travels as the token query parameter of the
  // controller WebSocket URL; it must never reach the console or the logger.
  it('never logs the query string of a socket URL', () => {
    const spies = [
      vi.spyOn(console, 'info').mockImplementation(() => undefined),
      vi.spyOn(console, 'warn').mockImplementation(() => undefined),
      vi.spyOn(console, 'error').mockImplementation(() => undefined),
      vi.spyOn(console, 'log').mockImplementation(() => undefined),
    ];
    logger.clear();

    const url = 'ws://router.test:9090/traffic?token=TOP-SECRET';
    socket.subscribe(url, vi.fn(), vi.fn());
    const ws = FakeWebSocket.instances[0];
    ws.emit('open');
    ws.emit('error');
    ws.emit('close');
    socket.send(url, 'x');

    const printed = spies
      .flatMap((spy) => spy.mock.calls)
      .map((args) => args.join(' '))
      .join('\n');
    expect(printed).toContain('ws://router.test:9090/traffic');
    expect(printed).not.toContain('TOP-SECRET');
    expect(printed).not.toContain('token=');
    expect(logger.getLogs()).not.toContain('TOP-SECRET');

    for (const spy of spies) spy.mockRestore();
  });
});
