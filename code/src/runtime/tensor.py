class Tensor[T]:
    def __init__(self, data: list[T], shape: tuple[int, int]) -> None:
        self.data = data
        self.shape = [shape[0], shape[1]]

    @inline
    @staticmethod
    def _index_2d(row: i32, col: i32, stride: i32) -> i32:
        return row * stride + col;

    def __getitem__(self, idxs: tuple[int, int]) -> T:
        row = idxs[0]
        col = idxs[1]
        index = Tensor._index_2d(row, col, self.shape[1])
        return self.data[index]

    def __setitem__(self, idxs: tuple[int, int], value: T) -> None:
        row = idxs[0]
        col = idxs[1]
        index = Tensor._index_2d(row, col, self.shape[1])
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
        # FIXME: hack for proper type propogation
        zero: T = 0
        res = Tensor.fill((self.shape[0], self.shape[1]), zero)
        Tensor._add_gpu(res.data, self.data, other.data, (self.shape[0] * self.shape[1], 1, 1))
        return res

    @gpu
    @staticmethod
    # (i, j) @ (j,k) = (i,k)
    def _matmul_gpu[U](out: list[U], a: list[U], b: list[U], J: i32, K: i32) -> None:
        i = global_id(0)
        k = global_id(1)
        acc: U = 0
        for j in range(J):
            a_i = Tensor._index_2d(i, j, J)
            b_i = Tensor._index_2d(j, k, K) 
            acc += a[a_i] * b[b_i]

        # (i, k)
        out[i * K + k] = acc
    
    def __matmul__(self, other: Tensor[T]) -> Tensor[T]:
        # FIXME: hack for proper type propogation
        zero: T = 0
        # (i, k)
        res = Tensor.fill((self.shape[0], other.shape[1]), zero)
        Tensor._matmul_gpu(
            res.data,
            self.data,
            other.data,
            self.shape[1],
            other.shape[1],
           (self.shape[0], other.shape[1], 1)
        )
        return res

    @gpu
    @staticmethod
    def _relu_gpu[U](out: list[U], a: list[U]) -> None:
        i = global_id(0)
        # hack showing up again
        zero: U = 0;
        out[i] = max(a[i], zero)

    def relu(self) -> Tensor[T]:
        # hack
        zero: T = 0
        res = Tensor.fill((self.shape[0], self.shape[1]), zero)
        Tensor._relu_gpu(
            res.data,
            self.data,
            (self.shape[0], self.shape[1])
        )
        return res
