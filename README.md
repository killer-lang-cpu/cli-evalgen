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
