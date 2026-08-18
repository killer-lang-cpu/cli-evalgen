import time
from typing import List, Dict, Any


def evaluate_ai_model_on_dataset(dataset_items: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Simulates an AI Coding Agent attempting to solve each generated SFT/RL task,
    verifying patches and calculating the Pass@1 Benchmark Accuracy.
    """
    total_tasks = len(dataset_items)
    if total_tasks == 0:
        return {"total_tasks": 0, "passed_tasks": 0, "pass_at_1": 0.0, "details": []}

    passed_tasks = 0
    eval_details = []

    for task in dataset_items:
        task_id = task.get("task_id", "task_001")
        tier = task.get("difficulty_tier", "Medium")
        
        # AI Decision Simulation (Easy=100%, Medium=75%, Hard=50% solve rate)
        if tier == "Easy":
            solved = True
        elif tier == "Medium":
            solved = (len(task.get("instruction", "")) % 2 == 0)
        else:
            solved = (len(task.get("patch", "")) % 3 == 0)

        if solved:
            passed_tasks += 1
            status = "PASSED (Reward: 1.0)"
        else:
            status = "FAILED (Reward: 0.0)"

        eval_details.append({
            "task_id": task_id,
            "tier": tier,
            "solved": solved,
            "status": status
        })

    pass_at_1_accuracy = round((passed_tasks / total_tasks) * 100, 1)

    return {
        "total_tasks": total_tasks,
        "passed_tasks": passed_tasks,
        "pass_at_1": pass_at_1_accuracy,
        "details": eval_details
    }