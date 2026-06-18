"""Lean build: hard lockdown of all NON-LLM outbound egress.

This fork is built for closed/DLP environments. The ONLY network contact it should make is the
LLM API the operator configures (their proxy/endpoint). Everything else — vendor telemetry,
"phone-home" analytics, and convenience downloads of third-party binaries/scripts — is blocked.

Two mechanisms live here:

1. Telemetry kill-switch (env defaults). Set the moment this module is imported — which is the very
   first thing the package does (see ``testzeus_hercules/__init__``), BEFORE chromadb / huggingface /
   sentry get a chance to initialize. We use ``setdefault`` so an operator can still override.

2. ``block_external_egress()`` — a fail-closed guard the feature tools call right before they reach
   out (nuclei binary download, axe-core CDN fetch, Google Maps, uBlock extension download). It raises
   unless the operator explicitly re-enables external access for the run.

The matching always-on phone-home (Sentry) is removed outright in ``telemetry.py`` — not merely
disabled here — so the hardcoded DSN is not even present in the built artifact.
"""

import os

# --- 1. telemetry kill-switch for transitive dependencies ------------------------------------
# setdefault: only applied if the operator has not already set the variable themselves.
_TELEMETRY_OFF = {
    "ENABLE_TELEMETRY": "0",            # Hercules' own flag (telemetry.py)
    "ANONYMIZED_TELEMETRY": "False",    # chromadb -> posthog
    "CHROMA_TELEMETRY_ENABLED": "False",
    "HF_HUB_DISABLE_TELEMETRY": "1",    # huggingface_hub / transformers / tokenizers
    "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
    "TRANSFORMERS_NO_ADVISORY_WARNINGS": "1",
    "DO_NOT_TRACK": "1",                # consoledonottrack standard (posthog & many CLIs honor it)
    "SCARF_NO_ANALYTICS": "true",       # scarf-gateway redirects in some wheels
    "SENTRY_DSN": "",                   # belt-and-suspenders: empty DSN disables any stray sentry init
}
for _k, _v in _TELEMETRY_OFF.items():
    os.environ.setdefault(_k, _v)


# --- 2. fail-closed guard for feature tools that fetch from the internet ---------------------
ALLOW_FLAG = "HERCULES_ALLOW_EXTERNAL_DOWNLOADS"


def external_allowed() -> bool:
    """True only if the operator explicitly opted back into external access for this run."""
    return os.environ.get(ALLOW_FLAG, "0").strip().lower() in ("1", "true", "yes", "on")


def block_external_egress(what: str, url: str = "") -> None:
    """Raise unless external access is explicitly allowed.

    Called by feature tools right before any non-LLM outbound contact (downloading a third-party
    binary, fetching a script from a CDN, hitting a maps API). In the lean build this fails loud
    instead of silently leaking traffic out of a closed environment.

    Set ``HERCULES_ALLOW_EXTERNAL_DOWNLOADS=1`` to opt back in for a single run.
    """
    if external_allowed():
        return
    target = f" ({url})" if url else ""
    raise RuntimeError(
        f"lean build: outbound network access is disabled — refusing {what}{target}. "
        f"Set {ALLOW_FLAG}=1 to allow it for this run."
    )


# --- 3. netguard: universal, defense-in-depth block of ALL public outbound connections -------
# The targeted guards above cover the egress sites we know about. This catches everything else —
# any library, any HTTP client, any future code path — at the socket layer, so nothing leaks out
# of a closed perimeter even if a call site was missed.
#
# Policy: a TCP connect is ALLOWED only to
#   * loopback / private (RFC1918) / link-local / CGNAT / reserved addresses — i.e. inside the
#     perimeter, where the operator's LLM proxy and in-house infra live; and
#   * hosts explicitly allow-listed via env (the configured LLM/embeddings endpoints), so a cloud
#     model still works.
# Any GLOBALLY-ROUTABLE (public-internet) address is BLOCKED — unless HERCULES_ALLOW_EXTERNAL_DOWNLOADS=1.
import ipaddress as _ipaddress
import socket as _socket
from urllib.parse import urlsplit as _urlsplit

