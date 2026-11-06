import itertools
import math
import unittest

from math_simple_paths import PathGraphError, count_simple_paths


class SimplePathTests(unittest.TestCase):
    def test_source_graph(self):
        adjacency = {'A': 'L M X', 'L': 'A N X', 'M': 'A N R X Y',
                     'N': 'L M B X Y', 'R': 'M B Y', 'B': 'N R Y',
                     'X': 'A L M N', 'Y': 'M N R B'}
        edges = [[a, b] for a, neighbors in adjacency.items()
                 for b in neighbors.split() if a < b]
        result = count_simple_paths(nodes=list(adjacency), edges=edges, start='A', end='B')
        self.assertEqual(result['total'], 69)
        self.assertEqual(result['by_first_step'], {'L': 29, 'M': 15, 'X': 25})
        self.assertEqual(result['by_edge_count'], {'3': 5, '4': 12, '5': 19, '6': 22, '7': 11})
        self.assertFalse(result['source_graph_verified'])
        self.assertFalse(result['human_approval_granted'])

    def test_all_four_vertex_graphs_against_permutation_oracle(self):
        nodes = list('ABCD')
        for directed in (False, True):
            possible = list(itertools.permutations(nodes, 2) if directed else itertools.combinations(nodes, 2))
            for mask in range(1 << len(possible)):
                edges = [e for i, e in enumerate(possible) if mask & (1 << i)]
                roads = set(edges)
                if not directed:
                    roads |= {(b, a) for a, b in edges}
                expected = {}
                first = {b: 0 for a, b in roads if a == 'A'}
                for length in range(3):
                    for middle in itertools.permutations('BC', length):
                        path = ('A',) + middle + ('D',)
                        if all(edge in roads for edge in zip(path, path[1:])):
                            key = str(len(path) - 1)
                            expected[key] = expected.get(key, 0) + 1
                            first[path[1]] += 1
                result = count_simple_paths(nodes=nodes, edges=edges, start='A', end='D', directed=directed)
                self.assertEqual(result['by_edge_count'], expected, (directed, mask))
                self.assertEqual(result['by_first_step'], first, (directed, mask))
                self.assertEqual(result['total'], sum(expected.values()))

    def test_terminal_and_disconnected(self):
        self.assertEqual(count_simple_paths(nodes=['A'], edges=[], start='A', end='A')['by_edge_count'], {'0': 1})
        self.assertEqual(count_simple_paths(nodes=['A', 'B'], edges=[], start='A', end='B')['total'], 0)
        self.assertEqual(count_simple_paths(nodes=list('ABC'), edges=[['A', 'B'], ['B', 'C'], ['C', 'A']], start='A', end='B')['total'], 2)

    def test_maximum_complete_directed_graph(self):
        nodes = [str(i) for i in range(12)]
        result = count_simple_paths(nodes=nodes, edges=list(itertools.permutations(nodes, 2)), start='0', end='11', directed=True)
        expected = {str(k + 1): math.factorial(10) // math.factorial(10 - k) for k in range(11)}
        self.assertEqual(result['by_edge_count'], expected)
        self.assertEqual(result['total'], sum(expected.values()))
        self.assertLessEqual(result['states_evaluated'], 12 * 2 ** 12)

    def test_invalid_inputs(self):
        base = dict(nodes=['A', 'B'], edges=[['A', 'B']], start='A', end='B')
        for patch in [dict(nodes=['A', 'A']), dict(nodes=list(map(str, range(13)))),
                      dict(edges=[['A', 'A']]), dict(edges=[['A', 'C']]),
                      dict(edges=[['A', 'B'], ['B', 'A']]), dict(directed=1),
                      dict(edges=[['A']]), dict(end='C'), dict(start=[]),
                      dict(edges=[[[], 'B']]), dict(nodes=[[], 'B'])]:
            with self.subTest(patch=patch), self.assertRaises(PathGraphError):
                count_simple_paths(**(base | patch))


if __name__ == '__main__':
    unittest.main()
