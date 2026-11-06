"""Exact graph-count submission, separate from inert drawing recipes."""
from math_simple_paths import PathGraphError, count_simple_paths
from math_solution_contract import SolutionContractError, _array, _object, _text

TOOL_NAME = 'count_simple_graph_paths'
DESCRIPTION = ('原图为直线段路网且节点不得重复时提交明确节点及逐段边，程序计数并给分支。'
               '每个节点必须一一提供原图位置及归一化坐标（左上为0,0，右下为1000,1000），不可臆造节点。'
               '交点可转向必须拆成节点，不可跨越；不支持不可转向但交点不得重访、重边。'
               '不得提交自行算出的答案。图结构由模型读取，仍需核对原图。')


def parameters(common):
    return _object({**common, 'nodes': _array(_text(40), 1, 12),
                    'node_locations': _array(_object({'node': _text(40), 'location': _text(160),
                        'x': {'type': 'integer', 'minimum': 0, 'maximum': 1000},
                        'y': {'type': 'integer', 'minimum': 0, 'maximum': 1000}}), 1, 12),
                    'edges': _array(_object({'from': _text(40), 'to': _text(40)}), 0, 132),
                    'start': _text(40), 'end': _text(40), 'directed': {'type': 'boolean'},
                    'source_evidence': _text(1500), 'crossing_convention': _text(500)})


def normalize(value):
    try:
        result = count_simple_paths(nodes=value['nodes'],
                                    edges=[[e['from'], e['to']] for e in value['edges']],
                                    start=value['start'], end=value['end'], directed=value['directed'])
    except PathGraphError as error:
        raise SolutionContractError('submission_shape', path='$.edges', rule='simple_graph') from error
    locations = value['node_locations']
    labels = [item['node'] for item in locations]
    positions = [(item['x'], item['y']) for item in locations]
    if (len(labels) != len(set(labels)) or set(labels) != set(value['nodes'])
            or len(positions) != len(set(positions))
            or any(not item['location'].strip() for item in locations)):
        raise SolutionContractError('submission_shape', path='$.node_locations', rule='node_location_bijection')
    coordinates = {item['node']: (item['x'], item['y']) for item in locations}
    for edge in value['edges']:
        ax, ay = coordinates[edge['from']]
        bx, by = coordinates[edge['to']]
        for node, (x, y) in coordinates.items():
            if node in (edge['from'], edge['to']):
                continue
            if ((x-ax)*(by-ay) == (y-ay)*(bx-ax)
                    and (x-ax)*(x-bx) + (y-ay)*(y-by) < 0):
                raise SolutionContractError('submission_shape', path='$.edges', rule='edge_skips_declared_vertex')
    adjacency = {node: [] for node in value['nodes']}
    for edge in value['edges']:
        adjacency[edge['from']].append(edge['to'])
        if not value['directed']:
            adjacency[edge['to']].append(edge['from'])
    lines = ['以下为所提交图结构下的程序精确计数；图结构与交叉规则仍须核对原题，尚未经过人工审核。',
             '题目依据：' + value['source_evidence'],
             '交叉规则：' + value['crossing_convention'],
             '节点：' + '、'.join(value['nodes']),
             '原图位置（坐标以图形左上为0,0，右下为1000,1000，仅供核图）：' +
             '；'.join(f"{item['node']}：{item['location']}（{item['x']},{item['y']}）" for item in locations),
             '边（' + ('有向' if value['directed'] else '无向') + '）：' +
             '；'.join(e['from'] + ('→' if value['directed'] else '—') + e['to'] for e in value['edges']),
             '逐点可走到：' + '；'.join(node + '→' + ('、'.join(sorted(neighbors)) or '无')
                                      for node, neighbors in adjacency.items()),
             f"从{value['start']}到{value['end']}，每个节点最多经过一次，到终点即停止。",
             '按已到达节点和完整已访问集合逐步分类；未到终点的死路计0，抵达终点计1。',
             '按第一步分类：' + ('；'.join(f'{node}：{count}条' for node, count in result['by_first_step'].items()) or '无后续第一步'),
             '按经过边数分类：' + ('；'.join(f'{length}步：{count}条' for length, count in result['by_edge_count'].items()) or '无可行路径'),
             f"合计：{result['total']}条。",
             '本次展示节点、边及计数表，尚未绘制与原图位置对应的路线图。']
    return {'schemaVersion': 1, 'mode': 'general', 'method_id': value['method_id'],
            'visual_method_ids': value['visual_method_ids'], 'answer': '\n\n'.join(lines), 'diagrams': []}
