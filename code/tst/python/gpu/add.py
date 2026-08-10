@gpu
def _add(out: list[i32], a: list[i32], b: list[i32], shape: tuple[int, int, int]) -> None:
    i = global_id(0)
    out[i] = a[i] + b[i]
    return

out: list[i32] = [0] * 25
a: list[i32] = [2] * 25
b: list[i32] = [3] * 25

_add(out, a, b, (25, 1, 1))
for i in range(25):
    print(out[i], end=" ")
print("\n", end="")
