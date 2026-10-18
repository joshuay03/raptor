#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

#define MAX_WORKERS 64
#define MAX_LISTENERS 16
#define UNAVAILABLE_LOAD 0xffffffff

// Per-worker listening sockets, keyed by listener index * MAX_WORKERS +
// worker index so each bound address has its own row of worker slots.
struct {
  __uint(type, BPF_MAP_TYPE_REUSEPORT_SOCKARRAY);
  __type(key, __u32);
  __type(value, __u64);
  __uint(max_entries, MAX_WORKERS * MAX_LISTENERS);
} socks SEC(".maps");

// Worker count at slot 0, per-worker backlog at slots 1..N.
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __type(key, __u32);
  __type(value, __u32);
  __uint(max_entries, MAX_WORKERS + 1);
} loads SEC(".maps");

// Account for routed connections before the worker reports its new backlog,
// so bursts do not keep selecting against stale load.
SEC("sk_reuseport")
int select_less_loaded(struct sk_reuseport_md *ctx) {
  __u32 count_key = 0;
  __u32 *count_ptr = bpf_map_lookup_elem(&loads, &count_key);
  if (!count_ptr || *count_ptr == 0) {
    return SK_DROP;
  }
  __u32 num_workers = *count_ptr;
  if (num_workers > MAX_WORKERS) {
    num_workers = MAX_WORKERS;
  }

  __u32 chosen_idx = ctx->hash % num_workers;
  __u32 chosen_key = chosen_idx + 1;
  __u32 *chosen_load = bpf_map_lookup_elem(&loads, &chosen_key);
  if (num_workers > 1) {
    __u32 alternate_idx = (chosen_idx + 1 + ((ctx->hash >> 16) % (num_workers - 1))) % num_workers;
    __u32 alternate_key = alternate_idx + 1;
    __u32 *alternate_load = bpf_map_lookup_elem(&loads, &alternate_key);
    if (chosen_load && alternate_load && *alternate_load < *chosen_load) {
      chosen_idx = alternate_idx;
      chosen_load = alternate_load;
    }
  }

  // Every bound address shares this program, and the kernel only accepts a
  // socket from the reuseport group the connection arrived on, so try the
  // chosen worker's socket for each address until one belongs to the group.
  for (__u32 listener = 0; listener < MAX_LISTENERS; listener++) {
    __u32 sock_key = listener * MAX_WORKERS + chosen_idx;
    if (bpf_sk_select_reuseport(ctx, &socks, &sock_key, 0) == 0) {
      if (chosen_load && *chosen_load != UNAVAILABLE_LOAD) {
        __sync_fetch_and_add(chosen_load, 1);
      }
      break;
    }
  }

  return SK_PASS;
}

char _license[] SEC("license") = "GPL";
