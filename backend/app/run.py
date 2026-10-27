"""One Uvicorn process on loopback plus an explicit private LAN address."""
import argparse
from contextlib import ExitStack
from ipaddress import IPv4Address, ip_network
import socket

import uvicorn
from app.core.config import settings


def validated_proxy_ips():
    values = []
    for value in settings.trusted_proxy_ips:
        address = value.strip()
        network = ip_network(address, strict=False)
        if network.prefixlen == 0:
            raise ValueError("All-address proxy trust is forbidden")
        values.append(address)
    return values


def main():
    settings.validate_demo_configuration()
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
        hosts = ("127.0.0.1", str(address)) if settings.backend_lan_enabled else ("127.0.0.1",)
        for host in hosts:
            listener = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
            listener.bind((host, args.port))
            listener.listen(128)
            sockets.append(listener)
        try:
            proxies = validated_proxy_ips()
        except ValueError:
            parser.error("Explicit trusted proxy IPs required; wildcard is forbidden")
        server = uvicorn.Server(uvicorn.Config("app.main:app", port=args.port, log_level="info",
            forwarded_allow_ips=proxies, proxy_headers=True, access_log=not settings.demo_enabled))
        server.run(sockets=sockets)


if __name__ == "__main__":
    main()
