#include "ruby.h"
#include <string.h>
#include <stdint.h>

#define HTTP2_FRAME_HEADER_SIZE 9
#define HTTP2_DEFAULT_HEADER_TABLE_SIZE 4096
#define HTTP2_ENTRY_OVERHEAD 32
#define HTTP2_CONNECTION_PREFACE "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
#define HTTP2_CONNECTION_PREFACE_LEN 24

#define FRAME_DATA          0x0
#define FRAME_HEADERS       0x1
#define FRAME_PRIORITY      0x2
#define FRAME_RST_STREAM    0x3
#define FRAME_SETTINGS      0x4
#define FRAME_PUSH_PROMISE  0x5
#define FRAME_PING          0x6
#define FRAME_GOAWAY        0x7
#define FRAME_WINDOW_UPDATE 0x8
#define FRAME_CONTINUATION  0x9

#define FLAG_END_STREAM  0x1
#define FLAG_END_HEADERS 0x4
#define FLAG_PADDED      0x8
#define FLAG_PRIORITY    0x20
#define FLAG_ACK         0x1

#define SETTINGS_HEADER_TABLE_SIZE      0x1
#define SETTINGS_ENABLE_PUSH            0x2
#define SETTINGS_MAX_CONCURRENT_STREAMS 0x3
#define SETTINGS_INITIAL_WINDOW_SIZE    0x4
#define SETTINGS_MAX_FRAME_SIZE         0x5
#define SETTINGS_MAX_HEADER_LIST_SIZE   0x6

#define STATIC_TABLE_SIZE 61

#define HUFFMAN_ACCEPTED   1
#define HUFFMAN_SYM        (1 << 1)
#define HUFFMAN_FAIL_STATE 0x100

static VALUE cHttp2Parser;
static VALUE eHttp2ParserError;

typedef struct {
  const char *name;
  const char *value;
} hpack_static_entry;

static const hpack_static_entry STATIC_TABLE[] = {
  {NULL, NULL},
  {":authority", ""},
  {":method", "GET"},
  {":method", "POST"},
  {":path", "/"},
  {":path", "/index.html"},
  {":scheme", "http"},
  {":scheme", "https"},
  {":status", "200"},
  {":status", "204"},
  {":status", "206"},
  {":status", "304"},
  {":status", "400"},
  {":status", "404"},
  {":status", "500"},
  {"accept-charset", ""},
  {"accept-encoding", "gzip, deflate"},
  {"accept-language", ""},
  {"accept-ranges", ""},
  {"accept", ""},
  {"access-control-allow-origin", ""},
  {"age", ""},
  {"allow", ""},
  {"authorization", ""},
  {"cache-control", ""},
  {"content-disposition", ""},
  {"content-encoding", ""},
  {"content-language", ""},
  {"content-length", ""},
  {"content-location", ""},
  {"content-range", ""},
  {"content-type", ""},
  {"cookie", ""},
  {"date", ""},
  {"etag", ""},
  {"expect", ""},
  {"expires", ""},
  {"from", ""},
  {"host", ""},
  {"if-match", ""},
  {"if-modified-since", ""},
  {"if-none-match", ""},
  {"if-range", ""},
  {"if-unmodified-since", ""},
  {"last-modified", ""},
  {"link", ""},
  {"location", ""},
  {"max-forwards", ""},
  {"proxy-authenticate", ""},
  {"proxy-authorization", ""},
  {"range", ""},
  {"referer", ""},
  {"refresh", ""},
  {"retry-after", ""},
  {"server", ""},
  {"set-cookie", ""},
  {"strict-transport-security", ""},
  {"transfer-encoding", ""},
  {"user-agent", ""},
  {"vary", ""},
  {"via", ""},
  {"www-authenticate", ""}
};

typedef struct {
  uint32_t code;
  uint8_t  bits;
} huffman_entry;

