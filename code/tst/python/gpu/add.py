@gpu
def add(out: list[i32], a: list[i32], b: list[i32]) -> None:
    i = global_id(0)
    out[i] = a[i] + b[i]

out: list[i32] = [i32(0)] * 25
a: list[i32] = [i32(2)] * 25
b: list[i32] = [i32(3)] * 25

add(out, a, b, (25, 1, 1))
for i in range(25):
    print(out[i], end=" ")
print("\n", end="")
