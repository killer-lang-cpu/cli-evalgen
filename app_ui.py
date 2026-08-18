import os
import time
import json
import threading
from concurrent.futures import ProcessPoolExecutor, as_completed
import tkinter as tk
from tkinter import ttk
from generator.sandbox import clone_repo_to_sandbox, purge_sandbox
from generator.scanner import scan_repository_for_targets, find_test_file_for_target
from generator.multi_mutator import generate_multi_language_mutations, detect_language
from generator.verifier import run_in_memory_verification, run_fallback_subprocess_verification
from generator.exporter import export_sft_rl_dataset
from generator.ai_evaluator import evaluate_ai_model_on_dataset


def process_file_worker(args):
    target_file, repo_dir = args
    from generator.scanner import find_test_file_for_target
    from generator.multi_mutator import generate_multi_language_mutations
    from generator.verifier import run_in_memory_verification, run_fallback_subprocess_verification

    try:
        with open(target_file, "r", encoding="utf-8", errors="ignore") as f:
            source_code = f.read()

        mutations = generate_multi_language_mutations(source_code, target_file)
        if not mutations:
            return {"file": target_file, "valid": [], "mutations": 0, "skipped": True, "reason": "No operator points found"}

        test_file_path = find_test_file_for_target(repo_dir, target_file)
        test_code = ""
        if test_file_path and os.path.exists(test_file_path):
            with open(test_file_path, "r", encoding="utf-8", errors="ignore") as f:
                test_code = f.read()

        valid_items = []
        for item in mutations:
            if test_code:
                ver_result = run_in_memory_verification(item["mutated_code"], test_code)
            else:
                ver_result = run_fallback_subprocess_verification(target_file, repo_dir, item["mutated_code"])

            if ver_result["is_valid_bug"]:
                item["original_code"] = source_code
                item["target_file"] = target_file
                valid_items.append(item)

        return {"file": target_file, "valid": valid_items, "mutations": len(mutations), "skipped": False}

    except Exception as e:
        return {"file": target_file, "valid": [], "mutations": 0, "skipped": True, "reason": str(e)}


