# Skill Template (used by phantomagent)

Each skill file provides a tool/capability the AI agents can use.

```yaml
name: "example-scan"
version: "1.0.0"
author: "anonymous"
description: "Run a port scan and describe results in plain language"
category: "network_recon"
tools:
  - name: "port_scan"
    description: "Scan a host for open ports using nmap"
    signature: "port_scan(target, ports='1-1000', args='') -> str"
```

```python
# Tool implementation (python)
def port_scan(target: str, ports: str = "1-1000", args: str = "") -> str:
    """Scan a host for open ports using nmap."""
    import subprocess, json
    cmd = f"nmap -sT -p {ports} {args} {target}"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300)
    return result.stdout + result.stderr
```

---
## Skill file structure

A skill is a Python module that lives in `/skills/`. Agents load them at runtime:
1. Scan `/skills/**/*.py` (and `.yaml` metadata).
2. Register each function with its docstring/metadata as an available tool.
3. On agent request, execute the skill and return output.

All skill results are written to `/results/skills/`.
