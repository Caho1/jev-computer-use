import copy
import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jev import Halt, decode_choice, build_candidates, make_request, choose, completed, validate_task
from benchmark import cases
from mac_use import run


def answer(options, selected, p=1.0):
    rest = (1-p)/(len(options)-1) if len(options)>1 else 0
    return {"type": "choice", "choice": selected, "confidence": .9,
            "probabilities": {o: p if o == selected else rest for o in options}}


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.case = copy.deepcopy(cases()[4])
        self.snap, self.task = self.case["snapshot"], self.case["task"]

    def test_disabled_and_secure_never_actions(self):
        self.snap["nodes"][0]["secure"] = True
        self.snap["nodes"][1]["enabled"] = False
        self.assertEqual(build_candidates(self.snap, self.task), [])

    def test_ambiguous_selector_stops(self):
        self.task["actions"][0]["selector"] = {"role": "AXTextField"}
        self.snap["nodes"].append(dict(self.snap["nodes"][0], id="e9"))
        with self.assertRaises(Halt): build_candidates(self.snap, self.task)

    def test_truncated_tree_stops(self):
        self.snap["truncated"] = True
        with self.assertRaises(Halt): build_candidates(self.snap, self.task)

    def test_no_redundant_value_write(self):
        self.snap["nodes"][0]["value"] = "penguin"
        self.assertTrue(all(c.op != "set_value" for c in build_candidates(self.snap, self.task)))

    def test_unobserved_capability_not_offered(self):
        self.snap["nodes"][1]["actions"] = []
        self.assertTrue(all(c.op != "press" for c in build_candidates(self.snap, self.task)))

    def test_malformed_probability_fails_closed(self):
        options = {"a": "one", "b": "two"}
        for bad in [float("nan"), -1, 2, True]:
            a = answer(options, "a")
            a["probabilities"]["a"] = bad
            with self.assertRaises(Halt): decode_choice(a, options)

    def test_unknown_choice_and_probability_key_rejected(self):
        for a in [answer(["a", "b"], "c"), answer(["a", "c"], "a")]:
            with self.assertRaises(Halt): decode_choice(a, {"a": "", "b": ""})

    def test_uncertainty_abstains(self):
        with self.assertRaises(Halt): decode_choice(answer(["a", "b"], "a", .55), ["a", "b"])

    def test_fanout_uses_only_chosen_operation_head(self):
        _, q, c = make_request(self.snap, self.task, mode="fanout")
        target = next(c for c in c if c.op == "set_value")
        data = {"answers": {"operation": answer(q["operation"]["criteria"], "set_value"),
                           "target_set_value": answer(q["target_set_value"]["criteria"], target.key),
                           "target_press": {"corrupt": "unused head"}}}
        status, action, _ = choose(data, q, c, "fanout")
        self.assertEqual((status, action.op), ("ACTION", "set_value"))

    def test_success_requires_exact_unique_evidence(self):
        self.task["success"] = [{"selector": {"identifier": "id0"}, "value": "penguin"}]
        self.assertFalse(completed(self.snap, self.task))
        self.snap["nodes"][0]["value"] = "penguin"
        self.assertTrue(completed(self.snap, self.task))
        self.snap["nodes"].append(dict(self.snap["nodes"][0], id="e9"))
        self.assertFalse(completed(self.snap, self.task))

    def test_task_cannot_grant_global_actions(self):
        self.task["actions"][0]["selector"] = {}
        with self.assertRaises(Halt): validate_task(self.task)

    def test_truncated_value_cannot_prove_completion(self):
        self.task["success"] = [{"selector": {"identifier": "id0"}, "value": "penguin"}]
        self.snap["nodes"][0].update(value="penguin", value_truncated=True)
        self.assertFalse(completed(self.snap, self.task))

    def test_model_done_without_evidence_is_not_success(self):
        class Client:
            def evaluate(self, state, questions):
                return {"answers": {"action": answer(questions["action"]["criteria"], "DONE")}}, {}
        snap = self.snap
        class Bridge:
            def request(self, cmd):
                assert cmd["cmd"] == "snapshot"
                return snap
        with redirect_stdout(io.StringIO()):
            result = run(self.task, Client(), Bridge(), "flat", 2, 10, True)
        self.assertEqual(result["status"], "needs_host_verification")

    def test_live_loop_checks_post_action(self):
        self.task["success"] = [{"selector": {"identifier": "id0"}, "value": "penguin"}]
        self.snap["snapshot"] = "v1"
        class Client:
            def evaluate(self, state, questions):
                return {"answers": {"action": answer(questions["action"]["criteria"], "A0")}}, {}
        snap = self.snap
        class Bridge:
            def request(self, cmd):
                if cmd["cmd"] == "snapshot": return snap
                if cmd["cmd"] == "act":
                    snap["nodes"][0]["value"] = cmd["text"]
                return {"ok": True}
        with redirect_stdout(io.StringIO()):
            result = run(self.task, Client(), Bridge(), "flat", 1, 10, True)
        self.assertEqual(result["status"], "verified")

    def test_demo_rejects_old_result_with_empty_query(self):
        import json
        task = json.loads((Path(__file__).resolve().parents[2] / "references/demo-task.json").read_text())
        snap = {"nodes": [{"id": "e1", "identifier": "jev.query", "value": ""},
                          {"id": "e2", "identifier": "jev.status", "value": "Results for: penguin"}]}
        self.assertFalse(completed(snap, task))

    def test_final_snapshot_checks_app(self):
        class Client:
            def evaluate(self, state, questions):
                return {"answers": {"action": answer(questions["action"]["criteria"], "WAIT")}}, {}
        snap = self.snap
        class Bridge:
            calls = 0
            def request(self, cmd):
                if cmd["cmd"] != "snapshot": return {"ok": True}
                self.calls += 1
                return snap if self.calls == 1 else dict(snap, bundle_id="wrong.app")
        with redirect_stdout(io.StringIO()), self.assertRaises(Halt):
            run(self.task, Client(), Bridge(), "flat", 1, 10, True)

    def test_failed_action_is_traced_without_text(self):
        self.snap["snapshot"] = "v1"
        class Client:
            def evaluate(self, state, questions):
                return {"answers": {"action": answer(questions["action"]["criteria"], "A0")}}, {}
        snap = self.snap
        class Bridge:
            def request(self, cmd):
                if cmd["cmd"] == "snapshot": return snap
                raise Halt("AX: target_changed")
        trace = io.StringIO()
        with redirect_stdout(io.StringIO()), self.assertRaises(Halt):
            run(self.task, Client(), Bridge(), "flat", 1, 10, True, trace)
        self.assertIn('action_failed', trace.getvalue())
        self.assertNotIn('penguin', trace.getvalue())


if __name__ == "__main__": unittest.main()
