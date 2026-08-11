@gpu
def kernel(out: list[int]) -> None:
    out[global_id(0)] = 42
    return

out: list[int] = [0, 0, 0, 0, 0]

kernel(out, (len(out), 1, 1))
print(out)