static const huffman_entry HUFFMAN_TABLE[257] = {
  {0x1ff8,     13}, {0x7fffd8,   23}, {0xfffffe2,  28}, {0xfffffe3,  28},
  {0xfffffe4,  28}, {0xfffffe5,  28}, {0xfffffe6,  28}, {0xfffffe7,  28},
  {0xfffffe8,  28}, {0xffffea,   24}, {0x3ffffffc, 30}, {0xfffffe9,  28},
  {0xfffffea,  28}, {0x3ffffffd, 30}, {0xfffffeb,  28}, {0xfffffec,  28},
  {0xfffffed,  28}, {0xfffffee,  28}, {0xfffffef,  28}, {0xffffff0,  28},
  {0xffffff1,  28}, {0xffffff2,  28}, {0x3ffffffe, 30}, {0xffffff3,  28},
  {0xffffff4,  28}, {0xffffff5,  28}, {0xffffff6,  28}, {0xffffff7,  28},
  {0xffffff8,  28}, {0xffffff9,  28}, {0xffffffa,  28}, {0xffffffb,  28},
  {0x14,        6}, {0x3f8,      10}, {0x3f9,      10}, {0xffa,      12},
  {0x1ff9,     13}, {0x15,        6}, {0xf8,        8}, {0x7fa,      11},
  {0x3fa,      10}, {0x3fb,      10}, {0xf9,        8}, {0x7fb,      11},
  {0xfa,        8}, {0x16,        6}, {0x17,        6}, {0x18,        6},
  {0x0,         5}, {0x1,         5}, {0x2,         5}, {0x19,        6},
  {0x1a,        6}, {0x1b,        6}, {0x1c,        6}, {0x1d,        6},
  {0x1e,        6}, {0x1f,        6}, {0x5c,        7}, {0xfb,        8},
  {0x7ffc,     15}, {0x20,        6}, {0xffb,      12}, {0x3fc,      10},
  {0x1ffa,     13}, {0x21,        6}, {0x5d,        7}, {0x5e,        7},
  {0x5f,        7}, {0x60,        7}, {0x61,        7}, {0x62,        7},
  {0x63,        7}, {0x64,        7}, {0x65,        7}, {0x66,        7},
  {0x67,        7}, {0x68,        7}, {0x69,        7}, {0x6a,        7},
  {0x6b,        7}, {0x6c,        7}, {0x6d,        7}, {0x6e,        7},
  {0x6f,        7}, {0x70,        7}, {0x71,        7}, {0x72,        7},
  {0xfc,        8}, {0x73,        7}, {0xfd,        8}, {0x1ffb,     13},
  {0x7fff0,    19}, {0x1ffc,     13}, {0x3ffc,     14}, {0x22,        6},
  {0x7ffd,     15}, {0x3,         5}, {0x23,        6}, {0x4,         5},
  {0x24,        6}, {0x5,         5}, {0x25,        6}, {0x26,        6},
  {0x27,        6}, {0x6,         5}, {0x74,        7}, {0x75,        7},
  {0x28,        6}, {0x29,        6}, {0x2a,        6}, {0x7,         5},
  {0x2b,        6}, {0x76,        7}, {0x2c,        6}, {0x8,         5},
  {0x9,         5}, {0x2d,        6}, {0x77,        7}, {0x78,        7},
  {0x79,        7}, {0x7a,        7}, {0x7b,        7}, {0x7fffe,    19},
  {0x7fc,      11}, {0x3ffd,     14}, {0x1ffd,     13}, {0xffffffc,  28},
  {0xfffe6,    20}, {0x3fffd2,   22}, {0xfffe7,    20}, {0xfffe8,    20},
  {0x3fffd3,   22}, {0x3fffd4,   22}, {0x3fffd5,   22}, {0x7fffd9,   23},
  {0x3fffd6,   22}, {0x7fffda,   23}, {0x7fffdb,   23}, {0x7fffdc,   23},
  {0x7fffdd,   23}, {0x7fffde,   23}, {0xffffeb,   24}, {0x7fffdf,   23},
  {0xffffec,   24}, {0xffffed,   24}, {0x3fffd7,   22}, {0x7fffe0,   23},
  {0xffffee,   24}, {0x7fffe1,   23}, {0x7fffe2,   23}, {0x7fffe3,   23},
  {0x7fffe4,   23}, {0x1fffdc,   21}, {0x3fffd8,   22}, {0x7fffe5,   23},
  {0x3fffd9,   22}, {0x7fffe6,   23}, {0x7fffe7,   23}, {0xffffef,   24},
  {0x3fffda,   22}, {0x1fffdd,   21}, {0xfffe9,    20}, {0x3fffdb,   22},
  {0x3fffdc,   22}, {0x7fffe8,   23}, {0x7fffe9,   23}, {0x1fffde,   21},
  {0x7fffea,   23}, {0x3fffdd,   22}, {0x3fffde,   22}, {0xfffff0,   24},
  {0x1fffdf,   21}, {0x3fffdf,   22}, {0x7fffeb,   23}, {0x7fffec,   23},
  {0x1fffe0,   21}, {0x1fffe1,   21}, {0x3fffe0,   22}, {0x1fffe2,   21},
  {0x7fffed,   23}, {0x3fffe1,   22}, {0x7fffee,   23}, {0x7fffef,   23},
  {0xfffea,    20}, {0x3fffe2,   22}, {0x3fffe3,   22}, {0x3fffe4,   22},
  {0x7ffff0,   23}, {0x3fffe5,   22}, {0x3fffe6,   22}, {0x7ffff1,   23},
  {0x3ffffe0,  26}, {0x3ffffe1,  26}, {0xfffeb,    20}, {0x7fff1,    19},
  {0x3fffe7,   22}, {0x7ffff2,   23}, {0x3fffe8,   22}, {0x1ffffec,  25},
  {0x3ffffe2,  26}, {0x3ffffe3,  26}, {0x3ffffe4,  26}, {0x7ffffde,  27},
  {0x7ffffdf,  27}, {0x3ffffe5,  26}, {0xfffff1,   24}, {0x1ffffed,  25},
  {0x7fff2,    19}, {0x1fffe3,   21}, {0x3ffffe6,  26}, {0x7ffffe0,  27},
  {0x7ffffe1,  27}, {0x3ffffe7,  26}, {0x7ffffe2,  27}, {0xfffff2,   24},
  {0x1fffe4,   21}, {0x1fffe5,   21}, {0x3ffffe8,  26}, {0x3ffffe9,  26},
  {0xffffffd,  28}, {0x7ffffe3,  27}, {0x7ffffe4,  27}, {0x7ffffe5,  27},
  {0xfffec,    20}, {0xfffff3,   24}, {0xfffed,    20}, {0x1fffe6,   21},
  {0x3fffe9,   22}, {0x1fffe7,   21}, {0x1fffe8,   21}, {0x7ffff3,   23},
  {0x3fffea,   22}, {0x3fffeb,   22}, {0x1ffffee,  25}, {0x1ffffef,  25},
  {0xfffff4,   24}, {0xfffff5,   24}, {0x3ffffea,  26}, {0x7ffff4,   23},
  {0x3ffffeb,  26}, {0x7ffffe6,  27}, {0x3ffffec,  26}, {0x3ffffed,  26},
  {0x7ffffe7,  27}, {0x7ffffe8,  27}, {0x7ffffe9,  27}, {0x7ffffea,  27},
  {0x7ffffeb,  27}, {0xffffffe,  28}, {0x7ffffec,  27}, {0x7ffffed,  27},
  {0x7ffffee,  27}, {0x7ffffef,  27}, {0x7fffff0,  27}, {0x3ffffee,  26},
  {0x3fffffff, 30}
};

