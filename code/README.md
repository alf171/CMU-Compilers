# Python Compiler Written in ZIG

The goal of this project is to learn more about compilers from a lower level. Previously implemented transpiler flavor of compiler.

## Run Commands

`zig build integration-test -- tst/python/simple.py /tmp/out.s`
- run python program and output asm
`clang /tmp/out.s -o /tmp/out`
- generate executable
`/tmp/out`
- run file

`zig build integration-test -- tst/python/simple.py /tmp/out.s --run`
- do all three steps above together
`--optim`
- run optimization passes of the compiler
`--dump-stats`
- dump assmebly stats useful for comparing perf

`zig build snapshot-test --`
- run snapshot testing against all tests written
`--regen`
- regenerate all snapshot results based on current output

## Design Choices
- leverage python
  - subset of its syntax
- modular
- compiled not interpreted
- arrays are currently fixed size on the heap
  - tuples are fixed on the stack
- function types are enforced

## Goals

### Compiler
- [ ] [critical edge splitting](https://nickdesaulniers.github.io/blog/2023/01/27/critical-edge-splitting/)
- [ ] more backends
  - [ ] x86 (qemu or amd cpu)
  - [ ] rdna3
- [ ] classes or objs or structs (?)
  - [ ] will be used eventually to write a minitorch
- [ ] support arbitrary transformations like `map`
- [ ] `tst/python/if.py` copy.zig bug
- [ ] rewrite tuple len into a constant op

### Linker
- [ ] remove clang on linux/x86

### MiniTorch
- a tiny ml framework leveraging language
1. forward/backward pass
2. common matrix operations like relu(), transpose(), matmul(), etc
3. [Optional] read/write weights to a file
4. build some models (ideas under)
  - 1k param: linear classifier of sorts?
  - 10k param: mnist
  - 100k param: audio model
  - 10-100M million param: lane follow maybe?
  - 1B small LLM
  - 10B strong local assistant
