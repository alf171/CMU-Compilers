
A_stride: tuple[i32, i32] = (2,2)
A = Tensor([1,2,3,4], A_stride)
print(A[1,0])
print(A[0,1])
