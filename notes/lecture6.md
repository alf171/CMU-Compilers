# SSA pt.2

## dominance frontier
- first node we encounter on path from x which x does not strictly dominate
- example x -> ... -> y -> z
- z dominates y if there is path from x -> z which doesnt go through  y
- there are the exact nodes in which we need to place phi functions
- we will have a dominance frontier criterion
  - place phi functions in everything in dominance frontier of the control graph
  - this then trickles down
- use DF to compute minimal SSA
  - place all phi functions
  - rename all variables
- there are techniques to reduce # of phi functions
  - prune or semi-prune ssa
- steps
  - gather all defsites of every variable
```
for var in eachVariable:
  for each def sight:
    for each node in DF(defside):
      if we dont have phi place one
      if node didnt define the variable before, add this node to defsites
```
- essentially compute the iterated dominace frontier on the fly creating a minimal ssa

### renaming variables
- walk the dominance tree, rename variables as you go
- replace uses with msot recent renamed def
  - for straight-line code, this is easy
  - what if there are a bunch of joins?
- for straight line code
  - need to extend phi functions
  - need to maintain property that defines dominate uses
  - a -> a_i
```
def rename(n):
  renameBasicBlock(n)
  for ecah successor Y of n where n is the j_th predecssor Y
    i = top(Stack[a])
    replace jth operand with a_i
```

### flavors of SSA
- minimal SSA
  - at each join with >1 outstanding definition isert a phi function
  - some may be dead
- pruned SSA
  - only add live phi functions
  - must compute LIVEOUT
- semi-pruned SSA
  - same as minimal ssa but on maes live across more than 1 basic block
  - avoid computing liveness
  - will prob implement this

### why ssa
- ssa is a useful and efficient IR
- definitionss dominate uses
- constructing ssa can be efficient (no need to do lengaur-tarjan algorithm)
  - instead use a simple, fast dominace algorithm by cooper, harvey, and kennedy
- do not do any optimizations yet!
- eventually, we need to get out of ssa though and deconstruct all the phi functions
- two choices
- before register allocation
  - source program -- ssa conversion -> ssa-form program -- ssa elimination -> post ssa form program -- register allocation -> executable program
  - deconstructing ssa can introduce lots of copies which are easier to eliminate without register constraint
- after register allocation (prefered)
  - source program -- ssa conversion -> ssa program -- register allocation -> colored ssa form program -- ssa elimination -> executable program
  - enables decoupled register allocation
    - spill, color, coalesce
  - phi functions may have sources which are register and memory
  - complicated by code-motion optimizations

## deconstructing ssa
- assuming we have an exchange instruction, we can deconstruct instruction safe w.r.t to an optimizations + no extra registers
- we have since now create a "conventional ssa"
  - none of the arguments of a phi function interfer with eachother
  - ex) x <- (x_0, x_1, x_2) (thus make them red and coalesce)
- however, code motion can destroy this property!
- ex)
```ssa
x <- 1
loop:
  y <-  x
  x <- x + 1
z <- y + something
```

```out of ssa
x_0 <- 1
x_1 <- x_0
loop:
  x_1 <- phi(x_0, x_2)
  y_0 <- x_1
  x_2 <- x_1 + 1
z <- y_0 + something
```

- copy propogation
  - remove y_0 and replace with x_1

```
x_0 <- 1
x_1 <- x_0
loop:
  x_1 <- phi(x_0, x_2)
  x_2 <- x_1 + 1
z <- x_1 + something
```

- but oh no! x_1 and x_2 now interfer with eachother!

```out of ssa
x_0 <- 1
x_1 <- x_0
loop:
  y_0 <- x_1
  x_2 <- x_1 + 1
  x_1 <- x_2 # from the x_1 <- phi(x_0, x_2)
z <- y_0 + something
```
- x_1 is now getting overwritten by x_2
- problem: a critical edge (caused by lost copy problem)
  - a -> b if a > 1 successor, b > 1 predecsor
  - so, we need to eliminate critical edges

- in our loop, we are going to insert x_1 <- x_2 instead of just inside of loop itself
  - therefore, in path out of the loop, we dont take overwrite change
- this is useful for other optimizations too so will helpful to do as a general pass also not just for removing ssa
- there is an additional problem!
  - semantics of phi functions
  - requires copies to be done in parallel
```basic block
x_1 <- phi(x_0, y_1)
y_1 <- phi(y_0, x_1)
# becomes
x_1 <- y_1
y_1 <- x_1 (but this just got overwritten!)
# instead let's do!
(x_1, y_1) <- (y_1, x_1)
```
- we seem to need temporary variables and we removed temps during our copy propogation + phi functions
  - we did things sequentially instead of in concurrently
  - introduce a parallel copy!

## new pipeline!
- what happens when we spill a phi related variable?
- ex) r <- phi(r, m_0), m_1 <- phi(r, m_0)
  - note that memory to memory moves are not allowed!
- solution
  - critical edge splitting
  - convert back to conventional-ssa (CSSA)
  - register allocation
    - build interference graph
    - pre-spilling
    - coloring
  - deconstructing ssa
    - put parallel-copies in predecessors
    - eliminate parallel copies
  - coalescing
- notice typical order has changed
- convert to CSSA
  - goal is to ensure that all phi related variables do not interfere
  - insert copies to (possibly split live ranges)
  - B1, ..., Bn for each block j x'_j <- x_j
    - where each j block joins, x'_0 <- phi(x'_1, ..., x'_n)
    - we know that no one else will use x_{0, n} only primes are used
    - after all other phi functions, we do x_0 <- x'_0
    - x'_0 has live range for sure broken up unlike x_0 which we aren't sure about
    - x's from above are also a tiny live range
  - we have inserted tons of copies and coalescing will need to take of that

### register allocation on cssa
- build interference graph
- pre-spill to make it colorable
  - if spill a phi-related variable, make sure all from same phi function use same memory slot
  - why do we know this is okay?
  - cheat: if you spill one, spill them all
- color using SEO

### elimination of phi functions
- put parallel copies in predecssor blocks
- sequentialize the parallel copies
- vector operation
  - phi function: v_1 = phi(v_11, v_12, ..., v_1m)
  - parallel copy: (v_1, ..., v_n) := (v_11, ..., v_1m)
- well now question is, how do we turn parallel copies into seqential ones?
  - creates a transfer graph
  - the in-degree is at most 1 (one for each phi function)
  - if we spill correctly, out-degree of any node is at most 1
  - if node in graph is memory location
- spartan transfer graph
  - these graphs are either cycle or start then end
  - each connected component forms a cycle (then all nodes are register), or a path (1st may be memory store and/or last node may be memory load)
  - can be implemented as sequential code
    - cycles use register swapping
    - pathes use moves (mov, ld, st, as appropriate)

### reducing stores for spilling
- every path from LTG that ends in a memory will produce a store
- e.g. a -> r_1 -> r_2 ... r_x -> m will create st r_x -> m at the end
- but only needs to be done once e.g. at point of definition
- so eliminate store and change register allocator to insert store at definition point
  - similar elimination of loads possible
