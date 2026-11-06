"""Reject a locally built helper whose submission schemas differ from current source.

Run with question-engine/.venv/bin/python (PyInstaller is already a build dependency).
This inspects the bundled contract, not provider accuracy or installed-app behavior.
Only pass trusted, locally built executables: their bundled Python code is evaluated.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import types

from PyInstaller.archive.readers import CArchiveReader

PROJECT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def path_behavior(module):
    value = {'method_id': None, 'visual_method_ids': [], 'nodes': ['A', 'B', 'C'],
        'node_locations': [{'node': n, 'location': n, 'x': x, 'y': y}
                           for n, x, y in [('A', 0, 0), ('B', 1000, 0), ('C', 0, 1000)]],
        'edges': [{'from': 'A', 'to': 'B'}, {'from': 'A', 'to': 'C'}, {'from': 'C', 'to': 'B'}],
        'start': 'A', 'end': 'B', 'directed': False,
        'source_evidence': 'Offline contract probe', 'crossing_convention': 'No crossings'}
    output = module.normalize_tool_arguments('count_simple_graph_paths', json.dumps(value))
    valid = '合计：2条' in output['answer'] and '尚未经过人工审核' in output['answer']
    value['node_locations'][2].update(x=500, y=0)
    try:
        module.normalize_tool_arguments('count_simple_graph_paths', json.dumps(value), preserve_general_answer=True)
    except Exception as error:
        rejected = (getattr(error, 'issue', None) == 'submission_shape'
                    and getattr(error, 'diagnostic', {}).get('rule') == 'edge_skips_declared_vertex')
    else:
        rejected = False
    return {'validTriangleCountAndNotice': valid, 'skippedVertexRejected': rejected}


def grid_behavior(module):
    value = {'method_id': None, 'visual_method_ids': [], 'grid': [[1, None], [None, None]],
             'diagonals': True, 'target': {'row': 2, 'column': 2}, 'source_evidence': 'Offline grid probe'}
    submission = module.normalize_tool_arguments('solve_equal_sum_grid', json.dumps(value))
    answer = submission['answer']
    exact = ('唯一确定为：1' in answer and '两条主对角线和：2、2' in answer
             and '等和线的算术推理' in answer and '基础算术步骤尚未推出' not in answer
             and submission.get('diagram_omission', {}).get('status') == 'no_helpful_diagram')
    value['grid'] = [[1, 2], [3, 4]]
    answer = module.normalize_tool_arguments('solve_equal_sum_grid', json.dumps(value))['answer']
    return {'exactGridResult': exact, 'conflictingCluesDoNotProduceAnswer': '互相冲突，不能给出答案' in answer}


def reflected_behavior(module):
    outputs = {}
    for starts, expected in [('same', '70 或 90'), ('opposite', '55 或 65')]:
        value = dict(method_id=None, visual_method_ids=[], starts=starts, a=40, b=10, evidence='Offline reflected probe')
        answer = module.normalize_tool_arguments('solve_reflected_meetings', json.dumps(value))['answer']
        outputs[starts] = expected in answer and '真正第二次迎面' in answer and 'L' not in answer
    return outputs


def digit_behavior(module):
    value = dict(method_id=None, visual_method_ids=[], larger_hundreds=2, smaller_hundreds=1,
                 repeated_digits=True, turn_order='report_then_place', evidence='Offline game probe')
    answer = module.normalize_tool_arguments('solve_reported_digit_game', json.dumps(value))['answer']
    return {'fullAnswerSHA256': hashlib.sha256(answer.encode()).hexdigest(),
            'readableFullCertificate': '|剩余空格|报0至9的结果序列|保证值|甲最优报数|' in answer and '$-81$' in answer,
            'optimalTranscripts': '240－100＝140' in answer and '299－159＝140' in answer,
            'successorLedger': '|9|被减数个位|9|81|90|' in answer and '|9|减数个位|-9|90|81|' in answer}


def hexagon_behavior(module):
    def arguments(payload):
        return json.dumps({'method_id': None, 'visual_method_ids': [],
            'answer': '```math-hexagon-partition\n' + payload + '\n```',
            'diagram_outcome': {'status': 'inline_hexagon'}})
    valid = all(module.normalize_tool_arguments(module.GENERAL_TOOL_NAME,
        arguments('{"sides":' + str(n) + '}'), diagram_scope='native_only')['answer']
        .startswith('```math-hexagon-partition') for n in (3, 4, 5))
    try:
        module.normalize_tool_arguments(module.GENERAL_TOOL_NAME,
            arguments('{"sides":3,"sides":5}'), diagram_scope='native_only')
    except Exception as error:
        rejected = getattr(error, 'issue', None) == 'submission_inline_hexagon'
    else:
        rejected = False
    return {'threeConstructionsAccepted': valid, 'duplicateFieldsRejected': rejected}


def check(executable):
    source = PROJECT / 'question-engine/math_solution_contract.py'
    spec = importlib.util.spec_from_file_location('current_math_contract', source)
    current = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(current)
    code = CArchiveReader(str(executable)).open_embedded_archive('PYZ.pyz').extract('math_solution_contract')
    namespace = {'__name__': 'frozen_math_contract'}
    exec(code, namespace)
    result = {
        'engineExecutable': str(executable), 'engineSHA256': digest(executable),
        'sourceContractSHA256': digest(source), 'schemas': {},
        'scope': 'Six schema variants, two graph probes and two equal-line grid probes and two reflected-motion probes; not whole-engine equivalence, source-image accuracy, or app acceptance.',
    }
    for strict in (False, True):
        expected = current.tool_schema(strict=strict)
        actual = namespace['tool_schema'](strict=strict)
        name = 'strict' if strict else 'normal'
        result['schemas'][name] = {
            'matchesSource': actual == expected,
            'frozenSHA256': hashlib.sha256(json.dumps(actual, sort_keys=True).encode()).hexdigest(),
            'sourceSHA256': hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest(),
        }
    # Renderer tools are the production fast path. Checking only the legacy
    # submission schema would accept a helper missing newly added executable tools.
    module_names = ['math_solution_contract', 'math_simple_paths', 'math_path_submission', 'math_equal_sum_grid', 'math_magic_submission', 'math_reflected_motion', 'math_reflected_submission', 'math_digit_placement', 'math_digit_submission', 'math_diagram_tools']
    saved = {name: sys.modules.get(name) for name in module_names}
    archive = CArchiveReader(str(executable)).open_embedded_archive('PYZ.pyz')
    try:
        current_modules = {}
        for name in module_names:
            module = types.ModuleType(name)
            sys.modules[name] = module
            exec(compile((PROJECT / 'question-engine' / (name + '.py')).read_bytes(), name, 'exec'), module.__dict__)
            current_modules[name] = module
        expected_tools = {(strict, scope): current_modules['math_diagram_tools'].tool_schemas(strict, diagram_scope=scope)
                          for strict in (False, True) for scope in ('full', 'native_only')}
        source_hexagon = hexagon_behavior(current_modules['math_diagram_tools'])
        source_behavior = path_behavior(current_modules['math_diagram_tools'])
        source_grid_behavior = grid_behavior(current_modules['math_diagram_tools'])
        source_digit_behavior = digit_behavior(current_modules['math_diagram_tools'])
        source_reflected_behavior = reflected_behavior(current_modules['math_diagram_tools'])
        for name in module_names:
            module = types.ModuleType(name)
            sys.modules[name] = module
            exec(archive.extract(name), module.__dict__)
        for (strict, scope), expected in expected_tools.items():
            actual = sys.modules['math_diagram_tools'].tool_schemas(strict, diagram_scope=scope)
            key = 'renderer_' + ('strict_' if strict else 'normal_') + scope
            result['schemas'][key] = {'matchesSource': actual == expected,
                'frozenSHA256': hashlib.sha256(json.dumps(actual, sort_keys=True).encode()).hexdigest(),
                'sourceSHA256': hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()}
        result['hexagonBehavior'] = {'source': source_hexagon, 'frozen': hexagon_behavior(sys.modules['math_diagram_tools'])}
        result['digitBehavior'] = {'source': source_digit_behavior, 'frozen': digit_behavior(sys.modules['math_diagram_tools'])}
        result['reflectedBehavior'] = {'source': source_reflected_behavior, 'frozen': reflected_behavior(sys.modules['math_diagram_tools'])}
        result['graphBehavior'] = {'source': source_behavior,
                                  'frozen': path_behavior(sys.modules['math_diagram_tools'])}
        result['gridBehavior'] = {'source': source_grid_behavior,
                                 'frozen': grid_behavior(sys.modules['math_diagram_tools'])}
    finally:
        for name, module in saved.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module
    result['passed'] = (all(s['matchesSource'] for s in result['schemas'].values())
                        and all(result['graphBehavior']['source'].values())
                        and all(result['graphBehavior']['frozen'].values())
                        and all(result['gridBehavior']['source'].values())
                        and all(result['gridBehavior']['frozen'].values())
                        and all(result['reflectedBehavior']['source'].values())
                        and all(result['reflectedBehavior']['frozen'].values())
                        and all(result['hexagonBehavior']['source'].values())
                        and all(result['hexagonBehavior']['frozen'].values())
                        and all(result['digitBehavior']['source'].values())
                        and all(result['digitBehavior']['frozen'].values())
                        and result['digitBehavior']['source'] == result['digitBehavior']['frozen'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        result = check(args.executable.resolve(strict=True))
    except Exception as error:
        # Avoid printing embedded data or configuration in failures.
        print('Frozen math contract inspection failed: ' + type(error).__name__, file=sys.stderr)
        return 1
    if args.report:
        args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    if not result['passed']:
        print('Frozen math submission contract differs from current source; rebuild the helper before packaging.', file=sys.stderr)
        return 1
    print('Frozen math contracts match source (six schema variants, two graph, two grid and two reflected and two digit-game and two hexagon probes).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
