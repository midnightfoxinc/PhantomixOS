#!/usr/bin/env python3
"""
Agent abstraction for llama.cpp HTTP server.
Each agent runs a specialized prompt template.
"""

import json
import time
import uuid
import logging
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field
import urllib.request
import urllib.error

logger = logging.getLogger(__name__)

@dataclass
class InferenceClient:
    """
    Client for llama.cpp HTTP server.

    Uses only the Python standard library (urllib) so the ISO needs no
    pip-installable packages at runtime — important for air-gapped use.
    """
    host: str = "127.0.0.1"
    port: int = 8080
    timeout: int = 120
    n_predict: int = 2048
    temperature: float = 0.7
    top_p: float = 0.9
    repeat_penalty: float = 1.1

    @property
    def url(self) -> str:
        return f"http://{self.host}:{self.port}/completion"

    def health(self) -> bool:
        """Return True if the inference server is responding."""
        try:
            with urllib.request.urlopen(
                f"http://{self.host}:{self.port}/health", timeout=5
            ) as resp:
                return resp.status == 200
        except Exception:
            return False

    def generate(self, prompt: str, **kwargs) -> str:
        """Generate text from llama.cpp server."""
        payload = {
            "prompt": prompt,
            "n_predict": kwargs.get("n_predict", self.n_predict),
            "temperature": kwargs.get("temperature", self.temperature),
            "top_p": kwargs.get("top_p", self.top_p),
            "repeat_penalty": kwargs.get("repeat_penalty", self.repeat_penalty),
            "stop": ["</s>", "\n\nHuman:", "\n\nAssistant:"],
            "stream": False
        }

        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                result = json.loads(resp.read().decode("utf-8"))
            return result.get("content", "")
        except urllib.error.URLError as e:
            logger.error(
                f"Connection to llama.cpp at {self.url} failed: {e}. "
                "Is the inference server running? (phantomixos-ai-autostart)"
            )
            raise
        except Exception as e:
            logger.error(f"Inference error: {e}")
            raise

@dataclass
class Agent:
    """Base agent class."""
    name: str
    description: str
    client: InferenceClient
    system_prompt: str = ""
    tools: Dict[str, callable] = field(default_factory=dict)
    memory: List[Dict] = field(default_factory=list)
    agent_id: str = field(default_factory=lambda: str(uuid.uuid4()))

    def add_tool(self, name: str, func: callable, description: str = ""):
        """Register a tool (e.g., skill function)."""
        self.tools[name] = {
            "func": func,
            "description": description or func.__doc__ or ""
        }
        logger.debug(f"Added tool '{name}' to agent {self.name}")

    def invoke_tool(self, name: str, *args, **kwargs) -> Any:
        """Execute a registered tool."""
        if name not in self.tools:
            raise ValueError(f"Tool '{name}' not found in agent {self.name}")
        tool = self.tools[name]
        logger.info(f"Agent {self.name} invoking tool '{name}'")
        return tool["func"](*args, **kwargs)

    def think(self, prompt: str, **kwargs) -> str:
        """Generate a thought/completion using the LLM."""
        full_prompt = f"{self.system_prompt}\n\n{prompt}" if self.system_prompt else prompt
        logger.debug(f"Agent {self.name} thinking...")
        return self.client.generate(full_prompt, **kwargs)

    def act(self, task: str, context: Optional[Dict] = None) -> str:
        """Perform an action (default: think + tool use if needed)."""
        context = context or {}
        # Default implementation: try to reason about tool use
        thought_prompt = f"""
        Task: {task}
        Context: {json.dumps(context, indent=2)}

        Think step by step about how to accomplish this task.
        If you need to use a tool, specify it in JSON format:
        {{"tool": "tool_name", "args": {...}}}
        Otherwise, provide a direct answer.
        """
        thought = self.think(thought_prompt, n_predict=512)

        # Try to parse tool use from thought
        try:
            import re
            json_match = re.search(r'\{[^}]+\}', thought)
            if json_match:
                tool_call = json.loads(json_match.group(0))
                if "tool" in tool_call:
                    result = self.invoke_tool(
                        tool_call["tool"],
                        **tool_call.get("args", {})
                    )
                    # Generate final response incorporating tool result
                    final_prompt = f"""
                    Task: {task}
                    Tool used: {tool_call['tool']}
                    Tool result: {result}

                    Provide a clear, concise answer to the original task.
                    """
                    return self.think(final_prompt, n_predict=1024)
        except (json.JSONDecodeError, KeyError, ValueError):
            pass  # Fall back to direct thought

        # No tool use detected, return thought as answer
        return thought
