import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

BASE_MODEL = "Qwen/Qwen2.5-Coder-0.5B-Instruct"
ADAPTER_DIR = "training/harbor_qwen_adapter"


def test_fine_tuned_model():
    print("\n🧠 Loading Base Model + Your LoRA Adapter on GPU...")
    
    device = "cuda" if torch.cuda.is_available() else "cpu"
    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL)
    
    base_model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL,
        torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
        device_map="auto" if torch.cuda.is_available() else None
    )
    
    # Attach your trained LoRA adapter
    model = PeftModel.from_pretrained(base_model, ADAPTER_DIR)
    model.eval()

    # Test Prompt (Harbor Task)
    prompt = (
        "<|im_start|>system\n"
        "You are an autonomous AI software engineer solving containerized Harbor benchmark tasks.<|im_end|>\n"
        "<|im_start|>user\n"
        "Bug Report: Unexpected regression detected in 'calculator.py' near line 2 (Add -> Sub). "
        "Unit tests fail on execution. Inspect source code and apply patch.<|im_end|>\n"
        "<|im_start|>assistant\n"
    )

    print("\n⚡ Prompting Fine-Tuned Model...")
    print("-" * 50)
    
    inputs = tokenizer(prompt, return_tensors="pt").to(device)
    
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=150,
            temperature=0.2,
            do_sample=True,
            pad_token_id=tokenizer.eos_token_id
        )

    response = tokenizer.decode(outputs[0], skip_special_tokens=False)
    
    # Extract only assistant response
    assistant_reply = response.split("<|im_start|>assistant\n")[-1].replace("<|im_end|>", "").strip()
    
    print("🤖 MODEL'S GENERATED HARBOR OUTPUT:")
    print("-" * 50)
    print(assistant_reply)
    print("-" * 50)


if __name__ == "__main__":
    test_fine_tuned_model()