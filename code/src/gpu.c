#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

struct KernelArgs {
  void *out;
  uint64_t n;
};

static void check(hsa_status_t status, const char *operation) {
  if (status == HSA_STATUS_SUCCESS)
    return;

  const char *message = NULL;
  hsa_status_string(status, &message);

  fprintf(stderr, "%s failed: %s\n", operation, message != NULL ? message : "unknown hsa");
  abort();
}

static hsa_status_t find_gpu(hsa_agent_t agent, void *data) {
  hsa_device_type_t type;
  hsa_status_t status = hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &type);

  if (status != HSA_STATUS_SUCCESS)
    return status;

  if (type == HSA_DEVICE_TYPE_GPU)
    *(hsa_agent_t *)data = agent;

  return HSA_STATUS_SUCCESS;
}

static hsa_status_t find_kernarg_region(hsa_region_t region, void *data) {
  hsa_region_segment_t segment;

  hsa_status_t status = hsa_region_get_info(region, HSA_REGION_INFO_SEGMENT, &segment);
  if (status != HSA_STATUS_SUCCESS)
    return status;

  if (segment != HSA_REGION_SEGMENT_GLOBAL)
    return HSA_STATUS_SUCCESS;

  uint32_t flags = 0;
  status = hsa_region_get_info(region, HSA_REGION_INFO_GLOBAL_FLAGS, &flags);

  if (status == HSA_STATUS_SUCCESS && (flags & HSA_REGION_GLOBAL_FLAG_KERNARG)) {
    *(hsa_region_t *)data = region;
  }

  return status;
}

