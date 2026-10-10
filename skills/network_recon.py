"""
Network reconnaissance skills for PhantomixAgent.
Loaded at runtime from /skills/ and registered as agent tools.
"""

import subprocess
import json
import os
import re
from typing import Dict, List, Any


def _run(cmd: str, timeout: int = 300) -> str:
    """Execute a shell command and return combined stdout+stderr."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return f"[TIMEOUT after {timeout}s] {cmd}"
    except Exception as e:
        return f"[ERROR] {e}"


def host_discovery(target: str) -> str:
    """
    Discover live hosts in a range. Returns list of alive IPs.

    Args:
        target: CIDR range (e.g. "192.168.1.0/24") or single IP.

    Returns:
        JSON list of alive IPs with basic info.
    """
    # Try ping sweep first (fast), then nmap host discovery as fallback
    cmd = f"nmap -sn -n -T4 {target}"
    output = _run(cmd, timeout=180)

    alive = []
    for match in re.finditer(r"Nmap scan report for (\d+\.\d+\.\d+\.\d+)", output):
        alive.append(match.group(1))

    if not alive:
        # Fallback: use ping broadcast
        ping_out = _run(f"ping -c1 -W1 {target}", timeout=60)
        for match in re.finditer(r"from (\d+\.\d+\.\d+\.\d+)", ping_out):
            alive.append(match.group(1))

    return json.dumps({"alive_hosts": sorted(set(alive)), "count": len(set(alive))})


def port_scan(target: str, ports: str = "1-1000", scan_type: str = "-sT") -> str:
    """
    Scan a host for open ports with nmap.

    Args:
        target: Target IP or hostname.
        ports: Port range (e.g. "1-1000", "22,80,443", "-top-ports 1000").
        scan_type: nmap scan type (-sT TCP connect, -sS SYN, -sU UDP).

    Returns:
        Raw nmap output plus parsed open ports.
    """
    cmd = f"nmap {scan_type} -p {ports} -n -T4 {target}"
    output = _run(cmd, timeout=300)

    # Parse open ports
    open_ports = []
    for match in re.finditer(r"^(\d+)/(\w+)\s+(\w+)\s+(.*)$", output, re.MULTILINE):
        port, proto, state, service = match.groups()
        if state == "open":
            open_ports.append(
                {"port": int(port), "proto": proto, "service": service.strip()}
            )

    return json.dumps({"target": target, "open_ports": open_ports, "raw": output})


def service_detection(target: str, ports: str = "-") -> str:
    """
    Detect service versions on a host.

    Args:
        target: Target IP or hostname.
        ports: Ports to scan (default all detected as open).

    Returns:
        JSON with detected services and versions.
    """
    cmd = f"nmap -sV -n -T4 {'' if ports == '-' else '-p ' + ports} {target}"
    output = _run(cmd, timeout=300)

    services = []
    for match in re.finditer(
        r"^(\d+)/(\w+)\s+(\w+)\s+(.*?)\s*(?=\d+/\w+\s|$)", output, re.MULTILINE
    ):
        port, proto, state, service = match.groups()
        if state == "open":
            services.append(
                {
                    "port": int(port),
                    "proto": proto,
                    "version": service.strip(),
                }
            )

    return json.dumps({"target": target, "services": services})


def os_fingerprint(target: str) -> str:
    """
    Fingerprint target OS using nmap -O.

    Args:
        target: Target IP.

    Returns:
        Detected OS string or "unknown".
    """
    cmd = f"nmap -O --osscan-limit -n -T4 {target}"
    output = _run(cmd, timeout=300)

    for match in re.finditer(r"OS details: (.+)", output):
        return json.dumps({"os": match.group(1).strip(), "raw": output})

    return json.dumps({"os": "unknown", "raw": output})


def http_enum(url: str) -> str:
    """
    Basic HTTP enumeration: title, headers, status.

    Args:
        url: URL to probe (e.g. "http://192.168.1.1").

    Returns:
        JSON with HTTP status, title, and key headers.
    """
    output = _run(f"curl -s -i -L --max-time 15 '{url}'", timeout=30)

    status = None
    title = None
    server = None
    headers = {}

    for line in output.split("\n"):
        line = line.strip()
        if line.startswith("HTTP/"):
            parts = line.split()
            if len(parts) > 1:
                status = int(parts[1])
        elif ":" in line and not line.startswith("<"):
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            if key.lower() == "server":
                server = val
            if key.lower() in ("x-powered-by", "content-type", "x-frame-options"):
                headers[key] = val

    title_match = re.search(r"<title[^>]*>(.*?)</title>", output, re.IGNORECASE | re.DOTALL)

    return json.dumps(
        {
            "url": url,
            "status": status,
            "title": title_match.group(1).strip() if title_match else None,
            "server": server,
            "headers": headers,
        }
    )


def dns_enum(domain: str) -> str:
    """
    DNS enumeration: A records, MX, NS, TXT.

    Args:
        domain: Domain name to query.

    Returns:
        JSON with DNS records.
    """
    result = {}

    for rtype in ["A", "MX", "NS", "TXT", "CNAME"]:
        output = _run(f"dig +short {rtype} {domain}", timeout=20)
        records = [line.strip() for line in output.split("\n") if line.strip()]
        if records:
            result[rtype] = records

    # Try zone transfer (often misconfigured)
    ns_out = _run(f"dig +short NS {domain}", timeout=20)
    ns = ns_out.split("\n")[0].strip() if ns_out.strip() else None
    if ns:
        axfr = _run(f"dig axfr {domain} @{ns}", timeout=30)
        if "Transfer failed" not in axfr and axfr.strip():
            result["AXFR"] = axfr.strip()[:500]

    return json.dumps({"domain": domain, "records": result})


# ---- Skill registry ----
SKILLS = [
    {
        "name": "host_discovery",
        "func": host_discovery,
        "description": "Discover live hosts in a CIDR range using nmap ping sweep",
        "category": "network_recon",
    },
    {
        "name": "port_scan",
        "func": port_scan,
        "description": "Scan target for open ports with nmap",
        "category": "network_recon",
    },
    {
        "name": "service_detection",
        "func": service_detection,
        "description": "Detect service versions on target",
        "category": "network_recon",
    },
    {
        "name": "os_fingerprint",
        "func": os_fingerprint,
        "description": "Fingerprint target operating system",
        "category": "network_recon",
    },
    {
        "name": "http_enum",
        "func": http_enum,
        "description": "Enumerate HTTP service: status, title, headers",
        "category": "web_enum",
    },
    {
        "name": "dns_enum",
        "func": dns_enum,
        "description": "Enumerate DNS records for a domain",
        "category": "dns_enum",
    },
]