# (M, N) @ (N, K) => (M, K)

M = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
N = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
P = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]

def matmul(
        _M: list[list[int]], _N: list[list[int]], _P: list[list[int]]
) -> None:
    for m in range(len(_M)):
        for k in range(len(_N[0])):
            acc = 0
            for n in range(len(_M[0])):
                acc = acc + (_M[m][n] * _N[n][k])
            _P[m][k] = acc
    print(_P[0][0])
    print(_P[1][1])
    print(_P[2][2])
    return

matmul(
    M, N, P
)
