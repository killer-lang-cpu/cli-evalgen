import difflib
import json
import os
from typing import List, Dict, Any
from generator.difficulty import calculate_difficulty_score
from generator.prompt_engine import generate_natural_issue_prompt, build_multi_turn_agent_trajectory


def sanitize_path(path: str, repo_dir: str) -> str:
    """Dynamically removes local machine paths (e.g. C:\\Users\\athul\\...) into clean relative paths."""
    try:
        rel = os.path.relpath(path, repo_dir)
        return rel.replace("\\", "/")
    except Exception:
        return os.path.basename(path).replace("\\", "/")


def create_git_diff(original_code: str, mutated_code: str, file_path: str) -> str:
    orig_lines = original_code.splitlines(keepends=True)
    mut_lines = mutated_code.splitlines(keepends=True)
    
    diff = difflib.unified_diff(
        mut_lines,
        orig_lines,
        fromfile=f"a/{file_path}",
        tofile=f"b/{file_path}"
    )
    return "".join(diff)


def export_sft_rl_dataset(valid_mutations: List[Dict[str, Any]], target_file: str, repo_dir: str, output_path: str = "dataset_output.json"):
    """
    Exports deduplicated, path-sanitized SFT/RL benchmark JSON with difficulty metrics.
    """
    dataset = []
    seen_signatures = set()
    difficulty_counts = {"Easy": 0, "Medium": 0, "Hard": 0}
    
    for idx, item in enumerate(valid_mutations, 1):
        original = item["original_code"]
        mutated = item["mutated_code"]
        meta = item["metadata"]
        raw_file_path = item.get("target_file", target_file)
        
        clean_file_path = sanitize_path(raw_file_path, repo_dir)
        
        # Deduplication Check
        sig = f"{clean_file_path}:{meta.get('line', 0)}:{meta.get('mutated_line', '')}"
        if sig in seen_signatures:
            continue
        seen_signatures.add(sig)
        
        diff_patch = create_git_diff(original, mutated, clean_file_path)
        difficulty_info = calculate_difficulty_score(original, meta.get("line", 0))
        
        tier = difficulty_info["difficulty"]
        difficulty_counts[tier] = difficulty_counts.get(tier, 0) + 1
        
        nl_prompt = generate_natural_issue_prompt(clean_file_path, meta)
        
        # Clean relative test command (No C:\Users\athul\... leaked!)
        test_cmd = "pytest ."
        task_id = f"cli_eval_{len(dataset) + 1:03d}"
        
        agent_trajectory = build_multi_turn_agent_trajectory(
            task_id, clean_file_path, mutated, diff_patch, test_cmd
        )
        
        entry = {
            "task_id": task_id,
            "file_path": clean_file_path,
            "difficulty_tier": tier,
            "instruction": nl_prompt,
            "buggy_code": mutated,
            "solution_code": original,
            "patch": diff_patch,
            "verification": {
                "command": test_cmd,
                "expected_exit_code": 0,
                "reward_signal": 1.0
            },
            "difficulty_metrics": difficulty_info,
            "agent_trajectory_trace": agent_trajectory
        }
        dataset.append(entry)
        
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(dataset, f, indent=2)
        
    return output_path, difficulty_counts, len(dataset)