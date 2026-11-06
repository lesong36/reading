"""Exact equal-line arithmetic on bounded, explicitly transcribed square grids.

No image recognition, digit range, all-different rule, or positivity assumption.
Rational solutions and freedom are retained; this is not a teaching approval.
"""
from fractions import Fraction


class EqualSumGridError(ValueError):
    pass


def elementary_equal_sum_trace(*, grid, diagonals, target):
    """Bounded equal-line cancellation and two-number sum/difference proof.

    Input is validated by the exact solver first. No solution values are used
    as premises; incomplete propagation remains explicitly incomplete.
    """
    n = len(grid)
    common = n*n
    names = [f'第{r+1}行' for r in range(n)] + [f'第{c+1}列' for c in range(n)]
    lines = [[r*n+c for c in range(n)] for r in range(n)]
    lines += [[r*n+c for r in range(n)] for c in range(n)]
    if diagonals:
        lines += [[i*n+i for i in range(n)], [i*n+n-1-i for i in range(n)]]
        names += ['左上到右下对角线', '右上到左下对角线']
    known = {r*n+c: Fraction(v) for r, row in enumerate(grid)
             for c, v in enumerate(row) if v is not None}
    steps = []

    def label(index):
        return '公共和' if index == common else f'第{index//n+1}行第{index%n+1}列'

    def equations():
        raw = [({**{i: Fraction(1) for i in line}, common: Fraction(-1)}, (k,))
               for k, line in enumerate(lines)]
        for a in range(len(lines)):
            for b in range(a+1, len(lines)):
                coefficients = {i: Fraction((i in lines[a]) - (i in lines[b]))
                                for i in set(lines[a]) | set(lines[b])}
                raw.append(({i: v for i, v in coefficients.items() if v}, (a, b)))
        output = []
        for coefficients, origins in raw:
            remaining = {i: v for i, v in coefficients.items() if i not in known}
            rhs = -sum(v*known[i] for i, v in coefficients.items() if i in known)
            if remaining:
                first = min(remaining)
                sign = remaining[first]
                if sign == -1:
                    remaining = {i: -v for i, v in remaining.items()}
                    rhs = -rhs
                output.append((remaining, rhs, origins))
        return output

    def reason(origins):
        if len(origins) == 1:
            return names[origins[0]]+'的各格相加等于公共和，代入已知数'
        shared = sorted(set(lines[origins[0]]) & set(lines[origins[1]]))
        cancellation = ('抵消共同的'+'、'.join(label(i) for i in shared)
                        if shared else '没有公共格需要抵消')
        return '比较'+names[origins[0]]+'与'+names[origins[1]]+'：两线等和，'+cancellation+'，再代入已知数'

    def sides(origins):
        left = set(lines[origins[0]])
        right = {common} if len(origins) == 1 else set(lines[origins[1]])
        return left-right, right-left

    def side_text(indices):
        parts = [label(i) for i in sorted(indices) if i not in known]
        subtotal = sum((known[i] for i in indices if i in known), Fraction(0))
        if subtotal or not parts:
            parts.append(f'（{subtotal}）' if subtotal < 0 else str(subtotal))
        return '＋'.join(parts)

    def record(text, assignments, premises):
        steps.append(dict(text=text, assignments={str(i): str(v) for i, v in assignments.items()},
                          premises=[dict(coefficients={str(i): str(v) for i, v in co.items()},
                                         rhs=str(rhs), lines=list(origins))
                                    for co, rhs, origins in premises]))
        known.update(assignments)

    for _ in range(n*n+2):
        candidates = equations()
        single = next((e for e in candidates if len(e[0]) == 1), None)
        if single:
            coefficients, rhs, origins = single
            index, coefficient = next(iter(coefficients.items()))
            value = rhs/coefficient
            left, right = sides(origins)
            own, other = (left, right) if index in left else (right, left)
            own_sum = sum((known[i] for i in own if i in known), Fraction(0))
            other_sum = sum((known[i] for i in other if i in known), Fraction(0))
            record(reason(origins)+f'，剩下{side_text(left)}＝{side_text(right)}。'
                   +f'所以{label(index)}为{other_sum}−（{own_sum}）＝{value}。',
                   {index: value}, [single])
            continue
        pairs = [e for e in candidates if len(e[0]) == 2 and common not in e[0]
                 and set(e[0].values()) <= {Fraction(-1), Fraction(1)}]
        found = False
        for a, first in enumerate(pairs):
            for second in pairs[a+1:]:
                x, y = sorted(first[0])
                if (set(first[0]) != set(second[0]) or first[0][y] == second[0][y]):
                    continue
                plus, minus = (first, second) if first[0][y] == 1 else (second, first)
                total, difference = plus[1], minus[1]
                vx = (total+difference)/2
                vy = total-vx
                text = (reason(plus[2])+f'，{label(x)}与{label(y)}的和为{total}。'
                        +reason(minus[2])+f'，前一格减去后一格为{difference}。'
                        +f'把这两份数合起来，后一格抵消，得到前一格的两倍为{total}＋（{difference}）。'
                        +f'所以{label(x)}为（{total}＋（{difference}））÷2＝{vx}，'
                        +f'{label(y)}为{total}−（{vx}）＝{vy}。')
                record(text, {x: vx, y: vy}, [plus, minus])
                found = True
                break
            if found:
                break
        if not found:
            break
    index = target[0]*n+target[1]
    return dict(steps=steps, target_derived=index in known,
                target_value=str(known[index]) if index in known else None,
                all_cells_derived=all(i in known for i in range(common)),
                common_sum=str(known[common]) if common in known else None)


