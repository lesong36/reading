import unittest

from math_solution_contract import SolutionContractError, _validate_inline_rectangle_dissection_answer


class RectangleDissectionContractTests(unittest.TestCase):
    def test_accepts_only_proved_case(self):
        _validate_inline_rectangle_dissection_answer(
            '说明边长与三块去向。\n```math-rectangle-dissection\n{"case":"404-e12"}\n```')

    def test_rejects_arbitrary_coordinates(self):
        with self.assertRaises(SolutionContractError):
            _validate_inline_rectangle_dissection_answer(
                '```math-rectangle-dissection\n{"case":"custom","points":[]}\n```')

    def test_rejects_unclosed_fence(self):
        with self.assertRaises(SolutionContractError):
            _validate_inline_rectangle_dissection_answer(
                '```math-rectangle-dissection\n{"case":"404-e12"}')


if __name__ == '__main__':
    unittest.main()
