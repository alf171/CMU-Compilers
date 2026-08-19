
@gpu
def fill(out: list[i32]) -> None:
    row = global_id(0)
    col = global_id(1)
    out[row * 5 + col] = 42

out: list[i32] = [0] * 25

fill(out, (5, 5, 1))
for i in range(25):
    print(out[i], end=" ")
print("\n", end="")
