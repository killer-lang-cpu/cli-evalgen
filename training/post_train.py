import os
import torch
from datasets import load_dataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    TrainingArguments,
    Trainer,
    DataCollatorForLanguageModeling
)
from peft import LoraConfig, get_peft_model
from prepare_data import prepare_harbor_training_data

MODEL_ID = "Qwen/Qwen2.5-Coder-0.5B-Instruct"
OUTPUT_DIR = "training/harbor_qwen_adapter"


def run_post_training():
    print(f"\n🚀 Starting Post-Training on {MODEL_ID} using Harbor Tasks...")

    # 1. Prepare Dataset from Harbor Tasks
    dataset_file = prepare_harbor_training_data()
    dataset = load_dataset("json", data_files=dataset_file, split="train")
    print(f"📊 Dataset loaded with {len(dataset)} training examples.")

    # 2. Load Tokenizer & Model
    print(f"📦 Loading base model '{MODEL_ID}'...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"⚡ Device detected: {device.upper()}")

    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
        device_map="auto" if torch.cuda.is_available() else None
    )

    # 3. Configure LoRA (Low-Rank Adaptation)
    lora_config = LoraConfig(
        r=8,
        lora_alpha=16,
        target_modules=["q_proj", "v_proj"],
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM"
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # 4. Tokenize Dataset
    def tokenize_fn(examples):
        tokens = tokenizer(
            examples["text"], 
            truncation=True, 
            max_length=512, 
            padding="max_length"
        )
        tokens["labels"] = tokens["input_ids"].copy()
        return tokens

    print("🔤 Tokenizing Harbor training dataset...")
    tokenized_dataset = dataset.map(tokenize_fn, batched=True)

    # 5. Training Arguments
    training_args = TrainingArguments(
        output_dir=OUTPUT_DIR,
        num_train_epochs=3,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=2,
        logging_steps=1,
        learning_rate=2e-4,
        fp16=torch.cuda.is_available(),
        save_strategy="no",
        report_to="none"
    )

    # 6. Trainer
    trainer = Trainer(
        model=model,
        train_dataset=tokenized_dataset,
        args=training_args,
        data_collator=DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)
    )

    # 7. Run Fine-Tuning on RTX 3050 CUDA
    print("\n⚡ Training LoRA Adapter on Harbor tasks...")
    trainer.train()

    # 8. Save Weights
    model.save_pretrained(OUTPUT_DIR)
    tokenizer.save_pretrained(OUTPUT_DIR)
    print(f"\n🎉 SUCCESS! Post-trained model adapter saved to '{OUTPUT_DIR}'")


if __name__ == "__main__":
    run_post_training()