# Runtime and local acceptance

## Contents

Local setup; task format; execution guarantees; performance limits; failure handling.

## Local setup

Use a terminal or local Codex executor on the user's Mac, in this skill's folder. Python must be 3.10 or newer. `xcrun --find swiftc` must succeed. If Xcode Command Line Tools are absent, the user can install them with `xcode-select --install`.

```bash
bash scripts/build.sh
python3 scripts/mac_use.py doctor
```

The compiler creates `~/Library/Caches/jev-mac-use/axbridge`. `doctor` reports `accessibility_trusted`. Grant Accessibility to the helper or responsible terminal/Codex host that macOS identifies in System Settings > Privacy & Security > Accessibility. Do not change TCC databases. The user handles this one-time OS permission. The loop requires the target app to stay frontmost and stops if the foreground changes.

Set `TYPESAFE_API_KEY` locally without saving it to shell history. In an interactive Bash session:

```bash
read -r -s -p 'TypeSafe API key: ' TYPESAFE_API_KEY
export TYPESAFE_API_KEY
```

For a native smoke demo, run the following as one command block so launching the app puts it in front before AX access:

```bash
bash scripts/demo.sh
python3 scripts/mac_use.py run --task references/demo-task.json --execute --trace /tmp/jev-mac-demo.jsonl
```

The demo app only edits its own temporary in-memory UI. Expected result is `Results for: penguin` and a final `verified`. Existing trace files are not overwritten; choose a fresh path on reruns. Reset the demo using its Reset button before another run. `--ask-key` is available when the environment variable is absent, but key entry can bring the terminal to the foreground; restore the target app before running the loop.

## Task format

```json
{
  "bundle_id": "local.jev.maclab",
  "goal": "Fill Search query with penguin and click Search.",
  "actions": [
    {"op": "set_value", "selector": {"identifier": "jev.query"}, "text": "penguin"},
    {"op": "press", "selector": {"identifier": "jev.search"}}
  ],
  "success": [
    {"selector": {"identifier": "jev.query"}, "value": "penguin"},
    {"selector": {"identifier": "jev.status"}, "value": "Results for: penguin"}
  ]
}
```

Selectors use exact equality for `identifier`, `label`, `role`, `parent_label`, or `value`, with at least a label or identifier. Multiple fields are ANDed. A selector matching more than one node stops the loop. A selector absent from the current screen is not offered as an action. Every action uses the handle in the current snapshot. Values already equal to their requested text are not written again.

`success` is a list of checks that must all pass. Each check must match exactly one current node, and its optional `value` must equal the expected value. For button state or other properties not covered by this schema, return control to the host for verification instead of inventing a weak success criterion. A vague goal needs host planning first; this v0.1 runtime does not autonomously discover arbitrary workflows.

Optional `include_menu: true` includes the menu bar tree. It is off by default to reduce irrelevant nodes and IPC. Enable it only for a menu subgoal, and use `observe --include-menu` first. Large menu trees can exceed the bounded snapshot budget and must be handled by the host.

## Execution guarantees and limitations

The Swift process maintains live `AXUIElement` references and runs an `AXObserver` on its main run loop. Each snapshot has a fresh UUID, an event epoch and a 5-second expiry. Before mutation it checks app PID, frontmost app, focused window, event epoch, element signature, enabled state, secure-field exclusion and capability. Each handle set is consumed by one mutation, including a failed attempt. Text is assigned through `AXValue`, with no clipboard or keyboard injection.

Snapshots stop at 250 nodes, depth 14, or approximately 1.5 seconds of traversal. Common attributes are fetched in a batched IPC call. Individual messaging timeout is 150 ms; the traversal deadline is checked between nodes, so it is a soft bound. The Python parent has a separate 15-second process-response timeout. Truncated or partly unreadable snapshots stop execution rather than imply complete UI coverage. Some apps omit notifications, and a UI can change between validation and action: AX provides no transaction across those operations. Foreground checks and target revalidation reduce this risk but do not eliminate it.

AX values and labels are clipped to 240 characters. This bounds request size but means long exact text assertions and long-value changes cannot be fully verified. Keep this prototype's text slots and expected values short; delegate long document editing to structured tools. Password fields are excluded; no comprehensive PII detector is claimed. A short quiet period after an action is only a settling heuristic, not proof a network page finished loading.

## Timing

One Python process reuses one HTTPS connection. It honors the environment's configured HTTP CONNECT proxy for HTTPS. Credentials go only inside TLS to the fixed TypeSafe host. A small warmup request runs before the first snapshot so cold latency does not expire a handle. No automatic request retries hide failures or inflate measurements.

`flat` offers complete action-target pairs plus WAIT/DONE/BLOCKED in one Choice. `fanout` asks operation and each compatible target head together. Only the head matching the chosen operation is used. The two decisions are independent; never interpret them as a jointly calibrated probability. At most 252 action pairs plus 3 terminal choices are offered.

Trace fields include `api_ms`, `observe_ms`, `execute_ms`, `settle_ms`, `loop_ms`, token usage, model version, action ID and confidence. Warmup, final result, and failures are recorded as separate events. Traces omit text slots and UI text. Report cold start, p50/p95 of full steps, task success rate, wrong-action rate and host fallback rate separately. Host planning/setup time is outside `loop_ms`.

## Failure handling

| Status/error | Meaning and next action |
| --- | --- |
| `verified` | All explicit success checks passed on a fresh snapshot. |
| `preview` | Proposed one action without executing. |
| `needs_host_verification` | Jev said DONE without the required evidence. Inspect through the host. |
| `stale_snapshot`, `target_changed`, `window_changed` | UI changed during decision. Inspect a new snapshot; no automatic replay. |
| `target_app_not_frontmost` | User or another app took focus. Restore the intended app before a new bounded run. |
| `no_progress`, `repeated_action`, `step_budget`, `wait_budget` | Stop and replan the current subgoal. |
| HTTP 401/429/529 or transport failure | Stop; inspect key, limits or network. No mutation occurred for that decision. |
| `ax_action_failed_*` | The action may have had partial effect. Reobserve before deciding anything else. |

The initial probability floor is 0.80 and top-two margin floor is 0.25. They are engineering starting points, not a measured confidence calibration for macOS.
