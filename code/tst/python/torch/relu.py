neg_one: i32 = -1
A = Tensor.fill((3,3), neg_one)
B = A.relu()
print(B[0,0])

one: i32 = 1
C = Tensor.fill((3,3), one)
D = C.relu()
print(D[0,0])
