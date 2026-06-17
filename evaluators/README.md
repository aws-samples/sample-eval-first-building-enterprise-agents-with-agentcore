# Custom Code-Based Evaluators

This folder contains two custom evaluators that run as Amazon Bedrock AgentCore
**code-based evaluators**. They demonstrate the *bring-your-own-evaluator* extension
point: how to plug your own evaluation logic into AgentCore's online / on-demand
evaluation, so the evaluation standard stays **your team's asset** while the platform
handles scheduling.

The two evaluators are **complementary**:

| Folder | Evaluator | Level | What it measures | Primary metric |
|--------|-----------|-------|------------------|----------------|
| `thelma_eval/` | **THELMA** | TRACE (single turn) | RAG retrieval & answer quality | 6-dimension scores; primary = **Groundedness** |
| `mtg_eval/`    | **Mind the Goal** | SESSION (multi-turn) | Whether the user's goal was achieved | Goal Success Rate (GSR) + Root Cause of Failure (RCOF) |

THELMA catches *"does a single answer hallucinate / is retrieval accurate?"*;
Mind the Goal catches *"across the whole conversation, did the user actually get
what they came for?"*

> **Scope.** These are teaching reference implementations that reproduce externally
> published research methods. They are **not** a product and are **not** meant to
> replace AgentCore's built-in evaluators (`Builtin.Correctness`,
> `Builtin.Faithfulness`, `Builtin.GoalSuccessRate`, …), which remain the
> recommended managed option for quick validation.

---

## How a code-based evaluator works

Each evaluator is a **Lambda function**. You don't call it — when you trigger an
evaluation, the AgentCore evaluation service calls it for you: it feeds in the trace
data of a conversation and collects a score back.

```
your conversation trace ──→ AgentCore eval service ──→ calls evaluator Lambda ──→ returns score
                          (packs trace as input)                              (writes result)
```

- **Input:** the evaluation level (SESSION / TRACE / TOOL_CALL), the conversation's
  span data (the raw trace), and — for TRACE-level — which trace to score.
- **Output:** `value` (a numeric score, e.g. `0.94`), `label` (e.g. `Pass` / `Fail`),
  and `explanation` (text describing how the score was derived).

---

## THELMA — single-turn RAG quality

THELMA decomposes one Q&A into the triplet `(user question, retrieved source
documents, agent answer)` and uses an LLM-as-Judge to check it point by point,
producing **6 scores from 0 to 1**:

| Metric | Full name | Meaning | What a low score means |
|--------|-----------|---------|------------------------|
| **SP**  | Source Precision        | Of the retrieved docs, the fraction that is actually relevant | retrieval pulled in irrelevant content |
| **SQC** | Source Query Coverage   | Do the source docs cover all aspects of the question?         | the answer isn't in the knowledge base |
| **RP**  | Response Precision      | Fraction of the answer that is on-topic                       | answer is verbose / off-topic |
| **RQC** | Response Query Coverage | Are all aspects of the question answered?                     | answer is incomplete |
| **SD**  | Self-Distinctness       | Is the answer free of internal repetition?                    | same info repeated |
| **GR**  | **Groundedness**        | **Is every sentence in the answer backed by a source doc?**   | **hallucination present** |

**GR (Groundedness) is the most critical metric** — it answers "is this answer
evidence-backed?" In HR / legal / compliance settings, low GR means the agent is
fabricating policy details from training knowledge instead of basing them on retrieval.

THELMA's real value is **diagnosis**: the *interplay* of the scores points at which
RAG component to fix, not just that the score is low.

| Score pattern | Diagnosis | Fix direction |
|---------------|-----------|---------------|
| `SQC↓` + `RQC↑` + `GR↓` | retrieval didn't cover it, but the model answered anyway with no source support → **the model is fabricating** | tighten the **prompt** ("answer only from retrieved content") |
| `SQC↓` + `RQC↓`         | retrieval missed and the answer is incomplete → **retrieval failure / KB gap** | fix the **retriever or add/clean source docs** |
| `RP↓` + `SP↑`           | retrieval is clean but the answer carries irrelevant content → **answer not focused** | constrain output in the **prompt** |

Implemented in `thelma_eval/` (metrics in `evaluators/thelma/metrics.py`, prompts in
`evaluators/thelma/prompts.py`, the metric-interplay diagnosis in `interplay.py`).

> SP appears in the diagnosis as **SP1** (chunk-level retrieval precision) and **SP2**
> (fact-level precision). A high SP1 with a low SP2 means the retrieved chunk looks
> on-topic but most of the *facts* it carries are noise — exactly the symptom of dirty
> data mixed into the source documents.

## Mind the Goal — multi-turn goal achievement

Real conversations are multi-turn. Where THELMA scores a single answer, Mind the Goal
asks: **across the entire conversation, did the user accomplish what they set out to
do?** It runs in three steps:

1. **Segment goals** — scan the conversation turn by turn and merge consecutive turns
   about the same thing into one **Goal**.
2. **Judge success/failure** — for each goal, decide success or failure; a goal fails
   if **any** turn within it fails.
3. **Compute GSR + attribute RCOF**:
   - **GSR (Goal Success Rate)** = successful goals / total goals.
   - **RCOF (Root Cause of Failure)** — attribute each failed goal to one of 7 defect
     categories.

Implemented in `mtg_eval/` (RCOF taxonomy in `shared/models.py`, GSR computation in
`evaluators/mind_the_goal/gsr.py`, prompts in `evaluators/mind_the_goal/prompts.py`).

---

## Method attribution

Both evaluators are **independent re-implementations** based on two published papers
(same research team). The algorithms, metric definitions (THELMA's 6 metrics, the RCOF
taxonomy), and prompt templates are derived from those works; the code here does not
derive from any other codebase.

- **THELMA: Task Based Holistic Evaluation of Large Language Model Applications — RAG
  Question Answering.** Udita Patel, Rutu Mulkar, Jay Roberts, Cibi Chakravarthy
  Senthilkumar, Sujay Gandhi, Xiaofei Zheng, Naumaan Nayyar, Parul Kalra, Rafael
  Castrillo. arXiv:2505.11626 (May 2025). https://arxiv.org/abs/2505.11626
- **Mind the Goal: Data-Efficient Goal-Oriented Evaluation of Conversational Agents and
  Chatbots using Teacher Models.** Deepak Babu Piskala, Sharlene Chen, Udita Patel,
  Parul Kalra, Rafael Castrillo. arXiv:2510.03696 (October 2025).
  https://arxiv.org/abs/2510.03696

**What's from the paper vs. ours:**

- **From the paper:** the evaluation algorithm, metric definitions, and prompt templates.
- **Our addition:** the **adapter layer** converting an AgentCore ADOT trace span into
  the evaluator's input (`thelma_eval/span_adapter.py`, `mtg_eval/session_adapter.py`),
  plus the AgentCore Lambda handler wiring (`lambda_function.py` in each folder).

---

## Runtime configuration

Both evaluators read their model / region / thresholds from environment variables,
with these defaults (set in each `lambda_function.py`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `THELMA_MODEL` / `MTG_MODEL` | `us.amazon.nova-2-lite-v1:0` | LLM-as-judge model |
| `THELMA_REGION` / `MTG_REGION` | `us-west-2` | Bedrock region |
| `THELMA_EMBED_MODEL` | `amazon.titan-embed-text-v2:0` | THELMA embedding model |
| `THELMA_GR_THRESHOLD` | `0.7` | Groundedness Pass/Fail threshold |
| `MTG_GSR_THRESHOLD` | `80` | GSR Pass/Fail threshold (percent) |
