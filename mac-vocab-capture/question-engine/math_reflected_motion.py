"""Bounded exact trajectory audit; does not authenticate source or approve teaching."""
from fractions import Fraction as F


class ReflectedMotionError(ValueError):
    pass


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int,str)) or len(str(value))>40:
        raise ReflectedMotionError('Expected bounded integer or rational string')
    try:
        x=F(value)
    except (ValueError,ZeroDivisionError) as error:
        raise ReflectedMotionError('Invalid rational') from error
    if abs(x)>1000000 or x.denominator>1000000:
        raise ReflectedMotionError('Quantity out of range')
    return x


def ledger(length,start,distance):
    length,distance=number(length),number(distance)
    if length<=0 or distance<0 or start not in ('left','right'):
        raise ReflectedMotionError('Invalid route')
    q,r=divmod(distance,length)
    right=(start=='left')==(q%2==0)
    direction='right' if right else 'left'
    return dict(distance=str(distance),wholeTraversals=int(q),remainder=str(r),
                position=str(r if right else length-r),endpoint=r==0,
                arrivalDirection=('left' if right else 'right') if r==0 and distance else direction,
                departureDirection=direction)


def segments(length,start,speed,end):
    if int(speed*end/length)+2>512:
        raise ReflectedMotionError('Segment budget exceeded')
    p=F(0) if start=='left' else length
    v=speed if start=='left' else -speed
    t=F(0)
    result=[]
    while t<end:
        stop=min(end,t+((length-p)/v if v>0 else -p/v))
        result.append((t,stop,p,v))
        p+=v*(stop-t)
        t,v=stop,-v
    return result


def audit_motion(*,length,start_a,speed_a,start_b,speed_b,end_time):
    length,speed_a,speed_b,end=map(number,(length,speed_a,speed_b,end_time))
    if min(length,speed_a,speed_b,end)<=0 or start_a not in ('left','right') or start_b not in ('left','right'):
        raise ReflectedMotionError('Invalid positive quantities or starts')
    a,b=segments(length,start_a,speed_a,end),segments(length,start_b,speed_b,end)
    i=j=0
    events={}
    while i<len(a) and j<len(b):
        ta,ea,pa,va=a[i]
        tb,eb,pb,vb=b[j]
        lo,hi=max(ta,tb),min(ea,eb)
        if va==vb:
            if pa-va*ta==pb-vb*tb and hi>lo:
                raise ReflectedMotionError('Coincident interval has no discrete meeting order')
        else:
            t=(pb-vb*tb-pa+va*ta)/(va-vb)
            if 0<t and lo<=t<=hi:
                p=pa+va*(t-ta)
                kind='endpoint' if p in (0,length) else ('head_on' if va*vb<0 else 'overtaking')
                item=dict(time=str(t),position=str(p),kind=kind,
                          a=ledger(str(length),start_a,str(speed_a*t)),b=ledger(str(length),start_b,str(speed_b*t)))
                if t in events and (events[t]['position'],events[t]['kind'])!=(str(p),kind):
                    raise ReflectedMotionError('Inconsistent event partition')
                events[t]=item
        if ea<=eb:i+=1
        if eb<=ea:j+=1
    ordered=[events[t] for t in sorted(events)]
    return dict(events=ordered,headOnEvents=[e for e in ordered if e['kind']=='head_on'],checkedThrough=str(end),endpointCountsAsHeadOn=False)
