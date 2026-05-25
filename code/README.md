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
- [ ] [critical edge splitting](https://nickdesaulniers.github.io/blog/2023/01/27/critical-edge-splitting/)
- [ ] rewrite print to be generic depending on datatype
  - controlled by the type system
  - could even be part of std lib instead of asm instruction
  - ac: call python `print` (obfuscates `print_str`, `print_int`...)
- [0.5] support lists?
  - support variable size arrays on the heap
- [ ] parallel copy needed according to `lecture 6` in `phi.zig`
- [ ] sub, mul, div, unary ops like neg
- [ ] and + or support?
- [0.5] for loops (python has two different ways!)
- [ ] make current optimization cross block + less hacky
- [ ] benchmarking?
- [ ] scalar evolution?
- [ ] llvm backend?
- [ ] watch lectures for more ideas

## Reading Materials
- https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms
- https://student.cs.uwaterloo.ca/~cs452/docs/ts7200/arm-architecture.pdf
