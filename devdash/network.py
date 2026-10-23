"""Local and network URLs for dev servers.

A server is reachable from other devices (a phone on the same Wi-Fi) only when it listens on all
interfaces or on the Mac's LAN address. Most dev servers listen on loopback by default.
"""
from __future__ import annotations

import ipaddress
import re
import socket
import ssl
import time

import psutil

LAN_IP_TTL = 30.0
PROBE_TIMEOUT = 0.1

_lan_ip: tuple[float, str | None] = (0.0, None)
_tls_cache: dict[tuple[int, int], bool] = {}


def pick_lan_ip(addrs: dict, stats: dict) -> str | None:
    """The first private IPv4 address on an `en*` interface that is up (Wi-Fi or Ethernet).

    VPN tunnels (`utun*`), bridges and loopback are skipped: a phone can't reach those.
    """
    for name in sorted(addrs):
        if not name.startswith("en"):
            continue
        stat = stats.get(name)
        if stat is None or not stat.isup:
            continue
        for addr in addrs[name]:
            if addr.family != socket.AF_INET:
                continue
            try:
                ip = ipaddress.IPv4Address(addr.address)
            except ValueError:
                continue
            if ip.is_private and not ip.is_loopback and not ip.is_link_local:
                return str(ip)
    return None


def lan_ip() -> str | None:
    """The Mac's address on the local network, cached for 30 seconds."""
    global _lan_ip
    checked, ip = _lan_ip
    if time.monotonic() - checked < LAN_IP_TTL:
        return ip
    try:
        ip = pick_lan_ip(psutil.net_if_addrs(), psutil.net_if_stats())
    except (OSError, psutil.Error):
        ip = None
    _lan_ip = (time.monotonic(), ip)
    return ip


def is_exposed(bind_ips: set[str], lan: str | None) -> bool:
    """Whether a port bound to these addresses accepts connections from other devices."""
    for raw in bind_ips:
        ip = raw.split("%", 1)[0]  # fe80::1%lo0
        if ip in ("0.0.0.0", "::", "*", ""):
            return True
        if lan is not None and ip == lan:
            return True
        try:
            # Link-local addresses (fe80::1%lo0) aren't what a phone connects to either.
            addr = ipaddress.ip_address(ip)
            if not addr.is_loopback and not addr.is_link_local:
                return True
        except ValueError:
            continue
    return False


def _speaks_tls(pid: int, port: int, bind_ips: set[str]) -> bool:
    """A quick TLS handshake against the port, cached per process and port, so Vite with
    `--https` gets an https link."""
    key = (pid, port)
    if key in _tls_cache:
        return _tls_cache[key]
    host = "::1" if bind_ips and all(":" in ip for ip in bind_ips) else "127.0.0.1"
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    result = False
    try:
        with socket.create_connection((host, port), timeout=PROBE_TIMEOUT) as sock:
            with context.wrap_socket(sock, server_hostname="localhost"):
                result = True
    except (OSError, ssl.SSLError, ValueError):
        result = False
    _tls_cache[key] = result
    return result


def forget_exited(pids: set[int]) -> None:
    """Drop probe results for processes that are gone, so a reused PID gets probed again."""
    for key in [k for k in _tls_cache if k[0] not in pids]:
        del _tls_cache[key]


def server_urls(pid: int, binds: dict[int, set[str]], probe_tls: bool) -> list[dict]:
    """One entry per listening port: the localhost URL, and the network URL when other devices can
    reach it. `exposed` is false for ports bound to loopback only; `lan` is also empty when the Mac
    isn't on a network."""
    lan = lan_ip()
    urls = []
    for port in sorted(binds):
        ips = binds[port]
        scheme = "https" if probe_tls and _speaks_tls(pid, port, ips) else "http"
        exposed = is_exposed(ips, lan)
        urls.append({
            "port": port,
            "local": f"{scheme}://localhost:{port}",
            "lan": f"{scheme}://{lan}:{port}" if exposed and lan else None,
            "exposed": exposed,
        })
    return urls


# Matched against the label and command, first match wins.
_EXPOSE_HINTS = (
    (re.compile(r"\bvite\b|\bastro\b|\bnuxt\b|\bsvelte-kit\b|\bremix\b"), "Restart it with --host, for example npm run dev -- --host"),
    (re.compile(r"\bnext\b"), "Restart it with -H 0.0.0.0, for example npm run dev -- -H 0.0.0.0"),
    (re.compile(r"\bng serve\b|@angular|\brsbuild\b|\bstorybook\b|webpack"), "Restart it with --host 0.0.0.0"),
    (re.compile(r"\buvicorn\b|\bfastapi\b|\bflask\b|\bhypercorn\b|\bgranian\b"), "Restart it with --host 0.0.0.0"),
    (re.compile(r"\bgunicorn\b"), "Restart it with --bind 0.0.0.0:PORT"),
    (re.compile(r"\bmanage\.py runserver\b|\brunserver\b"), "Restart it with runserver 0.0.0.0:PORT"),
    (re.compile(r"\brails\b|\bpuma\b"), "Restart it with -b 0.0.0.0"),
    (re.compile(r"\bphp artisan serve\b|\bartisan serve\b"), "Restart it with --host=0.0.0.0"),
    (re.compile(r"\bhugo\b"), "Restart it with --bind 0.0.0.0"),
)


def expose_hint(label: str, command: str, port: int) -> str:
    """How to make a loopback-only server reachable from other devices."""
    text = f"{label} {command}".lower()
    for pattern, hint in _EXPOSE_HINTS:
        if pattern.search(text):
            return hint.replace("PORT", str(port))
    return "Make it listen on 0.0.0.0 instead of localhost or 127.0.0.1"