typedef struct {
  uint16_t state;
  uint8_t  flags;
  uint8_t  symbol;
} huffman_decode_entry;

#include "huffman_table.h"

typedef struct {
  uint32_t length;
  uint8_t  type;
  uint8_t  flags;
  uint32_t stream_id;
} frame_header;

typedef struct {
  long max_table_size;
} raptor_h2_parser;

static int hpack_decode_int(const uint8_t *buf, size_t len, size_t *pos, uint8_t prefix_bits, uint64_t *result) {
  if (*pos >= len) return -1;

  uint8_t prefix_mask = (1 << prefix_bits) - 1;
  *result = buf[*pos] & prefix_mask;
  (*pos)++;

  if (*result < prefix_mask) return 0;

  uint64_t m = 0;
  do {
    if (*pos >= len) return -1;

    uint8_t byte = buf[*pos];
    (*pos)++;
    *result += (uint64_t)(byte & 0x7f) << m;
    m += 7;

    if (m > 63) return -1;
    if (!(byte & 0x80)) return 0;
  } while (1);
}

static size_t hpack_encode_int(uint8_t *buf, uint64_t value, uint8_t prefix_bits, uint8_t prefix_byte) {
  uint8_t prefix_mask = (1 << prefix_bits) - 1;
  size_t pos = 0;

  if (value < prefix_mask) {
    buf[pos++] = prefix_byte | (uint8_t)value;
    return pos;
  }

  buf[pos++] = prefix_byte | prefix_mask;
  value -= prefix_mask;

  while (value >= 128) {
    buf[pos++] = (uint8_t)(value & 0x7f) | 0x80;
    value >>= 7;
  }
  buf[pos++] = (uint8_t)value;
  return pos;
}

static int hpack_decode_huffman(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap, size_t *dst_len) {
  uint16_t state = 0;
  int accepted = 1;
  *dst_len = 0;

  for (size_t i = 0; i < src_len; i++) {
    uint8_t byte = src[i];
    const huffman_decode_entry *entry;

    entry = &huffman_decode_table[state][byte >> 4];
    if (entry->state == HUFFMAN_FAIL_STATE) return -1;
    if (entry->flags & HUFFMAN_SYM) {
      if (*dst_len >= dst_cap) return -1;
      dst[(*dst_len)++] = entry->symbol;
    }
    state = entry->state;

    entry = &huffman_decode_table[state][byte & 0x0f];
    if (entry->state == HUFFMAN_FAIL_STATE) return -1;
    if (entry->flags & HUFFMAN_SYM) {
      if (*dst_len >= dst_cap) return -1;
      dst[(*dst_len)++] = entry->symbol;
    }
    state = entry->state;
    accepted = (entry->flags & HUFFMAN_ACCEPTED) != 0;
  }

  return accepted ? 0 : -1;
}

