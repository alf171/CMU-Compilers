# Personal Notes on Lab1

- Will be reusing and rewriting code so design is important
- Start with a a compiler for small lang called L1
- Provided compiler targets a simple abstract assmevly lang
  - inf number of registers and instruction set for arithmetic ops
- task to extend this compiler to translate L1 source into x86
- main changes will be
  - modify instruction selector
  - dealing with finite number of registers
  - must be possible to assemble and link the target programs using gcc
- recommend implementing register allocation for entire lab1 (not just checkpoint)
- make sure you deeply understand instruction selection and register alloc
- getting use to libraries available for your programming lang
  - might depend on parser combinator library a LL(1) parser generator
- prepare to read through intel developer manuals for preciser behavior
  - plus GNU assembler docemenation for syntax to use
- reading x86 compilers like gcc is allowed and encouraged
  - helpful if manual is unclear
- L0 syntax is in straight line PDF
- variables can't be redeclared (easier for SSA i think)
- require every control flow path end with a return stmt (unless void)
- assignment table
  - x += e === x = x + e
  - -, *, /, %, etc
- ints are two's complemenet
  - no overflow exceptions
  - some more stuff here
- hand in compiler for L1
  - also copmiler/labl/README explaining design choices
  - include general layout of src code
  - if any public libraries are used
- test files should have extension .l1
- tests in dir tests...

"Your compiler is also expected to recognize a flag -t which, when present on the command line, stops the compiler immediately after typechecking and before the rest of the compiler runs"

- if compiler given a function main which contains _c0_main and then prints return
  - on mac, __co_main
  - %eax register contains the return value
  - c0_main must preverse all calllee-saved registers
- will need make use of platform detection mechanic if want to use mac

## Design Choices

- writing down design choices for later reference
- don't have access to starter code for this lab so will read: https://github.com/lichenk/compiler
- will use this as a base for ZIG code

## Goals

- [ ] I/O stub: read file, split //target, parse JSON into []Line.

- [ ] Collect temps + numbering.

- [ ] Interference graph from (def temp) vs live_out.

- [ ] Coloring (k-aware, no spills).

- [ ] Map to registers & emit JSON aligned to lines.

- [ ] Self tests on tiny handcrafted cases.

- [ ] Run verifier on a folder.
