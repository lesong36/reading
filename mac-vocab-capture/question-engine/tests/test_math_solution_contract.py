"""Single-submission shape is strict while native arithmetic remains authoritative."""
import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from math_solution_contract import TOOL_NAME, SolutionContractError, normalize_arguments, tool_schema


def quantity(value, unit="", evidence="原题条件"):
    return {"value": value, "unit": unit, "evidence": evidence}


def recipe():
    return {"id": "ratio", "title": "线段比较", "kind": "difference_ratio",
            "difference": quantity(72), "multiplier": {"value": 10, "evidence": "原数乘10"}}


def submission(diagram=None):
    return {"mode": "native_recipe", "method_id": None, "visual_method_ids": [], "answer": "72÷9=8。",
            "diagram_outcome": {"status": "renderable", "primary_diagram": diagram or recipe()}}


class SolutionContractTests(unittest.TestCase):
    def test_multiplier_notation_is_dimensionless_and_physical_units_reject(self):
        for kind in ("difference_ratio", "sum_ratio"):
            diagram = recipe()
            diagram["kind"] = kind
            if kind == "sum_ratio":
                diagram["total"] = diagram.pop("difference")
            for unit in ("", "倍"):
                diagram["multiplier"]["unit"] = unit
                self.assertEqual(self.normalize(submission(diagram))["diagrams"][0]["multiplier"]["unit"], unit)
            for unit in ("岁", "棵", "米"):
                diagram["multiplier"]["unit"] = unit
                self.assertRejected(submission(diagram))

    def normalize(self, value, **kwargs):
        return normalize_arguments(json.dumps({"solution": value} if kwargs.get("strict") else value, ensure_ascii=False), **kwargs)

    def assertRejected(self, value, issue=None):
        with self.assertRaises(SolutionContractError) as caught:
            self.normalize(value)
        if issue:
            self.assertEqual(caught.exception.issue, issue)
        self.assertNotIn("SECRET", str(caught.exception))

    def test_one_tool_nullable_method_normalizes_six_fields(self):
        tool = tool_schema()
        self.assertEqual(tool["function"]["name"], TOOL_NAME)
        self.assertNotIn("strict", tool["function"])
        result = self.normalize(submission())
        self.assertEqual(set(result), {"schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams"})
        self.assertIsNone(result["method_id"])
        self.assertEqual(result["diagrams"], [recipe()])
        tool["function"]["parameters"]["properties"].clear()
        self.assertTrue(tool_schema()["function"]["parameters"]["properties"])

    def test_non_renderable_branches_do_not_invent_diagrams(self):
        for status in ("unreadable_or_insufficient", "no_helpful_diagram"):
            value = submission()
            value["mode"] = "general"
            value["diagram_outcome"] = {"status": status, "reason": "原图条件不足。"}
            result = self.normalize(value)
            self.assertEqual(result["diagrams"], [])
            self.assertIn("原图条件不足。", result["answer"])
            self.assertIsNone(result["method_id"])

    def test_text_only_requires_separate_trusted_authorization(self):
        value = submission()
        value["mode"] = "general"
        value["diagram_outcome"] = {"status": "user_requested_text_only", "reason": "用户要求仅文字。"}
        self.assertRejected(value, "submission_text_only_unauthorized")
        self.assertEqual(self.normalize(value, text_only_authorized=True)["diagrams"], [])
        self.assertRejected({**value, "text_only_authorized": True})

    def test_missing_primary_or_blank_reason_and_branch_collisions_rejected(self):
        for outcome in ({"status": "renderable"}, {"status": "no_helpful_diagram", "reason": " "},
                        {"status": "renderable", "primary_diagram": recipe(), "reason": "SECRET"},
                        {"status": "no_helpful_diagram", "reason": "未识别", "primary_diagram": recipe()}):
            self.assertRejected({**submission(), "diagram_outcome": outcome})

    def test_native_mode_requires_typed_diagram(self):
        value = submission()
        value["diagram_outcome"] = {"status": "no_helpful_diagram", "reason": "普通算术"}
        self.assertRejected(value, "submission_mode")
        plan = {"id": "g", "title": "量", "kind": "quantity_plan", "view": "state",
                "quantities": [{"id": "q", "label": "未知", "unknown": True}], "layout": {"states": ["q"]}}
        self.assertRejected(submission(plan), "submission_mode")
        value = submission(plan)
        value["mode"] = "general"
        self.assertEqual(self.normalize(value)["diagrams"], [plan])

    def test_quantities_are_discriminated_and_exact(self):
        plan = {"id": "g", "title": "量", "kind": "quantity_plan", "view": "state",
                "quantities": [{"id": "q", "label": "未知", "unknown": True}], "layout": {"states": ["q"]}}
        value = submission(plan)
        value["mode"] = "general"
        for extra in ({"value": 8, "evidence": "8"}, {"outputID": "SECRET"}, {"origin": "given"}, {"unknown": 1}):
            bad = copy.deepcopy(value)
            bad["diagram_outcome"]["primary_diagram"]["quantities"][0].update(extra)
            self.assertRejected(bad)

    def test_no_arithmetic_results_or_additional_fields_in_recipe(self):
        for key in ("answer", "facts", "relations", "layout", "outputID"):
            bad = submission()
            bad["diagram_outcome"]["primary_diagram"][key] = "SECRET"
            self.assertRejected(bad)
        self.assertRejected({**submission(), "schemaVersion": 1})

    def test_truncated_trailing_fenced_duplicate_json_rejected(self):
        raw = json.dumps(submission())
        for bad in (raw[:-1], raw + "SECRET", "```json\n" + raw + "\n```", "[]", "null"):
            with self.assertRaises(SolutionContractError):
                normalize_arguments(bad)
        for bad in (raw.replace('"mode": "native_recipe"', '"mode":"general","mode":"native_recipe"'),
                    raw.replace('"value": 72', '"value":72,"value":73')):
            with self.assertRaises(SolutionContractError) as caught:
                normalize_arguments(bad)
            self.assertEqual(caught.exception.issue, "submission_duplicate_key")

    def test_nonfinite_boolean_oversize_numbers_and_utf8_limit(self):
        raw = json.dumps(submission())
        for number in ("NaN", "Infinity", "1e999", "true", "1000000001"):
            with self.assertRaises(SolutionContractError):
                normalize_arguments(raw.replace('"value": 72', '"value":' + number))
        value = submission()
        value["answer"] = "图" * 40_001
        self.assertRejected(value)
        with self.assertRaises(SolutionContractError) as caught:
            normalize_arguments(" " * 150_001)
        self.assertEqual(caught.exception.issue, "submission_size")

    def test_limits_duplicate_diagram_and_visual_ids(self):
        for additional in ([recipe()], [recipe(), recipe(), recipe()]):
            bad = submission()
            bad["diagram_outcome"]["additional_diagrams"] = additional
            self.assertRejected(bad)
        self.assertRejected({**submission(), "visual_method_ids": ["v", "v"]}, "submission_duplicate_id")
        self.assertRejected({**submission(), "visual_method_ids": ["v1", "v2", "v3"]})

    def test_native_schema_kind_and_field_parity(self):
        diagrams = tool_schema()["function"]["parameters"]["$defs"]["diagram"]["anyOf"]
        fields = {}
        for branch in diagrams:
            kind = branch["properties"]["kind"]["enum"][0]
            fields.setdefault(kind, []).append(set(branch["properties"]))
        self.assertEqual(set(fields), {"difference_ratio", "sum_difference", "sum_ratio", "equalize_transfer", "cyclic_pattern",
                                     "fixed_total", "state_changes", "rectangle_sum_difference", "venn_counts", "return_deadline", "interval_problem", "two_allocations", "purchase_comparison", "quantity_plan"})
        expected = {
            "sum_difference": "total difference", "sum_ratio": "total multiplier",
            "equalize_transfer": "larger smaller equality_evidence",
            "fixed_total": "resource_unit count_unit original_per_item original_count improved_per_item conservation_evidence",
            "cyclic_pattern": "count labels pattern_evidence",
            "state_changes": "initial changes",
            "rectangle_sum_difference": "rectangle_evidence total_sides difference",
            "venn_counts": "total left right intersection",
            "return_deadline": "distance_unit time_unit outward_speed return_speed outward_time deadline",
            "two_allocations": "item_unit recipient_unit allocations view",
            "purchase_comparison": "item_unit currency_unit quantity_policy required_count unit_price offers",
        }
        source = Path(__file__).resolve().parents[2] / "Sources" / "VocabCapture"
        all_native = "\n".join(p.read_text() for p in source.glob("Math*Recipe.swift"))
        for kind, extras in expected.items():
            self.assertEqual(fields[kind][0], {"id", "title", "kind", *extras.split()})
            self.assertIn('"' + kind + '"', all_native)
            for field in extras.split():
                self.assertIn('"' + field + '"', all_native)
        self.assertEqual(len(fields["interval_problem"]), 2)
        self.assertEqual(len(fields["quantity_plan"]), 20)

    def test_invalid_unicode_and_deep_payload_are_bounded_errors(self):
        value = submission()
        value["answer"] = "\ud800"
        with self.assertRaises(SolutionContractError) as caught:
            normalize_arguments(json.dumps(value))
        self.assertEqual(caught.exception.issue, "submission_json")
        with self.assertRaises(SolutionContractError):
            normalize_arguments("[" * 2000 + "0" + "]" * 2000)

    def test_schema_shared_definitions_keep_full_contract_bounded(self):
        schema = tool_schema()
        self.assertLess(len(json.dumps(schema, ensure_ascii=False).encode()), 30_000)
        self.assertIn("quantities", schema["function"]["parameters"]["$defs"])

    def strict_value(self):
        value = submission()
        value["diagram_outcome"]["primary_diagram"]["multiplier"]["unit"] = ""
        value["diagram_outcome"]["additional_diagrams"] = []
        return value

    def test_strict_beta_schema_has_documented_keywords_and_required_properties(self):
        schema = tool_schema(strict=True)
        self.assertIs(schema["function"]["strict"], True)
        parameters = schema["function"]["parameters"]
        self.assertIn("$def", parameters)
        self.assertNotIn("$defs", parameters)
        self.assertEqual(set(parameters["properties"]), {"solution"})
        self.assertEqual(parameters["required"], ["solution"])
        self.assertEqual(len(parameters["properties"]["solution"]["anyOf"]), 2)
        def visit(node):
            if isinstance(node, dict):
                self.assertFalse(set(node) & {"minLength", "maxLength", "minItems", "maxItems"})
                if node.get("type") == "object":
                    self.assertEqual(set(node["required"]), set(node["properties"]))
                    self.assertIs(node["additionalProperties"], False)
                if "$ref" in node:
                    self.assertTrue(node["$ref"].startswith("#/$def/"))
                    self.assertIn(node["$ref"].split("/")[-1], parameters["$def"])
                for item in node.values():
                    visit(item)
            elif isinstance(node, list):
                for item in node:
                    visit(item)
        visit(parameters)
        native = parameters["properties"]["solution"]["anyOf"][0]
        import re
        pattern = native["properties"]["answer"]["pattern"]
        self.assertIsNotNone(re.search(pattern, "解题" * 60))
        self.assertIsNone(re.search(pattern, "解题" * 61))
        self.assertIsNotNone(re.search(pattern, " " * 120))
        self.assertNotIn("pattern", parameters["properties"]["solution"]["anyOf"][1]["properties"]["answer"])
        self.assertNotIn("(?=", json.dumps(parameters))
        self.assertLess(len(json.dumps(schema, ensure_ascii=False).encode()), 35_000)

    def test_strict_native_brief_and_required_empty_arrays_keep_null(self):
        value = self.strict_value()
        self.assertIsNone(self.normalize(value, strict=True)["method_id"])
        value["answer"] = "解" * 121
        # Regular compatibility must preserve independently valid checked graphs.
        self.assertEqual(self.normalize(value)["diagrams"], [value["diagram_outcome"]["primary_diagram"]])
        with self.assertRaises(SolutionContractError):
            self.normalize(value, strict=True)
        value = self.strict_value()
        del value["diagram_outcome"]["additional_diagrams"]
        with self.assertRaises(SolutionContractError):
            self.normalize(value, strict=True)
        self.assertTrue(self.normalize(value)["diagrams"])

    def test_strict_general_accepts_full_answer_generic_graph_or_reason_only(self):
        value = self.strict_value()
        value["mode"] = "general"
        value["answer"] = "完整解释。" * 100
        with self.assertRaises(SolutionContractError):
            self.normalize(value, strict=True)
        self.assertTrue(self.normalize(value)["diagrams"])
        value["diagram_outcome"] = {"status": "renderable", "additional_diagrams": [], "primary_diagram": {
            "id": "g", "title": "未知量", "kind": "quantity_plan", "view": "state", "checks": [],
            "quantities": [{"id": "q", "label": "未知", "unit": "", "unknown": True}],
            "layout": {"states": ["q"]}}}
        self.assertEqual(len(self.normalize(value, strict=True)["diagrams"]), 1)
        value["diagram_outcome"] = {"status": "no_helpful_diagram", "reason": "图示无助于解释此题。"}
        self.assertEqual(self.normalize(value, strict=True)["diagrams"], [])

    def test_strict_local_limits_still_apply_when_provider_cannot_bound_arrays(self):
        value = self.strict_value()
        value["visual_method_ids"] = ["a", "b", "c"]
        with self.assertRaises(SolutionContractError):
            self.normalize(value, strict=True)
        value = self.strict_value()
        value["diagram_outcome"]["additional_diagrams"] = [{**recipe(), "id": str(i), "multiplier": {
            "value": 10, "unit": "", "evidence": "乘10"}} for i in range(3)]
        with self.assertRaises(SolutionContractError):
            self.normalize(value, strict=True)

    def test_strict_wire_root_is_exact_and_regular_wire_stays_flat(self):
        value = self.strict_value()
        with self.assertRaises(SolutionContractError):
            normalize_arguments(json.dumps(value), strict=True)
        with self.assertRaises(SolutionContractError):
            normalize_arguments(json.dumps({"solution": value, "extra": True}), strict=True)
        with self.assertRaises(SolutionContractError):
            normalize_arguments(json.dumps({"solution": value}))
        result = normalize_arguments(json.dumps({"solution": value}), strict=True)
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["diagrams"], [value["diagram_outcome"]["primary_diagram"]])
        self.assertIsNone(result["method_id"])

    def test_native_results_are_never_computed_here(self):
        # Source semantic checks intentionally stay native; shape validation isn't correctness certification.
        value = submission()
        value["answer"] = "故意错误的答案"
        result = self.normalize(value)
        self.assertEqual(result["answer"], value["answer"])
        self.assertEqual(result["diagrams"], [recipe()])


if __name__ == "__main__":
    unittest.main()
