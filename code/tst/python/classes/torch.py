
x = Tensor([1, 2, 3, 4], (2, 2))
print(x[0, 1])
print(x[1, 0])
x[1, 0] = 99
print(x[1, 0])

y = Tensor.fill((16, 16), 42);
print(y[0,0])
print(y[5,5])

z = Tensor.fill((16, 16), 42);
# this will get run on the gpu
a = y + z
for i in range(a.rows):
    for j in range(a.cols):
        print(a[i, j], end=" ")
print("\n", end="")

A_data: list[i32] = [1,2,3,4,5,6] 
A = Tensor(A_data, (2,3))
B_data: list[i32] = [7,8,9,10,11,12,13,14,15,16,17,18]
B = Tensor(B_data, (3,4))
C = A @ B
print(C.rows, end = ", ")
print(C.cols)
print(C[0,0])
