"""Arithmetic-only inverse meeting submission with exact event replay."""
from fractions import Fraction as F
from math_reflected_motion import audit_motion
from math_solution_contract import SolutionContractError, _object, _text

TOOL_NAME='solve_reflected_meetings'
DESCRIPTION='折返'


def parameters(common):
    common['visual_method_ids']['maxItems']=0
    distance={'type':'integer','minimum':1,'maximum':100000}
    return _object({**common,'starts':{'enum':['same','opposite']},
                    'a':distance,'b':distance,'evidence':_text(1500)})


def normalize(value):
    a,b=value['a'],value['b']
    if not 0<b<a:
        raise SolutionContractError('submission_shape',path='$.b',rule='reflected_scope')
    same=value['starts']=='same'
    base=2*a if same else 3*a
    candidates=[F(base-b,1 if same else 2),F(base+b,1 if same else 2)]
    lines=['原题依据：'+value['evidence'],
           '两车各自匀速，到端点立即折返；端点同时到达不计作迎面相遇。以下对提交条件作精确核算，原图抄录仍须核对。']
    if same:
        lines.append('为什么先看2份时间：把每辆车走过的路分成完整单程和最后一段。两车从同一端出发，在内部迎面时，走完的单程数必定一奇一偶；两段余程合起来又是一个全程，所以合走路程只能是2、4、6……个全程。合速度不变，首次合走2个全程，下次候选合走4个全程，用时就是首次的2倍。端点重合另行跳过并检查后续迎面。')
        lines += [f'第一次迎面时，两车合走两个全程。把第一次所用时间看作1份，慢车走{a}，快车走两个全程减{a}。',
                  f'下一个候选迎面时刻是2份时间，慢车累计走{a}×2＝{base}。全程大于{a}，因此慢车至多折返一次。',
                  f'慢车未到右端：{base}再加上距右端的{b}，全程为{base}＋{b}＝{candidates[1]}。',
                  f'慢车已从右端返回：走到右端再返回{b}，全程为{base}－{b}＝{candidates[0]}。']
    else:
        lines.append('为什么先看3份时间：把每辆车走过的路分成完整单程和最后一段。两车从不同端出发，在内部迎面时，走完的单程数同为奇数或同为偶数；两段余程合起来是一个全程，所以合走路程只能是1、3、5……个全程。合速度不变，首次合走1个全程，下次候选合走3个全程，用时就是首次的3倍。端点重合另行跳过并检查后续迎面。')
        lines += ['第一次迎面时合走一个全程。把首次用时看作1份，左端出发车走'+str(a)+'。',
                  f'下一个候选迎面时刻是3份时间，左端出发车累计走{a}×3＝{base}。全程大于{a}，故它至多完成两个单程。',
                  f'若尚未到右端，位置为{base}，不等于{b}；若折返一次还没回左端，补走{b}便完成两个单程：({base}＋{b})÷2＝{candidates[1]}。',
                  f'若已回左端又走{b}，先扣除这段，余下是两个单程：({base}－{b})÷2＝{candidates[0]}。']
    accepted=[]
    for length in candidates:
        if length<=a:continue
        u,v=(2*length-a,F(a)) if same else (F(a),length-a)
        result=audit_motion(length=str(length),start_a='left',speed_a=str(u),start_b='left' if same else 'right',speed_b=str(v),end_time=2 if same else 3)
        head=result['headOnEvents']
        target=length-b if same else F(b)
        if len(head)!=2 or F(head[0]['position'])!=a or F(head[1]['position'])!=target:
            raise SolutionContractError('submission_shape',rule='reflected_replay')
        accepted.append(str(length))
        lines.append('全程'+str(length)+'的逐车路程账：\n\n|迎面次序|时间份数|车|累计路程|完整单程数|余程|距左端位置|方向|\n|---|---|---|---|---|---|---|---|')
        for index,event in enumerate(head,1):
            for car in ('a','b'):
                q=event[car]
                direction='向右' if q['arrivalDirection']=='right' else '向左'
                lines[-1] += f"\n|{index}|{event['time']}|{car.upper()}|{q['distance']}|{q['wholeTraversals']}|{q['remainder']}|{q['position']}|{direction}|"
        lines.append('已逐段求交核对整个时间区间：两次之间没有更早的迎面相遇；两车位置一致、方向相反。')
    # Endpoint collisions can suppress the nominal next meeting. Check later genuine events.
    exceptional=[F(2*a)] if same else [F(3*a,2),F(3*a)]
    for length in exceptional:
        u,v=(2*length-a,F(a)) if same else (F(a),length-a)
        result=audit_motion(length=str(length),start_a='left',speed_a=str(u),start_b='left' if same else 'right',speed_b=str(v),end_time=3 if same else 5)
        head=result['headOnEvents']
        if len(head)<2:raise SolutionContractError('submission_shape',rule='reflected_endpoint_replay')
        second=head[1]
        actual=length-F(second['position']) if same else F(second['position'])
        lines.append(f"端点例外全程{length}：跳过端点同时到达后，真正第二次迎面在{second['time']}份时间、距左端{second['position']}；题目所问一侧的距离为{actual}，不是{b}，排除。")
    omission='用逐车路程表展示位置与方向，本次未另绘图。'
    lines += ['全程可能为：'+' 或 '.join(accepted)+'。',omission]
    return dict(schemaVersion=1,mode='general',method_id=value['method_id'],visual_method_ids=value['visual_method_ids'],
                answer='\n\n'.join(lines),diagrams=[],diagram_omission=dict(status='no_helpful_diagram',reason=omission))
