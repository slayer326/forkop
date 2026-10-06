import { logger } from './logger.service';

// eslint-disable-next-line
type Listener = (data: any) => void;
type ErrorListener = (error: Event | string) => void;

// Socket URLs of the Clash controller carry the secret as the token query
// parameter (UC-036): logs show the URL without its query string.
function loggableUrl(url: string): string {
  return url.split('?')[0];
}

class SocketManager {
  private static instance: SocketManager;
  private sockets = new Map<string, WebSocket>();
  private listeners = new Map<string, Set<Listener>>();
  private connected = new Map<string, boolean>();
  private errorListeners = new Map<string, Set<ErrorListener>>();

  private constructor() {}

  static getInstance(): SocketManager {
    if (!SocketManager.instance) {
      SocketManager.instance = new SocketManager();
    }
    return SocketManager.instance;
  }

  resetAll(): void {
    const sockets = Array.from(this.sockets.entries());
    this.sockets.clear();
    this.listeners.clear();
    this.errorListeners.clear();
    this.connected.clear();

    for (const [url, ws] of sockets) {
      try {
        if (
          ws.readyState === WebSocket.OPEN ||
          ws.readyState === WebSocket.CONNECTING
        ) {
          ws.close();
        }
      } catch (err) {
        logger.error(
          '[SOCKET]',
          `resetAll: failed to close socket ${loggableUrl(url)}`,
          err,
        );
      }
    }

    logger.info('[SOCKET]', 'All connections and state have been reset.');
  }

  connect(url: string): void {
    if (this.sockets.has(url)) return;

    let ws: WebSocket;

    try {
      ws = new WebSocket(url);
    } catch (err) {
      logger.error(
        '[SOCKET]',
        `failed to construct WebSocket for ${loggableUrl(url)}:`,
        err,
      );
      this.triggerError(url, err instanceof Event ? err : String(err));
      return;
    }

    this.sockets.set(url, ws);
    this.connected.set(url, false);
    if (!this.listeners.has(url)) this.listeners.set(url, new Set());
    if (!this.errorListeners.has(url)) this.errorListeners.set(url, new Set());

    ws.addEventListener('open', () => {
      if (this.sockets.get(url) !== ws) return;
      this.connected.set(url, true);
      logger.info('[SOCKET]', 'Connected to', loggableUrl(url));
    });

    ws.addEventListener('message', (event) => {
      const handlers = this.listeners.get(url);
      if (handlers) {
        for (const handler of handlers) {
          try {
            handler(event.data);
          } catch (err) {
            logger.error(
              '[SOCKET]',
              `Handler error for ${loggableUrl(url)}:`,
              err,
            );
          }
        }
      }
    });

    ws.addEventListener('close', () => {
      if (this.sockets.get(url) !== ws) return;
      this.connected.set(url, false);
      logger.warn('[SOCKET]', `Disconnected: ${loggableUrl(url)}`);
      this.triggerError(url, 'Connection closed');
    });

    ws.addEventListener('error', (err) => {
      if (this.sockets.get(url) !== ws) return;
      logger.error('[SOCKET]', `Socket error for ${loggableUrl(url)}:`, err);
      this.triggerError(url, err);
    });
  }

  subscribe(url: string, listener: Listener, onError?: ErrorListener): void {
    if (!this.errorListeners.has(url)) {
      this.errorListeners.set(url, new Set());
    }
    if (onError) {
      this.errorListeners.get(url)?.add(onError);
    }

    if (!this.sockets.has(url)) {
      this.connect(url);
    }

    if (!this.listeners.has(url)) {
      this.listeners.set(url, new Set());
    }
    this.listeners.get(url)?.add(listener);
  }

  unsubscribe(url: string, listener: Listener, onError?: ErrorListener): void {
    this.listeners.get(url)?.delete(listener);
    if (onError) {
      this.errorListeners.get(url)?.delete(onError);
    }
  }

  // eslint-disable-next-line
  send(url: string, data: any): void {
    const ws = this.sockets.get(url);
    if (ws && this.connected.get(url)) {
      ws.send(typeof data === 'string' ? data : JSON.stringify(data));
    } else {
      logger.warn(
        '[SOCKET]',
        `Cannot send: not connected to ${loggableUrl(url)}`,
      );
      this.triggerError(url, 'Not connected');
    }
  }

  disconnect(url: string): void {
    const ws = this.sockets.get(url);
    this.sockets.delete(url);
    this.listeners.delete(url);
    this.errorListeners.delete(url);
    this.connected.delete(url);
    if (ws) {
      ws.close();
    }
  }

  disconnectAll(): void {
    for (const url of this.sockets.keys()) {
      this.disconnect(url);
    }
  }

  private triggerError(url: string, err: Event | string): void {
    const handlers = this.errorListeners.get(url);
    if (handlers) {
      for (const cb of handlers) {
        try {
          cb(err);
        } catch (e) {
          logger.error(
            '[SOCKET]',
            `Error handler threw for ${loggableUrl(url)}:`,
            e,
          );
        }
      }
    }
  }
}

export const socket = SocketManager.getInstance();
