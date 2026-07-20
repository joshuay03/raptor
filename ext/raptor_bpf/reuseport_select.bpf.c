#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

#define MAX_WORKERS 64
#define LOAD_TIE_TOLERANCE 1

// Per-worker listening sockets, keyed by worker index.
struct {
  __uint(type, BPF_MAP_TYPE_REUSEPORT_SOCKARRAY);
  __type(key, __u32);
  __type(value, __u64);
  __uint(max_entries, MAX_WORKERS);
} socks SEC(".maps");

// Worker count at slot 0, per-worker backlog at slots 1..N.
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __type(key, __u32);
  __type(value, __u32);
  __uint(max_entries, MAX_WORKERS + 1);
} loads SEC(".maps");

// Routes each incoming connection to the least-loaded worker. When the
// spread between the busiest and idlest worker is within
// `LOAD_TIE_TOLERANCE`, all workers are treated as tied and the connection
// is placed by 4-tuple hash so bursts of accepts spread across workers
// instead of clustering on whichever worker most recently reported the
// lowest load.
SEC("sk_reuseport")
int select_least_loaded(struct sk_reuseport_md *ctx) {
  __u32 count_key = 0;
  __u32 *count_ptr = bpf_map_lookup_elem(&loads, &count_key);
  if (!count_ptr || *count_ptr == 0) {
    return SK_DROP;
  }
  __u32 num_workers = *count_ptr;
  if (num_workers > MAX_WORKERS) {
    num_workers = MAX_WORKERS;
  }

  __u32 min_load = ~0u;
  __u32 max_load = 0;
  __u32 min_idx = 0;

  for (__u32 worker_idx = 0; worker_idx < MAX_WORKERS; worker_idx++) {
    if (worker_idx >= num_workers) {
      break;
    }
    __u32 worker_key = worker_idx + 1;
    __u32 *load_ptr = bpf_map_lookup_elem(&loads, &worker_key);
    if (!load_ptr) {
      continue;
    }
    if (*load_ptr < min_load) {
      min_load = *load_ptr;
      min_idx = worker_idx;
    }
    if (*load_ptr > max_load) {
      max_load = *load_ptr;
    }
  }

  __u32 chosen_idx = (max_load - min_load <= LOAD_TIE_TOLERANCE) ? (ctx->hash % num_workers) : min_idx;
  bpf_sk_select_reuseport(ctx, &socks, &chosen_idx, 0);
  return SK_PASS;
}

char _license[] SEC("license") = "GPL";
