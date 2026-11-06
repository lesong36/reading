"""Bounded exact simple-path counts for an explicitly supplied graph.

This does not recognize an image or establish whether crossings are junctions.
Every physical junction must be represented explicitly. No-turn crossings need
additional transition state and are outside this graph contract.
"""
from functools import lru_cache


class PathGraphError(ValueError):
    """The input is outside the supported simple-graph contract."""


def count_simple_paths(*, nodes, edges, start, end, directed=False):
    if type(directed) is not bool:
        raise PathGraphError("directed must be a boolean")
    if not isinstance(nodes, list) or not 1 <= len(nodes) <= 12:
        raise PathGraphError("supply 1 to 12 nodes")
    if any(not isinstance(n, str) or not n.strip() or len(n) > 40 for n in nodes):
        raise PathGraphError("node labels must be nonempty strings of at most 40 characters")
    if len(set(nodes)) != len(nodes):
        raise PathGraphError("duplicate node labels")
    index = {n: i for i, n in enumerate(nodes)}
    if not isinstance(start, str) or not isinstance(end, str) or start not in index or end not in index:
        raise PathGraphError("start and end must name supplied nodes")
    if not isinstance(edges, list) or len(edges) > 132:
        raise PathGraphError("supply at most 132 edges")
    adjacency = [set() for _ in nodes]
    seen = set()
    for edge in edges:
        if not isinstance(edge, (list, tuple)) or len(edge) != 2:
            raise PathGraphError("each edge must have two endpoints")
        a, b = edge
        if not isinstance(a, str) or not isinstance(b, str) or a not in index or b not in index or a == b:
            raise PathGraphError("edge endpoints must be known distinct nodes")
        i, j = index[a], index[b]
        key = (i, j) if directed else tuple(sorted((i, j)))
        if key in seen:
            raise PathGraphError("duplicate edge; parallel roads are unsupported")
        seen.add(key)
        adjacency[i].add(j)
        if not directed:
            adjacency[j].add(i)
    size = len(nodes)
    target = index[end]

    @lru_cache(maxsize=None)
    def lengths(current, visited):
        counts = [0] * size
        if current == target:
            counts[0] = 1
        else:
            for neighbor in adjacency[current]:
                if not visited & (1 << neighbor):
                    child = lengths(neighbor, visited | (1 << neighbor))
                    for length in range(size - 1):
                        counts[length + 1] += child[length]
        return tuple(counts)

    origin = index[start]
    counts = lengths(origin, 1 << origin)
    first = {} if origin == target else {
        nodes[n]: sum(lengths(n, (1 << origin) | (1 << n)))
        for n in sorted(adjacency[origin])
    }
    return {
        "total": sum(counts),
        "by_edge_count": {str(i): count for i, count in enumerate(counts) if count},
        "by_first_step": first,
        "states_evaluated": lengths.cache_info().currsize,
        "source_graph_verified": False,
        "human_approval_granted": False,
    }
