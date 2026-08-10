
x = Tensor([1, 2, 3, 4], (2, 2))
print(x[0, 1])
print(x[1, 0])
x[1, 0] = 99
print(x[1, 0])
