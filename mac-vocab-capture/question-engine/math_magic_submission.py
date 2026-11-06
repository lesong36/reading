"""Program-verified equal-line table submission; no model-supplied answer."""
from math_equal_sum_grid import EqualSumGridError, elementary_equal_sum_trace, solve_equal_sum_grid
from math_solution_contract import SolutionContractError, _array, _object, _text

TOOL_NAME='solve_equal_sum_grid'
DESCRIPTION=('2至6阶残缺方形等和表或幻方：只抄原图已知整数，空格填null，声明两主对角线是否也等和及目标格，程序精确核算。'
             '允许重复、0及负数，不加1至n²或互异条件。另有限定数字域/互异/分区规则时不适用。不得提交猜测的幻和或答案。')


def parameters(common):
    cell={'anyOf':[{'type':'integer','minimum':-1000000,'maximum':1000000},{'type':'null'}]}
    coordinate={'type':'integer','minimum':1,'maximum':6}
    return _object({**common,'grid':_array(_array(cell,2,6),2,6),'diagonals':{'type':'boolean'},
                    'target':_object({'row':coordinate,'column':coordinate}),'source_evidence':_text(1500)})


def normalize(value):
    target=value['target']
    try:
        result=solve_equal_sum_grid(grid=value['grid'],diagonals=value['diagonals'],target=[target['row']-1,target['column']-1])
    except EqualSumGridError as error:
        raise SolutionContractError('submission_shape',path='$.grid',rule='equal_sum_grid') from error
    def table(grid):
        n=len(grid)
        return '\n'.join(['| '+' | '.join(str(i+1) for i in range(n))+' |',
                          '| '+' | '.join('---' for _ in range(n))+' |']+
                         ['| '+' | '.join('□' if v is None else str(v) for v in row)+' |' for row in grid])
    def checks(grid):
        from fractions import Fraction
        rows=[[Fraction(v) for v in row] for row in grid]
        n=len(rows)
        output=['各行和：'+'、'.join(str(sum(row)) for row in rows),
                '各列和：'+'、'.join(str(sum(rows[r][c] for r in range(n))) for c in range(n))]
        if value['diagonals']:
            output.append('两条主对角线和：'+str(sum(rows[i][i] for i in range(n)))+'、'+str(sum(rows[i][n-1-i] for i in range(n))))
        return '\n\n'.join(output)
    lines=['以下只对所抄录方格的等和条件作程序精确核算；已知格和规则仍须核对原图，尚未经过人工教学审核。',
           '原题依据：'+value['source_evidence'],
           '原图抄录（□表示未知，重复数和0照原样保留）：\n\n'+table(value['grid']),
           '规则：每行、每列'+('及两条主对角线' if value['diagonals'] else '（不添加对角线条件）')+'的和相同。不添加互异、连续整数、正数或有限数字范围条件。']
    if result['status']=='inconsistent':
        lines.append('所提交的已知格与等和规则互相冲突，不能给出答案。请核对抄录及要求哪些线等和；这不等于原题印刷有误。')
    else:
        if result['target_unique']:
            lines.append(f"第{target['row']}行第{target['column']}列唯一确定为：{result['target_value']}。")
        else:
            lines.append('目标格不能由所提交条件唯一确定；下面展示两份目标格不同、均满足这些条件的表作为核对依据。')
        if result['common_sum'] is not None:lines.append('公共和为：'+result['common_sum']+'。')
        trace=elementary_equal_sum_trace(grid=value['grid'],diagonals=value['diagonals'],
                                        target=[target['row']-1,target['column']-1])
        if trace['steps']:
            lines.append('等和线的算术推理（位置均按原图行列）：\n\n'+
                         '\n\n'.join(f"{i+1}. {step['text']}" for i,step in enumerate(trace['steps'])))
        if not trace['target_derived']:
            lines.append('上述基础算术步骤尚未推出所问格；程序精确计算结果不代替完整的学生推理。')
        lines.append(('完整表唯一确定：' if result['status']=='unique' else '一份满足提交条件的示例（全表尚不唯一）：')+'\n\n'+table(result['example_grid']))
        lines.append(checks(result['example_grid']))
        if result['alternative_grid'] is not None:
            lines.append('另一份有效示例：\n\n'+table(result['alternative_grid']))
            lines.append(checks(result['alternative_grid']))
        lines.append('已回查全部等和线与已知格；原图抄录与教学适龄性仍待人工审核。')
    omission='本次用方格表展示抄录、结果及逐线回查，未另绘图形。'
    lines.append(omission)
    return {'schemaVersion':1,'mode':'general','method_id':value['method_id'],
            'visual_method_ids':value['visual_method_ids'],'answer':'\n\n'.join(lines),'diagrams':[],
            'diagram_omission':{'status':'no_helpful_diagram','reason':omission}}
