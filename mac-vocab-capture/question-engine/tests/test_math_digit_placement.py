import copy
import unittest
from math_digit_placement import DigitPlacementGame


def history(weights,digits,positions,score):
    if not positions: return score
    return max(min(history(weights,digits,tuple(j for j in positions if j!=i),
                           score+weights[i]*digit) for i in positions) for digit in digits)


class DigitPlacementTests(unittest.TestCase):
    def test_source_all_states_against_uncached_full_histories(self):
        game=DigitPlacementGame()
        for mask in range(16):
            self.assertEqual(game.value(mask),history(game.weights,game.digits,game.positions(mask),0))
        self.assertEqual(game.state(15)['bestDigits'],[4,5])
        for first in (4,5):self.assertEqual(game.audit(game.transcript(first)),140)
        for mask in range(1,16):
            for row in game.state(mask)['reports']:
                self.assertLessEqual(row['minimum'],game.value(mask))
                if row['digit'] in game.state(mask)['bestDigits']:
                    self.assertTrue(all(v>=game.value(mask) for v in row['placementTotals'].values()))

    def test_transfer_and_all_optimal_first_reports(self):
        for weights,digits,offset in [((3,-2,1),(0,1,3),20),((1,-1),(2,5,8),-7),
                                      ((-10,-1),(0,9),100),((10,1),(0,9),0)]:
            game=DigitPlacementGame(weights,digits,offset)
            expected=history(weights,digits,tuple(range(len(weights))),offset)
            self.assertEqual(game.value(game.full_mask)+offset,expected)
            for first in game.state(game.full_mask)['bestDigits']:
                self.assertEqual(game.audit(game.transcript(first)),expected)

    def test_rejects_actual_v3_actions_even_when_final_difference_is_140(self):
        game=DigitPlacementGame()
        mask,turns=15,[]
        for digit,pos in [(5,2),(9,0),(9,1),(9,3)]:
            nxt=mask ^ (1 << pos)
            gain=game.weights[pos]*digit
            turns.append(dict(mask=mask,digit=digit,position=pos,gain=gain,
                              future=game.value(nxt),total=gain+game.value(nxt)))
            mask=nxt
        self.assertEqual(100+sum(t['gain'] for t in turns),140)
        with self.assertRaisesRegex(ValueError,'placer'):game.audit(turns)
        corrupted=copy.deepcopy(game.transcript(5));corrupted[1]['future']=-1
        with self.assertRaisesRegex(ValueError,'successor'):game.audit(corrupted)

    def test_omitted_state_reachable_under_both_optimal_actions(self):
        game=DigitPlacementGame();mask=15
        for digit,pos in [(4,0),(0,3)]:
            state=game.state(mask)
            self.assertIn(digit,state['bestDigits'])
            self.assertIn(pos,next(r for r in state['reports'] if r['digit']==digit)['bestPositions'])
            mask^=1 << pos
        self.assertEqual(mask,6)
        self.assertEqual(game.state(mask)['bestDigits'],[0])

    def test_bounds_types_and_illegal_actions(self):
        for kw in [dict(digits=[True]),dict(digits=[]),dict(digits=[0,0]),
                   dict(weights=[1]*7),dict(weights=[1.5]),dict(offset=True)]:
            with self.assertRaises(ValueError):DigitPlacementGame(**kw)
        game=DigitPlacementGame()
        for digit in [True,-1,10]:
            with self.assertRaises(ValueError):game.totals(15,digit)
        with self.assertRaises(ValueError):game.transcript(9)
        with self.assertRaises(ValueError):game.audit([])
        with self.assertRaises(ValueError):game.value(16)
