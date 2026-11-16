#!/usr/bin/env python3
"""Validate the 100-task catalog against the current native tool surface."""
from pathlib import Path
import argparse
import json
import re

ROOT = Path(__file__).resolve().parents[3]
CATALOG = ROOT / "plan/task-catalog.json"
TOOL_FILES = [
    ROOT / "editor/tiiny/tools/registry.gd",
    ROOT / "editor/tiiny/tools/transactions.gd",
    ROOT / "editor/tiiny/tools/inspector.gd",
    ROOT / "editor/tiiny/tools/debugger.gd",
]

def available_tools() -> set[str]:
    names = set()
    for path in TOOL_FILES:
        text = path.read_text()
        names.update(re.findall(r'"name":\s*"([a-z0-9_]+)"', text))
    return names

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, default=Path("/tmp/tiiny-task-coverage.json"))
    args = parser.parse_args()
    data = json.loads(CATALOG.read_text())
    tasks = data.get("tasks", [])
    errors = []
    if len(tasks) != 100:
        errors.append(f"catalog must contain exactly 100 tasks, found {len(tasks)}")
    ids = set()
    prompts = set()
    tools = available_tools()
    statuses = {"supported": 0, "partial": 0, "missing": 0}
    by_dimension = {}
    supported_with_tests = 0
    for task in tasks:
        tid = task.get("id", "")
        status = task.get("status", "")
        if not tid or tid in ids:
            errors.append(f"missing or duplicate id: {tid}")
        ids.add(tid)
        prompt = task.get("prompt", "")
        if not prompt or prompt in prompts:
            errors.append(f"{tid}: missing or duplicate prompt")
        prompts.add(prompt)
        if status not in statuses:
            errors.append(f"{tid}: invalid status {status}")
            continue
        statuses[status] += 1
        dim = task.get("dimension", "")
        by_dimension.setdefault(dim, {"supported": 0, "partial": 0, "missing": 0})[status] += 1
        listed = task.get("tools", [])
        if not isinstance(listed, list):
            errors.append(f"{tid}: tools must be an array")
            listed = []
        for name in listed:
            if name not in tools:
                errors.append(f"{tid}: tool is not implemented: {name}")
        if status == "supported" and not listed:
            errors.append(f"{tid}: supported task has no tools")
        if status == "missing" and listed:
            errors.append(f"{tid}: missing task unexpectedly lists tools")
        test = task.get("test", "")
        if test:
            if not (ROOT / test).exists():
                errors.append(f"{tid}: test file does not exist: {test}")
            if status == "supported":
                supported_with_tests += 1
        elif status == "supported":
            errors.append(f"{tid}: supported task has no test reference")
    report = {
        "catalog_version": data.get("version"),
        "total": len(tasks),
        "available_tools": sorted(tools),
        "tool_count": len(tools),
        "status": statuses,
        "by_dimension": by_dimension,
        "supported_with_test": supported_with_tests,
        "supported_coverage_percent": round(100.0 * statuses["supported"] / max(1, len(tasks)), 1),
        "errors": errors,
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Catalog: {len(tasks)} tasks, {len(tools)} native tools")
    print(f"Supported: {statuses['supported']} ({report['supported_coverage_percent']}%), Partial: {statuses['partial']}, Missing: {statuses['missing']}")
    print(f"Supported tasks with a test reference: {supported_with_tests}/{statuses['supported']}")
    for dim in ("2d", "3d", "project"):
        counts = by_dimension.get(dim, {})
        print(f"  {dim}: supported={counts.get('supported', 0)} partial={counts.get('partial', 0)} missing={counts.get('missing', 0)}")
    if errors:
        print("\nErrors:")
        for error in errors:
            print(" -", error)
        return 1
    print(f"Task catalog validated; report: {args.report}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
