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

## Design Choices
- leverage python subset of python syntax
- modular
- compiled not interpreted

## Goals
[ ] Copy propagation
- Basic-block-local first.
- Rewrite uses through simple move lines.
- Do not delete moves yet.
[ ] Dead move elimination
- After liveness works, remove moves whose destination is unused.
[ ] Then loop phis
- Add assigned-local prepass.
- Create header phis for loop-carried locals.
- Patch backedge phi input after walking body.
[ ] Constant propagation
- Easier after copy propagation because fewer temp aliases exist.

## Reading Materials
- https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms
- https://student.cs.uwaterloo.ca/~cs452/docs/ts7200/arm-architecture.pdf
