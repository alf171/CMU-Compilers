@gpu
def fill(out: list[list[i32]]) -> None:
    row = global_id(0)
    col = global_id(1)
    out[row][col] = 42
    return

out: list[list[i32]] = [[0] * 5] * 5

fill(out, (5, 5, 1))
for i in range(5):
    for j in range(5):
        print(out[i][j], end=" ")
print("\n", end="")
