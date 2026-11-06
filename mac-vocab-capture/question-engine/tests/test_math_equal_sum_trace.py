import itertools
import unittest
from fractions import Fraction

from math_equal_sum_grid import elementary_equal_sum_trace, solve_equal_sum_grid


class ElementaryTraceTests(unittest.TestCase):
    def replay(self, grid, diagonals, target):
        result = solve_equal_sum_grid(grid=grid, diagonals=diagonals, target=target)
        self.assertNotEqual(result['status'], 'inconsistent')
        trace = elementary_equal_sum_trace(grid=grid, diagonals=diagonals, target=target)
        n = len(grid)
        common = n*n
        known = {r*n+c: Fraction(v) for r, row in enumerate(grid)
                 for c, v in enumerate(row) if v is not None}
        lines = [set(r*n+c for c in range(n)) for r in range(n)]
        lines += [set(r*n+c for r in range(n)) for c in range(n)]
        if diagonals:
            lines += [set(i*n+i for i in range(n)), set(i*n+n-1-i for i in range(n))]
        for step in trace['steps']:
            assignments = {int(i): Fraction(v) for i, v in step['assignments'].items()}
            self.assertFalse(set(assignments) & set(known))
            constraints = []
            for premise in step['premises']:
                origins = premise['lines']
                left = lines[origins[0]]
                right = {common} if len(origins) == 1 else lines[origins[1]]
                coefficients = {i: Fraction((i in left) - (i in right)) for i in left | right}
                rhs = -sum(v*known[i] for i, v in coefficients.items() if i in known)
                coefficients = {i: v for i, v in coefficients.items() if i not in known and v}
                if coefficients[min(coefficients)] == -1:
                    coefficients = {i: -v for i, v in coefficients.items()}
                    rhs = -rhs
                self.assertEqual(coefficients, {int(i): Fraction(v) for i, v in premise['coefficients'].items()})
                self.assertEqual(rhs, Fraction(premise['rhs']))
                self.assertEqual(set(coefficients), set(assignments))
                self.assertEqual(sum(v*assignments[i] for i, v in coefficients.items()), rhs)
                constraints.append(coefficients)
            if len(assignments) == 2:
                x, y = sorted(assignments)
                self.assertNotEqual(constraints[0][x]*constraints[1][y],
                                    constraints[0][y]*constraints[1][x])
            known.update(assignments)
        for i, v in known.items():
            expected = result['common_sum'] if i == common else result['determined_grid'][i//n][i%n]
            self.assertIsNotNone(expected)
            self.assertEqual(v, Fraction(expected))
        self.assertEqual(trace['target_derived'], target[0]*n+target[1] in known)
        return trace

    def test_original_and_affine_transfers_have_replayable_complete_proof(self):
        source = [[None,9,None,None,None],[3,7,8,2,None],[None,3,8,4,6],
                  [8,4,None,2,3],[None,None,0,8,7]]
        for scale, shift in [(1,0),(2,-4),(-1,3),(3,100)]:
            grid = [[None if v is None else scale*v+shift for v in row] for row in source]
            for transpose in (False, True):
                changed = [list(row) for row in zip(*grid)] if transpose else grid
                target = [3,0] if transpose else [0,3]
                trace = self.replay(changed, True, target)
                self.assertTrue(trace['target_derived'])
                self.assertTrue(trace['all_cells_derived'])
                self.assertEqual(Fraction(trace['target_value']), 10*scale+shift)
                self.assertIn('＝', trace['steps'][0]['text'])

    def test_incomplete_trace_does_not_claim_free_target(self):
        trace = self.replay([[None]*3 for _ in range(3)], True, [0,0])
        self.assertFalse(trace['target_derived'])
        self.assertFalse(trace['all_cells_derived'])
        self.assertEqual(trace['steps'], [])

    def test_all_clue_masks_of_three_order_magic_and_rational_case(self):
        full = [[8,1,6],[3,5,7],[4,9,2]]
        pair_steps = 0
        for mask in itertools.product((False, True), repeat=9):
            grid = [[full[r][c] if mask[r*3+c] else None for c in range(3)] for r in range(3)]
            trace = self.replay(grid, True, [0,0])
            pair_steps += sum(len(s['assignments']) == 2 for s in trace['steps'])
        self.assertGreater(pair_steps, 0)
        self.replay([[1,None,None],[None,None,None],[None,None,2]], True, [1,1])


if __name__ == '__main__':
    unittest.main()