static int hpack_decode_string(const uint8_t *buf, size_t len, size_t *pos, VALUE *out_str) {
  if (*pos >= len) return -1;

  int huffman = (buf[*pos] & 0x80) != 0;
  uint64_t str_len;
  if (hpack_decode_int(buf, len, pos, 7, &str_len) < 0) return -1;
  if (*pos + str_len > len) return -1;

  if (huffman) {
    size_t decoded_cap = str_len * 2 + 256;
    uint8_t *decoded = ALLOCA_N(uint8_t, decoded_cap);
    size_t decoded_len;

    if (hpack_decode_huffman(buf + *pos, (size_t)str_len, decoded, decoded_cap, &decoded_len) < 0) {
      rb_raise(rb_eRuntimeError, "HPACK Huffman decode error");
      return -1;
    }

    *out_str = rb_str_new((const char *)decoded, decoded_len);
  } else {
    *out_str = rb_str_new((const char *)(buf + *pos), (long)str_len);
  }

  *pos += (size_t)str_len;
  return 0;
}

static size_t hpack_huffman_encode_len(const uint8_t *src, size_t src_len) {
  size_t bits = 0;
  for (size_t i = 0; i < src_len; i++)
    bits += HUFFMAN_TABLE[src[i]].bits;
  return (bits + 7) / 8;
}

static size_t hpack_huffman_encode(const uint8_t *src, size_t src_len, uint8_t *dst) {
  size_t pos = 0;
  uint64_t current = 0;
  int remaining = 0;

  for (size_t i = 0; i < src_len; i++) {
    uint32_t code = HUFFMAN_TABLE[src[i]].code;
    uint8_t  bits = HUFFMAN_TABLE[src[i]].bits;

    current = (current << bits) | code;
    remaining += bits;

    while (remaining >= 8) {
      remaining -= 8;
      dst[pos++] = (uint8_t)(current >> remaining);
    }
  }

  if (remaining > 0) {
    current = (current << (8 - remaining)) | ((1 << (8 - remaining)) - 1);
    dst[pos++] = (uint8_t)current;
  }

  return pos;
}

static VALUE dynamic_table_lookup(VALUE dyn_table, long index, VALUE *name, VALUE *value) {
  if (index < 1) return Qfalse;

  if (index <= STATIC_TABLE_SIZE) {
    *name  = rb_str_new_cstr(STATIC_TABLE[index].name);
    *value = rb_str_new_cstr(STATIC_TABLE[index].value);
    return Qtrue;
  }

  long dyn_index = index - STATIC_TABLE_SIZE - 1;
  if (dyn_index >= RARRAY_LEN(dyn_table)) return Qfalse;

  VALUE entry = rb_ary_entry(dyn_table, dyn_index);
  *name  = rb_ary_entry(entry, 0);
  *value = rb_ary_entry(entry, 1);
  return Qtrue;
}

static VALUE dynamic_table_add(VALUE dyn_table, VALUE name, VALUE value, long max_size) {
  long entry_size = RSTRING_LEN(name) + RSTRING_LEN(value) + HTTP2_ENTRY_OVERHEAD;

  VALUE new_table = rb_ary_new();
  VALUE new_entry = rb_ary_new_from_args(2, rb_str_freeze(rb_str_dup(name)), rb_str_freeze(rb_str_dup(value)));
  rb_ary_push(new_table, rb_ary_freeze(new_entry));

  long current_size = entry_size;
  for (long i = 0; i < RARRAY_LEN(dyn_table); i++) {
    VALUE existing = rb_ary_entry(dyn_table, i);
    VALUE ename = rb_ary_entry(existing, 0);
    VALUE evalue = rb_ary_entry(existing, 1);
    long esize = RSTRING_LEN(ename) + RSTRING_LEN(evalue) + HTTP2_ENTRY_OVERHEAD;

    if (current_size + esize > max_size) break;

    rb_ary_push(new_table, existing);
    current_size += esize;
  }

  return new_table;
}

