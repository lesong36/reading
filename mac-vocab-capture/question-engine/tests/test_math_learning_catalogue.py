import json
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import HumanMessage
from math_learning import learn_skills, catalogue_scan_for, LearningOutputError
from test_math_learning import Model, coverage, evidence, proposal, review


def rows(count=3, size=130000):
    return [{"id": "method-" + str(i), "version_id": "v1", "title": "method", "category": "arithmetic",
             "instructions": "x" * size} for i in range(count)]


def scan(ids, retained=()):
    return {"entries": [{"id": identifier, "disposition": "candidate" if identifier in retained else "excluded",
                         "reason": "Checked the complete method against all required substeps"} for identifier in ids]}


class CatalogueLearningTests(unittest.IsolatedAsyncioTestCase):
    async def run_graph(self, model, snapshots):
        value, execution = await learn_skills(model, [HumanMessage("Source")], snapshots, {"evidence": evidence()})
        return json.loads(value), execution

    async def test_cross_page_partial_methods_are_reconciled_with_complete_bodies(self):
        final = coverage("covered", ["q-a"])
        final["covered_method_ids"] = ["method-0", "method-2"]
        model = Model([scan(["method-0", "method-1"], ["method-0"]), scan(["method-2"], ["method-2"]), final])
        result, execution = await self.run_graph(model, rows())
        self.assertEqual(result["coverage"], "covered")
        self.assertEqual(execution["model_calls"], 3)
        self.assertEqual([r["id"] for r in model.inputs[-1]["skills"]], ["method-0", "method-2"])
        self.assertTrue(all(len(r["instructions"]) == 130000 for r in model.inputs[-1]["skills"]))

    async def test_incomplete_scan_after_one_repair_cannot_draft(self):
        model = Model([scan(["method-0"]), scan(["method-0"])])
        result, _ = await self.run_graph(model, rows())
        self.assertEqual(result["coverage"], "uncertain")
        self.assertEqual(result["status"], "observing")
        self.assertIsNone(result["proposal"])
        self.assertEqual(model.calls, 2)

    async def test_all_excluded_still_requires_final_reconciliation(self):
        model = Model([scan(["method-0", "method-1"]), scan(["method-2"]), coverage("uncertain", [])])
        result, _ = await self.run_graph(model, rows())
        self.assertEqual(result["coverage"], "uncertain")
        self.assertEqual(model.calls, 3)
        self.assertEqual(model.inputs[-1]["skills"], [])
        self.assertEqual(len(model.inputs[-1]["catalogue_scan"]), 2)

    async def test_complete_negative_scan_can_discover_only_after_reconciliation(self):
        model = Model([scan(["method-0", "method-1"]), scan(["method-2"]),
                       coverage(), proposal(), review()])
        result, execution = await self.run_graph(model, rows())
        self.assertEqual(result["status"], "awaiting_human")
        self.assertEqual(execution["model_calls"], 5)
        self.assertIsNotNone(result["proposal"])

    async def test_uncertain_submethod_is_not_discarded(self):
        first = scan(["method-0", "method-1"])
        first["entries"][0]["disposition"] = "uncertain"
        model = Model([first, scan(["method-2"]), coverage("uncertain", [])])
        await self.run_graph(model, rows())
        self.assertEqual([item["id"] for item in model.inputs[-1]["skills"]], ["method-0"])

    async def test_retained_workset_over_limit_cannot_claim_uncovered(self):
        model = Model([scan(["method-0", "method-1"], ["method-0", "method-1"]), scan(["method-2"], ["method-2"])])
        result, _ = await self.run_graph(model, rows())
        self.assertEqual(result["coverage"], "uncertain")
        self.assertEqual(model.calls, 2)
        self.assertIsNone(result["proposal"])

    async def test_page_limit_never_runs_partial_scan(self):
        model = Model([])
        result, _ = await self.run_graph(model, rows(9, 160000))
        self.assertEqual(result["coverage"], "uncertain")
        self.assertEqual(model.calls, 0)

    async def test_single_page_preserves_one_call_protocol(self):
        model = Model([coverage("uncertain", [])])
        result, _ = await self.run_graph(model, rows(1, 30))
        self.assertEqual(model.calls, 1)
        self.assertNotIn("catalogue_scan", model.inputs[0])
        self.assertEqual(result["coverage"], "uncertain")

    def test_every_id_exactly_once_and_uncertain_is_retained(self):
        value = scan(["a", "b"])
        value["entries"][1]["disposition"] = "uncertain"
        self.assertEqual(catalogue_scan_for(value, {"a", "b"})["retained"], {"b"})
        value["entries"].append(value["entries"][0])
        with self.assertRaises(LearningOutputError):
            catalogue_scan_for(value, {"a", "b"})
