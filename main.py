import argparse
import os
from generator.exporter import export_sft_rl_dataset
from generator.mutator import generate_mutations
from generator.verifier import run_verification


def main():
    parser = argparse.ArgumentParser(
        description="CLI-EvalGen: Automated SFT & RL Dataset Generator for AI Coding Agents"
    )
    parser.add_argument("--target", required=True, help="Path to the target Python code file")
    parser.add_argument("--tests", required=True, help="Path to the test directory or test file")
    parser.add_argument("--out", default="dataset_output.json", help="Path for generated output JSON dataset")
    
    args = parser.parse_args()
    
    if not os.path.exists(args.target):
        print(f"❌ Error: Target file '{args.target}' does not exist.")
        return

    print("\n🚀 Running CLI-EvalGen...")
    print(f"📁 Target File: {args.target}")
    print(f"🧪 Test Dir:    {args.tests}\n")

    # 1. Read Original File
    with open(args.target, "r") as f:
        original_code = f.read()

    # 2. Generate AST Mutations
    print("⚡ [1/3] Generating AST Code Mutations...")
    mutations = generate_mutations(original_code)
    print(f"   Found {len(mutations)} raw mutation points.\n")

    # 3. Verify Mutations via Pytest
    print("🧪 [2/3] Verifying Mutations with Background Pytest Execution...")
    valid_mutations = []
    
    for i, item in enumerate(mutations, 1):
        mutated_code = item["mutated_code"]
        meta = item["metadata"]
        
        ver_result = run_verification(args.target, args.tests, mutated_code)
        
        if ver_result["is_valid_bug"]:
            print(f"   [✓] Mutation #{i} (Line {meta['line']}: {meta['original']} -> {meta['mutated']}) -> VALID SFT/RL PAIR")
            item["original_code"] = original_code
            valid_mutations.append(item)
        else:
            print(f"   [✗] Mutation #{i} (Line {meta['line']}: {meta['original']} -> {meta['mutated']}) -> DISCARDED (Tests Still Passed)")

    # 4. Export to JSON Dataset
    print(f"\n📦 [3/3] Exporting {len(valid_mutations)} verified SFT/RL pairs to JSON...")
    out_file = export_sft_rl_dataset(valid_mutations, args.target, args.tests, args.out)
    
    print(f"\n🎉 SUCCESS! Dataset saved to '{out_file}'\n")


if __name__ == "__main__":
    main()