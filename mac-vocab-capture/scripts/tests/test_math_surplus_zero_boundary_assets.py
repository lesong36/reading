"""The zero-remainder revision preserves source identity and catalogue bindings."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("zero_boundary_validator", SCRIPTS / "validate-math-skills.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class SurplusZeroBoundaryAssetTests(unittest.TestCase):
    def test_original_source_and_new_version_remain_bound_without_human_approval(self):
        root = SCRIPTS.parent / "Sources/VocabCapture/Resources"
        self.assertEqual(validator.validate(root / "MathSkills"), 49)
        name = "surplus-and-shortfall"
        directory = root / "MathSkills" / name
        original_digest = "a358e1817e9e96b72874d31a82768560187cffa1783e6a2ffd8f17d383ffe281"
        self.assertEqual(hashlib.sha256((directory / "references/source.md").read_bytes()).hexdigest(), original_digest)
        entry = next(v for v in json.loads((root / "MathSkills/index.json").read_text())["skills"] if v["name"] == name)
        profile = next(v for v in json.loads((root / "MathTeachingReview/profiles.json").read_text())["profiles"] if v["skill_name"] == name)
        digest = hashlib.sha256((directory / "SKILL.md").read_bytes()).hexdigest()
        self.assertEqual(entry["version"], "2")
        self.assertEqual(profile["skill_version"], "2")
        self.assertEqual(entry["sha256"], digest)
        self.assertEqual(profile["skill_sha256"], digest)
        self.assertEqual(profile["applicable_when"], [entry["description"]])
        source = next(v for v in profile["source_references"] if v["locator"] == name + "/SKILL.md")
        self.assertEqual(source["sha256"], digest)
        self.assertEqual(profile["selection_roles"], ["solution"])
        self.assertNotEqual(profile["review_status"], "approved")


if __name__ == "__main__":
    unittest.main()
