"""Bounded address racing, without changing system DNS/routes or TLS validation."""
import errno
import http.client
import selectors
import socket
import time
import urllib.request

_WINNERS = {}


def connect_addresses(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, source_address=None):
    host, port = address
    timeout = socket.getdefaulttimeout() if timeout is socket._GLOBAL_DEFAULT_TIMEOUT else timeout
    results = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
    endpoints = []
    for family, kind, protocol, _, sockaddr in results:
        item = (family, kind, protocol, sockaddr)
        if item not in endpoints:
            endpoints.append(item)
    previous = _WINNERS.get(address)
    if previous in endpoints:
        endpoints.remove(previous)
        endpoints.insert(0, previous)
    endpoints = endpoints[:16]
    deadline = time.monotonic() + min(timeout if timeout is not None else 10, 10)
    pending, index, winner = {}, 0, None
    next_start = time.monotonic()
    last_error = None
    try:
        with selectors.DefaultSelector() as selector:
            while index < len(endpoints) or pending:
                now = time.monotonic()
                if now >= deadline:
                    raise TimeoutError('Upstream TCP connection timed out')
                if index < len(endpoints) and (now >= next_start or not pending):
                    endpoint = endpoints[index]
                    index += 1
                    family, kind, protocol, sockaddr = endpoint
                    sock = socket.socket(family, kind, protocol)
                    try:
                        sock.setblocking(False)
                        if source_address:
                            sock.bind(source_address)
                        result = sock.connect_ex(sockaddr)
                        if result in (0, errno.EISCONN):
                            winner = sock
                            _WINNERS[address] = endpoint
                            sock.settimeout(timeout)
                            return sock
                        if result not in (errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY, errno.EINTR):
                            raise OSError(result, 'Upstream address connection failed')
                        selector.register(sock, selectors.EVENT_WRITE)
                        pending[sock] = endpoint
                    except OSError as error:
                        last_error = error
                        sock.close()
                    next_start = time.monotonic() + 0.2
                if not pending:
                    continue
                wait = deadline - time.monotonic()
                if index < len(endpoints):
                    wait = min(wait, max(0, next_start - time.monotonic()))
                for key, _ in selector.select(max(0, wait)):
                    sock = key.fileobj
                    endpoint = pending.pop(sock)
                    selector.unregister(sock)
                    result = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                    if result:
                        last_error = OSError(result, 'Upstream address connection failed')
                        sock.close()
                        continue
                    winner = sock
                    _WINNERS[address] = endpoint
                    sock.settimeout(timeout)
                    return sock
        raise last_error or OSError('No usable upstream address')
    finally:
        for sock in pending:
            if sock is not winner:
                sock.close()


class FastHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Only TCP establishment differs. The standard HTTPSConnection.connect
        # still performs SNI, certificate and hostname verification as usual.
        self._create_connection = connect_addresses


class FastHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(FastHTTPSConnection, req, context=self._context)
