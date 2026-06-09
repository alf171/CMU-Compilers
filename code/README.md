# Python Compiler Written in ZIG

The goal of this project is to learn more about compilers from a lower level. Previously implemented transpiler flavor of compiler.

## Run Commands

`zig build -Doptimize=Debug run -- tst/medium.l1.in`
- this runs register generates an igraph, spills the graph, and does coalescing on the IR
- does nothing with colored graph currently

`zig build frontend-run`
- go from python code to AST
- eventually, this will 

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

## Design Choices
- leverage python subset of python syntax
- modular
- compiled not interpreted
- arrays are fixed size!
- type or enforced to some degree?
  - maybe we do sort of ssa like constraints

## Goals

### Compiler
- [ ] [critical edge splitting](https://nickdesaulniers.github.io/blog/2023/01/27/critical-edge-splitting/)
- [ ] blocks could have names for better printing
- [ ] matmul
  - [ ] array/list assignment
  - [ ] push range() further down the stack
- [ ] sub, mul, div, unary ops like neg
  - [ ] +=, -=, *=, /=
- [ ] and/or support?
- [ ] make current optimization cross block + less hacky
  - run against more than just `_main`
- [ ] benchmarking?
- [ ] scalar evolution?
- [ ] llvm backend?
- [ ] watch lectures for more ideas
### Linker
- [ ] remove clang dep

## Reading Materials
- https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms
- https://student.cs.uwaterloo.ca/~cs452/docs/ts7200/arm-architecture.pdf
