import os
import shutil
from typing import List, Dict, Any
from generator.difficulty import calculate_difficulty_score
from generator.prompt_engine import generate_natural_issue_prompt


def sanitize_relative_path(path: str, repo_dir: str) -> str:
    try:
        rel = os.path.relpath(path, repo_dir)
        return rel.replace("\\", "/")
    except Exception:
        return os.path.basename(path).replace("\\", "/")


def export_harbor_task_suite(valid_mutations: List[Dict[str, Any]], repo_dir: str, output_base_dir: str = "harbor_tasks") -> str:
    """
    Exports verified problem-solution pairs into the official Harbor Containerized Task Suite format:
    Each task directory contains:
      - instruction.md
      - task.toml
      - environment/Dockerfile
      - tests/test.sh
      - solution/solve.sh
    """
    os.makedirs(output_base_dir, exist_ok=True)
    task_count = 0

    for idx, item in enumerate(valid_mutations, 1):
        original = item["original_code"]
        mutated = item["mutated_code"]
        meta = item["metadata"]
        raw_file_path = item.get("target_file", "source.py")
        clean_file_path = sanitize_relative_path(raw_file_path, repo_dir)

        task_id = f"task_{idx:03d}_{clean_file_path.replace('/', '_').replace('.', '_')}"
        task_dir = os.path.join(output_base_dir, task_id)
        
        # Clean directory if already exists
        if os.path.exists(task_dir):
            shutil.rmtree(task_dir, ignore_errors=True)

        env_dir = os.path.join(task_dir, "environment")
        tests_dir = os.path.join(task_dir, "tests")
        solution_dir = os.path.join(task_dir, "solution")

        os.makedirs(env_dir, exist_ok=True)
        os.makedirs(tests_dir, exist_ok=True)
        os.makedirs(solution_dir, exist_ok=True)

        difficulty_info = calculate_difficulty_score(original, meta.get("line", 0))
        nl_prompt = generate_natural_issue_prompt(clean_file_path, meta)

        # 1. instruction.md
        instruction_content = f"""# Task: Fix Logic Regression in `{clean_file_path}`

## Description
{nl_prompt}

## Target File
- Path: `{clean_file_path}`
- Difficulty Tier: `{difficulty_info['difficulty']}` (Cyclomatic Complexity: {difficulty_info['cyclomatic_complexity']})

## Verification
Ensure all automated unit tests pass without modifying the test suite.
"""
        with open(os.path.join(task_dir, "instruction.md"), "w", encoding="utf-8") as f:
            f.write(instruction_content)

        # 2. task.toml (Official Harbor Task Config)
        toml_content = f"""[task]
id = "{task_id}"
name = "Fix logic regression in {clean_file_path}"
version = "1.0.0"
difficulty = "{difficulty_info['difficulty'].lower()}"
timeout_seconds = 300
tags = ["python", "ast-mutant", "bug-fix", "terminal-bench"]

[environment]
type = "docker"
dockerfile = "environment/Dockerfile"
workdir = "/workspace"

[verifier]
test_script = "tests/test.sh"
expected_exit_code = 0

[solution]
solve_script = "solution/solve.sh"
"""
        with open(os.path.join(task_dir, "task.toml"), "w", encoding="utf-8") as f:
            f.write(toml_content)

        # 3. environment/Dockerfile
        dockerfile_content = f"""FROM python:3.11-slim

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir pytest

WORKDIR /workspace

# Copy codebase with the injected bug
COPY . /workspace/

CMD ["/bin/bash"]
"""
        with open(os.path.join(env_dir, "Dockerfile"), "w", encoding="utf-8") as f:
            f.write(dockerfile_content)

        # 4. tests/test.sh (The Harbor Verifier Script)
        test_sh_content = """#!/bin/bash
set -e
echo "[Harbor Verifier] Running test suite..."
python -m pytest .
"""
        test_sh_path = os.path.join(tests_dir, "test.sh")
        with open(test_sh_path, "w", encoding="utf-8") as f:
            f.write(test_sh_content)

        # 5. solution/solve.sh (The Oracle Solution Script)
        solve_sh_content = f"""#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to {clean_file_path}..."

cat << 'EOF' > /workspace/{clean_file_path}
{original}
EOF

echo "[Harbor Oracle] Patch applied successfully."
"""
        solve_sh_path = os.path.join(solution_dir, "solve.sh")
        with open(solve_sh_path, "w", encoding="utf-8") as f:
            f.write(solve_sh_content)

        task_count += 1

    return output_base_dir, task_count