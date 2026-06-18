# (M, N) @ (N, K) => (M, K)

M = [[1, 2, 3, 4, 5], [6, 7, 8, 9, 10], [11, 12, 13, 14, 15], [16, 17, 18, 19, 20], [21, 22, 23, 24, 25]]
N = [[1, 2, 3, 4, 5], [6, 7, 8, 9, 10], [11, 12, 13, 14, 15], [16, 17, 18, 19, 20], [21, 22, 23, 24, 25]]
P = [[0, 0, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0]]

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
    print(_P[3][3])
    print(_P[4][4])
    return

matmul(
    M, N, P
)