void gpu_launch(void *out, uint64_t n) {
  check(hsa_init(), "hsa_init");

  hsa_agent_t gpu = {0};
  check(hsa_iterate_agents(find_gpu, &gpu), "hsa_iterate_agents");

  if (gpu.handle == 0) {
    fprintf(stderr, "no hsa gpu agent found\n");
    abort();
  }

  char name[64] = {0};
  check(hsa_agent_get_info(gpu, HSA_AGENT_INFO_NAME, name), "hsa_agent_info(name)");
  hsa_profile_t profile;
  check(hsa_agent_get_info(gpu, HSA_AGENT_INFO_PROFILE, &profile), "hsa_agent_get_info(PROFILE)");
  fprintf(stderr, "HSA GPU found: %s; out=%p; work_items=%lu\n", name, out, n);
  int code_object_fd = open("/tmp/device.co", O_RDONLY);
  if (code_object_fd < 0) {
    perror("open /tmp/device.co");
    hsa_shut_down();
    abort();
  }

  hsa_code_object_reader_t reader;
  check(hsa_code_object_reader_create_from_file(code_object_fd, &reader), "hsa_code_object_reader_create_from_file");

  hsa_executable_t executable;
  check(hsa_executable_create_alt(profile, HSA_DEFAULT_FLOAT_ROUNDING_MODE_DEFAULT, NULL, &executable), "hsa_executable_create_alt");

  hsa_loaded_code_object_t loaded_code_obj;
  check(hsa_executable_load_agent_code_object(executable, gpu, reader, NULL, &loaded_code_obj), "hsa_executable_load_agent_code_object");
  check(hsa_executable_freeze(executable, NULL), "hsa_executable_freeze");

  hsa_executable_symbol_t kernel_symbol;
  check(hsa_executable_get_symbol_by_name(executable, "kernel.kd", &gpu, &kernel_symbol), "hsa_executable_get_symbol_by_name");

  uint64_t kernel_object = 0;
  check(hsa_executable_symbol_get_info(kernel_symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT, &kernel_object), "hsa_executable_symbol_get_info");

  fprintf(stderr, "Loaded kernel.kd: kernel object=0x%lx\n", kernel_object);

  // load queue
  uint32_t queue_max_size = 0;
  check(hsa_agent_get_info(gpu, HSA_AGENT_INFO_QUEUE_MAX_SIZE, &queue_max_size), "hsa_agent_get_info");
  hsa_queue_t *queue = NULL;
  check(hsa_queue_create(gpu, queue_max_size, HSA_QUEUE_TYPE_SINGLE, NULL, NULL, UINT32_MAX, UINT32_MAX, &queue), "hsa_queue_create");
  hsa_signal_t completion_signal;
  check(hsa_signal_create(1, 0, NULL, &completion_signal), "hsa_signal_create");

  fprintf(stderr, "Created queue: id=%ld size=%u signal=%lu\n", queue->id, queue->size, completion_signal.handle);

  // get kernel_args
  hsa_region_t kernel_region = {0};
  check(hsa_agent_iterate_regions(gpu, find_kernarg_region, &kernel_region), "hsa_agent_iterate_regions");

  if (kernel_region.handle == 0) {
    fprintf(stderr, "No kernarg region found\n");
    abort();
  }

  void *gpu_out = NULL;
  size_t out_size = (n + 1) * sizeof(uint64_t);
  check(hsa_amd_memory_lock(out, out_size, &gpu, 1, &gpu_out), "hsa_amd_memory_lock");

  struct KernelArgs *kernel_args = NULL;
  check(hsa_memory_allocate(kernel_region, sizeof(*kernel_args), (void **)&kernel_args), "hsa_memory_allocate");
  kernel_args->out = gpu_out;
  kernel_args->n = n;

  uint64_t packet_id = hsa_queue_add_write_index_relaxed(queue, 1);
  uint32_t packet_index = packet_id & (queue->size - 1);
  hsa_kernel_dispatch_packet_t *packet = &((hsa_kernel_dispatch_packet_t*)queue->base_address)[packet_index];
  memset(packet, 0, sizeof(*packet));
  packet->setup = 1 << HSA_KERNEL_DISPATCH_PACKET_SETUP_DIMENSIONS;
  packet->workgroup_size_x = n;
  packet->workgroup_size_y = 1;
  packet->workgroup_size_z = 1;

  packet->grid_size_x = n;
  packet->grid_size_y = 1;
  packet->grid_size_z = 1;

  packet->private_segment_size = 0;
  packet->group_segment_size = 0;

  packet->kernel_object = kernel_object;
  packet->kernarg_address = kernel_args;
  packet->completion_signal = completion_signal;

  uint16_t header =
      (HSA_PACKET_TYPE_KERNEL_DISPATCH
          << HSA_PACKET_HEADER_TYPE) |
      (HSA_FENCE_SCOPE_SYSTEM
          << HSA_PACKET_HEADER_ACQUIRE_FENCE_SCOPE) |
      (HSA_FENCE_SCOPE_SYSTEM
          << HSA_PACKET_HEADER_RELEASE_FENCE_SCOPE);

  __atomic_store_n(
      &packet->header,
      header,
      __ATOMIC_RELEASE);

  hsa_signal_store_screlease(
      queue->doorbell_signal,
      packet_id);
   hsa_signal_value_t completion =
       hsa_signal_wait_scacquire(
           completion_signal,
           HSA_SIGNAL_CONDITION_LT,
           1,
           UINT64_MAX,
           HSA_WAIT_STATE_BLOCKED);
  
  check(hsa_amd_memory_unlock(out), "hsa_amd_memory_unlock(out)");

   fprintf(
       stderr,
       "Kernel completed: signal=%ld\n",
       completion);

  check(hsa_memory_free(kernel_args), "hsa_memory_free(kernel_args)");

  check(hsa_signal_destroy(completion_signal), "hsa_signal_destroy");
  check(hsa_queue_destroy(queue), "hsa_queue_destroy");

  check(hsa_executable_destroy(executable), "hsa_executable_destroy");
  check(hsa_code_object_reader_destroy(reader), "hsa_code_object_reader_destroy");
  close(code_object_fd);

  check(hsa_shut_down(), "hsa_shut_down");
}
