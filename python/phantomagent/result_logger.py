#!/usr/bin/env python3
"""
Result logger for engagement findings.
Writes to /results directory on persistent USB.
Structured JSON output for analysis phase.
"""

import json
import logging
import os
import uuid
import time
from typing import Dict, List, Optional, Any

logger = logging.getLogger(__name__)

RESULTS_DIR = "/results"


class ResultLogger:
    """Log engagement results to persistent storage."""

    def __init__(self, results_dir: str = RESULTS_DIR):
        self.results_dir = results_dir
        self.engagements: Dict[str, Dict] = {}
        os.makedirs(self.results_dir, exist_ok=True)
        logger.info(f"ResultLogger initialized at {self.results_dir}")

    def start_engagement(self, target: str, scope: str = "network") -> str:
        """Start a new engagement record."""
        task_id = str(uuid.uuid4())
        timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.engagements[task_id] = {
            "task_id": task_id,
            "target": target,
            "scope": scope,
            "start_time": timestamp,
            "end_time": None,
            "results": {},
            "summary": {},
        }
        logger.info(f"Started engagement {task_id}: target={target}, scope={scope}")
        return task_id

    def log_result(self, task_id: str, result_category: str, result_content: str) -> None:
        """Log a result under an engagement."""
        if task_id not in self.engagements:
            logger.warning(f"Unknown task_id: {task_id}, creating new one")
            task_id = self.start_engagement("unknown", "unknown")

        self.engagements[task_id]["results"][result_category] = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "content": result_content,
        }
        logger.debug(f"Logged [{result_category}] for task {task_id}")

    def log_summary(self, task_id: str, summary: Dict) -> None:
        """Set final summary for engagement."""
        if task_id in self.engagements:
            self.engagements[task_id]["summary"] = summary
            logger.info(f"Set summary for task {task_id}: {summary.get('status', 'unknown')}")

    def end_engagement(self, task_id: str, final_report: str) -> None:
        """End an engagement and write full report file."""
        if task_id not in self.engagements:
            logger.warning(f"Unknown task_id on end: {task_id}")
            return

        ts = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
        self.engagements[task_id]["end_time"] = ts

        # Write engagement report
        report_path = os.path.join(self.results_dir, f"engagement_{task_id[:8]}_{ts}.json")
        report_data = {
            "task_id": task_id,
            "engagement": self.engagements[task_id],
            "final_report": final_report,
        }

        with open(report_path, "w") as f:
            json.dump(report_data, f, indent=2)

        logger.info(f"Engagement report written to {report_path}")

    def report_path(self, task_id: str) -> str:
        """Get the path to the latest report for a task."""
        if task_id in self.engagements:
            return os.path.join(self.results_dir, f"engagement_{task_id[:8]}.json")
        return ""

    def list_engagements(self) -> List[Dict]:
        """List all engagements."""
        result = []
        for task_id, eng in self.engagements.items():
            result.append({
                "task_id": task_id,
                "target": eng.get("target", "unknown"),
                "scope": eng.get("scope", "unknown"),
                "start_time": eng.get("start_time", "unknown"),
                "end_time": eng.get("end_time"),
                "result_categories": list(eng.get("results", {}).keys()),
            })
        return result