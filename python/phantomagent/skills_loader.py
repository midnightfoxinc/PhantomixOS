#!/usr/bin/env python3
"""
Dynamic skill loader for /skills directory.
Loads Python skill modules at runtime and registers them as agent tools.
"""

import importlib
import importlib.util
import json
import logging
import os
import sys
from typing import Dict, List, Optional, Any, Tuple

logger = logging.getLogger(__name__)

SKILLS_DIR = "/skills"
SKILLS_INDEX_FILE = "/skills/.index.json"

class SkillLoader:
    """Load dynamic skills from /skills directory on the USB."""

    def __init__(self, skills_dir: str = SKILLS_DIR):
        self.skills_dir = skills_dir
        self.skills: Dict[str, Dict] = {}
        self._discover_skills()

    def _discover_skills(self) -> None:
        """Scan /skills directory for .py and manifest files."""
        if not os.path.isdir(self.skills_dir):
            logger.warning(f"Skills dir {self.skills_dir} not found; using empty skill set")
            return

        for entry in os.listdir(self.skills_dir):
            skill_path = os.path.join(self.skills_dir, entry)
            if os.path.isdir(skill_path):
                self._load_skill_package(entry, skill_path)
            elif entry.endswith(".py") and entry != "__init__.py":
                self._load_skill_module(entry, skill_path)

        logger.info(f"Discovered {len(self.skills)} skills from {self.skills_dir}")

    def _load_skill_module(self, name: str, path: str) -> None:
        """Load a single skill .py file."""
        skill_name = name.replace(".py", "")

        try:
            spec = importlib.util.spec_from_file_location(f"skill_{skill_name}", path)
            if spec and spec.loader:
                module = importlib.util.module_from_spec(spec)
                sys.modules[f"skill_{skill_name}"] = module
                spec.loader.exec_module(module)

                # Look for SKILLS list: each entry = {"name", "func", "description"}
                if hasattr(module, "SKILLS"):
                    for skill_def in module.SKILLS:
                        self.skills[skill_def["name"]] = {
                            "func": skill_def["func"],
                            "description": skill_def.get("description", ""),
                            "category": skill_def.get("category", "misc"),
                            "source": name,
                        }
        except Exception as e:
            logger.error(f"Failed to load skill from {path}: {e}")

    def _load_skill_package(self, name: str, path: str) -> None:
        """Load a skill package directory with manifest."""
        # Skip caches and dotted/hidden directories
        if name.startswith((".", "_")) or name == "__pycache__":
            return

        manifest = os.path.join(path, "manifest.json")
        if os.path.exists(manifest):
            try:
                with open(manifest) as f:
                    meta = json.load(f)
            except (json.JSONDecodeError, OSError) as e:
                logger.error(f"Invalid manifest.json in {path}: {e}")
                return
            for skill_name, skill_path in meta.get("skills", {}).items():
                full_path = os.path.join(path, skill_path)
                self._load_and_register(skill_name, full_path, meta)
            return

        # Otherwise treat as a plain module package if it has one
        init = os.path.join(path, "__init__.py")
        if os.path.isfile(init):
            self._load_skill_module(f"{name}.py", init)

    def _load_and_register(self, skill_name: str, path: str, meta: dict) -> None:
        """Load a skill from file path and register it."""
        try:
            spec = importlib.util.spec_from_file_location(skill_name, path)
            if spec and spec.loader:
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)

                func = getattr(module, skill_name.replace("-", "_"), None)
                if func:
                    self.skills[skill_name] = {
                        "func": func,
                        "description": meta.get("description", func.__doc__ or ""),
                        "category": meta.get("category", "misc"),
                    }
        except Exception as e:
            logger.error(f"Failed to load skill {skill_name}: {e}")

    def load_all(self) -> Dict[str, Dict]:
        """Return all registered skills."""
        return self.skills

    def get_by_category(self, category: str) -> Dict[str, Dict]:
        """Get skills filtered by category."""
        return {
            k: v for k, v in self.skills.items() if v.get("category") == category
        }

    def list_skills(self) -> List[Dict[str, str]]:
        """List all skills with metadata."""
        return [
            {
                "name": name,
                "description": info.get("description", ""),
                "category": info.get("category", "misc"),
            }
            for name, info in self.skills.items()
        ]
