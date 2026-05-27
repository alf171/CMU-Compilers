#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct Allocation {
  void *ptr;
  struct Allocation *next;
} Allocation;

static Allocation *allocations = NULL;
static uint64_t alloc_count = 0;
static uint64_t free_count = 0;

void *arena_malloc(uint64_t bytes) {
  void* ptr = malloc(bytes);
  if (ptr == NULL) {
    abort();
  }

  Allocation *node = malloc(sizeof(Allocation));
  if (node == NULL) {
    abort();
  }
  node->ptr = ptr;
  node->next = allocations;

  allocations = node;
  alloc_count += 1;
  return ptr;
}

void arena_free(void) {
  Allocation *node = allocations;
  while (node != NULL) {
    Allocation *current = node;
    Allocation *next = current->next;
    free(node->ptr);
    free(node);
    node = next;
    free_count += 1;
  }
  allocations = NULL;
  if (alloc_count > 0) {
    printf("[!!memory report!!]: allocs=%llu frees=%llu\n",
        (unsigned long long)alloc_count,
        (unsigned long long)free_count);
  }
}
