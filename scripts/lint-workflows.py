#!/usr/bin/env python3
"""
Structural linter for n8n workflow JSON files.

Validates workflow files against project conventions and catches
common issues before deployment.

Usage:
  ./scripts/lint-workflows.py                          # lint all workflows
  ./scripts/lint-workflows.py medika-preorders         # lint one project (test env)
  ./scripts/lint-workflows.py --env prod               # lint prod workflows
  ./scripts/lint-workflows.py workflows/test/medika-preorders/01_orchestrator.json  # single file

Exit codes:
  0 = all checks passed (warnings are OK)
  1 = one or more errors found
"""

import json
import os
import re
import sys
from pathlib import Path

# ── Constants ────────────────────────────────────────────────────────────────

TRIGGER_TYPES = {
    "n8n-nodes-base.executeWorkflowTrigger",
    "n8n-nodes-base.webhook",
    "n8n-nodes-base.scheduleTrigger",
    "n8n-nodes-base.manualTrigger",
    "n8n-nodes-base.errorTrigger",
    "@n8n/n8n-nodes-langchain.manualChatTrigger",
}

REQUIRED_TOP_LEVEL_FIELDS = {"name", "nodes", "connections"}

# WF number prefix pattern: extracts "01", "00b", "03" etc from filenames like 01_orchestrator.json
FILE_PREFIX_RE = re.compile(r"^(\d+\w?)_")

# WF reference pattern in node names: "WF-01:", "WF-00b:", "WF-03:"
WF_REF_RE = re.compile(r"WF-(\d+\w?)")

# Namespace pattern in workflow name: "[medika-preorders-test] WF-01: Orchestrator"
NAME_RE = re.compile(r"^\[([^\]]+)\]\s+WF-(\d+\w?):\s+.+$")

# Placeholder pattern
PLACEHOLDER_RE = re.compile(r"%%([A-Z_]+)%%")

ROOT = Path(__file__).resolve().parent.parent


# ── Result collection ────────────────────────────────────────────────────────

class LintResult:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, file, check, message):
        self.errors.append((file, check, message))

    def warn(self, file, check, message):
        self.warnings.append((file, check, message))

    @property
    def ok(self):
        return len(self.errors) == 0


# ── Checks ───────────────────────────────────────────────────────────────────

def check_valid_json(filepath, result):
    """File must be valid JSON."""
    try:
        with open(filepath) as f:
            data = json.load(f)
        return data
    except json.JSONDecodeError as e:
        result.error(filepath, "valid-json", f"Invalid JSON: {e}")
        return None


def check_required_fields(filepath, wf, result):
    """Workflow must have required top-level fields."""
    missing = REQUIRED_TOP_LEVEL_FIELDS - set(wf.keys())
    if missing:
        result.error(filepath, "required-fields", f"Missing fields: {', '.join(sorted(missing))}")


def check_naming_convention(filepath, wf, env, project, result):
    """Workflow name must match [namespace] WF-XX: Description pattern."""
    name = wf.get("name", "")
    match = NAME_RE.match(name)

    if not match:
        result.error(filepath, "naming-convention",
                     f"Name '{name}' doesn't match '[namespace] WF-XX: Description'")
        return

    namespace = match.group(1)
    wf_number = match.group(2)

    # Verify namespace matches directory
    if env == "test":
        expected_ns = f"{project}-test"
    else:
        expected_ns = project

    # Special case: shared project uses its own namespace
    if project == "shared":
        expected_ns = f"shared-test" if env == "test" else "shared"

    if namespace != expected_ns:
        result.error(filepath, "naming-convention",
                     f"Namespace [{namespace}] doesn't match expected [{expected_ns}] for {env}/{project}")

    # Verify WF number matches filename prefix
    filename = Path(filepath).stem
    file_match = FILE_PREFIX_RE.match(filename)
    if file_match:
        file_prefix = file_match.group(1)
        if file_prefix != wf_number:
            result.error(filepath, "naming-convention",
                         f"File prefix '{file_prefix}' doesn't match WF number 'WF-{wf_number}' in name")


def check_entry_point(filepath, wf, result):
    """Every workflow must have exactly one trigger node."""
    nodes = wf.get("nodes", [])
    triggers = [n for n in nodes if n.get("type") in TRIGGER_TYPES]

    if len(triggers) == 0:
        result.error(filepath, "entry-point", "No trigger node found")
    elif len(triggers) > 1:
        trigger_names = [t.get("name", "?") for t in triggers]
        result.warn(filepath, "entry-point",
                    f"Multiple trigger nodes: {', '.join(trigger_names)}")


