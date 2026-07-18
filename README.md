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
- [ ] advanced loop optimization(s): https://en.wikipedia.org/wiki/polytope_model 
- [ ] type checking

## Compilers Specs
- ir/coalescing
  - complexity O(nm) where n is nodes and m is their neighbors
  - look at size(nbor(n) U nbor(k)) < register count
- tuples are fixed size regardless of type `list[int, str, bool]`

## Reading Materials
- [phi function vs block args](https://mlir.llvm.org/docs/Rationale/Rationale/#block-arguments-vs-phi-nodes)
- [phi vs select](https://stackoverflow.com/questions/63048341/what-is-the-difference-between-select-and-phi-in-llvm-ir)
- [x86 abi](http://man6.org/lib/pdfjs/web/viewer.html?file=/blog/PdfFile/x86-64-psABI-1.0.pdf)
- [rdna3 abi](https://gpuopen.com/news/rdna3-isa-guide-now-available/)
