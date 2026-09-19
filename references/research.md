# Design evidence, 2026-09-18

## Model fit

Jev is a text-only typed decision API. The pinned model is `jev-1.13.0`, called through `POST https://api.typesafe.ai/v1/systemone` with a bearer key, `state`, `model`, and `questions`. Choice produces an option, distribution and confidence. Current input pricing is USD 0.042/M tokens, with no output-token charge. See [API](https://docs.typesafe.ai/api), [models](https://docs.typesafe.ai/models), and [Choice](https://docs.typesafe.ai/primitives/choice).

Use Jev for bounded semantic decisions, Codex for decomposition and text generation, and deterministic code for selectors, allowed capabilities, arithmetic and verification. A Choice supports up to 255 options, so the runtime reserves 3 for WAIT/DONE/BLOCKED. [Parallel questions](https://docs.typesafe.ai/patterns/fan-out) can combine operation and target heads into one request. They are independent evaluations; only execute a compatible head.

The vendor documents limitations with long irrelevant state, arithmetic, indirection, adversarial input and text generation. UI text is adversarial data, and a probability is not an authorization mechanism. See [model limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13) and [confidence semantics](https://docs.typesafe.ai/confidence).

## Measured API performance

Real authenticated calls, synthetic AX observations, Linux cloud environment behind its configured HTTPS proxy. Location unknown. One unreported-to-the-table cold warmup plus 60 sequential measured requests, randomized ordering, 10 distinct fixtures repeated 3 times for each mode. Fixed model; no automatic retries. Timing is full HTTP response wall time, including network, not server inference time. Both modes used one reused connection.

| Mode | Requests | p50 | p95 nearest-rank | Min/max | Correct fixture outcomes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Flat complete-action Choice | 30 | 313.769 ms | 393.131 ms | 202.081 / 427.123 ms | 30/30 |
| Fanout operation and compatible targets | 30 | 306.216 ms | 388.543 ms | 192.824 / 425.467 ms | 30/30 |

Cold warmup: 6376.420 ms. Total 187,018 input tokens including warmup. Estimated published-price input cost: USD 0.007854756, not a billing-statement reconciliation. Warm requests total 185,796 input tokens. All 60 cleared the provisional p>=0.80 / margin>=0.25 gates.

Fixtures include 8/60/180 buttons, a Chinese cancel instruction, filling a field, already-complete state, loading, missing target, disabled button, and one injected instruction. The set is simple and synthetic; repeated decisions are not independent task coverage. This does not establish robustness to real prompt injection or a Mac task success rate. Flat/fanout timing differences are small relative to variation, so no speed superiority is claimed. Default flat reduces complexity and used 2.8% fewer input tokens in this sample.

For the flat search fixtures, median HTTP latency rose from 294.772 ms (8 nodes, 1,222 input tokens) to 345.992 ms (60 nodes, 6,308 tokens) and 393.131 ms (180 nodes, 18,388 tokens). Each has only 3 samples. Compact relevant state is worth investigating; exact speed gains require real-app measurements.

## macOS design

Use a compiled resident Swift helper, app-scoped AX handles, batch reads of common attributes, and AXObserver notifications. Check snapshot identity and age, current app/window and target signature before each action. Keep total task time separate from model time. The version implemented here still traverses the focused tree each step; it does not yet maintain a fully incremental AX subtree cache.

[Apple accessibility model](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html) describes semantic UI exposure. [Batch attribute API](https://developer.apple.com/documentation/applicationservices/1462051-axuielementcopymultipleattribute) supplies the native observation primitive. Native notifications can be incomplete and AX is not a transactional interface.

[OpenAI Computer Use documentation](https://learn.chatgpt.com/docs/computer-use) confirms macOS permission and UI operation support, but does not establish what proportion of its private runtime uses AX trees versus screenshots. Do not claim that Codex exclusively uses an AX tree, or that this skill swaps an internal Codex model.

Relevant open-source references are [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast), which demonstrates indexed Jev action selection in a browser, and [Peekaboo](https://github.com/openclaw/Peekaboo), which exposes Mac accessibility inspection and UI automation. Neither project's performance is an independently reproduced benchmark in this work. The bundled implementation is original and does not vendor either project.

## Acceptance status

The Python control policy and HTTP client have been exercised on Linux; 17 behavioral tests pass. An independent offline two-step harness also exercised the Python loop. Findings about stale completion evidence, last-step app identity and trace coverage were fixed and regression-tested. Native Swift compilation, TCC behavior, AX notification coverage and end-to-end Mac latency remain unverified. Run the included native demo and then real-app tasks before describing the skill as Mac-validated. Do not reuse model-only latency as the total computer-use speed.
