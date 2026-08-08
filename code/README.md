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
`-Doptimize=ReleaseFast`
- zig flag for the best performance

## Short term goals

### Compiler
- [ ] [critical edge splitting](https://nickdesaulniers.github.io/blog/2023/01/27/critical-edge-splitting/)
- [ ] rdna3 laziness expressed through type system
  - [ ] loads to improve here :)
- [ ] support arbitrary transformations like `map`
- [ ] tuples elems not always being 8 bytes
- [ ] strings as tuples (stack allocation!)
- [ ] better type inference on y
```
  xs: list[i32] = [0]
  y = 123 # infer i64
  xs[0] = y
```
  - maybe we need to push width down into our backend
  - consider
```
_P: list[list[i32]]
_P[m]: list[i32]
_P[m][k]: i32
```
- [ ] support multiple GPU work-groups per dispatch
  - max workgroup: total=1024 dimensions=(1024, 1024, 1024)

### Assembler/Linker
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
