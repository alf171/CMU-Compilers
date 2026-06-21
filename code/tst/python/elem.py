x: int = 2
y: int = 3
z: int = x + y
# we should be able to fold into print(x + y)
print(z)
