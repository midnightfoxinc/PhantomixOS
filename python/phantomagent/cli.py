#!/usr/bin/env python3
"""
CLI entry point for HackinAgent.
Usage:
  phantomagent --target <host> --scope <network|local>
  phantomagent --skills-list
  phantomagent --server --model <path>
"""

import argparse
import json
import logging
import os
import sys
import time

from .agent import InferenceClient
from .orchestrator import Orchestrator
from .skills_loader import SkillLoader
from .result_logger import ResultLogger


def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


def cmd_run(args):
    """Run an automated penetration test engagement."""
    skills_dir = args.skills_dir or "/skills"
    results_dir = args.results_dir or "/results"

    client = InferenceClient(
        host=args.llm_host,
        port=args.llm_port,
        n_predict=args.max_tokens,
        temperature=args.temperature,
    )
    skill_loader = SkillLoader(skills_dir=skills_dir)
    result_logger = ResultLogger(results_dir=results_dir)

    orchestrator = Orchestrator(
        inference_client=client,
        skill_loader=skill_loader,
        result_logger=result_logger,
        llm_type=args.model_type,
    )

    print(f"[*] Starting automated penetration test against {args.target}")
    print(f"[*] Scope: {args.scope}")
    print(f"[*] Skills loaded: {len(skill_loader.load_all())}")

    result = orchestrator.run_engagement(
        target=args.target,
        scope=args.scope,
    )

    print(f"\n[+] Engagement complete!")
    print(f"[+] Report: {result['report_path']}")
    return result


def cmd_server(args):
    """Start llama.cpp HTTP server for inference."""
    import subprocess

    binary = args.binary
    model = args.model

    if not os.path.exists(binary):
        print(f"[!] llama.cpp binary not found: {binary}")
        return 1

    if not os.path.exists(model):
        print(f"[!] Model not found: {model}")
        return 1

    cmd = [
        binary,
        "-m", model,
        "-c", str(args.context),
        "-t", str(args.threads),
        "-ngl", "0",  # CPU-only (no GPU for air-gapped Intel i5)
        "--host", args.host,
        "--port", str(args.port),
        "-np", "1",  # single prompt at a time
        "-cb",       # continuous batching
    ]

    print(f"[*] Starting llama.cpp server: {' '.join(cmd)}")
    subprocess.call(cmd)
    return 0


def cmd_list_skills(args):
    """List all available skills."""
    skills_dir = args.skills_dir or "/skills"
    skill_loader = SkillLoader(skills_dir=skills_dir)
    skills = skill_loader.list_skills()

    print(f"[*] Found {len(skills)} skills in {skills_dir}:")
    for s in skills:
        print(f"  - {s['name']} [{s['category']}]: {s['description'][:80]}")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="HackinAgent - AI-powered penetration testing framework",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # run engagement
    run_p = sub.add_parser("run", help="Run automated penetration test")
    run_p.add_argument("--target", required=True, help="Target host/IP")
    run_p.add_argument("--scope", default="network", choices=["network", "local"])
    run_p.add_argument("--skills-dir", default="/skills")
    run_p.add_argument("--results-dir", default="/results")
    run_p.add_argument("--llm-host", default="127.0.0.1")
    run_p.add_argument("--llm-port", type=int, default=8080)
    run_p.add_argument("--model-type", default="qwen2.5")
    run_p.add_argument("--max-tokens", type=int, default=2048)
    run_p.add_argument("--temperature", type=float, default=0.7)

    # start inference server
    srv_p = sub.add_parser("server", help="Start llama.cpp inference server")
    srv_p.add_argument("--binary", required=True, help="Path to llama.cpp binary")
    srv_p.add_argument("--model", required=True, help="Path to GGUF model")
    srv_p.add_argument("--context", type=int, default=8192, help="Context size")
    srv_p.add_argument("--threads", type=int, default=4)
    srv_p.add_argument("--host", default="127.0.0.1")
    srv_p.add_argument("--port", type=int, default=8080)

    # list skills
    list_p = sub.add_parser("skills", help="List available skills")
    list_p.add_argument("--skills-dir", default="/skills")

    args = parser.parse_args()
    setup_logging()

    if args.command == "run":
        return cmd_run(args)
    elif args.command == "server":
        return cmd_server(args)
    elif args.command == "skills":
        return cmd_list_skills(args)


if __name__ == "__main__":
    sys.exit(main() or 0)