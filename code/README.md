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
- [x] Structured phi insertion in walkIf
- [x] Phi elimination: lower phi nodes into predecessor moves
- [x] CFG-aware liveness
### liveness thinks this code
```python
L1
if (cond):
  L2
else:
  L3
L4
```
### current liveness treats basic blocks like
```
L1
L2
L3
L4
```
### should treat like this
```
  L1
 /  \
L2  L3
 \  /
  L4
```
- [ ] Structured phi insertion for while
- [ ] Constant propagation
- [ ] Copy propagation
- [ ] Build real SSA construction pass with dominators/frontiers

## Reading Materials
- https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms
- https://student.cs.uwaterloo.ca/~cs452/docs/ts7200/arm-architecture.pdf
