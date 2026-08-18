import ast


class CodeMutator(ast.NodeTransformer):
    """
    Walks through the Python Abstract Syntax Tree (AST) and replaces 
    operators to introduce realistic logic bugs.
    """
    
    # Map original operators to their buggy replacements
    COMPARE_MUTATIONS = {
        ast.Gt: ast.GtE,     # >  becomes >=
        ast.GtE: ast.Lt,     # >= becomes <
        ast.Lt: ast.LtE,     # <  becomes <=
        ast.Eq: ast.NotEq,   # == becomes !=
    }
    
    BIN_OP_MUTATIONS = {
        ast.Add: ast.Sub,    # + becomes -
        ast.Sub: ast.Add,    # - becomes +
        ast.Mult: ast.Div,   # * becomes /
    }

    def __init__(self, target_index=0):
        super().__init__()
        self.target_index = target_index
        self.current_index = 0
        self.applied_mutation = None

    def visit_Compare(self, node):
        """Mutates comparison operators like > or =="""
        self.generic_visit(node)
        op_type = type(node.ops[0])
        
        if op_type in self.COMPARE_MUTATIONS:
            if self.current_index == self.target_index:
                new_op_class = self.COMPARE_MUTATIONS[op_type]
                original_op_name = op_type.__name__
                new_op_name = new_op_class.__name__
                
                # Replace the operator in the AST node
                node.ops[0] = new_op_class()
                
                self.applied_mutation = {
                    "line": getattr(node, "lineno", 0),
                    "type": "ComparisonOperator",
                    "original": original_op_name,
                    "mutated": new_op_name,
                }
            self.current_index += 1
        return node

    def visit_BinOp(self, node):
        """Mutates math operators like + or *"""
        self.generic_visit(node)
        op_type = type(node.op)
        
        if op_type in self.BIN_OP_MUTATIONS:
            if self.current_index == self.target_index:
                new_op_class = self.BIN_OP_MUTATIONS[op_type]
                original_op_name = op_type.__name__
                new_op_name = new_op_class.__name__
                
                # Replace the operator in the AST node
                node.op = new_op_class()
                
                self.applied_mutation = {
                    "line": getattr(node, "lineno", 0),
                    "type": "BinaryOperator",
                    "original": original_op_name,
                    "mutated": new_op_name,
                }
            self.current_index += 1
        return node


def generate_mutations(source_code: str):
    """
    Takes Python source code as a string, finds all possible mutation points,
    and returns a list of buggy code variations + metadata.
    """
    try:
        ast.parse(source_code)
    except SyntaxError:
        return []

    mutations = []
    target_idx = 0
    
    while True:
        # Re-parse fresh tree for every mutation
        fresh_tree = ast.parse(source_code)
        mutator = CodeMutator(target_index=target_idx)
        mutated_tree = mutator.visit(fresh_tree)
        
        if mutator.applied_mutation is None:
            # No more mutation points found
            break
            
        # Convert AST back to Python source code string
        mutated_code = ast.unparse(mutated_tree)
        
        mutations.append({
            "mutated_code": mutated_code,
            "metadata": mutator.applied_mutation
        })
        
        target_idx += 1

    return mutations