static VALUE dynamic_table_evict(VALUE dyn_table, long max_size) {
  long current_size = 0;
  long keep = 0;

  for (long i = 0; i < RARRAY_LEN(dyn_table); i++) {
    VALUE entry = rb_ary_entry(dyn_table, i);
    VALUE name = rb_ary_entry(entry, 0);
    VALUE value = rb_ary_entry(entry, 1);
    long esize = RSTRING_LEN(name) + RSTRING_LEN(value) + HTTP2_ENTRY_OVERHEAD;

    if (current_size + esize > max_size) break;

    current_size += esize;
    keep++;
  }

  if (keep == RARRAY_LEN(dyn_table)) return dyn_table;

  VALUE new_table = rb_ary_new_capa(keep);
  for (long i = 0; i < keep; i++)
    rb_ary_push(new_table, rb_ary_entry(dyn_table, i));
  return new_table;
}

static int hpack_decode_header_block(const uint8_t *buf, size_t len,
                                     VALUE headers_out, VALUE *dyn_table,
                                     long *max_table_size) {
  size_t pos = 0;

  while (pos < len) {
    uint8_t byte = buf[pos];

    if (byte & 0x80) {
      /* indexed (RFC 7541 6.1) */
      uint64_t index;
      if (hpack_decode_int(buf, len, &pos, 7, &index) < 0) return -1;
      if (index == 0) return -1;

      VALUE name, value;
      if (!RTEST(dynamic_table_lookup(*dyn_table, (long)index, &name, &value))) return -1;

      rb_ary_push(headers_out, rb_ary_new_from_args(2, name, value));

    } else if ((byte & 0xc0) == 0x40) {
      /* literal with incremental indexing (RFC 7541 6.2.1) */
      uint64_t index;
      if (hpack_decode_int(buf, len, &pos, 6, &index) < 0) return -1;

      VALUE name, value;
      if (index > 0) {
        VALUE dummy;
        if (!RTEST(dynamic_table_lookup(*dyn_table, (long)index, &name, &dummy))) return -1;
      } else {
        if (hpack_decode_string(buf, len, &pos, &name) < 0) return -1;
      }
      if (hpack_decode_string(buf, len, &pos, &value) < 0) return -1;

      rb_ary_push(headers_out, rb_ary_new_from_args(2, name, value));
      *dyn_table = dynamic_table_add(*dyn_table, name, value, *max_table_size);

    } else if ((byte & 0xf0) == 0x00 || (byte & 0xf0) == 0x10) {
      /* literal without indexing / never indexed (RFC 7541 6.2.2, 6.2.3) */
      uint64_t index;
      if (hpack_decode_int(buf, len, &pos, 4, &index) < 0) return -1;

      VALUE name, value;
      if (index > 0) {
        VALUE dummy;
        if (!RTEST(dynamic_table_lookup(*dyn_table, (long)index, &name, &dummy))) return -1;
      } else {
        if (hpack_decode_string(buf, len, &pos, &name) < 0) return -1;
      }
      if (hpack_decode_string(buf, len, &pos, &value) < 0) return -1;

      rb_ary_push(headers_out, rb_ary_new_from_args(2, name, value));

    } else if ((byte & 0xe0) == 0x20) {
      /* dynamic table size update (RFC 7541 6.3) */
      uint64_t new_size;
      if (hpack_decode_int(buf, len, &pos, 5, &new_size) < 0) return -1;
      *max_table_size = (long)new_size;
      *dyn_table = dynamic_table_evict(*dyn_table, *max_table_size);

    } else {
      return -1;
    }
  }

  return 0;
}

