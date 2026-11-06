"""Exact report-then-place minimax with repeated digits and audited optimal play."""
from functools import cache


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('integer outside supported scope')
    return value


class DigitPlacementGame:
    def __init__(self, weights=(10,1,-10,-1), digits=tuple(range(10)), offset=100):
        self.weights, self.digits = tuple(weights), tuple(digits)
        self.offset = integer(offset,-100000,100000)
        if not 1 <= len(self.weights) <= 6 or not 1 <= len(self.digits) <= 10:
            raise ValueError('unsupported size')
        for w in self.weights: integer(w,-10000,10000)
        for d in self.digits: integer(d,0,9)
        if len(set(self.digits)) != len(self.digits): raise ValueError('duplicate choices')
        self.full_mask = (1 << len(self.weights))-1
        self.value = cache(self._value)

    def positions(self, mask):
        integer(mask,0,self.full_mask)
        return [i for i in range(len(self.weights)) if mask & (1 << i)]

    def totals(self, mask, digit):
        positions = self.positions(mask)
        if not positions or type(digit) is not int or digit not in self.digits:
            raise ValueError('illegal report or terminal state')
        return {i:self.weights[i]*digit+self.value(mask ^ (1 << i)) for i in positions}

    def _value(self, mask):
        if not self.positions(mask): return 0
        return max(min(self.totals(mask,d).values()) for d in self.digits)

    def state(self, mask):
        if not self.positions(mask): return dict(mask=0,value=0,reports=[],bestDigits=[])
        reports=[]
        for digit in self.digits:
            totals=self.totals(mask,digit)
            minimum=min(totals.values())
            reports.append(dict(digit=digit,placementTotals=totals,minimum=minimum,
                                bestPositions=[i for i,v in totals.items() if v==minimum]))
        value=max(r['minimum'] for r in reports)
        return dict(mask=mask,value=value,reports=reports,
                    bestDigits=[r['digit'] for r in reports if r['minimum']==value])

    def transcript(self, first_digit=None):
        mask, turns=self.full_mask,[]
        while mask:
            state=self.state(mask)
            digit=first_digit if mask==self.full_mask and first_digit is not None else state['bestDigits'][0]
            if type(digit) is not int or digit not in state['bestDigits']:
                raise ValueError('nonoptimal first report')
            row=next(r for r in state['reports'] if r['digit']==digit)
            pos=row['bestPositions'][0]
            nxt=mask ^ (1 << pos)
            gain=self.weights[pos]*digit
            turns.append(dict(mask=mask,digit=digit,position=pos,gain=gain,
                              future=self.value(nxt),total=gain+self.value(nxt)))
            mask=nxt
        self.audit(turns)
        return turns

    def audit(self, turns):
        if len(turns)!=len(self.weights): raise ValueError('incomplete transcript')
        mask,score=self.full_mask,self.offset
        for turn in turns:
            digit,pos=turn['digit'],turn['position']
            integer(pos,0,len(self.weights)-1)
            if pos not in self.positions(mask): raise ValueError('occupied position')
            totals=self.totals(mask,digit)
            nxt=mask ^ (1 << pos)
            gain=self.weights[pos]*digit
            expected=dict(mask=mask,digit=digit,position=pos,gain=gain,
                          future=self.value(nxt),total=gain+self.value(nxt))
            if turn!=expected: raise ValueError('incorrect successor or positional value')
            if min(totals.values())!=self.value(mask): raise ValueError('nonoptimal reporter action')
            if totals[pos]!=min(totals.values()): raise ValueError('nonoptimal placer action')
            score+=gain
            mask=nxt
        if mask or score!=self.offset+self.value(self.full_mask): raise ValueError('terminal score')
        return score
