
class Tensor[T]:
    def __init__(self, data: list[T], shape: tuple[int, int]) -> None:
        self.data = data
        self.shape = shape

    def __getitem__(self, idxs: tuple[int, int]) -> T:
        row = idxs[0]
        col = idxs[1]
        index = row * self.shape[1] + col
        return self.data[index]