static VALUE hpack_encode_header_block(VALUE headers) {
  VALUE buf = rb_str_buf_new(256);

  for (long i = 0; i < RARRAY_LEN(headers); i++) {
    VALUE pair = rb_ary_entry(headers, i);
    VALUE name = rb_ary_entry(pair, 0);
    VALUE value = rb_ary_entry(pair, 1);

    const uint8_t *name_ptr = (const uint8_t *)RSTRING_PTR(name);
    size_t name_len = RSTRING_LEN(name);
    const uint8_t *value_ptr = (const uint8_t *)RSTRING_PTR(value);
    size_t value_len = RSTRING_LEN(value);

    uint8_t int_buf[16];
    size_t int_len;

    int found_index = 0;
    for (int idx = 1; idx <= STATIC_TABLE_SIZE; idx++) {
      if (strlen(STATIC_TABLE[idx].name) == name_len &&
          memcmp(STATIC_TABLE[idx].name, name_ptr, name_len) == 0) {
        found_index = idx;
        break;
      }
    }

    if (found_index > 0) {
      int_len = hpack_encode_int(int_buf, found_index, 4, 0x00);
      rb_str_buf_cat(buf, (const char *)int_buf, int_len);
    } else {
      rb_str_buf_cat(buf, "\x00", 1);

      size_t huff_len = hpack_huffman_encode_len(name_ptr, name_len);
      if (huff_len < name_len) {
        int_len = hpack_encode_int(int_buf, huff_len, 7, 0x80);
        rb_str_buf_cat(buf, (const char *)int_buf, int_len);
        uint8_t *huff_buf = ALLOCA_N(uint8_t, huff_len);
        hpack_huffman_encode(name_ptr, name_len, huff_buf);
        rb_str_buf_cat(buf, (const char *)huff_buf, huff_len);
      } else {
        int_len = hpack_encode_int(int_buf, name_len, 7, 0x00);
        rb_str_buf_cat(buf, (const char *)int_buf, int_len);
        rb_str_buf_cat(buf, (const char *)name_ptr, name_len);
      }
    }

    size_t huff_len = hpack_huffman_encode_len(value_ptr, value_len);
    if (huff_len < value_len) {
      int_len = hpack_encode_int(int_buf, huff_len, 7, 0x80);
      rb_str_buf_cat(buf, (const char *)int_buf, int_len);
      uint8_t *huff_buf = ALLOCA_N(uint8_t, huff_len);
      hpack_huffman_encode(value_ptr, value_len, huff_buf);
      rb_str_buf_cat(buf, (const char *)huff_buf, huff_len);
    } else {
      int_len = hpack_encode_int(int_buf, value_len, 7, 0x00);
      rb_str_buf_cat(buf, (const char *)int_buf, int_len);
      rb_str_buf_cat(buf, (const char *)value_ptr, value_len);
    }
  }

  return buf;
}

static void parse_frame_header(const uint8_t *buf, frame_header *fh) {
  fh->length    = ((uint32_t)buf[0] << 16) | ((uint32_t)buf[1] << 8) | buf[2];
  fh->type      = buf[3];
  fh->flags     = buf[4];
  fh->stream_id = ((uint32_t)(buf[5] & 0x7f) << 24) | ((uint32_t)buf[6] << 16) |
                  ((uint32_t)buf[7] << 8) | buf[8];
}

static VALUE frame_type_sym(uint8_t type) {
  switch (type) {
    case FRAME_DATA:          return ID2SYM(rb_intern("data"));
    case FRAME_HEADERS:       return ID2SYM(rb_intern("headers"));
    case FRAME_PRIORITY:      return ID2SYM(rb_intern("priority"));
    case FRAME_RST_STREAM:    return ID2SYM(rb_intern("rst_stream"));
    case FRAME_SETTINGS:      return ID2SYM(rb_intern("settings"));
    case FRAME_PUSH_PROMISE:  return ID2SYM(rb_intern("push_promise"));
    case FRAME_PING:          return ID2SYM(rb_intern("ping"));
    case FRAME_GOAWAY:        return ID2SYM(rb_intern("goaway"));
    case FRAME_WINDOW_UPDATE: return ID2SYM(rb_intern("window_update"));
    case FRAME_CONTINUATION:  return ID2SYM(rb_intern("continuation"));
    default:                  return ID2SYM(rb_intern("unknown"));
  }
}

static void h2_parser_mark(void *ptr) { (void)ptr; }
static void h2_parser_free(void *ptr) { xfree(ptr); }
static size_t h2_parser_memsize(const void *ptr) { return sizeof(raptor_h2_parser); }

