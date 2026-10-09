"""Real loopback socket state; never substitutes the ss client."""

import socket
import sys
import time


def listen(family, address, port):
    listener = socket.socket(family, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    listener.bind((address, port))
    listener.listen(8)
    listener.settimeout(5)
    return listener


def connect(listener, family, address, port):
    client = socket.socket(family, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect((address, port))
    server, _ = listener.accept()
    server.settimeout(5)
    return client, server


if sys.argv[1] == "timewait":
    for family, address, port, count in (
        (socket.AF_INET, "127.0.0.1", 23456, 3),
        (socket.AF_INET, "127.0.0.1", 23457, 2),
        (socket.AF_INET6, "::1", 23458, 2),
    ):
        with listen(family, address, port) as listener:
            for _ in range(count):
                client, server = connect(listener, family, address, port)
                with client, server:
                    # The client actively closes and owns the TIME-WAIT row.
                    client.shutdown(socket.SHUT_WR)
                    assert server.recv(1) == b""
                    server.close()
                    assert client.recv(1) == b""
elif sys.argv[1] == "established":
    sockets = []
    for family, address, port in (
        (socket.AF_INET, "127.0.0.1", 23456),
        (socket.AF_INET6, "::1", 23458),
    ):
        listener = listen(family, address, port)
        client, server = connect(listener, family, address, port)
        sockets.extend((listener, client, server))
    print("ready", flush=True)
    time.sleep(600)
else:
    raise ValueError("unknown socket fixture mode")