def solve_equal_sum_grid(*, grid, diagonals, target):
    if type(diagonals) is not bool:
        raise EqualSumGridError('diagonals must be boolean')
    if not isinstance(grid, list) or not 2 <= len(grid) <= 6:
        raise EqualSumGridError('supply a square grid of order2 to6')
    n = len(grid)
    if any(not isinstance(row, list) or len(row) != n for row in grid):
        raise EqualSumGridError('grid must be square')
    if any(value is not None and (type(value) is not int or abs(value) > 1_000_000)
           for row in grid for value in row):
        raise EqualSumGridError('clues must be bounded integers or null')
    if (not isinstance(target, (list, tuple)) or len(target) != 2
            or any(type(v) is not int or not 0 <= v < n for v in target)):
        raise EqualSumGridError('target must be a zero-based in-grid row and column')
    size = n*n + 1
    lines = [[r*n+c for c in range(n)] for r in range(n)]
    lines += [[r*n+c for r in range(n)] for c in range(n)]
    if diagonals:
        lines += [[i*n+i for i in range(n)], [i*n+n-1-i for i in range(n)]]
    matrix = []
    for line in lines:
        row = [Fraction(0)] * (size+1)
        for index in line:
            row[index] = Fraction(1)
        row[size-1] = Fraction(-1)
        matrix.append(row)
    for r in range(n):
        for c in range(n):
            if grid[r][c] is not None:
                row = [Fraction(0)] * (size+1)
                row[r*n+c] = Fraction(1)
                row[-1] = Fraction(grid[r][c])
                matrix.append(row)
    pivots = []
    for column in range(size):
        pivot = next((r for r in range(len(pivots), len(matrix)) if matrix[r][column]), None)
        if pivot is None:
            continue
        rank = len(pivots)
        matrix[rank], matrix[pivot] = matrix[pivot], matrix[rank]
        divisor = matrix[rank][column]
        matrix[rank] = [x/divisor for x in matrix[rank]]
        for r in range(len(matrix)):
            if r != rank and matrix[r][column]:
                factor = matrix[r][column]
                matrix[r] = [a-factor*b for a,b in zip(matrix[r], matrix[rank])]
        pivots.append(column)
    common = dict(source_grid_verified=False, human_approval_granted=False,
                  variables=size, rank=len(pivots))
    if any(not any(row[:-1]) and row[-1] for row in matrix):
        return dict(common, status='inconsistent', target_unique=False,
                    target_value=None, common_sum=None, determined_grid=None,
                    example_grid=None, alternative_grid=None)
    free = [i for i in range(size) if i not in pivots]
    by_pivot = {column: matrix[r] for r,column in enumerate(pivots)}
    particular = [Fraction(0)] * size
    for column,row in by_pivot.items():
        particular[column] = row[-1]
    def unique(index):
        return index in by_pivot and all(not by_pivot[index][j] for j in free)
    def as_grid(values):
        return [[str(values[r*n+c]) for c in range(n)] for r in range(n)]
    target_index = target[0]*n+target[1]
    target_unique = unique(target_index)
    alternative = None
    if not target_unique:
        direction = target_index if target_index in free else next(j for j in free if by_pivot[target_index][j])
        changed = particular[:]
        changed[direction] += 1
        for column,row in by_pivot.items():
            changed[column] -= row[direction]
        alternative = as_grid(changed)
    return dict(common, status='unique' if not free else 'underdetermined',
                target_unique=target_unique,
                target_value=str(particular[target_index]) if target_unique else None,
                common_sum=str(particular[-1]) if unique(size-1) else None,
                determined_grid=[[str(particular[r*n+c]) if unique(r*n+c) else None for c in range(n)] for r in range(n)],
                example_grid=as_grid(particular), alternative_grid=alternative)
