# Overview

Goal of this project is to create a python like language which can write gpu/ai accelerator kernels without the hassle of things like cuda.

This is a project to learn more about the implementations of a compilers, linkers, hardware, and more!

## Design Choices
- leverage python
  - subset of its syntax
- modular
- compiled not interpreted
- function types are enforced

## Compilers Specs
- TODO

## Reading Materials
- user scheduling lanuage
  - [exo1](https://dl.acm.org/doi/epdf/10.1145/3519939.3523446)
  - [exo2](https://arxiv.org/pdf/2411.07211)
- hardware
  - [gemmini](https://arxiv.org/pdf/1911.09925)
- compilers
  - [phi function vs block args](https://mlir.llvm.org/docs/Rationale/Rationale/#block-arguments-vs-phi-nodes)
  - [phi vs select](https://stackoverflow.com/questions/63048341/what-is-the-difference-between-select-and-phi-in-llvm-ir)
  - [garbage collection](https://www.microsoft.com/en-us/research/wp-content/uploads/2020/11/perceus-tr-v1.pdf)