def check_duplicate_node_names(filepath, wf, result):
    """No duplicate node names within a workflow."""
    nodes = wf.get("nodes", [])
    names = [n.get("name", "") for n in nodes]
    seen = set()
    for name in names:
        if name in seen:
            result.error(filepath, "duplicate-names", f"Duplicate node name: '{name}'")
        seen.add(name)


def check_orphan_nodes(filepath, wf, result):
    """Every non-trigger node must be a connection target somewhere."""
    nodes = wf.get("nodes", [])
    connections = wf.get("connections", {})

    # Build set of all node names that are connection targets
    targets = set()
    for source_name, outputs in connections.items():
        for output_type, output_branches in outputs.items():
            for branch in output_branches:
                for conn in branch:
                    targets.add(conn.get("node", ""))

    node_names = {n.get("name", "") for n in nodes}
    trigger_names = {n.get("name", "") for n in nodes if n.get("type") in TRIGGER_TYPES}

    for node in nodes:
        name = node.get("name", "")
        node_type = node.get("type", "")

        # Triggers don't need incoming connections
        if node_type in TRIGGER_TYPES:
            continue

        # noOp nodes used as merge points are fine even if orphaned
        if name not in targets:
            result.warn(filepath, "orphan-node", f"Node '{name}' has no incoming connections")


def check_dangling_connections(filepath, wf, result):
    """Every node referenced in connections must exist in the nodes array."""
    nodes = wf.get("nodes", [])
    connections = wf.get("connections", {})
    node_names = {n.get("name", "") for n in nodes}

    # Check source nodes (keys of connections)
    for source_name in connections:
        if source_name not in node_names:
            result.error(filepath, "dangling-connection",
                         f"Connection source '{source_name}' not found in nodes")

    # Check target nodes
    for source_name, outputs in connections.items():
        for output_type, output_branches in outputs.items():
            for branch in output_branches:
                for conn in branch:
                    target = conn.get("node", "")
                    if target and target not in node_names:
                        result.error(filepath, "dangling-connection",
                                     f"Connection target '{target}' (from '{source_name}') not found in nodes")


def check_sub_workflow_refs(filepath, wf, project_files, result):
    """executeWorkflow nodes with WF-XX names should have matching files."""
    nodes = wf.get("nodes", [])

    # Build map of WF number → filename from project files
    available_wfs = {}
    for f in project_files:
        m = FILE_PREFIX_RE.match(Path(f).stem)
        if m:
            available_wfs[m.group(1)] = Path(f).name

    for node in nodes:
        if node.get("type") != "n8n-nodes-base.executeWorkflow":
            continue

        name = node.get("name", "")
        match = WF_REF_RE.search(name)
        if not match:
            continue

        wf_num = match.group(1)
        if wf_num not in available_wfs:
            result.error(filepath, "sub-workflow-ref",
                         f"Node '{name}' references WF-{wf_num} but no matching file "
                         f"({wf_num}_*.json) found in project directory")


def check_placeholders(filepath, wf, known_vars, result):
    """All %%VAR%% placeholders must be defined in .env.workflow.example."""
    content = json.dumps(wf)
    found = set(PLACEHOLDER_RE.findall(content))

    for var in found:
        if var not in known_vars:
            result.error(filepath, "unknown-placeholder",
                         f"Placeholder %%{var}%% not defined in .env.workflow.example")


def check_webhook_path_convention(filepath, wf, env, result):
    """Test env webhook paths should have 'test-' prefix."""
    nodes = wf.get("nodes", [])

    for node in nodes:
        if node.get("type") != "n8n-nodes-base.webhook":
            continue

        path = node.get("parameters", {}).get("path", "")
        if not path:
            continue

        if env == "test" and not path.startswith("test-"):
            result.warn(filepath, "webhook-path",
                        f"Webhook path '{path}' in test env should have 'test-' prefix")
        elif env == "prod" and path.startswith("test-"):
            result.error(filepath, "webhook-path",
                         f"Webhook path '{path}' in prod env should NOT have 'test-' prefix")


def check_active_false_in_repo(filepath, wf, result):
    """Committed workflow files should have active=false (activation is runtime)."""
    if wf.get("active") is True:
        result.warn(filepath, "active-flag",
                    "Workflow has active=true in repo (activation should be a runtime concern)")


