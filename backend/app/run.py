"""One Uvicorn process on loopback plus an explicit private LAN address."""
import argparse
from contextlib import ExitStack
from ipaddress import IPv4Address
import socket

import uvicorn


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lan-host", required=True, help="Private IPv4 address of this PC")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    address = IPv4Address(args.lan_host)
    if not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast:
        parser.error("Use a specific private LAN IPv4 address, not a wildcard or public address")
    if not 1 <= args.port <= 65535:
        parser.error("Invalid port")
    with ExitStack() as stack:
        sockets = []
        for host in ("127.0.0.1", str(address)):
            listener = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
            listener.bind((host, args.port))
            listener.listen(128)
            sockets.append(listener)
        server = uvicorn.Server(uvicorn.Config("app.main:app", port=args.port, log_level="info"))
        server.run(sockets=sockets)


if __name__ == "__main__":
    main()
