def _print_int_helper(d: int) -> None:
    ten = 10
    ascii_zero = 48
    prev = d / ten

    if (prev != 0):
        _print_int_helper(prev)

    digit = d % 10
    buf = (digit + ascii_zero,)
    write(1, buf, 1)

# print(d: int) delegates to this method
def print_int(d: int) -> None:
    if (d < 0):
        write(1, '-', 1)
        d = -d
    _print_int_helper(d)
    write(1, '\n', 1)

# print(b: bool) delegates to this method
def print_bool(b: bool) -> None:
    s = "True\n" if b else "False\n"
    len = 5 if b else 6
    write(1, s, len)

# print(b: str) delegates to this method
def print_string(s: str) -> None:
    write(1, s, len(s) - 1)
    write(1, '\n', 1)

# print(f: float) delegates to this method
def print_float(f: float) -> None:
    if (f < 0.0):
        write(1, '-', 1)
        f = -f

    whole: int = int(f)
    _print_int_helper(whole)
    write(1, '.', 1)

    frac: float = f - float(whole)

    for _ in range(5):
        frac = frac * 10.0
        whole: int = int(frac)
        _print_int_helper(whole)
        frac = frac - float(whole)

    write(1, '\n', 1)
