"""
PhantomixAgent - Multi-agent penetration testing orchestration framework.
Fully offline, runs on llama.cpp (GGUF) inference server.
Runs at /usr/local/bin/phantom-agent inside the ISO.
"""

__version__ = "0.1.0"
__author__ = "PhantomixOS Team"

from .agent import Agent, InferenceClient
from .orchestrator import Orchestrator
from .skills_loader import SkillLoader
from .result_logger import ResultLogger

__all__ = [
    "Agent",
    "InferenceClient",
    "Orchestrator",
    "SkillLoader",
    "ResultLogger",
]
