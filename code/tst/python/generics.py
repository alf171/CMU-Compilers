
lst_int: list[int] = [1, 2, 3, 4]
lst_str: list[str] = ["foo", "bar"]
lst_bool: list[bool] = [False, True]

def print_len[T](_lst: list[T]) -> None:
    res = len(_lst)
    print(res)

def get_last_item[T](_lst: list[T]) -> T:
    length = len(_lst)
    return _lst[length - 1]

print_len(lst_int)
print_len(lst_str)
print_len(lst_bool)

print(get_last_item(lst_int))
print(get_last_item(lst_str))
print(get_last_item(lst_bool))