def check_node_references_in_expressions(filepath, wf, result):
    """Expression references like $('Node Name') should point to existing nodes."""
    nodes = wf.get("nodes", [])
    node_names = {n.get("name", "") for n in nodes}
    content = json.dumps(wf)

    # Find all $('Node Name') or $("Node Name") references
    refs = re.findall(r"""\$\(['"]([^'"]+)['"]\)""", content)

    for ref in refs:
        if ref not in node_names:
            result.error(filepath, "expression-ref",
                         f"Expression references node '{ref}' which doesn't exist in this workflow")


# Env vars that should use _TEST suffix in test workflows and bare names in prod
ENV_VARS_WITH_TEST_SUFFIX = {
    "MEDIKA_ERP_URL",
    "MEDIKA_ERP_USERNAME",
    "MEDIKA_ERP_PASSWORD",
    "MS_GRAPH_MAILBOX_READ",
    "MS_GRAPH_MAILBOX_SEND",
}

# Pattern to find $env.VARNAME references
ENV_REF_RE = re.compile(r"\$env\.([A-Z_]+)")


def check_if_branch_coverage(filepath, wf, result):
    """IF nodes should have both True and False branches connected."""
    nodes = wf.get("nodes", [])
    connections = wf.get("connections", {})

    for node in nodes:
        if node.get("type") != "n8n-nodes-base.if":
            continue

        name = node.get("name", "")
        outputs = connections.get(name, {}).get("main", [])

        # IF nodes have 2 outputs: index 0 = True, index 1 = False
        true_branch = outputs[0] if len(outputs) > 0 else []
        false_branch = outputs[1] if len(outputs) > 1 else []

        if not true_branch and not false_branch:
            result.warn(filepath, "if-branch-coverage",
                        f"IF node '{name}' has no branches connected")
        elif not true_branch:
            result.warn(filepath, "if-branch-coverage",
                        f"IF node '{name}' has no True branch connected")
        elif not false_branch:
            result.warn(filepath, "if-branch-coverage",
                        f"IF node '{name}' has no False branch connected")


def check_env_var_convention(filepath, wf, env, result):
    """Test workflows should use _TEST suffix env vars; prod should not."""
    content = json.dumps(wf)
    refs = set(ENV_REF_RE.findall(content))

    for var in ENV_VARS_WITH_TEST_SUFFIX:
        test_var = f"{var}_TEST"
        if env == "test":
            if var in refs and test_var not in refs:
                result.error(filepath, "env-var-convention",
                             f"Test workflow uses $env.{var} — should be $env.{test_var}")
        elif env == "prod":
            if test_var in refs:
                result.error(filepath, "env-var-convention",
                             f"Prod workflow uses $env.{test_var} — should be $env.{var}")


# ── File/directory resolution ────────────────────────────────────────────────

def _load_vars_from_example(filepath):
    """Load variable names from an .env.workflow example file."""
    vars_set = set()
    if filepath.exists():
        with open(filepath) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key = line.split("=", 1)[0].strip()
                if key:
                    vars_set.add(key)
    return vars_set


def load_known_vars():
    """Load variable names from .env.workflow.{test,prod}.example files.
    Falls back to .env.workflow.example for backwards compatibility."""
    test_vars = _load_vars_from_example(ROOT / ".env.workflow.test.example")
    prod_vars = _load_vars_from_example(ROOT / ".env.workflow.prod.example")

    if test_vars or prod_vars:
        return test_vars | prod_vars

    return _load_vars_from_example(ROOT / ".env.workflow.example")


def check_workflow_vars_parity(result):
    """Test and prod .env.workflow example files must define the same variables."""
    test_file = ROOT / ".env.workflow.test.example"
    prod_file = ROOT / ".env.workflow.prod.example"

    if not test_file.exists() or not prod_file.exists():
        return

    test_vars = _load_vars_from_example(test_file)
    prod_vars = _load_vars_from_example(prod_file)

    only_test = test_vars - prod_vars
    only_prod = prod_vars - test_vars

    for var in sorted(only_test):
        result.error(str(test_file), "workflow-vars-parity",
                     f"Variable '{var}' defined in test example but missing from prod example")
    for var in sorted(only_prod):
        result.error(str(prod_file), "workflow-vars-parity",
                     f"Variable '{var}' defined in prod example but missing from test example")


