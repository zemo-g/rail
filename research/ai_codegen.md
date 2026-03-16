# AI Code Generation & Language Design Research

Research compiled 2026-03-16. Focus: what matters for Rail's relationship with AI.

---

## 1. Languages Designed for LLM Generation

**Nobody has built a real one.** The field is wide open.

The closest attempts:

- **SudoLang** (Eric Elliott, 2023): A pseudocode language that LLMs "execute" by inference. Declarative, constraint-based. Claims 20-30% fewer tokens than natural language prompts. But it's not a real language -- there's no compiler, no runtime, no type system. It's structured prompting dressed as a language. The LLM infers meaning without a spec being loaded. This works because it maps onto patterns already in training data.

- **Mojo** (Modular): Designed for AI *workloads* (GPU/accelerator targeting via MLIR), not for AI *generation*. Python superset. GPU programming integrated June 2025, pip-installable September 2025. But the ecosystem is nascent -- no web frameworks, limited DB drivers. Mojo solves "run AI fast" not "let AI write code."

- **MoonBit** and **Wing**: Target edge/WASM. AI-adjacent but not AI-native in the generation sense.

**The gap**: No one has designed a language where the syntax, semantics, and toolchain are optimized for an LLM to produce correct programs. Everyone is making languages for humans that AI happens to use, or prompt frameworks that aren't real languages.

**Rail implication**: This is genuinely uncharted territory. A language with minimal syntax, strong structural constraints, and grammar-guided generation could be the first real AI-native language.

---

## 2. DSPy, LMQL, Guidance, SGLang -- Structuring LLM Calls

These split into two camps:

### High-level: DSPy
- "Programming, not prompting." Auto-optimizes prompts for task alignment.
- Treats LLM calls as modules with typed signatures.
- Doesn't control individual completions -- controls the *system*.
- Key insight: structured output doesn't mean *correct* output. DSPy optimizes for correctness at the pipeline level.

### Low-level: LMQL, Guidance, SGLang
- Control token-by-token generation. Enforce schemas, regex, grammars.
- **LMQL**: Worst performance. Slow backend, complex pre/post-processing. Batch size of one only.
- **Guidance**: Faster than LMQL, some KV cache reuse. Still batch-size-one.
- **SGLang** (Stanford/LMSYS): The clear winner. RadixAttention gives automatic KV cache reuse across calls. 85-95% cache hit rates vs vLLM's 15-25%. Up to 6.4x higher throughput. Compressed finite state machines for constrained decoding.

**Key technical detail**: Constrained decoding works by restricting token selection at each step to tokens that keep output on a valid path per a grammar (EBNF, JSON schema, regex). The challenge is mapping sub-word tokens to grammar rules -- they don't align naturally. XGrammar and Outlines solve this at the token level.

**Rail implication**: If Rail has a formal grammar (it does -- it has a parser), that grammar can directly drive constrained decoding. An LLM generating Rail code could be *structurally incapable* of producing syntax errors. This is not theoretical -- vLLM, TensorRT-LLM, and SGLang all support EBNF-guided generation today.

---

## 3. What Makes a Language Easy for LLMs to Generate

### Training data volume dominates
- Python is easiest because there's the most Python in training data. Period.
- StarCoder trained on 80+ languages from GitHub. Further trained on 35B Python tokens to create the Python-specialized version.
- Models "master syntax and semantics" through exposure. More exposure = better generation.

### Error patterns reveal language design problems
- 40%+ of syntactic errors across six LLMs were "missing code block" or "incorrect code block" -- structural/indentation issues.
- Semantic errors (logic) > syntactic errors for well-known languages.
- For obscure languages, syntactic errors dominate -- the model doesn't know the rules.

### What actually helps
- **Consistent syntax**: Fewer special cases = fewer errors.
- **Explicit structure**: Languages where blocks are delimited (not indentation-sensitive) are easier.
- **Small keyword set**: Less to memorize/confuse.
- **Predictable patterns**: If seeing `fn` always means the same thing in every context.

