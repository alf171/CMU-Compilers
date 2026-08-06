
class MiniTorch[T]:
    def __init__(self, data: list[T]) -> None:
        self.data = data

    def get_item(self, i: int) -> T:
        return self.data[i]


tensor = MiniTorch[int]([1,2,3,4])
print(tensor.get_item(0))
print(tensor.get_item(1))
print(tensor.get_item(2))
