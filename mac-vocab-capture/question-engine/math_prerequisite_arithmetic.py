"""Finite arithmetic witnesses for prerequisite assertions, not answer certification.

Source bindings check literal text or the presence of the original image. Image
transcription and whether a predicate expresses the right prerequisite remain
model judgments. No model-supplied expression is executed as Python code.
"""
import ast
from fractions import Fraction
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field
from math_source_numbers import source_contains_number


ARITHMETIC_ERROR_CODES = frozenset({"numeric_value", "source_value", "problem_source", "skill_source",
    "image_source", "expression", "operands", "predicate", "division_zero", "bounds", "witness"})
OPERAND_DETAIL_CODES = frozenset({"operand_type", "duplicate_operand", "operand_origin", "unused_operand"})
EXPRESSION_DETAIL_CODES = frozenset({"expression_syntax", "expression_empty", "unknown_operand", "literal_operand", "unsupported_operator", "unsupported_expression"})


class ArithmeticWitnessError(ValueError):
    """A fixed safe reason, without operands, excerpts or provider content."""
    def __init__(self, code="witness", detail=None):
        self.code = code if isinstance(code, str) and code in ARITHMETIC_ERROR_CODES else "witness"
        allowed = OPERAND_DETAIL_CODES if self.code == "operands" else EXPRESSION_DETAIL_CODES if self.code == "expression" else ()
        self.detail = detail if isinstance(detail, str) and detail in allowed else self.code
        super().__init__("invalid arithmetic prerequisite witness: " + self.code)


class ArithmeticOperand(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    name: str = Field(pattern=r"^q[1-8]$")
    value: str = Field(min_length=1, max_length=32,
        description="Exact signed integer, decimal or fraction copied from the cited source; no computed answer or scientific notation.")
    origin: Literal["problem_text", "problem_image", "skill"]
    source_excerpt: str = Field(min_length=1, max_length=600,
        description="Literal source quote containing this numeric value. skill is only for an explicit rule constant, never an example's problem data.")


class ArithmeticWitness(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    operands: list[ArithmeticOperand] = Field(min_length=1, max_length=8)
    expression: str = Field(min_length=1, max_length=128,
        description="Finite arithmetic with named operands q1..q8, + - * / %, parentheses, and only literal constants 0 or 1. No floor division, calls, attributes or powers.")
    predicate: Literal["integer", "positive_integer", "nonnegative_integer", "nonzero",
        "equal", "less_than", "less_equal", "greater_than", "greater_equal"]
    comparison_expression: str | None = Field(max_length=128,
        description="Required right-hand expression for comparison predicates; null for integer/nonzero predicates. Express the positive prerequisite, not its negation.")


VALUE = re.compile(r"-?(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,12}|/[1-9][0-9]{0,11})?\Z")
RELATIONAL = {"equal", "less_than", "less_equal", "greater_than", "greater_equal"}
RESULT_BOUND = 10 ** 30


def fail(code, detail=None):
    raise ArithmeticWitnessError(code, detail)


def bounded(value):
    if abs(value.numerator) > RESULT_BOUND or value.denominator > RESULT_BOUND:
        fail("bounds")
    return value


def evaluate_expression(expression, operands, used):
    if not isinstance(expression, str) or not expression.strip():
        fail("expression", "expression_empty")
    if len(expression) > 128:
        fail("bounds")
    try:
        tree = ast.parse(expression, mode="eval")
    except (ValueError, SyntaxError, RecursionError):
        fail("expression", "expression_syntax")
    if sum(1 for _ in ast.walk(tree)) > 64:
        fail("bounds")

    def visit(node):
        if isinstance(node, ast.Name) and node.id in operands:
            used.add(node.id)
            return operands[node.id]
        if isinstance(node, ast.Name):
            fail("expression", "unknown_operand")
        if isinstance(node, ast.Constant) and type(node.value) is int and node.value in (0, 1):
            return Fraction(node.value)
        if isinstance(node, ast.Constant):
            fail("expression", "literal_operand")
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = visit(node.operand)
            return -value if isinstance(node.op, ast.USub) else value
        if isinstance(node, ast.BinOp):
            if not isinstance(node.op, (ast.Add, ast.Sub, ast.Mult, ast.Div, ast.Mod)):
                fail("expression", "unsupported_operator")
            left, right = visit(node.left), visit(node.right)
            try:
                if isinstance(node.op, ast.Add): return bounded(left + right)
                if isinstance(node.op, ast.Sub): return bounded(left - right)
                if isinstance(node.op, ast.Mult): return bounded(left * right)
                if isinstance(node.op, ast.Div): return bounded(left / right)
                if isinstance(node.op, ast.Mod): return bounded(left % right)
            except ZeroDivisionError:
                fail("division_zero")
            fail("expression", "unsupported_operator")
        fail("expression", "unsupported_expression")

    return visit(tree.body)


def evaluate_witness(witness, *, problem_texts, has_problem_image, skill_body, allow_result_literal=False):
    """Validate source quotes and return exact truth; never change a selection."""
    if not isinstance(witness, ArithmeticWitness):
        fail("operands", "operand_type")
    operands = {}
    for operand in witness.operands:
        if operand.name in operands:
            fail("operands", "duplicate_operand")
        if not VALUE.fullmatch(operand.value):
            fail("numeric_value")
        excerpt = operand.source_excerpt
        contains_value = source_contains_number(excerpt, operand.value) if allow_result_literal else bool(
            re.search(r"(?<![A-Za-z0-9./-])" + re.escape(operand.value) + r"(?![A-Za-z0-9./])", excerpt))
        if not excerpt.strip() or not contains_value:
            fail("source_value")
        if operand.origin == "problem_text":
            if not any(excerpt in text for text in problem_texts): fail("problem_source")
        elif operand.origin == "problem_image":
            if not has_problem_image: fail("image_source")
        elif operand.origin == "skill":
            if excerpt not in skill_body: fail("skill_source")
        else:
            fail("operands", "operand_origin")
        try:
            value = Fraction(operand.value)
        except (ValueError, ZeroDivisionError):
            fail("numeric_value")
        operands[operand.name] = bounded(value)
    used = set()
    left = evaluate_expression(witness.expression, operands, used)
    if witness.predicate in RELATIONAL:
        if witness.comparison_expression is None:
            fail("predicate")
        # Daily equality may state an expected calculation result. It is never
        # an input/premise: the source-bound left expression independently derives
        # its value, and exact equality must still agree with declared truth.
        expected = witness.comparison_expression.strip()
        if allow_result_literal and witness.predicate == "equal" and VALUE.fullmatch(expected):
            right = bounded(Fraction(expected))
        else:
            right = evaluate_expression(witness.comparison_expression, operands, used)
        result = {"equal": left == right, "less_than": left < right, "less_equal": left <= right,
            "greater_than": left > right, "greater_equal": left >= right}[witness.predicate]
    else:
        if witness.comparison_expression is not None or witness.predicate not in {"integer", "positive_integer", "nonnegative_integer", "nonzero"}:
            fail("predicate")
        result = {"integer": left.denominator == 1,
            "positive_integer": left.denominator == 1 and left > 0,
            "nonnegative_integer": left.denominator == 1 and left >= 0,
            "nonzero": left != 0}[witness.predicate]
    if used != set(operands):
        fail("operands", "unused_operand")
    return result
