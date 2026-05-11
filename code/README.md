# Python Compiler Written in ZIG

The goal of this project is to learn more about compilers from a lower level. Previously implemented transpiler flavor of compiler.

## Run Commands

`zig build -Doptimize=Debug run -- tst/medium.l1.in`
- this runs register generates an igraph, spills the graph, and does coalescing on the IR
- does nothing with colored graph currently

`zig build frontend-run`
- go from python code to AST
- eventually, this will 

`zig build integration-test && clang /tmp/out.s -o /tmp/out && /tmp/out`
- super hacky running entire pipeline

## Design Choices
- leverage python subset of python syntax
- modular
- compiled not interpreted

## Goals
- [x] color ir graph
- [x] Go from python AST to IR
- [x] hook up AST and IR modules
- [x] target a specific ISA
- [ ] add support for branching logic
- [ ] TBD
