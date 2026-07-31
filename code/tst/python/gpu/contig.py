
@gpu
def fill(out: list[i32], shape: tuple[int, int, int]) -> None:
    row = global_id(0)
    col = global_id(1)
    out[row * 5 + col] = 42
    return

# out: list[list[int]] = [[0] * 5] * 5
out: list[i32] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

fill(out, (5, 5, 1))
for i in range(25):
    print(out[i], end=" ")
print("\n", end="")
