import errno
import socket
import ssl
import types
import unittest
from unittest.mock import patch
import fast_https


class FakeSocket:
    def __init__(self, result=errno.EINPROGRESS):
        self.result = result
        self.closed = False
        self.timeout = None
    def setblocking(self, flag): pass
    def settimeout(self, value): self.timeout = value
    def connect_ex(self, address): return self.result
    def getsockopt(self, *args): return 0
    def close(self): self.closed = True


class Clock:
    now = 0
    def time(self): return self.now


class RaceTests(unittest.TestCase):
    def setUp(self): fast_https._WINNERS.clear()

    def test_second_address_wins_without_waiting_for_first(self):
        sockets = [FakeSocket(), FakeSocket()]
        clock = Clock()
        class Selector:
            def __init__(self): self.registered = []
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def register(self, sock, flags): self.registered.append(sock)
            def unregister(self, sock): self.registered.remove(sock)
            def select(self, delay):
                if len(self.registered) > 1:
                    return [(types.SimpleNamespace(fileobj=sockets[1]), 2)]
                clock.now += delay
                return []
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('192.0.2.1', 443)),
                     (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('192.0.2.2', 443))]
        with patch.object(fast_https.socket, 'getaddrinfo', return_value=addresses), \
             patch.object(fast_https.socket, 'socket', side_effect=sockets), \
             patch.object(fast_https.selectors, 'DefaultSelector', Selector), \
             patch.object(fast_https.time, 'monotonic', clock.time):
            result = fast_https.connect_addresses(('example.test', 443), 30)
        self.assertIs(result, sockets[1])
        self.assertTrue(sockets[0].closed)
        self.assertFalse(sockets[1].closed)
        self.assertEqual(sockets[1].timeout, 30)
        self.assertLess(clock.now, 1)

    def test_all_failed_addresses_are_closed(self):
        sock = FakeSocket(errno.ECONNREFUSED)
        with patch.object(fast_https.socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('192.0.2.1', 443))]), \
             patch.object(fast_https.socket, 'socket', return_value=sock):
            with self.assertRaises(OSError):
                fast_https.connect_addresses(('example.test', 443), 1)
        self.assertTrue(sock.closed)

    def test_tls_validation_remains_enabled(self):
        handler = fast_https.FastHTTPSHandler()
        self.assertTrue(handler._context.check_hostname)
        self.assertEqual(handler._context.verify_mode, ssl.CERT_REQUIRED)
        connection = fast_https.FastHTTPSConnection('example.test', context=handler._context)
        self.assertTrue(connection._context.check_hostname)
        self.assertIs(connection._create_connection, fast_https.connect_addresses)


if __name__ == '__main__': unittest.main()
