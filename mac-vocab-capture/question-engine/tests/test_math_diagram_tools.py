"""Renderer names determine inert recipe contracts without forcing pedagogical labels."""
import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from math_solution_contract import SolutionContractError, _DIAGRAMS
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments, tool_schemas


def source(value, unit=None):
    result = {"value": value, "evidence": f"原题数量{value}"}
    if unit is not None:
        result["unit"] = unit
    return result


def native():
    return {"method_id": None, "visual_method_ids": [], "relationship": "差数72对应多出的9份。",
            "diagram": {"id": "difference", "title": "倍数比较", "difference": source(72, ""),
                        "multiplier": source(10, "")}}


def general(view="state", layout=None):
    return {"method_id": None, "visual_method_ids": [], "answer": "一般解答，不强行匹配题型。",
            "diagram_outcome": {"status": "renderable", "additional_diagrams": [], "primary_diagram": {
                "id": "general", "title": "数量关系", "kind": "quantity_plan", "view": view,
                "quantities": [{"id": "q", "label": "待求量", "unit": "", "unknown": True}],
                "checks": [], "layout": layout or {"states": ["q"]}}}}


class DiagramToolTests(unittest.TestCase):
    def normalize(self, name, value, **kwargs):
        return normalize_tool_arguments(name, json.dumps(value, ensure_ascii=False), **kwargs)

    def test_one_tool_per_native_kind_and_one_general(self):
        tools = tool_schemas()
        names = {tool["function"]["name"] for tool in tools}
        self.assertEqual(len(names), 18)
        self.assertEqual(names, {GENERAL_TOOL_NAME, "count_simple_graph_paths", "solve_equal_sum_grid", "solve_reflected_meetings", "solve_reported_digit_game", *["render_" + k for k in (
            "difference_ratio", "sum_difference", "sum_ratio", "equalize_transfer", "cyclic_pattern",
            "fixed_total", "state_changes", "rectangle_sum_difference", "venn_counts", "return_deadline", "interval_problem", "two_allocations", "purchase_comparison")]})
        interval = next(t for t in tools if t["function"]["name"] == "render_interval_problem")
        self.assertEqual(len(interval["function"]["parameters"]["properties"]["diagram"]["anyOf"]), 2)
        self.assertTrue(all("strict" not in t["function"] for t in tools))
        tools[0]["function"]["parameters"].clear()
        self.assertTrue(tool_schemas()[0]["function"]["parameters"])

    def test_compact_general_schema_preserves_all_ten_view_layout_pairs(self):
        parameters = tool_schemas()[-1]["function"]["parameters"]
        compact = parameters["$defs"]["general_diagram"]
        canonical = [d for d in _DIAGRAMS if d["properties"]["kind"]["enum"] == ["quantity_plan"] and "layout" in d["properties"]]
        self.assertEqual(len(compact["anyOf"]), 10)
        common = {k: v for k, v in compact.items() if k != "anyOf"}
        self.assertEqual(common["additionalProperties"], False)
        self.assertEqual(common["required"], canonical[0]["required"])
        self.assertEqual(set(common["properties"]), set(canonical[0]["properties"]))
        for branch, old in zip(compact["anyOf"], canonical):
            self.assertEqual(branch["properties"]["view"], old["properties"]["view"])
            # Provider bound stripping is deliberate, but the layout itself
            # must match the pre-existing provider contract exactly.
            from math_diagram_tools import _provider_bounds
            self.assertEqual(branch["properties"]["layout"], _provider_bounds(old["properties"]["layout"]))
            self.assertEqual(branch["required"], ["view", "layout"])
        self.assertLess(len(json.dumps(compact)), len(json.dumps({"anyOf": canonical})) * 0.65)
        # Sharing does not leak to strict Beta or mutate canonical local checks.
        strict = tool_schemas(strict=True)[-1]["function"]["parameters"]
        self.assertEqual(len(strict["$def"]["general_diagram"]["anyOf"]), 10)
        self.assertNotIn("properties", strict["$def"]["general_diagram"])
        self.assertEqual(self.normalize(GENERAL_TOOL_NAME, general())["diagrams"][0]["view"], "state")
        for malformed in [general("state", {"items": ["q"]}), general("invalid")]:
            with self.assertRaises(SolutionContractError):
                self.normalize(GENERAL_TOOL_NAME, malformed)

    def testStateChangeToolPreservesOriginalInputsAndRejectsUnknownDirection(self):
        def quantity(value, text):
            return {"value": value, "unit": "人", "evidence": text}
        value = {"method_id": None, "visual_method_ids": [], "relationship": "先离开再加入，顺序计算。",
                 "diagram": {"id": "people", "title": "人数变化", "initial": quantity(100, "原有100人"),
                             "changes": [{"direction": "decrease", "amount": quantity(30, "先离开30人")},
                                         {"direction": "increase", "amount": quantity(20, "又来了20人")}]}}
        normalized = self.normalize("render_state_changes", value)
        self.assertEqual(normalized["diagrams"][0], {**value["diagram"], "kind": "state_changes"})
        self.assertNotIn("90", json.dumps(normalized))
        value["diagram"]["changes"][0]["direction"] = "cycle"
        with self.assertRaises(SolutionContractError):
            self.normalize("render_state_changes", value)

    def testRectangleAndVennToolsSubmitOnlyOriginalInputsWithoutComputedTargets(self):
        samples = {
            "rectangle_sum_difference": {"rectangle_evidence": "题目给出长方形", "total_sides": source(18, "厘米"), "difference": source(2, "厘米")},
            "venn_counts": {k: source(v, "人") for k, v in zip(("total", "left", "right", "intersection"), (40, 25, 22, 12))},
        }
        for kind, fields in samples.items():
            value = {"method_id": None, "visual_method_ids": [], "relationship": "依据原题条件计算所问数量。",
                     "diagram": {"id": "original", "title": "数量关系", **fields}}
            result = self.normalize("render_" + kind, value)
            self.assertEqual(result["diagrams"], [{**value["diagram"], "kind": kind}])
            self.assertIsNone(result["method_id"])
            value["diagram"]["answer"] = 80
            with self.assertRaises(SolutionContractError):
                self.normalize("render_" + kind, value)

    def testIntervalUnitNamespacesMatchCompilerAndDoNotLeakToOtherTools(self):
        def quantity(value, unit):
            return {"value": value, "unit": unit, "evidence": f"原题{value}{unit}"}
        value = {"method_id": None, "visual_method_ids": [], "relationship": "楼层间隔乘每段台阶。",
                 "diagram": {"id": "stairs", "title": "台阶", "scenario": "stairs",
                             "start_floor": quantity(1, "楼"), "end_floor": quantity(14, "楼"),
                             "steps_per_interval": quantity(21, "级台阶")}}
        self.assertEqual(self.normalize("render_interval_problem", value)["diagrams"][0]["kind"], "interval_problem")
        for invalid in ["层", "米", "", "名同学"]:
            value["diagram"]["steps_per_interval"]["unit"] = invalid
            with self.assertRaises(SolutionContractError):
                self.normalize("render_interval_problem", value)
        tools = {t["function"]["name"]: t["function"]["parameters"] for t in tool_schemas()}
        self.assertEqual(tools["render_interval_problem"]["$defs"]["step_quantity"]["properties"]["unit"], {"enum": ["级", "级台阶"]})
        self.assertNotIn("step_quantity", tools["render_sum_difference"].get("$defs", {}))

    def test_native_name_inserts_kind_and_preserves_original_values_without_computing(self):
        value = native()
        result = self.normalize("render_difference_ratio", value, strict=True)
        self.assertIsNone(result["method_id"])
        self.assertEqual(result["mode"], "native_recipe")
        self.assertEqual(result["answer"], value["relationship"])
        self.assertEqual(result["diagrams"], [{**value["diagram"], "kind": "difference_ratio"}])
        self.assertNotIn("facts", result["diagrams"][0])
        self.assertNotIn("value", result)
        self.assertEqual(set(result), {"schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams"})

    def test_purchase_comparison_keeps_main_null_and_original_discount_conditions(self):
        diagram = {"id": "offers", "title": "两店优惠比较", "item_unit": "本", "currency_unit": "元",
                   "quantity_policy": "exact_required_quantity", "required_count": source(245), "unit_price": source(12),
                   "offers": [{"name": "A书店", "kind": "threshold_reduction", "threshold": source(100), "reduction": source(15)},
                              {"name": "B书店", "kind": "buy_get", "paid": source(8), "free": source(1)}]}
        value = {"method_id": None, "visual_method_ids": [], "relationship": "逐店按优惠规则计算实际付款并比较。", "diagram": diagram}
        result = self.normalize("render_purchase_comparison", value, strict=True)
        self.assertIsNone(result["method_id"])
        self.assertEqual(result["diagrams"], [{**diagram, "kind": "purchase_comparison"}])
        self.assertNotIn("归一", result["answer"])
        self.assertNotIn("2505", json.dumps(result))
        self.assertNotIn("2616", json.dumps(result))

    def test_native_rejects_model_selected_mode_kind_results_and_long_relationship(self):
        for field, item in (("mode", "general"), ("answer", "SECRET")):
            with self.assertRaises(SolutionContractError):
                self.normalize("render_difference_ratio", {**native(), field: item})
        for field in ("kind", "facts", "relations", "layout", "answer"):
            value = native()
            value["diagram"][field] = "SECRET"
            with self.assertRaises(SolutionContractError):
                self.normalize("render_difference_ratio", value)
        value = native()
        value["relationship"] = "解" * 121
        with self.assertRaises(SolutionContractError):
            self.normalize("render_difference_ratio", value)

    def test_general_all_ten_named_views_keep_unknown_and_do_not_compute(self):
        layouts = {
            "bar_comparison": {"items": ["q"]}, "equal_parts": {"items": ["q"], "parts": [1]},
            "state": {"states": ["q"]}, "table": {"columns": ["数量"], "rows": [{"label": "未知", "factIDs": ["q"]}]},
            "area": {k: "q" for k in ("length", "width", "area")},
            "interval": {k: "q" for k in ("start", "end", "gaps", "per", "total")},
            "balance": {k: "q" for k in ("high", "low", "mean", "transfer")},
            "part_whole": {"whole": "q", "portions": ["q"]},
            "venn": {k: "q" for k in ("leftOnly", "intersection", "rightOnly", "union")},
            "cycle": {**{k: "q" for k in ("count", "period", "cycles", "remainder")}, "labels": ["红"]},
        }
        for view, layout in layouts.items():
            with self.subTest(view=view):
                value = general(view, layout)
                result = self.normalize(GENERAL_TOOL_NAME, value, strict=True)
                self.assertEqual(result["mode"], "general")
                self.assertEqual(result["diagrams"][0], value["diagram_outcome"]["primary_diagram"])
                self.assertIs(result["diagrams"][0]["quantities"][0]["unknown"], True)

    def test_general_explicit_reason_or_incomplete_original_no_fake_graph(self):
        for status in ("no_helpful_diagram", "unreadable_or_insufficient"):
            value = general()
            value["diagram_outcome"] = {"status": status, "reason": "原题条件不足。"}
            result = self.normalize(GENERAL_TOOL_NAME, value, strict=True)
            self.assertEqual(result["diagrams"], [])
            self.assertIn("原题条件不足。", result["answer"])
            self.assertIsNone(result["method_id"])

    def test_general_has_no_legacy_positional_or_native_recipe_branch(self):
        value = general()
        diagram = value["diagram_outcome"]["primary_diagram"]
        del diagram["layout"]
        diagram["factIDs"] = ["q"]
        with self.assertRaises(SolutionContractError):
            self.normalize(GENERAL_TOOL_NAME, value)
        value = general()
        value["diagram_outcome"]["primary_diagram"] = {**native()["diagram"], "kind": "difference_ratio"}
        with self.assertRaises(SolutionContractError):
            self.normalize(GENERAL_TOOL_NAME, value)

    def test_unknown_tool_duplicate_keys_nonfinite_and_truncated_are_nonsecret_errors(self):
        raw = json.dumps(native())
        for name, payload in (("SECRET", raw), ("render_difference_ratio", raw[:-1]),
                              ("render_difference_ratio", raw.replace('"value": 72', '"value":72,"value":73')),
                              ("render_difference_ratio", raw.replace('"value": 72', '"value":NaN'))):
            with self.assertRaises(SolutionContractError) as caught:
                normalize_tool_arguments(name, payload)
            self.assertNotIn("SECRET", str(caught.exception))

    def test_duplicate_metadata_and_general_diagram_ids_rejected(self):
        value = native()
        value["visual_method_ids"] = ["a", "a"]
        with self.assertRaises(SolutionContractError):
            self.normalize("render_difference_ratio", value)
        value = general()
        value["diagram_outcome"]["additional_diagrams"] = [copy.deepcopy(value["diagram_outcome"]["primary_diagram"])]
        with self.assertRaises(SolutionContractError):
            self.normalize(GENERAL_TOOL_NAME, value)

    def test_strict_schema_subset_required_fields_reachable_defs_and_size(self):
        tools = tool_schemas(strict=True)
        for tool in tools:
            function = tool["function"]
            self.assertIs(function["strict"], True)
            root = function["parameters"]
            self.assertEqual(root["type"], "object")
            def visit(node):
                if isinstance(node, dict):
                    self.assertFalse(set(node) & {"minLength", "maxLength", "minItems", "maxItems", "$defs"})
                    if node.get("type") == "object":
                        self.assertEqual(set(node["properties"]), set(node["required"]))
                        self.assertIs(node["additionalProperties"], False)
                    if "$ref" in node:
                        self.assertTrue(node["$ref"].startswith("#/$def/"))
                        self.assertIn(node["$ref"].split("/")[-1], root["$def"])
                    for item in node.values():
                        visit(item)
                elif isinstance(node, list):
                    for item in node:
                        visit(item)
            visit(root)
        # Explicit bounded graph submission adds one tool plus auditable node locations, without duplicating drawing definitions.
        self.assertLess(len(json.dumps(tool_schemas(), ensure_ascii=False).encode()), 34_000)
        self.assertLess(len(json.dumps(tools, ensure_ascii=False).encode()), 36_000)

    def test_opt_in_preserves_full_answer_when_generic_diagram_is_invalid(self):
        value = general()
        value["method_id"] = "user-authored-skill"
        value["answer"] = "原来791套，每套3.2米，现每套2.8米，可做904套。"
        value["diagram_outcome"]["primary_diagram"]["quantities"][0]["origin"] = "SECRET_MODEL_DIAGRAM"
        with self.assertRaises(SolutionContractError):
            self.normalize(GENERAL_TOOL_NAME, value)
        result = self.normalize(GENERAL_TOOL_NAME, value, preserve_general_answer=True)
        self.assertEqual(result["answer"], value["answer"])
        self.assertEqual(result["method_id"], value["method_id"])
        self.assertEqual(result["diagrams"], [])
        self.assertEqual(result["diagram_submission_failure"], "submission_shape")
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertNotIn("no_helpful_diagram", json.dumps(result))
        self.assertEqual(set(result), {"schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams", "diagram_submission_failure"})

    def test_preservation_salvages_independently_valid_generic_diagrams(self):
        for invalid_primary in (True, False):
            value = general()
            other = copy.deepcopy(value["diagram_outcome"]["primary_diagram"])
            other["id"] = "second"
            value["diagram_outcome"]["additional_diagrams"] = [other]
            target = value["diagram_outcome"]["primary_diagram"] if invalid_primary else other
            target["quantities"][0]["unknown"] = "SECRET_INVALID"
            expected = other if invalid_primary else value["diagram_outcome"]["primary_diagram"]
            result = self.normalize(GENERAL_TOOL_NAME, value, strict=True, preserve_general_answer=True)
            self.assertEqual(result["diagrams"], [expected])
            self.assertEqual(result["diagram_submission_failure"], "submission_shape")
            self.assertNotIn("SECRET", json.dumps(result))

    def test_duplicate_graph_namespace_preserves_answer_without_selecting_winner(self):
        value = general()
        value["diagram_outcome"]["additional_diagrams"] = [copy.deepcopy(value["diagram_outcome"]["primary_diagram"])]
        with self.assertRaises(SolutionContractError):
            self.normalize(GENERAL_TOOL_NAME, value)
        result = self.normalize(GENERAL_TOOL_NAME, value, preserve_general_answer=True)
        self.assertEqual(result["answer"], value["answer"])
        self.assertEqual(result["diagrams"], [])
        self.assertEqual(result["diagram_submission_failure"], "submission_shape")
        value["diagram_outcome"]["additional_diagrams"][0]["quantities"][0]["unknown"] = "invalid"
        result = self.normalize(GENERAL_TOOL_NAME, value, preserve_general_answer=True)
        self.assertEqual(result["diagrams"], [])
        self.assertEqual(result["diagram_submission_failure"], "submission_shape")

    def test_general_preserves_independent_answer_with_invalid_or_missing_controls(self):
        for field, item in (("method_id", 42), ("visual_method_ids", ["x", "x"]),
                            ("visual_method_ids", ["x", "y", "z"]), ("visual_method_ids", "invalid")):
            value = general()
            value[field] = item
            with self.subTest(field=field, item=item):
                with self.assertRaises(SolutionContractError):
                    self.normalize(GENERAL_TOOL_NAME, value)
                result = self.normalize(GENERAL_TOOL_NAME, value, preserve_general_answer=True)
                self.assertEqual(result["answer"], value["answer"])
                self.assertIsNone(result["method_id"])
                self.assertEqual(result["visual_method_ids"], [])
        for value in ({"answer": "115×2×12=2760元。"}, {**general(), "extra": "SECRET"}):
            result = self.normalize(GENERAL_TOOL_NAME, value, preserve_general_answer=True)
            self.assertEqual(result["answer"], value["answer"])
            self.assertNotIn("SECRET", json.dumps(result))

    def test_general_bad_diagram_number_keeps_answer_and_only_valid_diagrams(self):
        value = general()
        value["diagram_outcome"]["primary_diagram"]["quantities"] = [
            {"id": "bad", "label": "超界数", "unit": "元", "value": 1e100, "evidence": "原题"}]
        result = self.normalize(GENERAL_TOOL_NAME, value, preserve_general_answer=True)
        self.assertEqual(result["answer"], value["answer"])
        self.assertEqual(result["diagrams"], [])

    def test_native_invalid_recipe_preserves_relation_only_and_clears_controls(self):
        for invalid in ("missing", "number", "metadata"):
            value = native()
            if invalid == "missing":
                del value["diagram"]["difference"]["evidence"]
            elif invalid == "number":
                value["diagram"]["multiplier"]["value"] = 1
            else:
                value["visual_method_ids"] = ["x", "x"]
            with self.subTest(invalid=invalid):
                with self.assertRaises(SolutionContractError):
                    self.normalize("render_difference_ratio", value)
                result = self.normalize("render_difference_ratio", value, preserve_general_answer=True)
                self.assertEqual(result["answer"], value["relationship"])
                self.assertEqual(result["mode"], "general")
                self.assertIsNone(result["method_id"])
                self.assertEqual(result["visual_method_ids"], [])
                self.assertEqual(result["diagrams"], [])
                self.assertEqual(result["diagram_submission_failure"], "submission_relationship_only")

    def test_preservation_never_accepts_missing_invalid_text_or_malformed_json(self):
        for name, template, field, limit in ((GENERAL_TOOL_NAME, general(), "answer", 40_000),
                                            ("render_difference_ratio", native(), "relationship", 120)):
            for item in (None, " ", 904, "a" * (limit + 1)):
                value = copy.deepcopy(template)
                value[field] = item
                with self.assertRaises(SolutionContractError):
                    self.normalize(name, value, preserve_general_answer=True)
            value = copy.deepcopy(template)
            del value[field]
            with self.assertRaises(SolutionContractError):
                self.normalize(name, value, preserve_general_answer=True)
            raw = json.dumps(template)
            for bad in (raw[:-1], raw.replace('"method_id": null', '"method_id":NaN'),
                        raw.replace('"method_id": null', '"method_id":1e999'),
                        raw.replace('"method_id": null', '"method_id":null,"method_id":null'),
                        " " * 150_001 + raw):
                with self.assertRaises(SolutionContractError):
                    normalize_tool_arguments(name, bad, preserve_general_answer=True)
            with self.assertRaises(SolutionContractError):
                self.normalize("unknown_tool", template, preserve_general_answer=True)

    def test_successful_general_answer_has_no_new_failure_field_even_with_opt_in(self):
        result = self.normalize(GENERAL_TOOL_NAME, general(), preserve_general_answer=True)
        self.assertEqual(len(result), 6)
        self.assertEqual(len(result["diagrams"]), 1)
        self.assertNotIn("diagram_submission_failure", result)
        value = general()
        value["diagram_outcome"]["primary_diagram"]["quantities"] = [
            {"id": "derived", "label": "计算值", "operation": "sum", "inputs": ["missing1", "missing2"]}]
        # Graph references are native arithmetic validation, not transport schema failure.
        result = self.normalize(GENERAL_TOOL_NAME, value, preserve_general_answer=True)
        self.assertEqual(result["answer"], value["answer"])
        self.assertEqual(len(result["diagrams"]), 1)
        self.assertNotIn("diagram_submission_failure", result)

    def test_general_text_only_needs_trusted_authorization(self):
        value = general()
        value["diagram_outcome"] = {"status": "user_requested_text_only", "reason": "用户仅要文字。"}
        with self.assertRaises(SolutionContractError):
            self.normalize(GENERAL_TOOL_NAME, value)
        self.assertEqual(self.normalize(GENERAL_TOOL_NAME, value, text_only_authorized=True)["diagrams"], [])


if __name__ == "__main__":
    unittest.main()
