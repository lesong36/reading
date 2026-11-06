import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/"evaluate-math-teaching.py"
spec=importlib.util.spec_from_file_location("math_teaching_evaluation",SCRIPT)
audit=importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)


class TeachingEvaluationTests(unittest.TestCase):
    def test_real_corpus_checks_do_not_claim_model_accuracy_or_human_approval(self):
        result=audit.audit()
        self.assertEqual(result["profile_count"],49)
        self.assertGreater(result["exact_gold_checks"],0)
        self.assertFalse(result["model_accuracy_evaluated"])
        self.assertFalse(result["human_approval_granted"])

    def test_fractional_math_is_exact_and_programs_are_rejected(self):
        self.assertEqual(audit.exact("120/(6-1/2)"),audit.Fraction(240,11))
        for expression in ("__import__('os').system('echo bad')","2**100000000","[1,2]","1.5", "False"):
            with self.assertRaises(ValueError): audit.exact(expression)

    def test_wrong_digit_extremum_and_square_are_detected(self):
        with self.assertRaises(ValueError):
            audit.verify_gold({"kind":"digit_product_extrema","digits":[3,6,7,4],"widths":[2,2],"expected_max":4662,"expected_min":1692})
        with self.assertRaises(ValueError):
            audit.verify_gold({"kind":"magic_square","grid":[[8,1,6],[3,5,7],[4,9,3]],"expected":15})

    def test_stale_profile_and_ai_approval_cannot_pass_asset_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name in ("MathSkills","MathTeachingReview"): shutil.copytree(audit.ROOT/name,root/name)
            path=root/"MathTeachingReview/profiles.json"
            data=json.loads(path.read_text()); original=json.loads(path.read_text())
            data["profiles"][0]["skill_sha256"]="0"*64
            path.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError,"stale"): audit.audit(root)
            original["profiles"][0]["review_status"]="approved"
            path.write_text(json.dumps(original))
            with self.assertRaisesRegex(ValueError,"review status"): audit.audit(root)

    def test_invalid_selection_role_schema_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name in ("MathSkills","MathTeachingReview"): shutil.copytree(audit.ROOT/name,root/name)
            path=root/"MathTeachingReview/profiles.json"
            original=json.loads(path.read_text())
            for roles in (None, "solution", [], ["solution", "solution"], ["unknown"],
                          ["routing", "visual"], ["solution", "visual", "routing"], [{}]):
                with self.subTest(roles=roles):
                    data=json.loads(json.dumps(original))
                    if roles is None: data["profiles"][0].pop("selection_roles")
                    else: data["profiles"][0]["selection_roles"]=roles
                    path.write_text(json.dumps(data))
                    with self.assertRaisesRegex(ValueError,"invalid selection roles"): audit.audit(root)

    def test_gold_cannot_select_wrong_role_or_require_an_unexpected_visual(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name in ("MathSkills","MathTeachingReview"): shutil.copytree(audit.ROOT/name,root/name)
            path=root/"MathTeachingReview/evaluation-corpus.json"
            original=json.loads(path.read_text())
            for field, values, message in (
                ("expected_methods", ["comparison-line-diagram"], "role mismatch"),
                ("expected_methods", ["math-diagram-routing"], "role mismatch"),
                ("expected_visuals", ["difference-and-ratio"], "role mismatch"),
                ("expected_visuals", ["math-diagram-routing"], "role mismatch"),
                ("required_visuals", ["math-diagram-routing"], "role mismatch"),
                ("required_visuals", ["part-whole-diagram"], "required visuals must"),
                ("expected_methods", ["difference-and-ratio", "difference-and-ratio"], "invalid expected_methods"),
                ("expected_visuals", "comparison-line-diagram", "invalid expected_visuals"),
                ("required_visuals", [{}], "invalid required_visuals"),
            ):
                with self.subTest(field=field, values=values):
                    data=json.loads(json.dumps(original))
                    case=next(case for case in data["cases"] if case["id"]=="visual-math-diagram-routing")
                    case[field]=values
                    path.write_text(json.dumps(data))
                    with self.assertRaisesRegex(ValueError,message): audit.audit(root)

    def test_routing_transfer_gold_requires_concrete_comparison_diagram(self):
        corpus=json.loads((audit.ROOT/"MathTeachingReview/evaluation-corpus.json").read_text())
        case=next(case for case in corpus["cases"] if case["id"]=="visual-math-diagram-routing")
        self.assertEqual(case["expected_methods"],["difference-and-ratio"])
        self.assertEqual(case["expected_visuals"],["comparison-line-diagram"])
        self.assertEqual(case["required_visuals"],["comparison-line-diagram"])
        self.assertEqual(len(case["gold_checks"]),2)


if __name__=="__main__": unittest.main()
