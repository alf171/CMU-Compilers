def list_repeat_int(dst: list[int], src: list[int], repeat_count: int) -> None:
    src_len = len(src)
    for i in range(src_len * repeat_count):
        dst[i] = src[i % src_len]

def list_repeat_i32(dst: list[i32], src: list[i32], repeat_count: int) -> None:
    src_len = len(src)
    for i in range(src_len * repeat_count):
        dst[i] = src[i % src_len]
