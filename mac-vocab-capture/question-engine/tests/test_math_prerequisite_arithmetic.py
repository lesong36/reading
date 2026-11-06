import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from math_prerequisite_arithmetic import ARITHMETIC_ERROR_CODES, ArithmeticWitness, ArithmeticWitnessError, evaluate_witness


def witness(left="178", right="8", predicate="integer", expression="q1/q2", comparison=None):
    return {"operands": [
        {"name": "q1", "value": left, "origin": "problem_text", "source_excerpt": f"每边{left}米"},
        {"name": "q2", "value": right, "origin": "problem_text", "source_excerpt": f"间距{right}米"}],
        "expression": expression, "predicate": predicate, "comparison_expression": comparison}


class ArithmeticWitnessTests(unittest.TestCase):
    def evaluate(self, value, texts=None, image=False, body=""):
        return evaluate_witness(ArithmeticWitness.model_validate(value),
            problem_texts=texts if texts is not None else ["每边178米，间距8米", "每边176米，间距8米"],
            has_problem_image=image, skill_body=body)

    def test_indivisible_corner_is_false_and_divisible_corner_is_true(self):
        self.assertFalse(self.evaluate(witness()))
        self.assertTrue(self.evaluate(witness("176")))

    def test_outer_ring_uses_literal_rule_constant_and_exact_integer_truth(self):
        value = witness("14", "4")
        value["operands"][0]["source_excerpt"] = "最外圈14人"
        value["operands"][1].update(origin="skill", source_excerpt="人数必须为4的倍数")
        self.assertFalse(self.evaluate(value, ["最外圈14人"], body="最外圈人数必须为4的倍数。"))
        value["operands"][0].update(value="16", source_excerpt="最外圈16人")
        self.assertTrue(self.evaluate(value, ["最外圈16人"], body="最外圈人数必须为4的倍数。"))

    def test_decimal_and_fraction_comparison_is_exact(self):
        value = witness("0.1", "0.2", "equal", "q1+q2", "(1+1+1)/ (1+1+1+1+1+1+1+1+1+1)")
        self.assertTrue(self.evaluate(value, ["每边0.1米，间距0.2米"]))
        self.assertTrue(self.evaluate(witness("1/3", "2/3", "equal", "q1+q2", "1"), ["每边1/3米，间距2/3米"]))

    def test_remainder_zero_and_positive_integer_predicates(self):
        self.assertFalse(self.evaluate(witness(predicate="equal", expression="q1%q2", comparison="0")))
        self.assertTrue(self.evaluate(witness("176", predicate="positive_integer")))
        self.assertFalse(self.evaluate(witness("-176", predicate="positive_integer"), ["每边-176米，间距8米"]))
        self.assertTrue(self.evaluate(witness("0", predicate="nonnegative_integer"), ["每边0米，间距8米"]))

    def test_missing_or_invented_text_and_skill_quotes_are_rejected(self):
        for texts in ([], ["另一题每边1780米，间距80米"]):
            with self.subTest(texts=texts), self.assertRaises(ArithmeticWitnessError): self.evaluate(witness(), texts)
        value = witness(); value["operands"][0]["origin"] = "skill"
        with self.assertRaises(ArithmeticWitnessError): self.evaluate(value, body="每边176米")

    def test_images_require_original_attachment_and_do_not_claim_transcription_proof(self):
        value = witness()
        for operand in value["operands"]: operand["origin"] = "problem_image"
        with self.assertRaises(ArithmeticWitnessError): self.evaluate(value, [], image=False)
        self.assertFalse(self.evaluate(value, [], image=True))

    def test_values_must_occur_as_numeric_tokens_in_source_quotes(self):
        for excerpt in ("每边1780米", "每边1178米", "每边0.178米", "每边178/8米", "每边-178米", "每边1e178米", " "):
            value = witness(); value["operands"][0]["source_excerpt"] = excerpt
            with self.subTest(excerpt=excerpt), self.assertRaises(ArithmeticWitnessError): self.evaluate(value, [excerpt, "间距8米"])

    def test_code_access_floor_division_and_hidden_constants_are_rejected(self):
        for expression in ("__import__('os')", "q1.real", "q1//q2", "q1**q2", "q1[0]", "q1/q2+4", "True", "q1<q2", "sum([q1,q2])"):
            with self.subTest(expression=expression), self.assertRaises(ArithmeticWitnessError):
                self.evaluate(witness(expression=expression))

    def test_daily_result_literal_only_validates_exact_equality(self):
        def daily(value):
            return evaluate_witness(ArithmeticWitness.model_validate(value),
                problem_texts=["每边176米，间距8米"], has_problem_image=False, skill_body="", allow_result_literal=True)
        value = witness("176", predicate="equal", expression="q1/q2", comparison="22")
        self.assertTrue(daily(value))
        value["comparison_expression"] = "23"
        self.assertFalse(daily(value))
        for expression, predicate, right in [("q1/8", "equal", "22"), ("q1/q2", "greater_than", "21"),
                ("q1/q2", "equal", "22+0"), ("q1/q2", "equal", "True"), ("q1/q2", "equal", "1e99")]:
            with self.subTest(expression=expression, predicate=predicate, right=right), self.assertRaises(ArithmeticWitnessError):
                daily(witness("176", predicate=predicate, expression=expression, comparison=right))
        with self.assertRaises(ArithmeticWitnessError):
            self.evaluate(witness("176", predicate="equal", expression="q1/q2", comparison="22"))

    def test_daily_chinese_numerals_bind_only_to_unchanged_original_citations(self):
        value = witness("10", "5", "equal", "q1*q2", "50")
        value["operands"][0]["source_excerpt"] = "每行十棵"
        value["operands"][1]["source_excerpt"] = "种了五行"
        def daily(draft):
            return evaluate_witness(ArithmeticWitness.model_validate(draft),
                problem_texts=["每行十棵，种了五行。"], has_problem_image=False,
                skill_body="", allow_result_literal=True)
        self.assertTrue(daily(value))
        rewritten = copy.deepcopy(value)
        rewritten["operands"][0]["source_excerpt"] = "每行10棵"
        with self.assertRaises(ArithmeticWitnessError) as caught:
            daily(rewritten)
        self.assertEqual(caught.exception.code, "problem_source")
        invented = copy.deepcopy(value)
        invented["operands"][0]["value"] = "50"
        with self.assertRaises(ArithmeticWitnessError) as caught:
            daily(invented)
        self.assertEqual(caught.exception.code, "source_value")
        with self.assertRaises(ArithmeticWitnessError) as caught:
            self.evaluate(value, ["每行十棵，种了五行。"])
        self.assertEqual(caught.exception.code, "source_value")

    def test_daily_chinese_boundary_and_image_presence_remain_required(self):
        value = witness("3", "1", "integer", "q1-q2")
        value["operands"][0]["source_excerpt"] = "三十六人"
        value["operands"][1]["source_excerpt"] = "一人"
        with self.assertRaises(ArithmeticWitnessError) as caught:
            evaluate_witness(ArithmeticWitness.model_validate(value),
                problem_texts=["三十六人，一人。"], has_problem_image=False,
                skill_body="", allow_result_literal=True)
        self.assertEqual(caught.exception.code, "source_value")
        value["operands"][0]["source_excerpt"] = "三层"
        value["operands"][0]["origin"] = "problem_image"
        with self.assertRaises(ArithmeticWitnessError) as caught:
            evaluate_witness(ArithmeticWitness.model_validate(value),
                problem_texts=["一人。"], has_problem_image=False,
                skill_body="", allow_result_literal=True)
        self.assertEqual(caught.exception.code, "image_source")

    def test_duplicate_unused_unknown_and_oversized_operands_are_rejected(self):
        cases = []
        value = witness(); value["operands"][1]["name"] = "q1"; cases.append(value)
        value = witness(expression="q1"); cases.append(value)
        value = witness(expression="q1/q3"); cases.append(value)
        value = witness(); value["operands"][0]["value"] = "1e999"; cases.append(value)
        value = witness(); value["operands"][0]["value"] = "9"*13; cases.append(value)
        for value in cases:
            with self.subTest(value=value), self.assertRaises((ArithmeticWitnessError, ValueError)): self.evaluate(value)

    def test_comparison_contract_and_zero_division_are_rejected(self):
        cases = [witness(predicate="equal"), witness(comparison="0"), witness(expression="q1/(q2-q2)")]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ArithmeticWitnessError): self.evaluate(value)

    def test_expression_and_intermediate_result_are_bounded(self):
        value = witness(expression="q1*q2*q1*q2*q1*q2*q1*q2*q1*q2*q1*q2*q1*q2")
        value["operands"][0].update(value="999999999999", source_excerpt="每边999999999999米")
        with self.assertRaises(ArithmeticWitnessError): self.evaluate(value, ["每边999999999999米，间距8米"])
        value = witness(expression="q1+" + "1+"*64 + "q2")
        with self.assertRaises((ArithmeticWitnessError, ValueError)): self.evaluate(value)

    def test_fixed_reason_codes_distinguish_witness_failures(self):
        cases = []
        value = witness(); value["operands"][0]["value"] = "1e178"
        cases.append((value, {}, "numeric_value"))
        value = witness(); value["operands"][0]["source_excerpt"] = "每边1780米"
        cases.append((value, {"texts": ["每边1780米，间距8米"]}, "source_value"))
        cases.append((witness(), {"texts": []}, "problem_source"))
        value = witness(); value["operands"][0]["origin"] = "skill"
        cases.append((value, {}, "skill_source"))
        value = witness(); value["operands"][0]["origin"] = "problem_image"
        cases.append((value, {}, "image_source"))
        cases.append((witness(expression="q1//q2"), {}, "expression"))
        value = witness(); value["operands"][1]["name"] = "q1"
        cases.append((value, {}, "operands"))
        cases.append((witness(expression="q1"), {}, "operands"))
        cases.append((witness(predicate="equal"), {}, "predicate"))
        cases.append((witness(comparison="0"), {}, "predicate"))
        for expression in ("q1/(q2-q2)", "q1%(q2-q2)"):
            cases.append((witness(expression=expression), {}, "division_zero"))
        cases.append((witness(expression="q1+" + "1+"*32 + "q2"), {}, "bounds"))
        value = witness("999999999999", expression="q1*q1*q1*q2")
        cases.append((value, {"texts": ["每边999999999999米，间距8米"]}, "bounds"))
        for value, context, code in cases:
            with self.subTest(code=code, value=value), self.assertRaises(ArithmeticWitnessError) as captured:
                self.evaluate(value, **context)
            self.assertEqual(captured.exception.code, code)
            self.assertEqual(str(captured.exception), "invalid arithmetic prerequisite witness: " + code)
            self.assertNotIn("178", str(captured.exception))

    def test_error_constructor_and_skill_forwarding_allow_only_fixed_reasons(self):
        from math_skills import SkillError
        for code in ARITHMETIC_ERROR_CODES:
            self.assertEqual(ArithmeticWitnessError(code).code, code)
            issue = "review.methods[0].conditions[0].arithmetic:" + code
            self.assertEqual(SkillError("skillsOutput", issue=issue).issue, issue)
        for value in ("private_secret178", "expression:private_secret", [], None):
            error = ArithmeticWitnessError(value)
            self.assertEqual(error.code, "witness")
            self.assertEqual(str(error), "invalid arithmetic prerequisite witness: witness")
        for issue in ("review.methods[0].conditions[0].arithmetic:private_secret178",
            "review.methods[0].conditions[0].arithmetic:expression:private_secret178",
            "review.methods[8].conditions[0].arithmetic:expression"):
            self.assertIsNone(SkillError("skillsOutput", issue=issue).issue)

    def test_operand_details_are_fixed_and_preserve_historical_error_code(self):
        from math_skills import check_prerequisite_predicate, PrerequisiteCondition
        for value, detail in ((witness(expression="q1"), "unused_operand"),
                              (dict(witness(), operands=[witness()["operands"][0]] * 2), "duplicate_operand")):
            original = copy.deepcopy(value)
            with self.assertRaises(ArithmeticWitnessError) as caught:
                self.evaluate(value)
            self.assertEqual(caught.exception.code, "operands")
            self.assertEqual(caught.exception.detail, detail)
            self.assertEqual(value, original)
            condition = PrerequisiteCondition.model_validate({"condition_id":"p1", "proposition":"数量条件", "basis":"computed", "arithmetic":value, "truth":True, "evidence":"源数来自题面"})
            for daily in (False, True):
                with self.assertRaises(Exception) as forwarded:
                    check_prerequisite_predicate(condition, "", "review.methods[0].conditions[0]",
                        problem_texts=["每边178米，间距8米"], has_problem_image=False, allow_result_literal=daily)
                self.assertTrue(forwarded.exception.issue.endswith(detail if daily else "operands"))
        for detail in ("SECRET", [], None):
            self.assertEqual(ArithmeticWitnessError("operands", detail).detail, "operands")

    def test_truth_is_returned_without_mutating_model_evidence(self):
        value = witness(); before = copy.deepcopy(value)
        self.assertIs(self.evaluate(value), False)
        self.assertEqual(value, before)


if __name__ == "__main__": unittest.main()