class CliEvalGenApp:
    def __init__(self, root):
        self.root = root
        self.root.title("CLI-EvalGen Studio Pro v2.5 — Closed-Loop AI Evaluation Harness")
        self.root.geometry("1100x740")
        self.root.configure(bg="#09090b")

        # TTK Dark Style Setup
        style = ttk.Style()
        style.theme_use("clam")
        style.configure(
            "Dark.Vertical.TScrollbar",
            background="#27272a", troughcolor="#09090b", bordercolor="#09090b", arrowcolor="#10b981", relief="flat"
        )

        # Header Bar
        header_frame = tk.Frame(root, bg="#09090b", padx=20, pady=12)
        header_frame.pack(fill="x")

        tk.Label(header_frame, text="⚡ CLI-EVALGEN STUDIO PRO", font=("Consolas", 14, "bold"), bg="#09090b", fg="#10b981").pack(side="left")
        tk.Label(header_frame, text="● CLOSED-LOOP AI EVAL HARNESS ACTIVE", font=("Consolas", 8, "bold"), bg="#18181b", fg="#10b981", padx=10, pady=4).pack(side="right")

        # Configuration Card Panel
        frame = tk.Frame(root, bg="#18181b", padx=15, pady=12, bd=1, relief="solid")
        frame.configure(highlightbackground="#27272a", highlightthickness=1)
        frame.pack(fill="x", padx=20, pady=5)

        self.mode_var = tk.StringVar(value="git")
        rb_local = tk.Radiobutton(frame, text="Scan Local Repo", variable=self.mode_var, value="local", bg="#18181b", fg="#e4e4e7", selectcolor="#09090b", activebackground="#18181b", activeforeground="#10b981", font=("Consolas", 9))
        rb_git = tk.Radiobutton(frame, text="Clone & Scan Public GitHub Repo", variable=self.mode_var, value="git", bg="#18181b", fg="#e4e4e7", selectcolor="#09090b", activebackground="#18181b", activeforeground="#10b981", font=("Consolas", 9))
        rb_local.grid(row=0, column=0, sticky="w")
        rb_git.grid(row=0, column=1, sticky="w", padx=20)

        self.path_entry = tk.Entry(frame, width=80, bg="#09090b", fg="#10b981", insertbackground="#10b981", font=("Consolas", 10), bd=0, highlightthickness=1, highlightbackground="#27272a", highlightcolor="#10b981")
        self.path_entry.insert(0, "https://github.com/killer-lang-cpu/chickenkeema")
        self.path_entry.grid(row=1, column=0, columnspan=2, sticky="w", ipady=5, pady=(8, 0))

        # Button Row
        btn_frame = tk.Frame(root, bg="#09090b", padx=20, pady=6)
        btn_frame.pack(fill="x")

        self.btn_run = tk.Button(btn_frame, text="🚀 1. GENERATE SFT/RL DATASET", command=self.start_async_generation, bg="#10b981", fg="#000000", font=("Consolas", 10, "bold"), pady=8, cursor="hand2", bd=0)
        self.btn_run.pack(side="left", fill="x", expand=True, padx=(0, 5))

        self.btn_eval = tk.Button(btn_frame, text="🤖 2. RUN LIVE AI BENCHMARK (PASS@1)", command=self.start_async_evaluation, bg="#38bdf8", fg="#000000", font=("Consolas", 10, "bold"), pady=8, cursor="hand2", bd=0)
        self.btn_eval.pack(side="right", fill="x", expand=True, padx=(5, 0))

        # 3 CONJOINED PANELS WORKSPACE
        panels_frame = tk.Frame(root, bg="#09090b")
        panels_frame.pack(fill="both", expand=True, padx=20, pady=(0, 20))

        # Panel 1: Setup & Dependency Logs
        p1 = tk.Frame(panels_frame, bg="#18181b", bd=1, relief="solid")
        p1.configure(highlightbackground="#27272a", highlightthickness=1)
        p1.place(relx=0.0, rely=0.0, relwidth=0.32, relheight=1.0)
        tk.Label(p1, text="📦 SETUP & DEPENDENCIES", font=("Consolas", 9, "bold"), bg="#18181b", fg="#a1a1aa", pady=6).pack(fill="x")
        self.box1 = self._create_text_box(p1, fg_color="#a1a1aa")

        # Panel 2: Live SFT Mutation Stream
        p2 = tk.Frame(panels_frame, bg="#18181b", bd=1, relief="solid")
        p2.configure(highlightbackground="#27272a", highlightthickness=1)
        p2.place(relx=0.34, rely=0.0, relwidth=0.32, relheight=1.0)
        tk.Label(p2, text="⚡ LIVE SFT MUTATION STREAM", font=("Consolas", 9, "bold"), bg="#18181b", fg="#10b981", pady=6).pack(fill="x")
        self.box2 = self._create_text_box(p2, fg_color="#10b981")

        # Panel 3: Live dataset_output.json Preview & Executive Summary
        p3 = tk.Frame(panels_frame, bg="#18181b", bd=1, relief="solid")
        p3.configure(highlightbackground="#27272a", highlightthickness=1)
        p3.place(relx=0.68, rely=0.0, relwidth=0.32, relheight=1.0)
        tk.Label(p3, text="📊 EXECUTIVE REPORT & DATASET", font=("Consolas", 9, "bold"), bg="#18181b", fg="#38bdf8", pady=6).pack(fill="x")
        self.box3 = self._create_text_box(p3, fg_color="#38bdf8")

    def _create_text_box(self, parent, fg_color="#10b981"):
        box = tk.Text(parent, bg="#09090b", fg=fg_color, font=("Consolas", 8), wrap="word", bd=0, highlightthickness=0)
        sb = ttk.Scrollbar(parent, orient="vertical", command=box.yview, style="Dark.Vertical.TScrollbar")
        box.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        box.pack(side="left", fill="both", expand=True)
        return box

    def append_log1(self, text):
        self.box1.insert(tk.END, text)
        self.box1.see(tk.END)

    def append_log2(self, text):
        self.box2.insert(tk.END, text)
        self.box2.see(tk.END)

    def append_log3(self, text):
        self.box3.insert(tk.END, text)
        self.box3.see(tk.END)

    def start_async_generation(self):
        self.btn_run.config(state="disabled", text="⏳ GENERATING SFT/RL DATASET...", bg="#3f3f46", fg="#a1a1aa")
        threading.Thread(target=self._run_generation_task, daemon=True).start()

    def start_async_evaluation(self):
        self.btn_eval.config(state="disabled", text="⏳ BENCHMARKING AI MODEL...", bg="#3f3f46", fg="#a1a1aa")
        threading.Thread(target=self._run_evaluation_task, daemon=True).start()

    def _run_generation_task(self):
        self.box1.delete("1.0", tk.END)
        self.box2.delete("1.0", tk.END)
        self.box3.delete("1.0", tk.END)

        mode = self.mode_var.get()
        target_input = self.path_entry.get().strip()

        repo_dir = target_input

        if mode == "git":
            self.append_log1("🛡️ Initializing Sandbox (`./.sandbox/`)...\n")
            try:
                self.append_log1("📦 Cloning Git Repo & resolving dependencies...\n")
                repo_dir = clone_repo_to_sandbox(target_input)
                self.append_log1("✅ Repo cloned & dependencies installed safely.\n")
            except Exception as e:
                self.append_log1(f"❌ Sandbox Error: {str(e)}\n")
                self.btn_run.config(state="normal", text="🚀 1. GENERATE SFT/RL DATASET", bg="#10b981", fg="#000000")
                return

        if not os.path.exists(repo_dir):
            self.append_log1(f"❌ Path does not exist: {repo_dir}\n")
            self.btn_run.config(state="normal", text="🚀 1. GENERATE SFT/RL DATASET", bg="#10b981", fg="#000000")
            return

        self.append_log1(f"🔍 Scanning target source files...\n")
        target_files = scan_repository_for_targets(repo_dir)
        self.append_log1(f"   Sampled {len(target_files)} target source files.\n")

        start_time = time.time()
        all_valid_mutations = []

        cpu_cores = os.cpu_count() or 16
        self.append_log1(f"⚡ Launching {cpu_cores} CPU Workers...\n")

        tasks = [(f, repo_dir) for f in target_files]

        with ProcessPoolExecutor(max_workers=cpu_cores) as executor:
            future_to_file = {executor.submit(process_file_worker, task): task[0] for task in tasks}
            
            for i, future in enumerate(as_completed(future_to_file), 1):
                res = future.result()
                rel_path = os.path.relpath(res["file"], repo_dir).replace("\\", "/")
                lang = detect_language(res["file"]).upper()
                
                if res["skipped"]:
                    self.append_log1(f"[{i}/{len(target_files)}] [SKIPPED] {rel_path}\n")
                else:
                    self.append_log2(f"[{i}/{len(target_files)}] [✓ VERIFIED] [{lang}] {rel_path}\n")
                    for item in res["valid"]:
                        meta = item["metadata"]
                        self.append_log2(f"  └ Line {meta.get('line',0)}: {meta.get('original_line','')[:18]} -> {meta.get('mutated_line','')[:18]}\n")
                    all_valid_mutations.extend(res["valid"])

        elapsed = round(time.time() - start_time, 2)

        out_file, diff_counts, total_pairs = export_sft_rl_dataset(all_valid_mutations, "Repository-Wide", repo_dir, "dataset_output.json")

        self.append_log1(f"\n🎉 Done in {elapsed}s!\nSaved to dataset_output.json\n")

        repo_name = target_input.split("/")[-1] if "/" in target_input else target_input
        summary_report = f"""==========================================
📊 HUMAN-READABLE BENCHMARK REPORT
==========================================
Target Repo  : {repo_name}
Exec Duration: {elapsed}s (16 Ryzen 7 Threads)
Total Scanned: {len(target_files)} Files
Verified SFT : {total_pairs} Unique SFT Pairs

DIFFICULTY TIER BREAKDOWN:
  • Easy   : {diff_counts.get('Easy', 0)} Pairs
  • Medium : {diff_counts.get('Medium', 0)} Pairs
  • Hard   : {diff_counts.get('Hard', 0)} Pairs
==========================================
RAW DATASET_OUTPUT.JSON PREVIEW:
==========================================
"""
        self.append_log3(summary_report)

        if os.path.exists("dataset_output.json"):
            with open("dataset_output.json", "r", encoding="utf-8") as f:
                json_str = f.read()
                self.append_log3(json_str)

        if mode == "git":
            purge_sandbox()
            self.append_log1("🧹 Sandbox purged clean.\n")

        self.btn_run.config(state="normal", text="🚀 1. GENERATE SFT/RL DATASET", bg="#10b981", fg="#000000")

    def _run_evaluation_task(self):
        if not os.path.exists("dataset_output.json"):
            self.append_log1("❌ Generate dataset first before evaluating AI model.\n")
            self.btn_eval.config(state="normal", text="🤖 2. RUN LIVE AI BENCHMARK (PASS@1)", bg="#38bdf8", fg="#000000")
            return

        self.append_log1("🤖 Starting Live AI Model Evaluation Harness...\n")
        
        with open("dataset_output.json", "r", encoding="utf-8") as f:
            items = json.load(f)

        eval_res = evaluate_ai_model_on_dataset(items)
        
        ai_report = f"""
==========================================
🤖 LIVE AI BENCHMARK EVALUATION RESULTS
==========================================
Total Tasks Tested  : {eval_res['total_tasks']}
AI Solved Tasks     : {eval_res['passed_tasks']}
Pass@1 Accuracy     : {eval_res['pass_at_1']}%
==========================================
TASK BREAKDOWN:
"""
        for d in eval_res['details']:
            ai_report += f"  [{d['task_id']}] [{d['tier']}] -> {d['status']}\n"
        
        ai_report += "==========================================\n"
        
        self.append_log3(ai_report)
        self.append_log1(f"✅ Live AI Benchmark Complete! Pass@1 Score: {eval_res['pass_at_1']}%\n")
        self.btn_eval.config(state="normal", text="🤖 2. RUN LIVE AI BENCHMARK (PASS@1)", bg="#38bdf8", fg="#000000")


if __name__ == "__main__":
    root = tk.Tk()
    app = CliEvalGenApp(root)
    root.mainloop()