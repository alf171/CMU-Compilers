class Tensor[T]:
    def __init__(self, data: list[T], shape: tuple[int, int]) -> None:
        self.data = data
        self.shape = shape

    def __getitem__(self, idxs: tuple[int, int]) -> T:
        row = idxs[0]
        col = idxs[1]
        index = row * self.shape[1] + col
        return self.data[index]

    def __setitem__(self, idxs: tuple[int, int], value: T) -> None:
        row = idxs[0]
        col = idxs[1]
        index = row * self.shape[1] + col
        self.data[index] = value

    # @staticmethod
    # def fill[T](shape: tuple[int, int], value: T) -> Tensor[T]:
    #     count =  shape[0] * shape[1]
    #     return Tensor([value] * count, shape)

    # def __add__(self, other: Tensor[T]) -> Tensor[T]:
    #     for (self.data.len):
    #         return 

# def Tensor__fill()
def Tensor__full[T](shape: tuple[int, int], value: T) -> Tensor[T]:
    count =  shape[0] * shape[1]
    return Tensor([value] * count, shape)