static const rb_data_type_t h2_parser_type = {
  "raptor_http2_parser",
  {h2_parser_mark, h2_parser_free, h2_parser_memsize},
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE h2_parser_alloc(VALUE klass) {
  raptor_h2_parser *parser;
  VALUE obj = TypedData_Make_Struct(klass, raptor_h2_parser, &h2_parser_type, parser);
  parser->max_table_size = HTTP2_DEFAULT_HEADER_TABLE_SIZE;
  return obj;
}

static VALUE h2_parse_headers(VALUE self, VALUE header_block, VALUE dyn_table) {
  raptor_h2_parser *parser;
  TypedData_Get_Struct(self, raptor_h2_parser, &h2_parser_type, parser);

  Check_Type(header_block, T_STRING);
  Check_Type(dyn_table, T_ARRAY);

  const uint8_t *buf = (const uint8_t *)RSTRING_PTR(header_block);
  size_t len = RSTRING_LEN(header_block);

  VALUE headers = rb_ary_new();
  VALUE table = rb_ary_dup(dyn_table);
  long max_size = parser->max_table_size;

  if (hpack_decode_header_block(buf, len, headers, &table, &max_size) < 0)
    rb_raise(eHttp2ParserError, "HPACK header block decode error");

  parser->max_table_size = max_size;
  return rb_ary_new_from_args(2, headers, table);
}

static VALUE h2_encode_headers(VALUE self, VALUE headers) {
  (void)self;
  Check_Type(headers, T_ARRAY);
  return hpack_encode_header_block(headers);
}

static VALUE h2_parse_frame(VALUE self, VALUE buffer) {
  (void)self;
  Check_Type(buffer, T_STRING);

  const uint8_t *buf = (const uint8_t *)RSTRING_PTR(buffer);
  size_t len = RSTRING_LEN(buffer);

  if (len < HTTP2_FRAME_HEADER_SIZE) return Qnil;

  frame_header fh;
  parse_frame_header(buf, &fh);

  size_t total = HTTP2_FRAME_HEADER_SIZE + fh.length;
  if (len < total) return Qnil;

  VALUE frame = rb_hash_new();
  rb_hash_aset(frame, ID2SYM(rb_intern("type")),      frame_type_sym(fh.type));
  rb_hash_aset(frame, ID2SYM(rb_intern("length")),     UINT2NUM(fh.length));
  rb_hash_aset(frame, ID2SYM(rb_intern("flags")),      UINT2NUM(fh.flags));
  rb_hash_aset(frame, ID2SYM(rb_intern("stream_id")),  UINT2NUM(fh.stream_id));
  rb_hash_aset(frame, ID2SYM(rb_intern("payload")),    rb_str_new((const char *)(buf + HTTP2_FRAME_HEADER_SIZE), fh.length));

  return rb_ary_new_from_args(2, frame, SIZET2NUM(total));
}

static VALUE h2_build_frame(VALUE self, VALUE type, VALUE flags, VALUE stream_id, VALUE payload) {
  (void)self;

  uint8_t frame_type;
  ID type_id = SYM2ID(type);

  if (type_id == rb_intern("data"))               frame_type = FRAME_DATA;
  else if (type_id == rb_intern("headers"))        frame_type = FRAME_HEADERS;
  else if (type_id == rb_intern("priority"))       frame_type = FRAME_PRIORITY;
  else if (type_id == rb_intern("rst_stream"))     frame_type = FRAME_RST_STREAM;
  else if (type_id == rb_intern("settings"))       frame_type = FRAME_SETTINGS;
  else if (type_id == rb_intern("push_promise"))   frame_type = FRAME_PUSH_PROMISE;
  else if (type_id == rb_intern("ping"))           frame_type = FRAME_PING;
  else if (type_id == rb_intern("goaway"))         frame_type = FRAME_GOAWAY;
  else if (type_id == rb_intern("window_update"))  frame_type = FRAME_WINDOW_UPDATE;
  else if (type_id == rb_intern("continuation"))   frame_type = FRAME_CONTINUATION;
  else rb_raise(rb_eArgError, "unknown frame type");

  uint8_t frame_flags = (uint8_t)NUM2UINT(flags);
  uint32_t sid = NUM2UINT(stream_id);

  const char *payload_ptr = NIL_P(payload) ? "" : RSTRING_PTR(payload);
  size_t payload_len = NIL_P(payload) ? 0 : RSTRING_LEN(payload);

  uint8_t header[HTTP2_FRAME_HEADER_SIZE];
  header[0] = (payload_len >> 16) & 0xff;
  header[1] = (payload_len >> 8) & 0xff;
  header[2] = payload_len & 0xff;
  header[3] = frame_type;
  header[4] = frame_flags;
  header[5] = (sid >> 24) & 0x7f;
  header[6] = (sid >> 16) & 0xff;
  header[7] = (sid >> 8) & 0xff;
  header[8] = sid & 0xff;

  VALUE result = rb_str_new((const char *)header, HTTP2_FRAME_HEADER_SIZE);
  rb_str_buf_cat(result, payload_ptr, payload_len);
  return result;
}

static VALUE h2_connection_preface(VALUE self) {
  (void)self;
  return rb_str_new(HTTP2_CONNECTION_PREFACE, HTTP2_CONNECTION_PREFACE_LEN);
}

static VALUE h2_parse_settings(VALUE self, VALUE payload) {
  (void)self;
  Check_Type(payload, T_STRING);

  const uint8_t *buf = (const uint8_t *)RSTRING_PTR(payload);
  size_t len = RSTRING_LEN(payload);

  if (len % 6 != 0)
    rb_raise(eHttp2ParserError, "invalid SETTINGS payload length");

  VALUE settings = rb_hash_new();

  for (size_t i = 0; i < len; i += 6) {
    uint16_t id = ((uint16_t)buf[i] << 8) | buf[i + 1];
    uint32_t val = ((uint32_t)buf[i + 2] << 24) | ((uint32_t)buf[i + 3] << 16) |
                   ((uint32_t)buf[i + 4] << 8) | buf[i + 5];

    switch (id) {
      case SETTINGS_HEADER_TABLE_SIZE:
        rb_hash_aset(settings, ID2SYM(rb_intern("header_table_size")), UINT2NUM(val));       break;
      case SETTINGS_ENABLE_PUSH:
        rb_hash_aset(settings, ID2SYM(rb_intern("enable_push")), UINT2NUM(val));              break;
      case SETTINGS_MAX_CONCURRENT_STREAMS:
        rb_hash_aset(settings, ID2SYM(rb_intern("max_concurrent_streams")), UINT2NUM(val));   break;
      case SETTINGS_INITIAL_WINDOW_SIZE:
        rb_hash_aset(settings, ID2SYM(rb_intern("initial_window_size")), UINT2NUM(val));      break;
      case SETTINGS_MAX_FRAME_SIZE:
        rb_hash_aset(settings, ID2SYM(rb_intern("max_frame_size")), UINT2NUM(val));           break;
      case SETTINGS_MAX_HEADER_LIST_SIZE:
        rb_hash_aset(settings, ID2SYM(rb_intern("max_header_list_size")), UINT2NUM(val));     break;
    }
  }

  return settings;
}

static VALUE h2_build_settings(VALUE self, VALUE settings) {
  (void)self;
  Check_Type(settings, T_HASH);

  VALUE buf = rb_str_buf_new(36);
  VALUE keys = rb_funcall(settings, rb_intern("keys"), 0);

  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i);
    VALUE val = rb_hash_aref(settings, key);
    ID key_id = SYM2ID(key);

    uint16_t id;
    if (key_id == rb_intern("header_table_size"))           id = SETTINGS_HEADER_TABLE_SIZE;
    else if (key_id == rb_intern("enable_push"))            id = SETTINGS_ENABLE_PUSH;
    else if (key_id == rb_intern("max_concurrent_streams")) id = SETTINGS_MAX_CONCURRENT_STREAMS;
    else if (key_id == rb_intern("initial_window_size"))    id = SETTINGS_INITIAL_WINDOW_SIZE;
    else if (key_id == rb_intern("max_frame_size"))         id = SETTINGS_MAX_FRAME_SIZE;
    else if (key_id == rb_intern("max_header_list_size"))   id = SETTINGS_MAX_HEADER_LIST_SIZE;
    else continue;

    uint32_t v = NUM2UINT(val);
    uint8_t entry[6];
    entry[0] = (id >> 8) & 0xff;
    entry[1] = id & 0xff;
    entry[2] = (v >> 24) & 0xff;
    entry[3] = (v >> 16) & 0xff;
    entry[4] = (v >> 8) & 0xff;
    entry[5] = v & 0xff;
    rb_str_buf_cat(buf, (const char *)entry, 6);
  }

  return buf;
}