**Rail implication**: Rail's minimal syntax (fn, let, if/else, match, pipe operator) and explicit block delimiters are inherently LLM-friendly. But zero training data exists. The question becomes: can you compensate for zero training data with grammar constraints + fine-tuning?

---

## 4. LoRA Fine-Tuning: What Actually Works

### Dataset size thresholds
- **< 200-300 examples**: Diminishing returns. Can't meaningfully shift model behavior.
- **500-1,000 examples**: LoRA starts outperforming full fine-tuning. Sweet spot for preventing overfitting on limited data.
- **1,200-2,500 examples**: Sweet spot for Qwen-family models. Returns taper beyond this.
- **> 3 epochs on instruction data**: Overfitting risk increases, diminishing returns.
- **100K+ samples**: Full fine-tuning catches up to and surpasses LoRA.

### LoRA vs full fine-tuning
- LoRA matches full fine-tuning on small-to-medium datasets.
- LoRA *outperforms* full fine-tuning under 1,000 examples (regularization effect).
- Full fine-tuning only wins with million-scale datasets.

### Catastrophic forgetting
- Fine-tuning on domain-specific data causes the model to lose general knowledge.
- Low-perplexity training data (close to what the model already knows) produces better results with less forgetting.
- This means: training on Rail code that *looks like* existing languages the model knows will transfer better than alien syntax.

### Practical parameters
- LoRA rank 4, alpha 16 is typical.
- Single GPU sufficient for 1.5B models.
- QLoRA (4-bit quantization + LoRA) extends to larger models on consumer hardware.

**Rail implication**: 1,000-2,000 high-quality Rail examples with LoRA on Qwen2.5-Coder-1.5B is a viable path. Rail's Python-like feel (fn, let, pipe) should reduce catastrophic forgetting vs a truly alien syntax. The grammar-guided generation from section 2 means the model only needs to learn *semantics*, not syntax.

---

## 5. How Code Models Were Trained

### DeepSeek-Coder (2T tokens)
- **87% source code, 10% English code-related NL, 3% Chinese NL**
- 87 programming languages
- Repository-level organization: files grouped by repo to teach cross-file understanding
- Aggressive filtering: only 32.8% of raw data survived quality filters
- Both next-token prediction AND Fill-In-the-Middle (FIM) training
- HumanEval: 34.8% (1.3B) -> 49.4% (6.7B) -> 56.1% (33B)

### StarCoder / StarCoder2
- GitHub data: code, commits, issues, Jupyter notebooks
- StarCoder2's "The Stack v2": 619 languages, PRs, Kaggle notebooks, docs
- 4x larger training set than StarCoder 1
- Further specialized by training on 35B Python tokens

### What mattered most
1. **Data quality filtering** (aggressive -- kept only 1/3 of raw data)
2. **Repository-level context** (not isolated files)
3. **FIM training** (fill-in-the-middle, not just left-to-right)
4. **Multi-task training** (code + NL about code + commits)

**Rail implication**: For Rail fine-tuning, include not just Rail code but Rail-related natural language (comments explaining what the code does, documentation-style pairs). Include repo-level context -- files that import each other. FIM training could teach the model to complete partial Rail programs.

---

## 6. Tree-sitter and Incremental Parsing

### Performance gains
- Autocompletion 60% faster after tree-sitter integration (500ms -> 200ms).
- Static analysis: 45% faster, 65% fewer false positives.
- Scales to 8,000+ line files without performance degradation.

### How it works
- Parses file into concrete syntax tree on open.
- On edit, produces new tree sharing unchanged nodes with old tree.
- Preserves every token and boundary -- exact byte/line/column mapping.

### AI integration
- Tree-sitter ASTs provide precise snippet retrieval for RAG (retrieval-augmented generation).
- Exact node-to-source mapping lets you feed the LLM only the relevant context.
- Supported in: Neovim, Zed, Helix, Emacs, Lapce.

**Rail implication**: Rail already has a parser. Writing a tree-sitter grammar for Rail would unlock: (a) instant syntax validation of AI-generated code, (b) incremental re-parsing as AI streams output, (c) editor support in all major tree-sitter editors, (d) precise context extraction for RAG-based generation.

