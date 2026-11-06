import unittest
from fractions import Fraction as F
from math_reflected_motion import ReflectedMotionError, audit_motion, ledger


class ReflectedMotionTests(unittest.TestCase):
    def test_source_and_endpoint_routes(self):
        for l,start,u,v,end,p in [(70,'left',100,40,2,60),(90,'left',140,40,2,80),(55,'right',40,15,3,10),(65,'right',40,25,3,10),(80,'left',120,40,3,40),(60,'right',40,20,5,40),(120,'right',40,80,5,40)]:
            r=audit_motion(length=l,start_a='left',speed_a=u,start_b=start,speed_b=v,end_time=end)
            self.assertEqual([(e['time'],e['position']) for e in r['headOnEvents']],[('1','40'),(str(end),str(p))])
            for e in r['events']:self.assertEqual(e['a']['position'],e['b']['position'])
            if l in (80,60,120):self.assertTrue(any(e['kind']=='endpoint' for e in r['events']))

    def test_ledger(self):
        self.assertEqual(ledger(70,'left',200)['position'],'60')
        self.assertEqual(ledger(55,'right',45)['arrivalDirection'],'left')
        r=ledger(70,'left',140)
        self.assertEqual((r['arrivalDirection'],r['departureDirection']),('left','right'))
        self.assertEqual(ledger('5/2','right','7/2')['position'],'1')

    def test_independent_unfolded_oracle(self):
        def fold(x,l):
            r=x%(2*l)
            return min(r,2*l-r)
        for l in range(1,9):
            for u in range(1,9):
                for v in range(1,9):
                    if u==v:continue
                    for opposite in (False,True):
                        start,w=(l,-v) if opposite else (0,v)
                        expected=set()
                        bound=int((start+(u+v)*6)/(2*l))+2
                        for sign in (-1,1):
                            d=u-sign*w
                            if not d:continue
                            for k in range(-bound,bound+1):
                                t=F(sign*start+2*k*l,d)
                                if 0<t<=6:
                                    self.assertEqual(fold(u*t,l),fold(start+w*t,l))
                                    expected.add((t,fold(u*t,l)))
                        r=audit_motion(length=l,start_a='left',speed_a=u,start_b='right' if opposite else 'left',speed_b=v,end_time=6)
                        self.assertEqual({(F(e['time']),F(e['position'])) for e in r['events']},expected)

    def test_invalid_and_budget(self):
        for x in (True,0,'1/0',1.5,'9'*41):
            with self.assertRaises(ReflectedMotionError):ledger(x,'left',1)
        for u,v in [(1000,1),(1,1)]:
            with self.assertRaises(ReflectedMotionError):
                audit_motion(length=1,start_a='left',speed_a=u,start_b='left',speed_b=v,end_time=1)
