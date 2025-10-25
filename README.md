# Overview

- Going through CMU compilers course from online lectures
- The plan is to write the compiler in Zig
- I have went through crafting interpreters so somewhat familiar with compilers
- don't understand things more on the backend side of things
- takes notes on lectures and doing best effort to do labs/hws
- might be slightly challenging since won't be using one of main langs + project class
- Zig should be able to interface nicely with C/C++ though I'm hoping

## GOALS (order by passes)

first try at each one will trying to get code with python code with no branches working

- [ ] type checking?
- [ ] AST -> IR (non SSA) -> SSA IR (+ constant propogation)
- [x] Liveness Analysis -> Interference Graph -> Coalescing -> Coloring
- [ ] asm generation (decide which ISA to target - ARM?)

optimizations
- TBD

## Compilers Specs
- ir/coalescing
  - complexity O(nm) where n is nodes and m is their neighbors
  - look at size(nbor(n) U nbor(k)) < register count
