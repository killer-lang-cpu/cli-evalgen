# ⚡ CLI-EvalGen Studio Pro

<div align="center">

![Python](https://img.shields.io/badge/Python-3.11%2B-blue?style=for-the-badge&logo=python&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-emerald?style=for-the-badge)
![Languages](https://img.shields.io/badge/Languages-Python%20%7C%20C%2FC%2B%2B%20%7C%20Shell%20%7C%20JS%2FTS-orange?style=for-the-badge)
![Architecture](https://img.shields.io/badge/Engine-In--Memory%20AST%20%2B%20Multi--Core%20ProcessPool-purple?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

**Polyglot SFT & RL Dataset Benchmark Generator & Closed-Loop Evaluation Harness for AI Coding & Command-Line Agents**

</div>

---

##  Overview

**CLI-EvalGen** is an enterprise-grade systems tool and evaluation harness designed to automate the creation of **Supervised Fine-Tuning (SFT)** datasets, **Reinforcement Learning (RL)** reward signals, and **Multi-Turn Agent Trajectories** directly from local repositories or public GitHub repositories.

Instead of relying on static, overfitted public benchmarks (like HumanEval or LeetCode), `CLI-EvalGen` dynamically analyzes any target codebase, programmatically injects subtle logical AST/token mutations across multiple programming languages, verifies assertion invariants in RAM at microsecond speeds, and exports standardized datasets with verified `git diff` patches and simulated command-line agent tool-call traces.

---

##  System Architecture

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
                  │ 5. Dataset Exporter & Trajectory Synthesizer      │
                  │    • Generates unified `git diff` patch           │
                  │    • Classifies Difficulty: Easy | Medium | Hard  │
                  │    • Formats Multi-Turn CLI Agent Trajectories    │
                  └─────────────────────────┬─────────────────────────┘
                                            │
                                            ▼
                  ┌───────────────────────────────────────────────────┐
                  │ 6. Closed-Loop Live AI Model Evaluator            │
                  │    • Evaluates local AI models on generated tasks │
                  │    • Outputs Pass@1 Accuracy % & RL Reward Signals│
                  └───────────────────────────────────────────────────┘


✨ Key Technical Features

     Polyglot Language Support: Natively parses and mutates operators across Python (.py), C/C++ (.c, .cpp), Linux Shell/Bash (.sh), and JavaScript/TypeScript (.js, .ts).

     In-Memory RAM Execution Engine: Compiles mutated ASTs directly into bytecode in memory (compile() + exec()) to evaluate test assertion invariants in ~0.5ms, eliminating slow disk subprocess spawning bottlenecks.

     Quarantined Local Sandboxing (./.sandbox/): Clones external GitHub repositories into a localized, auto-cleaning workspace with Windows read-only permission overrides (os.chmod / stat.S_IWRITE).

     Auto-Dependency Resolver: Automatically detects requirements.txt, setup.py, pyproject.toml, and package.json upon clone to install dependencies before test execution.

     Multi-Core Parallel Processing: Hardware-optimized using Python's ProcessPoolExecutor across 16 CPU threads, scanning and evaluating entire repositories in under 8 seconds.

     Multi-Turn CLI Agent Trajectories: Synthesizes realistic step-by-step terminal execution traces (Terminal Command

            
    →
    →

          

    Assertion Failure

            
    →
    →

          

    Patch Application

            
    →
    →

          

    Exit Code 0) specifically for training CLI agents (like Claude Code, Cursor, Devin).

    Cyclomatic Complexity Classifier: Measures AST branching depth and function length to categorize tasks into Easy, Medium, and Hard difficulty tiers.

     Closed-Loop AI Evaluator: Live benchmarking harness that stress-tests AI models against generated tasks, computing Pass@1 Accuracy % and Reward Signals (1.0 vs 0.0).

     3-Panel Dark-Mode Studio UI: A developer-focused Tkinter desktop application featuring real-time dependency logs, live SFT mutation streams, and human-readable executive reporting.

 Quickstart & Installation
1. Clone the Repository
code Bash

git clone https://github.com/killer-lang-cpu/cli-evalgen.git
cd cli-evalgen

2. Setup Virtual Environment
code Bash

# Windows
python -m venv venv
.\venv\Scripts\activate

# Linux / macOS
python3 -m venv venv
source venv/bin/activate

3. Install Dependencies
code Bash

pip install -r requirements.txt

 Usage
Option A: Launch the 3-Panel Desktop Studio UI (Recommended)
code Bash

python app_ui.py

    Select "Scan Local Repo" or "Clone & Scan Public GitHub Repo".

    Click  1. GENERATE SFT/RL DATASET to run multi-core AST mutation and export dataset JSON.

    Click  2. RUN LIVE AI BENCHMARK (PASS@1) to evaluate an AI model live and calculate its Pass@1 score.

Option B: Run via Headless CLI
code Bash

python main.py --target sample_repo/calculator.py --tests sample_repo/ --out dataset_output.json

📄 Dataset Schema Output (dataset_output.json)

Each generated task item follows the standardized SFT/RL AI agent benchmark format:
code JSON

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

    Host Hardware: AMD Ryzen 7 Processor (8 Cores / 16 Threads), 16GB RAM, Windows 11

    In-Memory RAM Mutation Rate: ~0.5 milliseconds per AST transformation pass

    Full Repository Scan Time: <8.0 seconds across 16 parallel CPU workers (sampled on 30 core target files)

    Dataset Export Speed: Instantaneous JSON formatting and unified git patch generation

 Scalability Roadmap (Enterprise Cloud)

    Distributed Worker Orchestration: Scaling local multiprocessing to distributed cloud task queues using Ray / Celery / AWS Batch to process 100,000+ files concurrently.

    Native Tree-Sitter C-Bindings: Integrating Tree-Sitter C-bindings for microsecond in-memory AST transformations across Rust, Go, C++, and Swift.

    Automated LLM API Connectors: Native API hooks for Ollama, DeepSeek-Coder, and OpenAI to benchmark real-time Pass@k metrics automatically.

 License

Distributed under the MIT License. See LICENSE for more information.
