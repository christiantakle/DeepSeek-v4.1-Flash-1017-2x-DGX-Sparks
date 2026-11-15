# Exploratory serving concurrency and prefill scheduling

Two DGX Sparks, DeepSeek-V4.1-Flash-1017, observations from 2026-11-15.
This is a standalone experiment note on the operator's fork. It proposes no
runtime defaults or engine changes and is separate from the upstream build/cache
and dependency-maintenance PRs. Original production settings were restored.

## Findings

- An earlier four-active versus eight-active comparison changed both context
  length and reply budget. It did not isolate a long-history or RAM limit.
- Identical eight cached ~100k-token prompts with reply budgets256→1024→256
  observed running peaks4→8→4. Source and admission timings support a deliberate
  short-output admission policy.
- With8192-token budgets, eight slots start coding replies earlier but do not
  demonstrate a material batch-throughput gain; median completed-reply latency
  worsens in the small coding suite.
- One four-stream candidate, `TF_FILL_CHUNKS=1` instead of4, improves completed
  coding-response latency during a cold source read, while delaying that read.
  It is a promising interactive-latency tradeoff, not a universal speedup.

## Tested environment and measurement

ARM64 two-Spark TensorFold TP2, stock EAQ v1 2.9-bpw model. Engine revision
`fbbc97132cd004237d9887b8d3185896efaedc5c`, inputs revision
`59402086381a42c74d53053443224eec2790b4c5`, the recipe's53 engine/twoinputs patches.
Runtime checkpoint `70b3722050b33d8a394886ace737aaada6e8a064` used NVIDIA26.10,
Zig0.17.1, Pillow13.0.0 and host driver580.178.04. The same production image,
model, prepared data, clocks and reserve/memory guards were retained for the
coding comparisons. The code on this draft branch is not itself a new runtime.

Requests used temperature0, seed1234 and thinking off. Streaming TTFT includes
queueing. Completion latency is wall time until the response ends. Running and
waiting requests were sampled from `/metrics` at roughly100ms; host MemAvailable
and swap at roughly2 s. Running includes admitted prefill/decode, not proof that
all requests decode in a single GPU round. Samples can miss brief transients.
Fresh server starts separated configuration phases; actual cached-token counts
and health-counter accounting checked cache state and extra request traffic.

## Output-budget admission control

The [pinned lane host](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/src/core/lane_host.zig)
uses `long_pass_ns=1 s`, `finish_ns=5 s` and `finish_left=256`. After an admission's
prompt pass takes at least1 s, it can delay new admissions for up to5 s while a
started unfinished request has at most256 tokens left of its configured output
budget. This is not a prediction of EOS or a test of actual eventual reply size.
The engine tests that a short reply can finish before the next gets its first token.

Same eight independent cached inputs99,983–99,998 tokens each,98,304cached/request,
shared1,048,576-position pool/window, eight slots, drafts on, spill/sharding off,
read-ahead off and fill4/4/cutin8192:

| Reply budget | Peak running | Batch completion, s | First-token gaps |
| --- | ---: | ---: | --- |
| 256 control A | 4 | 32.806 | Repeated5–6 s gaps mixed with~1 s gaps |
| 1024 | 8 | 55.533 | All seven successive gaps~1 s |
| 256 control B | 4 | 32.271 | Repeated5–6 s gaps mixed with~1 s gaps |

Prompt hashes/counts and cached-token counts match across all rounds. Both256
controls fill their budgets and match8/8 server token/text hashes. At1024, actual
replies contain698–1024 tokens. Server prefill durations0.995–1.014 s sit near the
one-second trigger:5/8 controls and8/8 larger-budget prefills exceeded1 s. Cached
~1.7k tails fit the first four-chunk allowance and reach that admission branch.

Source plus reversible timing strongly supports the short-output policy as the
explanation of this contrast, not a fixed four-request capacity ceiling for
these histories. Longer generation also increases overlap; the policy was not
independently disabled. Different output lengths preclude a speedup comparison.
RAM headroom was an observation, not a diagnosis of memory exhaustion.

## Coding concurrency comparison

