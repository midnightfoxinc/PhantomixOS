#!/usr/bin/env python3
"""
Multi-agent orchestration framework for automated penetration testing.
Coordinating agents: Recon, Exploit, Analysis, Reporting.
"""

import json
import logging
import time
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field

from .agent import Agent, InferenceClient
from .skills_loader import SkillLoader
from .result_logger import ResultLogger

logger = logging.getLogger(__name__)

@dataclass
class Orchestrator:
    """Multi-agent pentest orchestrator."""

    inference_client: InferenceClient
    skill_loader: SkillLoader
    result_logger: ResultLogger
    llm_type: str = "qwen2.5"  # which model is serving
    max_rounds: int = 10  # max agent conversation rounds

    # Agent role templates
    ROLE_TEMPLATES: Dict[str, str] = field(default_factory=lambda: {
        "coordinator": (
            "You are the Coordinator Agent. You orchestrate specialized agents "
            "in an automated penetration test. Your job is to: analyze the mission, "
            "assign subtasks to specialists, aggregate results, and coordinate.\n\n"
            "Available specialists: ReconAgent (network/service discovery), "
            "ExploitAgent (vulnerability exploitation), "
            "CodeAgent (exploit/script generation), "
            "AnalysisAgent (result analysis and reporting).\n\n"
            "Think step by step (chain of thought). For each subtask, provide a clear "
            "objective and hand it to the right specialist. After receiving results, "
            "decide if escalation, re-testing, or the next phase is needed."
        ),
        "recon": (
            "You are the ReconAgent. You discover active hosts, open ports, services, "
            "and versions. Use tools like nmap, masscan, http enumeration, DNS recon.\n\n"
            "Report findings as structured JSON: "
            '{"hosts": [...], "services": [...], "vulns": [...]}'
        ),
        "exploit": (
            "You are the ExploitAgent. You take recon findings and identify/executes "
            "vulnerabilities. Use metasploit, hydra, sqlmap, nikto, nuclei, manual exploits. "
            "Only target systems in scope. Document each attempt.\n\n"
            "Report: exploit used, result, evidence."
        ),
        "code": (
            "You are the CodeAgent (Code Specialist). You write and execute Python scripts, "
            "exploits, payloads, and proof-of-concept code. Use pwntools, requests, socket, "
            "struct, rop gadgets. Generate exploit code for identified vulnerabilities and "
            "test it against the CodeAgent's execution environment.\n\n"
            "Output code in ```python blocks. Execute it, report results + evidence."
        ),
        "analysis": (
            "You are the AnalysisAgent. You analyze all results, correlate findings, "
            "generate a risk report, and summarize evidence. Convert raw tool output "
            "into structured findings with CVSS-style severity ratings.\n\n"
            "Produce: vulnerability report JSON, mitigation recommendations."
        ),
    })

    def create_agent(self, role: str) -> Agent:
        """Create a specialized sub-agent."""
        template = self.ROLE_TEMPLATES.get(role, self.ROLE_TEMPLATES["coordinator"])
        return Agent(
            name=role,
            description=f"Agent for role: {role}",
            client=self.inference_client,
            system_prompt=template
        )

    def register_skills(self, agent: Agent):
        """Load all available skills and register them with an agent."""
        skills = self.skill_loader.load_all()
        for skill_name, skill_info in skills.items():
            func = skill_info.get("func")
            desc = skill_info.get("description", "")
            if func:
                agent.add_tool(skill_name, func, desc)
                logger.info(f"Registered skill '{skill_name}' with {agent.name}")

    def run_engagement(self, target: str, scope: str = "network",
                       max_rounds: Optional[int] = None) -> Dict:
        """Run a full automated penetration test."""
        rounds = max_rounds or self.max_rounds
        task_id = self.result_logger.start_engagement(target, scope)

        logger.info(f"Starting engagement #{task_id} against {target} (scope={scope})")

        # 1. Phase 1: Reconnaissance
        recon_agent = self.create_agent("recon")
        self.register_skills(recon_agent)

        recon_task = f"""
        RECONNAISSANCE PHASE
        Target: {target}
        Scope: {scope}

        Perform comprehensive reconnaissance:
        1. Host discovery (ping sweep)
        2. Port scan (top 1000)
        3. Service version detection
        4. Basic OS detection
        5. HTTP enumeration (directories, titles, headers)
        6. DNS enumeration

        Report ALL findings as structured JSON. Focus on accuracy.
        """

        recon_report = self._run_agent_round(recon_agent, recon_task, task_id, "recon")
        self.result_logger.log_result(task_id, "recon", recon_report)

        # 2. Phase 2: Exploitation
        exploit_agent = self.create_agent("exploit")
        self.register_skills(exploit_agent)

        exploit_task = f"""
        EXPLOITATION PHASE
        Recon Report: {recon_report}
        Target: {target}

        Analyze findings. Identify vulnerabilities. Execute:
        1. Vulnerability scanning (nuclei/nikto against HTTP services)
        2. Brute force (hydra against SSH/FTP/HTTP)
        3. Metasploit for known service exploits
        4. SQL injection (sqlmap)
        5. Weak credential checks

        For each: report success/failure, evidence. Only in-scope targets.
        """

        exploit_report = self._run_agent_round(exploit_agent, exploit_task, task_id, "exploit")
        self.result_logger.log_result(task_id, "exploit", exploit_report)

        # 3. Phase 3: Code/Exploit generation
        code_agent = self.create_agent("code")
        self.register_skills(code_agent)

        code_task = f"""
        CODE GENERATION PHASE
        Findings: {recon_report}
        Exploits: {exploit_report}
        Target: {target}

        For each promising finding, write and execute a Python PoC exploit.
        Use socket, requests, pwntools. Report:
        - PoC code
        - Execution result (success/failure)
        - Evidence / proof
        """

        code_report = self._run_agent_round(code_agent, code_task, task_id, "code")
        self.result_logger.log_result(task_id, "code", code_report)

        # 4. Phase 4: Analysis & Reporting
        analysis_agent = self.create_agent("analysis")
        self.register_skills(analysis_agent)

        analysis_task = f"""
        ANALYSIS & REPORTING PHASE

        Reconnaissance: {recon_report}
        Exploitation: {exploit_report}
        Code/Exploits: {code_report}
        Target: {target}

        Correlate all findings. Generate:
        1. Vulnerability list with CVSS-style severity (Critical/High/Medium/Low)
        2. Evidence summary (proofs of exploitation)
        3. Mitigation recommendations
        4. Executive summary

        Output as structured JSON report.
        """

        final_report = self._run_agent_round(analysis_agent, analysis_task, task_id, "analysis")
        self.result_logger.log_result(task_id, "report", final_report)

        self.result_logger.end_engagement(task_id, final_report)
        logger.info(f"Engagement #{task_id} complete. Report at {self.result_logger.report_path(task_id)}")

        return {
            "task_id": task_id,
            "target": target,
            "report": final_report,
            "report_path": self.result_logger.report_path(task_id)
        }

    def _run_agent_round(self, agent: Agent, task: str, task_id: str, phase: str) -> str:
        """Execute a single agent conversation round with tool-use loop."""
        results = []
        current_prompt = task

        for round_num in range(self.max_rounds):
            logger.info(f"  [{phase}] Round {round_num+1}/{self.max_rounds}")
            response = agent.act(current_prompt)
            results.append(response)

            # Check if agent wants to do another round (simple keyword heuristic)
            if "round_complete" in response.lower() or round_num == 0:
                break
            current_prompt = f"Based on: {response}\nContinue to next step."

        return "\n".join(results)