---

## 7. "Grammar Prompting" -- The Most Relevant Research

**NeurIPS 2023 paper: "Grammar Prompting for Domain-Specific Language Generation with Large Language Models"**

This is the most directly relevant research for Rail.

### Core idea
Instead of few-shot examples alone, augment each demonstration with a *specialized BNF grammar* -- a minimal subset of the full DSL grammar sufficient for that example. At inference, the LLM first predicts a BNF grammar for the test input, then generates output constrained by that grammar.

### Why it works
- The grammar acts as an intermediate representation (like chain-of-thought, but formal).
- Syntactic validity is *guaranteed* during generation via constrained decoding.
- The LLM learns to manipulate grammar rules symbolically.

### Results
- Competitive on: semantic parsing (SMCalFlow, Overnight, GeoQuery), PDDL planning, molecule generation (SMILES).
- Works with *few-shot* examples -- no fine-tuning required.
- The key insight: giving the LLM the grammar makes it dramatically better at generating valid DSL code.

**Rail implication**: This is the playbook. Rail's BNF grammar can be included in prompts. For each generation task, provide a *subset* of Rail's grammar relevant to the task (e.g., only the rules for function definitions and match expressions if that's what's needed). Combine with constrained decoding for guaranteed syntax. This could work *without any fine-tuning* on larger models.

---

## 8. Program Synthesis vs Code Generation

### Code generation (LLMs)
- Statistical pattern matching on training data.
- Works great for common patterns. Falls apart on novel logic.
- No correctness guarantees. "Usually right" for typical code.

### Program synthesis (formal)
- Generates code from logical specifications.
- Correct by construction -- if it produces output, it's provably correct.
- Slow. Limited to small programs. Requires formal specs humans rarely write.

### The hybrid that's emerging
- LLM generates formal spec from natural language.
- Program synthesis generates provably correct code from the spec.
- Or: LLM generates candidate, formal methods verify it.
- Enumerative synthesis algorithms now integrate LLM calls for guidance -- the LLM steers the search, the synthesizer guarantees correctness.

**Rail implication**: Rail's type system and algebraic effects could serve as lightweight formal specs. If `fn add(a: Int, b: Int) -> Int` with an effect annotation tells you everything about the function's contract, the LLM only needs to fill in the body, and the type checker verifies it. This is synthesis-lite -- not full formal verification, but enough to catch most errors.

---

## 9. Verified Code Generation

### Current state (2025-2026)
- Martin Kleppmann (Dec 2025): "AI will make formal verification go mainstream."
- His argument: (1) verification is about to get vastly cheaper via AI, (2) AI-generated code *needs* verification because humans can't review it all, (3) proofs are perfect for LLMs because hallucinated proofs get rejected by the checker.
- **Key insight**: It doesn't matter if the LLM hallucinates a proof. The proof checker rejects invalid proofs. The LLM just retries. This is a fundamentally different failure mode than code generation.

### Benchmarks
- CLEVER benchmark: state-of-the-art LLMs solve only 1/161 end-to-end verified code generation problems.
- Astrogator (Ansible-specific): verifies correct code 83% of the time, identifies incorrect code 92%.
- Lean and Dafny are the leading targets for LLM-generated verified code.

### Verification-oriented approach
- Languages like Dafny and Verus use SMT solvers for automated theorem proving.
- LLMs provide "proof hints" (loop invariants, assertions) rather than full proofs.
- The term "vericoding" coined Sept 2025: LLMs generating formally verified code.

**Rail implication**: Rail doesn't need full Lean-style verification to benefit. Even lightweight contracts (preconditions, postconditions, type-level constraints) give the LLM guardrails. If the model generates `fn sort(xs: List[Int]) -> List[Int]` and Rail's type checker can verify the output is sorted (via refinement types or property assertions), you get verification without the proof theory.

---

## 10. Smallest Model for Reliable Code Generation

