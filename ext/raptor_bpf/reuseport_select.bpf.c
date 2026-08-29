#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

#define MAX_WORKERS 64

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

// Uses the power-of-two-choices strategy and reserves the selected worker's
// slot before returning. Sampling two hash-selected workers avoids
// concentrating variable-cost requests, while the reservation prevents a
// burst from repeatedly selecting the same reported load.
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

  if (chosen_load) {
    __sync_fetch_and_add(chosen_load, 1);
  }

  bpf_sk_select_reuseport(ctx, &socks, &chosen_idx, 0);
  return SK_PASS;
}

char _license[] SEC("license") = "GPL";