# Env vars whose URLs point at the operator's own LLM/embeddings endpoints (must stay reachable).
_LLM_URL_VARS = ("OPENAI_BASE_URL", "LLM_MODEL_BASE_URL", "EMBED_BASE_URL")
_EXTRA_HOSTS_VAR = "HERCULES_ALLOWED_HOSTS"  # optional CSV of extra allowed hostnames/IPs


def _allowed_hostnames():
    hosts = set()
    for var in _LLM_URL_VARS:
        val = os.environ.get(var, "").strip()
        if not val:
            continue
        host = _urlsplit(val).hostname if "://" in val else val.split(":")[0]
        if host:
            hosts.add(host.lower())
    for h in os.environ.get(_EXTRA_HOSTS_VAR, "").split(","):
        h = h.strip().lower()
        if h:
            hosts.add(h)
    return hosts


_allowed_ip_cache = None


def _allowed_ips():
    """Resolve the allow-listed hostnames to a set of IP strings (cached, via the real resolver)."""
    global _allowed_ip_cache
    if _allowed_ip_cache is not None:
        return _allowed_ip_cache
    ips = set()
    for host in _allowed_hostnames():
        try:
            ipaddress_obj = _ipaddress.ip_address(host)
            ips.add(str(ipaddress_obj))
            continue
        except ValueError:
            pass
        try:
            for info in _socket.getaddrinfo(host, None):
                ips.add(info[4][0])
        except OSError:
            pass
    _allowed_ip_cache = ips
    return ips


def _ip_is_inside_perimeter(ip_str):
    try:
        ip = _ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    # Not "outside" if it's loopback / private / link-local / CGNAT / reserved / unspecified.
    return ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_reserved or ip.is_unspecified


def _host_is_allowed(host):
    """Decide whether a connect target (IP or hostname) is permitted."""
    # Literal IP?
    try:
        _ipaddress.ip_address(host)
        return _ip_is_inside_perimeter(host) or host in _allowed_ips()
    except ValueError:
        pass
    # Hostname: allow if explicitly listed, else if every/any resolved IP is inside the perimeter.
    if host.lower() in _allowed_hostnames():
        return True
    try:
        resolved = {info[4][0] for info in _socket.getaddrinfo(host, None)}
    except OSError:
        return False
    return any(_ip_is_inside_perimeter(ip) or ip in _allowed_ips() for ip in resolved)


def _check_connect_target(family, address):
    # Only police IP sockets; leave AF_UNIX and exotic families alone.
    if family not in (_socket.AF_INET, _socket.AF_INET6):
        return
    if external_allowed():
        return
    try:
        host = address[0]
    except (TypeError, IndexError):
        return
    if _host_is_allowed(host):
        return
    raise RuntimeError(
        f"lean build: blocked outbound connection to public address {host!r}. "
        f"Only loopback/private/allow-listed hosts are reachable. "
        f"Set {ALLOW_FLAG}=1 (or add the host to {_EXTRA_HOSTS_VAR}) to allow it."
    )


def install_netguard():
    """Monkeypatch socket.connect / connect_ex to enforce the egress policy. Idempotent."""
    if getattr(_socket.socket, "_lean_netguard_installed", False):
        return
    _orig_connect = _socket.socket.connect
    _orig_connect_ex = _socket.socket.connect_ex

    def _guarded_connect(self, address, *args, **kwargs):
        _check_connect_target(self.family, address)
        return _orig_connect(self, address, *args, **kwargs)

    def _guarded_connect_ex(self, address, *args, **kwargs):
        _check_connect_target(self.family, address)
        return _orig_connect_ex(self, address, *args, **kwargs)

    _socket.socket.connect = _guarded_connect
    _socket.socket.connect_ex = _guarded_connect_ex
    _socket.socket._lean_netguard_installed = True


install_netguard()
