# Python Compiler Written in ZIG

The goal of this project is to learn more about compilers from a lower level. Previously implemented transpiler flavor of compiler.

## Run Commands

`zig build -Doptimize=Debug run -- tst/medium.l1.in`
  - this runs register generates an igraph, spills the graph, and does coalescing on the IR
  - does nothing with colored graph currently

`zig build codegen-run`
  - go from python code to AST
  - eventually, this will 

## Design Choices

TODO: fill out

## Goals

- [x] color ir graph
- [ ] Go from python AST to IR
- [ ] hook up AST and IR modules
- [ ] target a specific ISA
- [ ] add support for branching logic
- [ ] TBD
