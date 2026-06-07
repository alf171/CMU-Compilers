M = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
N = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
P = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]

# (M, N) @ (N, K) => (M, K)

lm = len(M)
for m in range(lm):
# for m in range(3):
    # for k in range(len(N[0])):
    for k in range(3):
        acc = 0
        # for n in range(len(M[0])):
        for n in range(3):
            acc = acc + (M[m][n] * N[n][k])
        # P[m][k] = acc
