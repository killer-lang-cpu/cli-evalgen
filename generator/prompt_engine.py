from typing import Dict, Any, List


def generate_natural_issue_prompt(file_path: str, meta: dict) -> str:
    """
    Converts raw line mutations into realistic natural language GitHub Issue descriptions.
    """
    op_type = meta.get("type", "Operator")
    orig_op = meta.get("original", "operator")
    mutated_op = meta.get("mutated", "operator")
    line = meta.get("line", 0)

    templates = [
        f"Bug Report: Unexpected regression detected in '{file_path}' near line {line}. "
        f"Recent changes altered expected logic ({orig_op} evaluated as {mutated_op}). "
        f"Unit tests fail on execution. Inspect source code and apply patch.",
        
        f"Issue #[Auto-Generated]: Assertion failure in '{file_path}' (Line {line}). "
        f"Logical branch evaluated incorrectly during runtime check. "
        f"Restore original {orig_op} behavior to satisfy test suite."
    ]
    
    return templates[line % len(templates)]


def build_multi_turn_agent_trajectory(task_id: str, file_path: str, buggy_code: str, patch: str, test_cmd: str) -> List[Dict[str, Any]]:
    """
    Formats SFT dataset items as Multi-Turn Command-Line Agent Interaction Traces.
    """
    return [
        {
            "role": "user",
            "content": f"Fix the failing unit tests in target file '{file_path}'."
        },
        {
            "role": "assistant",
            "thought": "I will run the unit test suite first to observe the failure logs.",
            "tool_call": {
                "tool": "execute_terminal_command",
                "command": test_cmd
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
                "file_path": file_path,
                "patch": patch
            }
        },
        {
            "role": "assistant",
            "thought": "Re-running test suite to confirm patch resolution.",
            "tool_call": {
                "tool": "execute_terminal_command",
                "command": test_cmd
            }
        },
        {
            "role": "tool_response",
            "content": "Pytest Execution: All Tests Passed (Exit Code 0, Reward = 1.0)"
        }
    ]