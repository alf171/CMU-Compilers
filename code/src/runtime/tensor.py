class Tensor[T]:
    def __init__(self, data: list[T], shape: tuple[i32, i32]) -> None:
        self.data = data
        self.rows = shape[0]
        self.cols = shape[1]
        self.row_stride = shape[1]
        self.col_stride = 1

    @inline
    @staticmethod
    def _index_2d(row: i32, col: i32, row_stride: i32, col_stride: i32) -> i32:
        return row * row_stride + col * col_stride;

    def __getitem__(self, idxs: tuple[i32, i32]) -> T:
        row = idxs[0]
        col = idxs[1]
        index = Tensor._index_2d(row, col, self.row_stride, self.col_stride)
        return self.data[index]

    def __setitem__(self, idxs: tuple[i32, i32], value: T) -> None:
        row = idxs[0]
        col = idxs[1]
        index = Tensor._index_2d(row, col, self.row_stride, self.col_stride)
        self.data[index] = value

    @staticmethod
    def fill[U](shape: tuple[i32, i32], value: U) -> Tensor[U]:
        # FIXME: shouldnt need a cast here
        count =  int(shape[0]) * int(shape[1])
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
        res = Tensor.fill((self.rows, self.cols), zero)
        Tensor._add_gpu(res.data, self.data, other.data, (self.rows * self.cols, 1, 1))
        return res

    @gpu
    @staticmethod
    def _sub_gpu[U](out: list[U], a: list[U], b: list[U]) -> None:
        i = global_id(0)
        out[i] = a[i] - b[i]
        return

    def __sub__(self, other: Tensor[T]) -> Tensor[T]:
        # FIXME: hack for proper type propogation
        zero: T = 0
        res = Tensor.fill((self.rows, self.cols), zero)
        Tensor._sub_gpu(res.data, self.data, other.data, (self.rows * self.cols, 1, 1))
        return res

    @gpu
    @staticmethod
    def _mul_gpu[U](out: list[U], a: list[U], b: list[U]) -> None:
        i = global_id(0)
        out[i] = a[i] * b[i]
        return

    def __mul__(self, other: Tensor[T]) -> Tensor[T]:
        # FIXME: hack for proper type propogation
        zero: T = 0
        res = Tensor.fill((self.rows, self.cols), zero)
        Tensor._mul_gpu(res.data, self.data, other.data, (self.rows * self.cols, 1, 1))
        return res

    @gpu
    @staticmethod
    # (i, j) @ (j,k) = (i,k)
    def _matmul_gpu[U](out: list[U], a: list[U], b: list[U], J: i32, K: i32) -> None:
        i = global_id(0)
        k = global_id(1)
        acc: U = 0
        for j in range(J):
            a_i = Tensor._index_2d(i, j, J, 1)
            b_i = Tensor._index_2d(j, k, K, 1) 
            acc += a[a_i] * b[b_i]

        # (i, k)
        out[i * K + k] = acc
    
    def __matmul__(self, other: Tensor[T]) -> Tensor[T]:
        # FIXME: hack for proper type propogation
        zero: T = 0
        # (i, k)
        res = Tensor.fill((self.rows, other.cols), zero)
        Tensor._matmul_gpu(
            res.data,
            self.data,
            other.data,
            self.cols,
            other.cols,
           (self.rows, other.cols, 1)
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
        res = Tensor.fill((self.rows, self.cols), zero)
        Tensor._relu_gpu(
            res.data,
            self.data,
            (self.rows, self.cols)
        )
        return res
