import re
from typing import Dict, List, Any

# Extension to Language Mapping
LANGUAGE_MAP = {
    ".py": "python",
    ".c": "c",
    ".cpp": "cpp",
    ".h": "c",
    ".hpp": "cpp",
    ".sh": "bash",
    ".bash": "bash",
    ".js": "javascript",
    ".ts": "typescript"
}

# Language-specific mutation rules
MUTATION_RULES = {
    "c_like": [
        (r"\b==\b", "!="),
        (r"\b!=\b", "=="),
        (r"\b>=\b", "<"),
        (r"\b<=\b", ">"),
        (r"\b&&\b", "||"),
        (r"\b\|\|\b", "&&"),
        (r"\b\+\b", "-"),
        (r"\b-\b", "+")
    ],
    "bash": [
        (r"\b-eq\b", "-ne"),
        (r"\b-ne\b", "-eq"),
        (r"\b-gt\b", "-lt"),
        (r"\b-lt\b", "-gt"),
        (r"\b-ge\b", "-le"),
        (r"\b-le\b", "-ge"),
        (r"\b&&\b", "||"),
        (r"\b\|\|\b", "&&")
    ]
}


def detect_language(file_path: str) -> str:
    """Detects the programming language based on file extension."""
    ext = "." + file_path.split(".")[-1].lower() if "." in file_path else ""
    return LANGUAGE_MAP.get(ext, "unknown")


def generate_multi_language_mutations(source_code: str, file_path: str) -> List[Dict[str, Any]]:
    """
    Generates realistic bug mutations for Python, C, C++, Shell/Bash, JS, and TS.
    """
    lang = detect_language(file_path)
    if lang == "unknown":
        return []

    rules = MUTATION_RULES["bash"] if lang == "bash" else MUTATION_RULES["c_like"]
    lines = source_code.splitlines()
    mutations = []

    for line_idx, line in enumerate(lines, 1):
        # Skip comments and empty lines
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "//", "/*", "*")):
            continue

        for pattern, replacement in rules:
            if re.search(pattern, line):
                mutated_line = re.sub(pattern, replacement, line, count=1)
                mutated_lines = list(lines)
                mutated_lines[line_idx - 1] = mutated_line
                mutated_code = "\n".join(mutated_lines)

                mutations.append({
                    "mutated_code": mutated_code,
                    "metadata": {
                        "line": line_idx,
                        "language": lang,
                        "type": "TokenOperatorMutation",
                        "original_line": line.strip(),
                        "mutated_line": mutated_line.strip()
                    }
                })

    return mutations