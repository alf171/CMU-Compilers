# Overview

- Going through CMU compilers course from online lectures
- The plan is to write the compiler in Zig
- I have went through crafting interpreters so somewhat familiar with compilers
- don't understand things more on the backend side of things
- takes notes on lectures and doing best effort to do labs/hws
- might be slightly challenging since won't be using one of main langs + project class
- Zig should be able to interface nicely with C/C++ though I'm hoping

## Interesting Ideas Worth Exploring

- [ ] python for loop syntax(s)
- [ ] advanced loop optimization(s): https://en.wikipedia.org/wiki/Polytope_model 
- [ ] type checking

## Compilers Specs
- using phi functions. [interesting articles](https://mlir.llvm.org/docs/Rationale/Rationale/#block-arguments-vs-phi-nodes)
- ir/coalescing
  - complexity O(nm) where n is nodes and m is their neighbors
  - look at size(nbor(n) U nbor(k)) < register count
