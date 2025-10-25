## SSA

- static assignment is an IR where each variable has one def in the program
  - could be a loop which is executed dynamically many times
- phi functions to deal with this merging
- definition dominate uses
  - path from entry to use -> def is on that path
  - will never be after
- SSA makes optimizations faster and easier

consder this program
```
x <- ..
y <- ..
while (x < 100) {
  x <- x + 1
  y <- y + 1
}
```

becomes
```
x <- ..
y <- ..
if (x >= 100) goto end
loop:
  x <- x + 1
  y <- y + 1
  if (x < 100) goto loop
end:
```

- [x, y, if]
- -> [x -> x + 1, ...] -> [exit]
- -> [exit]

- a join point is where two or more basic blocks connect
- insert phi functions at each
  - x_1 <- phi(x_0, x_2), y_1 <- phi(y_0, y_2)
    - either from loop calling itself or first block
    - we do this for each join point!
  - then renumber variables for SSA purposes
- should we always put a phi function around things
  - minimal SSA can be used to prevent this but for now yes
- phi function
  - merges multiple def into a single one
  - predencesors are the args in phi
  - how we chose which to use? we dont really care
- trivial SSA
  - each assignment generates a fresh variable
  - each variable will get inserted into the live_out set
- minimal ssa
  - only need a variable in the phi parameters for terms with multiple defs
  - each assignment still generates its own variable
- constant propogation of SSA
  - i_1 <- 1 can replace usages with 1
  - x <- phi(1,1,1) can also replace with 1
  - alg
```
W <- list of all defs
while !W.isEmpty() {
  Stmt S <- W.removeOne()
  if S has form "v <- phi(c, ..., c)"
    replace S with V <- c
  if S has form "v <- c"
    delete S
    foreach stmt U that uses v,
      replace v with c in U
      W.add(U)
}
```

- in some sense, you need to do some sort of partial evaluation in order to optimization
  - instead of constant progation, we will do conditional constant propogation
    - assume blocks dont execute until prove otherwise
    - assume value are constant until proven otherwise
    - keep track of variables, blocks and whether they `might` be executed
    - proving if they will be is the halting problem though
  - keep track of variables with a lattice
    - keep track of min and max value, change range overtime
    - if we dont know value of a conditional and we changed understanding of block, we need to reevaluate BBs
- can use this knowledge we've gained to delete dead code
  - remove dead blocks essentially
  - can also remove variables and constants from within blocks
  - can also prove terms will terminate but this is a more complex optimization than conditional constant propogation (CCP)
- we need a ohi function wherever there are multiple outstanding definitions
  - loop aren't consider redefs. it needs to be the same def in different blocks propogated to other blocks which conflict
- dominance property of SSA
  - if the only way to get through a node is through another node or BB, then the node dominates the other
  - by def all defs dominants uses
  - a dom b if, for all paths to b, a is on that path
    - note nodes dominate themselves
  - dominators are useful in indentifying "natural loops"
    - pretty important for optimizations later
- a strickly dominates (sdom) b 
  - also that we are dealing with different nodes
- a immediate dominator (idom) b
  - no such c that a sdom c and c sdom b
  - esssentially no one in between them
- compute dominace with a dataflow equation
  - D[n] -- init with all blocks and then iterate until no changes to D[n]
    - chose some arbitrary order
  - D[n] = {n} U intersection[p \in pred(n) D[p]]
  - O(n^2e) assuming bit vector sets
  - more efficent algorithm due ot legauer and tarjan O(e * phi(e, n))
    - much more complicated though
- formulas for update rule, can thus use itself
  - sD[n] = D[n] - {n}
  - iD[n] = iD[n] - U_{d \in ID[n]}sD[d]
- dominance frontier
  - nodes that meet the path criteria
  - first node you get to from x which doesnt sdom
  - x dom y but not x sdom z (z is on dominance frontiner of x)
  - items themselves can be on the domaninence frontier too