static VALUE h2_parse_window_update(VALUE self, VALUE payload) {
  (void)self;
  Check_Type(payload, T_STRING);

  if (RSTRING_LEN(payload) != 4)
    rb_raise(eHttp2ParserError, "invalid WINDOW_UPDATE payload length");

  const uint8_t *buf = (const uint8_t *)RSTRING_PTR(payload);
  uint32_t increment = ((uint32_t)(buf[0] & 0x7f) << 24) | ((uint32_t)buf[1] << 16) |
                       ((uint32_t)buf[2] << 8) | buf[3];

  return UINT2NUM(increment);
}

RUBY_FUNC_EXPORTED void Init_raptor_http2(void) {
  rb_ext_ractor_safe(true);

  VALUE mRaptor = rb_define_module("Raptor");
  cHttp2Parser = rb_define_class_under(mRaptor, "Http2Parser", rb_cObject);
  eHttp2ParserError = rb_define_class_under(mRaptor, "Http2ParserError", rb_eStandardError);

  rb_define_alloc_func(cHttp2Parser, h2_parser_alloc);
  rb_define_method(cHttp2Parser, "parse_frame", h2_parse_frame, 1);
  rb_define_method(cHttp2Parser, "parse_headers", h2_parse_headers, 2);
  rb_define_method(cHttp2Parser, "encode_headers", h2_encode_headers, 1);
  rb_define_method(cHttp2Parser, "parse_settings", h2_parse_settings, 1);
  rb_define_method(cHttp2Parser, "build_settings", h2_build_settings, 1);
  rb_define_method(cHttp2Parser, "build_frame", h2_build_frame, 4);
  rb_define_method(cHttp2Parser, "parse_window_update", h2_parse_window_update, 1);
  rb_define_singleton_method(cHttp2Parser, "connection_preface", h2_connection_preface, 0);
}
