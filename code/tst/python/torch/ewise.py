two: i32 = 2
A = Tensor.fill((3,3), two)
three: i32 = 3
B = Tensor.fill((3,3), three)
C = A * B
print(C[0,0])

D = B - A
print(D[0,0])