Fresh4→8→4 server phases:524288-token window, shared1572864-position pool,
drafts on, read-ahead off, `TF_FILL_CHUNKS=4`, `TF_FILL_FIRST=4`,
`TF_FILL_CUT_IN=8192`. Every request declared8192 reply tokens. Three rounds per
phase submitted eight simultaneous clients, even when the server had four slots.
A separate short warmup preceded measurement.

The custom suite asks for six self-contained TypeScript modules: strict ASCII
port parsing; LRU with Map semantics; bounded async mapping with failure handling;
stable topological sorting; interval merging; original-offset UTF-16 text edits.
Two jobs repeat the LRU and async-map contracts. Salts vary by job/round, not
configuration. No repository-scale patch generation or agent tool loop is tested.

| Metric | Four A1 | Eight B | Four A2 |
| --- | ---: | ---: | ---: |
| Median eight-job batch completion, s | 17.246 | 16.570 | 17.279 |
| Median first token, s | 3.270 | 1.705 | 3.278 |
| p95 first token, s | 11.424 | 3.033 | 11.734 |
| Median complete reply, s | 11.901 | 15.195 | 11.805 |
| p95 complete reply, s | 17.245 | 17.295 | 17.345 |
| Total output tokens across three rounds | 7683 | 7683 | 7683 |
| Observed peak running each round | 4 | 8 | 4 |

Percentiles use nearest rank on24 requests/phase. All24prompt/count/token/text
hashes match across phases; cache counts zero. Eight slots reduce initial
queueing but do not establish a material batch-throughput improvement in this
small sample. Actual replies peak at438 tokens, so the short-output policy
cannot bind these8192-budget jobs.

## Mixed workload and one-chunk candidate

A cold source-reading request contains110768actual input tokens from28 complete
public repository files (349150 characters). Five questions about script defaults
are checked against exact JSON ground truth. Eight coding requests arrive five
seconds after the source read starts. Source cache counts zero and identical
prompt hashes across configurations are verified.

| Metric | Four A1 | Eight B | Four A2 | Four, chunks1 |
| --- | ---: | ---: | ---: | ---: |
| Median complete coding reply, s | 62.444 | 63.003 | 62.384 | **40.441** |
| First complete coding reply, s | 33.788 | 57.102 | 33.917 | **11.182** |
| Source-read completion, s | 60.391 | 62.681 | 60.728 | **72.138** |
| Total scenario completion, s | 70.909 | 71.096 | 71.057 | 72.195 |
| Worst content-token gap, s | 4.241 | 4.247 | 4.256 | **1.337** |

Coding latencies start at coding submission; source latency starts at source
submission. The candidate changes only `TF_FILL_CHUNKS=4` to1; first-piece4,
cut-in8192, four streams and guards remain unchanged. This gives decoding more
frequent turns between prefill pieces.

In this single candidate sample, median completed-code latency improves about35%
and first completion about67%; source-read completion becomes about19%slower and
total scenario time about2%longer. All eight tuned token/text hashes match the
tested baseline. It looks useful for interactive coding amid cold prefills;
it is not evidence that every workload improves or a new default is optimal.

## Correctness, safety and limits

96 baseline coding drafts map to18 distinct reviewed implementations. Local isolated
Deno2.9.8 type/functional checks pass, including a NUL-node topological-sort
regression. Byte-identical tested projects are reused by hash; these are not96
independent coding-quality samples. Eight tuned outputs match accepted baseline
implementations. Ground-truth source answers and usage/accounting checks pass.

Sampled MemAvailable minima, head/worker GiB: budget-control7.18/10.00;
coding A1 7.49/10.00; B8 7.55/10.06; A2 7.52/9.95; tuned7.62/10.01. Swap0,
container OOM flags false and selected new kernel fault-pattern matches0/0
through restoration. No memory guard or engine policy was disabled. Original
image IDs/config/prepared marker verified restored; routine four-stream,
four-chunk settings remain active.

Three coding rounds and one mixed scenario per control phase, one tuned mixed
sample, one hardware pair: no statistical-significance, sustained-agent, thermal
soak, arbitrary long-context quality or universal-throughput claim. These tables
summarize a custom private harness; exact prompts/acceptance fixtures are not
published here, so they are not a complete reproduction package. Machine-local
configuration, addresses, raw transcripts, generated code and credentials are
excluded. No runtime change is proposed by this documentation-only draft.
