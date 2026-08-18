# ⚡ CLI-EvalGen Studio Pro

<div align="center">

![Python](https://img.shields.io/badge/Python-3.11%2B-blue?style=for-the-badge&logo=python&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-emerald?style=for-the-badge)
![Languages](https://img.shields.io/badge/Languages-Python%20%7C%20C%2FC%2B%2B%20%7C%20Shell%20%7C%20JS%2FTS-orange?style=for-the-badge)
![Architecture](https://img.shields.io/badge/Engine-In--Memory%20AST%20%2B%20Multi--Core%20ProcessPool-purple?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

**Polyglot Harbor Task Pipeline, SFT/RL Dataset Generator & Closed-Loop Post-Training Harness for AI Coding & Command-Line Agents**

</div>

---

## Overview

**CLI-EvalGen Studio Pro** is an automated data engineering pipeline and closed-loop evaluation harness designed for AI coding and command-line agents.

Instead of hand-crafting coding benchmarks, `CLI-EvalGen` dynamically analyzes any target repository, programmatically injects subtle logical AST/token mutations across multiple programming languages, verifies assertion invariants in RAM at microsecond speeds, and automatically exports:
1. **Containerized Harbor Task Suites** (`instruction.md`, `task.toml`, `Dockerfile`, `test.sh`, `solve.sh`).
2. **Standardized SFT & RL Datasets** with unified `git diff` patches and multi-turn CLI agent trajectories.
3. **Automated Model Post-Training** to fine-tune open-source models (like `Qwen-2.5-Coder-0.5B`) using LoRA directly on the generated Harbor tasks.

---

## System Architecture

```text
                     [ Target Repository (Local / Public GitHub URL) ]
                                            │
                                            ▼
                  ┌───────────────────────────────────────────────────┐
                  │ 1. Quarantined Sandbox & Auto-Dependency Resolver │
                  │    • Isolated in-project workspace (./.sandbox/)  │
                  │    • Auto-resolves Python (pip) & JS/TS (npm)     │
                  └─────────────────────────┬─────────────────────────┘
                                            │
                                            ▼
                  ┌───────────────────────────────────────────────────┐
                  │ 2. Polyglot Core Scanner & Smart Sampler          │
                  │    • Scans Python (.py), C/C++, Shell (.sh), JS/TS│
                  │    • Excludes third-party vendor noise & bundles  │
                  └─────────────────────────┬─────────────────────────┘
                                            │
                                            ▼
                  ┌───────────────────────────────────────────────────┐
                  │ 3. Multi-Pass AST & Token Mutation Engine         │
                  │    • Pass 1: Tree Parsing & Cyclomatic Complexity │
                  │    • Pass 2: Semantic Logic Operator Mutation     │
                  └─────────────────────────┬─────────────────────────┘
                                            │
                                            ▼
                  ┌───────────────────────────────────────────────────┐
                  │ 4. Microsecond In-Memory RAM Verification Engine  │
                  │    • Compiles AST to RAM bytecode (compile/exec)  │
                  │    • Evaluates assertion invariants in ~0.5ms     │
                  └─────────────────────────┬─────────────────────────┘
                                            │
                                            ▼
                  ┌───────────────────────────────────────────────────┐
                  │ 5. Dual Dataset & Harbor Suite Exporter           │
                  │    • Generates containerized Harbor Task bundles  │
                  │    • Formats SFT/RL JSON with unified `git diff`  │
                  │    • Synthesizes Multi-Turn CLI Agent Trajectories│
                  └─────────────────────────┬─────────────────────────┘
                                            │
                                            ▼
                  ┌───────────────────────────────────────────────────┐
                  │ 6. Model Post-Training & Live Evaluation Harness  │
                  │    • LoRA SFT Fine-Tuning on Qwen-2.5-Coder-0.5B  │
                  │    • Dynamic Pass@1 Benchmarking & Inference Test │
                  └───────────────────────────────────────────────────┘

Key Technical Features

  - Automated Harbor Task Generator: Packages detected codebase bugs into
    official Harbor container suites (instruction.md, task.toml,
    environment/Dockerfile, tests/test.sh, solution/solve.sh).
  - Polyglot Language Support: Natively parses and mutates operators across
    Python (.py), C/C++ (.c, .cpp), Linux Shell/Bash (.sh), and
    JavaScript/TypeScript (.js, .ts).
  - In-Memory RAM Execution Engine: Compiles mutated ASTs directly into bytecode
    in memory (compile() + exec()) to evaluate test assertion invariants in
    ~0.5ms, eliminating slow disk subprocess spawning bottlenecks.
  - Model Post-Training Pipeline: Built-in fine-tuning engine
    (training/post_train.py) that trains Qwen/Qwen2.5-Coder-0.5B-Instruct with
    LoRA on local GPU/CUDA hardware.
  - Quarantined Local Sandboxing (./.sandbox/): Clones external GitHub
    repositories into a localized, auto-cleaning workspace with Windows
    read-only permission overrides (os.chmod / stat.S_IWRITE).
  - Auto-Dependency Resolver: Automatically detects requirements.txt, setup.py,
    pyproject.toml, and package.json upon clone to install dependencies before
    test execution.
  - Multi-Core Parallel Processing: Hardware-optimized using Python's
    ProcessPoolExecutor across 16 CPU threads, scanning and evaluating entire
    repositories in under 8 seconds.
  - Multi-Turn CLI Agent Trajectories: Synthesizes realistic step-by-step
    terminal execution traces (Terminal Command -> Assertion Failure -> Patch
    Application -> Exit Code 0) specifically for training CLI agents (like
    Claude Code, Cursor, Devin).
  - Cyclomatic Complexity Classifier: Measures AST branching depth and function
    length to categorize tasks into Easy, Medium, and Hard difficulty tiers.
  - Closed-Loop AI Evaluator: Live benchmarking harness that stress-tests AI
    models against generated tasks, computing Pass@1 Accuracy % and Reward
    Signals (1.0 vs 0.0).
  - 3-Panel Dark-Mode Studio UI: A developer-focused Tkinter desktop application
    featuring real-time dependency logs, live SFT mutation streams, and
    human-readable executive reporting.

Quickstart & Installation

1. Clone the Repository

git clone https://github.com/killer-lang-cpu/cli-evalgen.git
cd cli-evalgen

2. Setup Virtual Environment

# Windows
python -m venv venv
.\venv\Scripts\activate

# Linux / macOS
python3 -m venv venv
source venv/bin/activate

3. Install Dependencies

pip install -r requirements.txt
pip install torch transformers peft trl datasets accelerate

Usage

Option A: Launch the 3-Panel Desktop Studio UI (Recommended)

python app_ui.py

  - Select Scan Local Repo or Clone & Scan Public GitHub Repo.
  - Click 1. GENERATE HARBOR TASKS to run multi-core AST mutation and export
    Harbor bundles + SFT dataset.
  - Click 2. BENCHMARK PASS@1 to compute real dynamic evaluation metrics.
  - Click 3. TEST TRAINED QWEN MODEL to run live on-device GPU inference.

Option B: Post-Train Qwen-2.5-Coder Model via CLI

python training/post_train.py

Fine-tunes Qwen/Qwen2.5-Coder-0.5B-Instruct on the generated Harbor tasks using
LoRA and saves weights in training/harbor_qwen_adapter/.

Option C: Run Headless Dataset Generator via CLI

python main.py --target sample_repo/calculator.py --tests sample_repo/ --out dataset_output.json

Harbor Task Structure (harbor_tasks/)

Each generated task folder contains a self-contained containerized benchmark
suite:

harbor_tasks/task_001_calculator_py/
├── instruction.md         # Problem description & localized context
├── task.toml              # Harbor task configuration & timeout limits
├── environment/
│   └── Dockerfile         # Reproducible container environment
├── tests/
│   └── test.sh            # Oracle verifier script (Exit Code 0 vs 1)
└── solution/
    └── solve.sh           # Ground-truth fix script applying the patch

Dataset Schema Output (dataset_output.json)

[
  {
    "task_id": "cli_eval_001",
    "file_path": "calculator.py",
    "difficulty_tier": "Easy",
    "instruction": "Bug Report: Unexpected regression detected in 'calculator.py' near line 2. Recent changes altered expected logic (Add evaluated as Sub). Unit tests fail on execution. Inspect source code and apply patch.",
    "buggy_code": "def add(a: int, b: int) -> int:\n    return a - b\n",
    "solution_code": "def add(a: int, b: int) -> int:\n    return a + b\n",
    "patch": "--- a/calculator.py\n+++ b/calculator.py\n@@ -1,2 +1,2 @@\n def add(a: int, b: int) -> int:\n-    return a - b\n+    return a + b\n",
    "verification": {
      "command": "pytest .",
      "expected_exit_code": 0,
      "reward_signal": 1.0
    },
    "difficulty_metrics": {
      "difficulty": "Easy",
      "cyclomatic_complexity": 2,
      "total_lines": 14
    },
    "agent_trajectory_trace": [
      {
        "role": "user",
        "content": "Fix the failing unit tests in target file 'calculator.py'."
      },
      {
        "role": "assistant",
        "thought": "I will run the unit test suite first to observe the failure logs.",
        "tool_call": {
          "tool": "execute_terminal_command",
          "command": "pytest ."
        }
      },
      {
        "role": "tool_response",
        "content": "Pytest Execution: 1 Failed, 0 Passed (Exit Code 1)"
      },
      {
        "role": "assistant",
        "thought": "The test failed due to logic mutation. Applying fix patch to file.",
        "tool_call": {
          "tool": "apply_git_patch",
          "file_path": "calculator.py",
          "patch": "--- a/calculator.py\n+++ b/calculator.py\n..."
        }
      },
      {
        "role": "assistant",
        "thought": "Re-running test suite to confirm patch resolution.",
        "tool_call": {
          "tool": "execute_terminal_command",
          "command": "pytest ."
        }
      },
      {
        "role": "tool_response",
        "content": "Pytest Execution: All Tests Passed (Exit Code 0, Reward = 1.0)"
      }
    ]
  }
]

Performance Benchmarks

  - Host Hardware: AMD Ryzen 7 Processor (8 Cores / 16 Threads), 16GB RAM,
    NVIDIA RTX 3050 Laptop GPU, Windows 11
  - In-Memory RAM Mutation Rate: ~0.5 milliseconds per AST transformation pass
  - Full Repository Scan Time: <8.0 seconds across 16 parallel CPU workers
    (sampled on 30 core target files)
  - Model Training Convergence: LoRA cross-entropy loss converged from 4.123
    -> 4.050 on Qwen-2.5-Coder-0.5B

License

Distributed under the MIT License.

