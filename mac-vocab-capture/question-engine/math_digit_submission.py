"""Source-condition submission for a bounded repeated-digit placement game."""
from math_digit_placement import DigitPlacementGame
from math_solution_contract import SolutionContractError, _object, _text

TOOL_NAME = 'solve_reported_digit_game'
DESCRIPTION = '甲报0至9数字、乙看见后放入三位数减三位数的四个空位，允许重复，固定百位；程序生成完整双向策略证明及最优对局。非重复库存、先选位或其他运算不用。'
POSITIONS = ('被减数十位','被减数个位','减数十位','减数个位')


def parameters(common):
    common['visual_method_ids']['maxItems'] = 0
    hundred = {'type':'integer','minimum':1,'maximum':9}
    return _object({**common,'larger_hundreds':hundred,'smaller_hundreds':hundred,
                    'repeated_digits':{'type':'boolean','enum':[True]},
                    'turn_order':{'enum':['report_then_place']},'evidence':_text(1500)})


def normalize(value):
    larger, smaller = value['larger_hundreds'], value['smaller_hundreds']
    if larger <= smaller:
        raise SolutionContractError('submission_shape',path='$.larger_hundreds',rule='minimum')
    offset = (larger-smaller)*100
    game = DigitPlacementGame(offset=offset)
    final = offset+game.value(15)
    lines = ['原题依据：'+value['evidence'],
             '按提交条件：甲每轮报0至9中的一个数字，可重复；乙看见后填一个空格，共四轮。百位固定。原图条件的识别仍须核对。',
             f'双方都用最佳策略，最后的差是{final}。',
             f'百位贡献：{larger}00－{smaller}00＝{offset}。被减数十位加所报数字的10倍、个位加数字本身；减数对应位置扣去10倍或数字本身。',
             '乙不是只看眼前贡献。每次比较“本轮贡献＋余下空格的保证值”，选最小的位置。甲比较每个报数遇到乙最佳回应后的值，选最大的报数。没有空格时未来贡献0，由一格向四格推回。',
             '完整算术表：每行结果序列依次对应甲报0至9；各数是乙在全部空位中选择最小后继得到的值。保证值取这十个数的最大数。每行只引用更少空格的行，故可以逐层核对。',
             '|剩余空格|报0至9的结果序列|保证值|甲最优报数|\n|---|---|---|---|']
    for mask in sorted(range(1,16),key=lambda m:(m.bit_count(),m)):
        row = game.state(mask)
        label = '、'.join(POSITIONS[i] for i in game.positions(mask))
        entries = ['$'+str(r['minimum'])+'$' for r in row['reports']]
        lines[-1] += '\n|'+label+'|'+'、'.join(entries)+'|'+str(row['value'])+'|'+'、'.join(map(str,row['bestDigits']))+'|'
    lines += ['怎样核对一格比较：只剩两个十位，报4时放被减数十位得40＋0＝40，放减数十位得−40＋90＝50，乙取40；报5时两种为50和40，仍取40。这一行报0至9的结果为0、10、20、30、40、40、30、20、10、0，最大40。',
              '为什么同时保证双方：每行任意报数都有一个乙回应使结果不超过该行保证值；甲选最优报数时，每个乙落位的本轮贡献加余格值都不少于该保证值。后继少一格，反复应用直到填满，便得到乙的上界和甲的下界，覆盖所有对手动作。',
              f'初始四格保证值40。因此甲按表报数能保证差至少{offset}＋40＝{final}；乙按本轮加后继选最小能保证差至多{final}。双方最优才恰好{final}，乙任意放并不都得这个差。']
    for first in game.state(15)['bestDigits']:
        turns = game.transcript(first)
        assert game.audit(turns) == final
        filled = [0]*4
        table = f'首报{first}的完整最优对局：\n\n|甲报数|乙放入|本轮贡献|余格保证值|合计|\n|---|---|---|---|---|'
        for turn in turns:
            filled[turn['position']] = turn['digit']
            table += f"\n|{turn['digit']}|{POSITIONS[turn['position']]}|{turn['gain']}|{turn['future']}|{turn['total']}|"
        a = larger*100+filled[0]*10+filled[1]
        b = smaller*100+filled[2]*10+filled[3]
        assert a-b == final
        lines += [table,f'逐位验算：{a}－{b}＝{final}。每一步报数与落位均已按完整后继值核对最优；这两条仅为策略验算，完整保证由前表与逐层推回给出。']
    omission = '用完整状态算术表和逐步对局说明，本次未另绘图。'
    lines.append(omission)
    return dict(schemaVersion=1,mode='general',method_id=value['method_id'],visual_method_ids=[],
                answer='\n\n'.join(lines),diagrams=[],
                diagram_omission=dict(status='no_helpful_diagram',reason=omission))
