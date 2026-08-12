
x = Tensor([1, 2, 3, 4], (2, 2))
print(x[0, 1])
print(x[1, 0])
x[1, 0] = 99
print(x[1, 0])

y = Tensor.fill((32, 32), 42);
print(y[0,0])
print(y[5,5])

z = Tensor.fill((32, 32), 42);
# this will get run on the gpu
a = y + x
print(a[25, 25])