def resolve_files(args):
    """
    Resolve which workflow files to lint based on CLI arguments.
    Returns list of (filepath, env, project) tuples.
    """
    files = []
    workflows_dir = ROOT / "workflows"

    if not args:
        # Lint all workflows in all envs
        for env_dir in sorted(workflows_dir.iterdir()):
            if not env_dir.is_dir():
                continue
            env = env_dir.name
            for project_dir in sorted(env_dir.iterdir()):
                if not project_dir.is_dir():
                    continue
                # Skip deprecated subdirectories
                if project_dir.name == "deprecated":
                    continue
                project = project_dir.name
                for f in sorted(project_dir.glob("*.json")):
                    files.append((str(f), env, project))
        # Also check example workflow at root level
        example = workflows_dir / "example_workflow.json"
        if example.exists():
            files.append((str(example), None, None))
        return files

    arg = args[0]

    # Single file path
    if arg.endswith(".json"):
        filepath = Path(arg)
        if not filepath.is_absolute():
            filepath = ROOT / filepath
        # Extract env/project from path
        match = re.search(r"workflows/([^/]+)/([^/]+)/", str(filepath))
        if match:
            files.append((str(filepath), match.group(1), match.group(2)))
        else:
            files.append((str(filepath), None, None))
        return files

    # Project name — check for --env flag
    project = arg
    env = "test"
    if len(args) > 1 and args[1] == "--env" and len(args) > 2:
        env = args[2]

    project_dir = workflows_dir / env / project
    if project_dir.is_dir():
        for f in sorted(project_dir.glob("*.json")):
            files.append((str(f), env, project))

    return files


def get_project_files(filepath, env, project):
    """Get all workflow files in the same project directory."""
    if env is None or project is None:
        return [filepath]
    project_dir = ROOT / "workflows" / env / project
    return [str(f) for f in sorted(project_dir.glob("*.json"))]


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    files = resolve_files(args)

    if not files:
        print("No workflow files found.")
        sys.exit(0)

    result = LintResult()
    known_vars = load_known_vars()

    # Global checks (not per-file)
    check_workflow_vars_parity(result)

    print(f"Linting {len(files)} workflow file(s)...\n")

    for filepath, env, project in files:
        filename = os.path.relpath(filepath, ROOT)

        # 1. Valid JSON (gate — skip remaining checks if invalid)
        wf = check_valid_json(filepath, result)
        if wf is None:
            continue

        # Skip non-workflow files (e.g., example_workflow.json with no namespace)
        if env is None:
            continue

        # Get sibling files for cross-reference checks
        project_files = get_project_files(filepath, env, project)

        # 2. Required fields
        check_required_fields(filepath, wf, result)

        # 3. Naming convention
        check_naming_convention(filepath, wf, env, project, result)

        # 4. Entry point
        check_entry_point(filepath, wf, result)

        # 5. Duplicate node names
        check_duplicate_node_names(filepath, wf, result)

        # 6. Orphan nodes
        check_orphan_nodes(filepath, wf, result)

        # 7. Dangling connections
        check_dangling_connections(filepath, wf, result)

        # 8. Sub-workflow references
        check_sub_workflow_refs(filepath, wf, project_files, result)

        # 9. Placeholder validation
        check_placeholders(filepath, wf, known_vars, result)

        # 10. Webhook path convention
        check_webhook_path_convention(filepath, wf, env, result)

        # 11. Active flag
        check_active_false_in_repo(filepath, wf, result)

        # 12. Expression node references
        check_node_references_in_expressions(filepath, wf, result)

        # 13. Env var _TEST convention
        check_env_var_convention(filepath, wf, env, result)

        # 14. IF node branch coverage
        check_if_branch_coverage(filepath, wf, result)

    # ── Report ───────────────────────────────────────────────────────────
    if result.warnings:
        print("WARNINGS:")
        for filepath, check, msg in result.warnings:
            rel = os.path.relpath(filepath, ROOT)
            print(f"  {rel} [{check}] {msg}")
        print()

    if result.errors:
        print("ERRORS:")
        for filepath, check, msg in result.errors:
            rel = os.path.relpath(filepath, ROOT)
            print(f"  {rel} [{check}] {msg}")
        print()

    error_count = len(result.errors)
    warn_count = len(result.warnings)

    if result.ok:
        print(f"All checks passed. ({warn_count} warning(s))")
        sys.exit(0)
    else:
        print(f"FAILED: {error_count} error(s), {warn_count} warning(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
