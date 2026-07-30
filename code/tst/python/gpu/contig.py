
@gpu
def fill(out: list[i32], shape: tuple[int, int, int], kernel_name: tuple[char, char, char, char, char, char, char, char]) -> None:
    row = global_id(0)
    col = global_id(1)
    out[row * 5 + col] = 42
    return

# out: list[list[int]] = [[0] * 5] * 5
out: list[i32] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
kernel_name: tuple[char, char, char, char, char, char, char, char] = (
  'f', 'i', 'l', 'l', '.', 'k', 'd', '\0'
)
fill(out, (5, 5, 1), kernel_name)
print(out[12])
print(out[24])
# for i in range(25):
#     print(out[i], end="")