### Benchmark data (HumanEval pass@1, mainstream languages)
| Model | Params | HumanEval |
|-------|--------|-----------|
| DeepSeek-Coder-1.3B | 1.3B | 34.8% |
| Qwen2.5-Coder-1.5B | 1.5B | 54.0% |
| Qwen2.5-Coder-3B | 3.0B | 59.0% |
| DeepSeek-Coder-6.7B | 6.7B | 49.4% (base) / 66.1% (instruct) |
| Qwen2.5-Coder-7B | 7.0B | 65.0% |

### Key findings
- **Qwen2.5-Coder-1.5B outperforms several 7B models** including CodeLlama 7B and StarCoder2 7B. Architecture matters more than raw parameter count.
- 1.5B -> 3B: +5 percentage points. 3B -> 7B: +6 points. Diminishing returns per parameter.
- VRAM: 1.5B and 3B both under 10GB, inference under 0.75s. 7B requires 261% more VRAM.
- Qwen2.5-Coder-7B has stability score 1.00 (consistently #1). 3B scores 0.40 (variable).

### Competitive programming (Codeforces)
- Llama-3.2-3B: reasonable up to rating 900, sporadic above that.
- Phi-4-14B: 63.6% pass@3, nearing o3-mini-high (86.8%).
- Combining Python + C++ outputs increases Phi-4-14B pass@6 to 73.6%.

### For custom languages specifically
- Fine-tuned SantaCoder (1.1B) on custom code: measurable improvements.
- Fine-tuned Llama 3 8B with LoRA: 18% accuracy improvement on domain tasks, beating Llama 3 70B and Nemotron 340B.
- The pattern: small model + domain LoRA > large general model on domain tasks.

**Rail implication**: 1.5B is enough -- but only with the right base model and fine-tuning. Qwen2.5-Coder-1.5B is the clear choice for base. With 1,000-2,000 Rail examples + LoRA + grammar-constrained decoding, the effective accuracy for Rail generation should exceed the base HumanEval numbers because:
1. Grammar constraints eliminate all syntax errors (biggest error category).
2. Rail's minimal syntax means fewer rules to learn.
3. Domain LoRA concentrates the model's capacity on Rail patterns.

---

## Synthesis: What This Means for Rail

### The three-layer strategy

**Layer 1: Grammar-constrained generation (free, works now)**
- Rail's BNF grammar feeds directly into constrained decoding (XGrammar/Outlines).
- Any LLM generating Rail is *structurally incapable* of syntax errors.
- Works with zero fine-tuning. Works with any model.
- Grammar prompting (NeurIPS 2023) shows this alone makes DSL generation competitive.

**Layer 2: LoRA fine-tuning on Qwen2.5-Coder-1.5B (small investment)**
- 1,000-2,000 Rail examples: input/output pairs, commented code, repo-level context.
- Include FIM (fill-in-the-middle) training for completion tasks.
- LoRA rank 4, alpha 16. Single GPU. Hours not days.
- Expected result: model learns Rail semantics. Grammar handles syntax.
- Rail's Python-adjacent feel minimizes catastrophic forgetting.

**Layer 3: Type-guided verification (medium investment)**
- Rail's type system acts as lightweight formal verification.
- LLM generates code, type checker validates it, retry on failure.
- Same pattern as Kleppmann's "proof checking" argument -- hallucinated code gets rejected, model retries.
- No need for full Lean-style proofs. Type checking is enough for most cases.

### The unique position
No one else has: a language with a formal grammar + a fine-tuned small model + constrained decoding + type checking, all working together. Each piece exists separately. The combination is Rail's opportunity.

### Concrete numbers to target
- Grammar-constrained generation alone: ~0% syntax errors (vs 40%+ baseline for unknown languages).
- With 1.5B LoRA: ~60-70% semantic correctness on Rail-specific tasks (extrapolating from Qwen2.5-Coder-1.5B's 54% on Python + domain LoRA gains).
- With type checking retry loop: ~80-85% end-to-end correctness (each retry eliminates type errors).
- All running locally on Mac Mini M4 Pro in under 1 second per generation.

### What to build first
1. **Rail BNF grammar in EBNF format** for constrained decoding engines.
2. **500 Rail example pairs** (natural language description -> Rail code) as seed dataset.
3. **tree-sitter grammar for Rail** for editor integration + AST-based validation.
4. **LoRA training script** targeting Qwen2.5-Coder-1.5B with Unsloth.
5. **Type-check retry loop** that feeds errors back to the model.

---

## Sources

### Languages and AI-native design
- [SudoLang: A Powerful Pseudocode Programming Language for LLMs](https://medium.com/javascript-scene/sudolang-a-powerful-pseudocode-programming-language-for-llms-d64d42aa719b)
- [AI-Enhanced Programming Languages for 2026](https://www.thefullstack.co.in/ai-enhanced-programming-languages-2026/)

### LLM call structuring
- [SGLang: Efficient Execution of Structured Language Model Programs](https://arxiv.org/abs/2312.07104)
- [DSPy: The framework for programming language models](https://github.com/stanfordnlp/dspy)
- [DSPy vs LangChain Comparison](https://qdrant.tech/blog/dspy-vs-langchain/)

### Code generation quality
- [LLMs for Code Generation: Research on Quality (Sonar)](https://www.sonarsource.com/resources/library/llm-code-generation/)
- [A Survey on Large Language Models for Code Generation](https://arxiv.org/abs/2406.00515)

### LoRA and fine-tuning
- [LoRA Fine-tuning Hyperparameters Guide (Unsloth)](https://unsloth.ai/docs/get-started/fine-tuning-llms-guide/lora-hyperparameters-guide)
- [Efficient Fine-Tuning with LoRA (Databricks)](https://www.databricks.com/blog/efficient-fine-tuning-lora-guide-llms)
- [Fine-Tuning Small LMs for Code Review (NVIDIA)](https://developer.nvidia.com/blog/fine-tuning-small-language-models-to-optimize-code-review-accuracy/)
- [Fine-tuning a Code LLM on a single GPU (HuggingFace)](https://huggingface.co/learn/cookbook/en/fine_tuning_code_llm_on_single_gpu)

### Code model training
- [DeepSeek-Coder: When the LLM Meets Programming](https://deepseekcoder.github.io/)
- [StarCoder 2 and The Stack v2](https://huggingface.co/papers/2402.19173)

### Tree-sitter
- [Tree-sitter: Incremental Parsing for Programming Tools](https://github.com/tree-sitter/tree-sitter)
- [Incremental Parsing with Tree-sitter: Enhancing Code Analysis](https://dasroot.net/posts/2026/02/incremental-parsing-tree-sitter-code-analysis/)
- [Semantic Code Indexing with AST and Tree-sitter for AI Agents](https://medium.com/@email2dineshkuppan/semantic-code-indexing-with-ast-and-tree-sitter-for-ai-agents-part-1-of-3-eb5237ba687a)

### Grammar prompting
- [Grammar Prompting for Domain-Specific Language Generation (NeurIPS 2023)](https://arxiv.org/abs/2305.19234)
- [Constrained Decoding: Grammar-Guided Generation](https://mbrenndoerfer.com/writing/constrained-decoding-structured-llm-output)

### Program synthesis and verification
- [Combining LLM Code Generation with Formal Specifications](https://arxiv.org/abs/2410.19736)
- [Prediction: AI will make formal verification go mainstream (Kleppmann)](https://martin.kleppmann.com/2025/12/08/ai-formal-verification.html)
- [CLEVER: Benchmark for Formally Verified Code Generation](https://arxiv.org/pdf/2505.13938)
- [A Benchmark for Vericoding](https://arxiv.org/pdf/2509.22908)

### Small model benchmarks
- [Assessing Small Language Models for Code Generation](https://arxiv.org/html/2507.03160v3)
- [Code Generation with Small Language Models: Codeforces Study](https://arxiv.org/html/2504.07343v2)
- [DeepSeek-Coder Benchmarks](https://deepwiki.com/deepseek-ai/DeepSeek-Coder/2.2-performance-and-benchmarks)
