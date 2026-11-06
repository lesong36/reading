#!/usr/bin/env python3
"""Audit teaching profiles, source bindings and exact gold checks; never certify AI accuracy."""
from __future__ import annotations

import argparse
import ast
from collections import Counter
from fractions import Fraction
import hashlib
import itertools
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1] / "Sources/VocabCapture/Resources"


def require(value, message):
    if not value:
        raise ValueError(message)


def exact(expression):
    require(isinstance(expression, str) and len(expression) <= 256, "invalid arithmetic expression")
    tree = ast.parse(expression, mode="eval")
    require(sum(1 for _ in ast.walk(tree)) <= 64, "arithmetic expression too large")

    def visit(node):
        if isinstance(node, ast.Constant) and type(node.value) is int:
            require(abs(node.value) <= 10**12, "integer exceeds gold-check bounds")
            return Fraction(node.value)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
            value = visit(node.operand)
            return -value if isinstance(node.op, ast.USub) else value
        if isinstance(node, ast.BinOp):
            left, right = visit(node.left), visit(node.right)
            if isinstance(node.op, ast.Add): return left + right
            if isinstance(node.op, ast.Sub): return left - right
            if isinstance(node.op, ast.Mult): return left * right
            if isinstance(node.op, ast.Div): return left / right
            if isinstance(node.op, ast.FloorDiv): return Fraction(left // right)
            if isinstance(node.op, ast.Mod): return left % right
        raise ValueError("gold arithmetic allows integers and + - * / // % only")

    return visit(tree.body)


def verify_gold(check):
    require(isinstance(check, dict), "gold check must be an object")
    kind = check.get("kind")
    if kind == "exact_arithmetic":
        require(exact(check["expression"]) == exact(check["expected"]), "exact arithmetic gold mismatch")
    elif kind == "gcd":
        require(all(type(v) is int and 0 < v <= 10**9 for v in check["inputs"]), "invalid gcd inputs")
        require(math.gcd(*check["inputs"]) == check["expected"], "gcd gold mismatch")
    elif kind == "bottle_exchange":
        bottles, cost = check["initial"], check["cost"]
        require(type(bottles) is int and type(cost) is int and 0 <= bottles <= 100_000 and cost > 1,
                "invalid finite bottle exchange")
        total = bottles
        while bottles >= cost:
            new, rest = divmod(bottles, cost)
            total += new
            bottles = new + rest
        require(total == check["expected"], "bottle exchange gold mismatch")
    elif kind == "digit_product_extrema":
        digits, widths = check["digits"], check["widths"]
        require(2 <= len(digits) <= 7 and len(widths) == 2 and sum(widths) == len(digits), "invalid digit product widths")
        require(all(type(v) is int and 0 <= v <= 9 for v in digits), "invalid digits")
        products = []
        for order in set(itertools.permutations(digits)):
            if not order[0] or not order[widths[0]]: continue
            left = int("".join(map(str, order[:widths[0]])))
            right = int("".join(map(str, order[widths[0]:])))
            products.append(left * right)
        require(products and max(products) == check["expected_max"] and min(products) == check["expected_min"],
                "digit product extrema gold mismatch")
    elif kind == "magic_square":
        grid, target = check["grid"], check["expected"]
        require(len(grid) == 3 and all(len(row) == 3 for row in grid), "invalid magic square")
        require(sorted(v for row in grid for v in row) == list(range(1, 10)), "magic square must use digits 1–9 once")
        lines = grid + [list(column) for column in zip(*grid)] + [[grid[i][i] for i in range(3)], [grid[i][2-i] for i in range(3)]]
        require(all(sum(line) == target for line in lines), "magic square gold mismatch")
    else:
        raise ValueError(f"unknown gold check: {kind}")


def audit(root=ROOT):
    skills = {v["name"]: v for v in json.loads((root / "MathSkills/index.json").read_text())["skills"]}
    profiles_doc = json.loads((root / "MathTeachingReview/profiles.json").read_text())
    corpus = json.loads((root / "MathTeachingReview/evaluation-corpus.json").read_text())
    require(profiles_doc["schema_version"] == corpus["schema_version"] == 1, "unsupported teaching schema")
    require(profiles_doc["approval_policy"] == "human_review_only", "AI must not approve methods")
    profiles, cases = profiles_doc["profiles"], corpus["cases"]
    require(len(profiles) == len(skills) and {p["skill_name"] for p in profiles} == set(skills), "profiles must cover each bundled skill exactly once")
    roles_by_skill = {}
    for profile in profiles:
        name, roles = profile["skill_name"], profile.get("selection_roles")
        require(isinstance(roles, list) and 1 <= len(roles) <= 2
                and all(isinstance(role, str) and role in {"solution", "visual", "routing"} for role in roles)
                and len(set(roles)) == len(roles)
                and ("routing" not in roles or roles == ["routing"]),
                f"invalid selection roles: {name}")
        roles_by_skill[name] = set(roles)
    identifiers, checked = set(), 0
    for case in cases:
        identifier = case["id"]
        require(identifier not in identifiers, f"duplicate teaching case: {identifier}")
        identifiers.add(identifier)
        require(case["kind"] in {"positive", "confusing_negative", "source_example", "source_quarantine"}, f"invalid case kind: {identifier}")
        require(case["split"] in {"held_out", "source_regression"}, f"invalid case split: {identifier}")
        require(isinstance(case["stem"], str) and case["stem"].strip(), f"empty stem: {identifier}")
        require(type(case["grade"]) is int and 1 <= case["grade"] <= 6, f"invalid grade: {identifier}")
        for field in ("expected_methods", "expected_visuals", "required_visuals", "forbidden_methods"):
            values = case.get(field, [])
            require(isinstance(values, list) and all(isinstance(value, str) for value in values)
                    and len(set(values)) == len(values), f"invalid {field}: {identifier}")
        methods = case["expected_methods"] + case.get("expected_visuals", []) + case.get("required_visuals", [])
        require(set(methods + case["forbidden_methods"]) <= set(skills), f"unknown method: {identifier}")
        require(set(methods).isdisjoint(case["forbidden_methods"]), f"contradictory method gold: {identifier}")
        for field, role in (("expected_methods", "solution"), ("expected_visuals", "visual"), ("required_visuals", "visual")):
            require(all(role in roles_by_skill[name] for name in case.get(field, [])),
                    f"gold selection role mismatch in {field}: {identifier}")
        require(set(case.get("required_visuals", [])) <= set(case.get("expected_visuals", [])),
                f"required visuals must be expected visuals: {identifier}")
        if case["kind"] == "source_quarantine":
            require(not case["gold_checks"] and case.get("limitations"), f"quarantined source must not certify an answer: {identifier}")
        for check in case["gold_checks"]:
            try: verify_gold(check)
            except (ValueError, KeyError, ZeroDivisionError) as error:
                raise ValueError(f"{identifier}: {error}") from error
            checked += 1
        require(case["review_status"] != "approved", f"generated corpus cannot imply human approval: {identifier}")
    for profile in profiles:
        name = profile["skill_name"]
        skill = skills[name]
        data = (root / "MathSkills" / skill["path"]).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        require(profile["skill_sha256"] == skill["sha256"] == digest and profile["skill_version"] == skill["version"], f"profile is stale: {name}")
        require(profile["review_status"] in {"unreviewed", "review_required", "regression_checked"}, f"invalid generated review status: {name}")
        require(profile["prerequisites"] and profile["applicable_when"] and profile["exclusions"], f"profile lacks boundaries: {name}")
        require(set(profile["evidence_case_ids"]) <= identifiers, f"profile cites missing evidence: {name}")
        require(profile["grade_guidance"]["grade4_policy"] in {"arithmetic_only", "extension_requires_permission", "visual_only"}, f"invalid grade policy: {name}")
    return {"profile_count": len(profiles), "case_count": len(cases), "exact_gold_checks": checked,
            "case_kinds": dict(Counter(v["kind"] for v in cases)),
            "cases_without_gold": [v["id"] for v in cases if not v["gold_checks"]],
            "model_accuracy_evaluated": False, "human_approval_granted": False,
            "limitations": ["Checks arithmetic and source bindings only; does not prove teaching quality or real-model selection accuracy.",
                            "The held_out label means excluded from skill instructions; some cases were already used in project regressions and are not newly unseen."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try: result = audit(args.root)
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Teaching audit failed: {error}", file=sys.stderr); return 1
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.report: args.report.write_text(text)
    print(text, end="")
    return 0


if __name__ == "__main__": sys.exit(main())
