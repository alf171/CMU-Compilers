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

    @staticmethod
    def fill[U](shape: tuple[int, int], value: U) -> Tensor[U]:
        count =  shape[0] * shape[1]
        return Tensor([value] * count, shape)

    @gpu
    @staticmethod
    def _add_gpu[U](out: list[U], a: list[U], b: list[U]) -> None:
        i = global_id(0)
        out[i] = a[i] + b[i]
        return

    def __add__(self, other: Tensor[T]) -> Tensor[T]:
        res = Tensor.fill(self.shape, 0)
        Tensor._add_gpu(res.data, self.data, other.data, (self.shape[0] * self.shape[1], 1, 1))
        return res

    @gpu
    @staticmethod
    # (i, j) @ (j,k) = (i,k)
    # should we push classes into gpu kernels to cleanup indexing logic?
    def _matmul_gpu[U](out: list[U], a: list[U], b: list[U], J: int, K: int) -> None:
        i = global_id(0)
        k = global_id(1)
        acc: U = 0
        for j in range(J):
            acc += a[i * J + j] * b[j * K + k]

        # (i, k)
        out[i * K + k] = acc
    
    def __matmul__(self, other: Tensor[T]) -> Tensor[T]:
        res = Tensor.fill(self.shape, 0)
        Tensor._matmul_gpu(
            res.data,
            self.data,
            other.data,
            self.shape[1],
            other.shape[1],
           (self.shape[0], other.shape[1], 1)
       )
        return res

