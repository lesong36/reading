import itertools
import unittest
from fractions import Fraction
from math_equal_sum_grid import EqualSumGridError, solve_equal_sum_grid


class EqualSumGridTests(unittest.TestCase):
    def verify(self, original, result, diagonals):
        for key in ('example_grid', 'alternative_grid'):
            if result[key] is None:
                continue
            grid = [[Fraction(v) for v in row] for row in result[key]]
            n=len(grid)
            sums=[sum(row) for row in grid]+[sum(grid[r][c] for r in range(n)) for c in range(n)]
            if diagonals:
                sums += [sum(grid[i][i] for i in range(n)),sum(grid[i][n-1-i] for i in range(n))]
            self.assertEqual(len(set(sums)),1)
            for r,c in itertools.product(range(n),repeat=2):
                if original[r][c] is not None:self.assertEqual(grid[r][c],original[r][c])

    def test_source_five_and_affine_transfers(self):
        source=[[None,9,None,None,None],[3,7,8,2,None],[None,3,8,4,6],[8,4,None,2,3],[None,None,0,8,7]]
        for scale,shift in [(1,0),(1,7),(2,-4),(-1,3)]:
            grid=[[None if v is None else scale*v+shift for v in row] for row in source]
            result=solve_equal_sum_grid(grid=grid,diagonals=True,target=[0,3])
            self.assertEqual(result['status'],'unique')
            self.assertEqual(Fraction(result['target_value']),10*scale+shift)
            self.assertEqual(Fraction(result['common_sum']),26*scale+5*shift)
            self.verify(grid,result,True)

    def test_exhaustive_two_by_two_clues_against_independent_completions(self):
        for diagonal in (False,True):
            possible=[]
            for flat in itertools.product((-1,0,1),repeat=4):
                a,b,c,d=flat
                sums=[a+b,c+d,a+c,b+d]+([a+d,b+c] if diagonal else [])
                if len(set(sums))==1:possible.append(flat)
            for clues in itertools.product((None,-1,0,1),repeat=4):
                completions=[flat for flat in possible if all(c is None or c==v for c,v in zip(clues,flat))]
                grid=[list(clues[:2]),list(clues[2:])]
                result=solve_equal_sum_grid(grid=grid,diagonals=diagonal,target=[0,0])
                self.assertEqual(result['status']=='inconsistent',not completions)
                if completions:
                    values={flat[0] for flat in completions}
                    self.assertEqual(result['target_unique'],len(values)==1)
                    if result['target_unique']:self.assertEqual(Fraction(result['target_value']),next(iter(values)))
                    else:self.assertNotEqual(result['example_grid'][0][0],result['alternative_grid'][0][0])
                    self.verify(grid,result,diagonal)

    def test_target_known_does_not_imply_full_unique(self):
        result=solve_equal_sum_grid(grid=[[None]*3,[None,5,None],[None]*3],diagonals=True,target=[1,1])
        self.assertEqual(result['status'],'underdetermined')
        self.assertTrue(result['target_unique'])
        self.assertEqual(result['target_value'],'5')
        self.assertEqual(result['common_sum'],'15')

    def test_invalid_inputs(self):
        base=dict(grid=[[None,None],[None,None]],diagonals=True,target=[0,0])
        for patch in [dict(grid=[]),dict(grid=[[1]]),dict(grid=[[None]*7]*7),dict(grid=[[1,2],[3]]),dict(grid=[[True,None],[None,None]]),dict(grid=[[1.5,None],[None,None]]),dict(grid=[[1000001,None],[None,None]]),dict(diagonals=1),dict(target=[2,0]),dict(target=[True,0])]:
            with self.subTest(patch=patch),self.assertRaises(EqualSumGridError):solve_equal_sum_grid(**(base|patch))

    def test_rational_solution_is_not_rejected_as_noninteger(self):
        grid=[[1,None,None],[None,None,None],[None,None,2]]
        result=solve_equal_sum_grid(grid=grid,diagonals=True,target=[1,1])
        self.assertEqual(result['target_value'],'3/2')
        self.assertEqual(result['common_sum'],'9/2')
        self.verify(grid,result,True)

    def test_maximum_order_and_clue_magnitude(self):
        grid=[[1000000]*6 for _ in range(6)]
        result=solve_equal_sum_grid(grid=grid,diagonals=True,target=[5,5])
        self.assertEqual(result['status'],'unique')
        self.assertEqual(result['common_sum'],'6000000')
        self.verify(grid,result,True)
