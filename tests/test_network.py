import socket
from types import SimpleNamespace

from devdash import network


def _addr(ip, family=socket.AF_INET):
    return SimpleNamespace(family=family, address=ip)


def _up(isup=True):
    return SimpleNamespace(isup=isup)


def test_lan_ip_prefers_up_en_interfaces_with_private_ipv4():
    addrs = {
        "lo0": [_addr("127.0.0.1")],
        "utun3": [_addr("10.8.0.2")],
        "en1": [_addr("192.168.1.30")],
        "en0": [_addr("fe80::1", socket.AF_INET6), _addr("169.254.10.2"), _addr("192.168.1.24")],
    }
    stats = {"lo0": _up(), "utun3": _up(), "en0": _up(), "en1": _up(False)}
    assert network.pick_lan_ip(addrs, stats) == "192.168.1.24"


def test_lan_ip_none_when_offline():
    assert network.pick_lan_ip({"en0": [_addr("192.168.1.24")]}, {"en0": _up(False)}) is None
    assert network.pick_lan_ip({"en0": [_addr("8.8.8.8")]}, {"en0": _up()}) is None


def test_exposed_bind_addresses():
    lan = "192.168.1.24"
    assert network.is_exposed({"0.0.0.0"}, lan)
    assert network.is_exposed({"::"}, lan)
    assert network.is_exposed({"192.168.1.24"}, lan)
    assert network.is_exposed({"127.0.0.1", "::"}, None)
    assert not network.is_exposed({"127.0.0.1"}, lan)
    assert not network.is_exposed({"::1"}, lan)
    assert not network.is_exposed({"127.0.0.1", "::1", "fe80::1%lo0"}, lan)


def test_server_urls(monkeypatch):
    monkeypatch.setattr(network, "lan_ip", lambda: "192.168.1.24")
    urls = network.server_urls(1, {5173: {"::1"}, 3000: {"::"}}, probe_tls=False)
    assert urls == [
        {"port": 3000, "local": "http://localhost:3000", "lan": "http://192.168.1.24:3000", "exposed": True},
        {"port": 5173, "local": "http://localhost:5173", "lan": None, "exposed": False},
    ]


def test_server_urls_offline(monkeypatch):
    monkeypatch.setattr(network, "lan_ip", lambda: None)
    [url] = network.server_urls(1, {3000: {"0.0.0.0"}}, probe_tls=False)
    assert url["exposed"] and url["lan"] is None


def test_tls_probe_on_closed_port_is_http():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    [url] = network.server_urls(99999, {port: {"127.0.0.1"}}, probe_tls=True)
    assert url["local"] == f"http://localhost:{port}"


def test_expose_hints():
    assert "--host" in network.expose_hint("vite", "vite --port 5173", 5173)
    assert "-H 0.0.0.0" in network.expose_hint("next dev", "next dev", 3000)
    assert "0.0.0.0:8000" in network.expose_hint("manage.py", "python manage.py runserver", 8000)
    assert "0.0.0.0" in network.expose_hint("server.mjs", "node server.mjs", 8765)
    assert "--host 0.0.0.0" in network.expose_hint("storybook", "storybook dev -p 6006", 6006)
    assert "--host 0.0.0.0" in network.expose_hint("rsbuild", "rsbuild dev", 3001)
