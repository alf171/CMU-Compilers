from typing import Callable

def f(c: bool) -> int:
  if c:
      x = 1
  else:
      x = 2
  return x

def g(f: Callable[[bool], int], y: bool) -> int:
    return 2 * f(y)

f_temp = f
y = g(f_temp, False)
print(y)
