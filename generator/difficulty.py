import ast


def calculate_difficulty_score(source_code: str, line_no: int) -> dict:
    """
    Measures AST depth, function length, and Cyclomatic Complexity 
    to score problem difficulty as Easy, Medium, or Hard.
    """
    try:
        tree = ast.parse(source_code)
    except SyntaxError:
        return {"difficulty": "Medium", "complexity_score": 5, "ast_depth": 3}

    ast_depth = 0
    complexity_score = 1
    total_lines = len(source_code.splitlines())

    # Walk AST to compute Cyclomatic Complexity
    for node in ast.walk(tree):
        # Measure AST depth
        if hasattr(node, "lineno"):
            ast_depth = max(ast_depth, getattr(node, "lineno", 0))

        # Branching points increase complexity
        if isinstance(node, (ast.If, ast.For, ast.While, ast.And, ast.Or, ast.ExceptHandler)):
            complexity_score += 1

    # Classify Difficulty Tier
    if complexity_score <= 3 and total_lines < 30:
        difficulty = "Easy"
    elif complexity_score <= 8 or total_lines < 100:
        difficulty = "Medium"
    else:
        difficulty = "Hard"

    return {
        "difficulty": difficulty,
        "cyclomatic_complexity": complexity_score,
        "total_lines": total_lines
    }