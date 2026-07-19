@gpu
def kernel(out: list[int], n: int) -> None:
    out[global_id()] = 42
    return

out: list[int] = [0, 0, 0, 0, 0]

kernel(out, len(out))
print(out)
