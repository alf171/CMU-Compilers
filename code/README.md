# Python Compiler Written in ZIG

The goal of this project is to learn more about compilers from a lower level. Previously implemented transpiler flavor of compiler.

## Run Commands

`zig build integration-test -- tst/python/simple.py /tmp/host.s`
- run python program and output asm
`clang /tmp/host.s -o /tmp/out`
- generate executable
`/tmp/out`
- run file

`zig build integration-test -- tst/python/simple.py /tmp/host.s --run`
- do all three steps above together
`--optim`
- run optimization passes of the compiler
`--dump-ir`
- dump ir in different phases for debugging
`--dump-stats`
- dump assmebly stats useful for comparing perf
`--host`
- x86 or arm to indicate host platform to run program on
`--device`

`zig build snapshot-test --`
- run snapshot testing against all tests written
`--host`
- x86 or arm to indicate host platform to run program on
`--regen`
- regenerate all snapshot results based on current output

## Design Choices
- leverage python
  - subset of its syntax
- modular
- compiled not interpreted
- arrays are currently fixed size on the heap
  - tuples are fixed on the stack
- tuples are mutable also
- function types are enforced

## Goals

### Compiler
- [ ] [critical edge splitting](https://nickdesaulniers.github.io/blog/2023/01/27/critical-edge-splitting/)
- [ ] rdna3 laziness expressed through type system
  - [ ] loads to improve here :)
- [ ] python list expansion syntax
  - ex) `x: list[int] = [0] * 32`
- [ ] classes or objs or structs (?)
  - [ ] will be used eventually to write a minitorch
- [ ] support arbitrary transformations like `map`
- [ ] tuples elems not always being 8 bytes
- [ ] strings as tuples (stack allocation!)

### Linker
- [ ] remove clang on linux/x86
- [ ] replace bespoke c scripts

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
