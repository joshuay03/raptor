/**
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby.
 */

#include "ruby.h"
#include "ruby/encoding.h"
#include <assert.h>
#include <string.h>
#include <ctype.h>

#define MAX_HEADER_LENGTH (112 * 1024)
#define MAX_URI_LENGTH (12 * 1024)
#define MAX_FIELD_NAME 256
#define MAX_FIELD_VALUE (80 * 1024)

typedef struct raptor_parser {
  int cs;
  size_t mark;
  size_t field_start;
  size_t field_len;
  size_t query_start;
  size_t nread;
  size_t body_start;
  off_t content_len;
  unsigned int flags;
  VALUE request;
  VALUE body;
  char buf[MAX_FIELD_NAME + 6];
} raptor_parser;

#define MARK(M, P) (parser->M = (P) - buffer)
#define LEN(AT, P) ((P) - buffer - parser->AT)
#define PTR_TO(F) (buffer + parser->F)

#define FLAG_CHUNKED 0x1
#define FLAG_HAS_BODY 0x2
#define FLAG_FINISHED 0x4

static VALUE eHttpParserError;
static VALUE global_request_method;
static VALUE global_request_uri;
static VALUE global_query_string;
static VALUE global_server_protocol;
static VALUE global_request_path;
static VALUE global_fragment;

struct common_field {
  const char *name;
  size_t len;
  VALUE interned;
};

#define FIELD(name) { name, sizeof(name) - 1, Qnil }

static struct common_field common_fields[] = {
  FIELD("HTTP_HOST"),
  FIELD("HTTP_USER_AGENT"),
  FIELD("HTTP_CONNECTION"),
  FIELD("HTTP_ACCEPT"),
  FIELD("HTTP_ACCEPT_ENCODING"),
  FIELD("HTTP_ACCEPT_LANGUAGE"),
  FIELD("HTTP_ACCEPT_CHARSET"),
  FIELD("HTTP_COOKIE"),
  FIELD("HTTP_REFERER"),
  FIELD("HTTP_CACHE_CONTROL"),
  FIELD("HTTP_PRAGMA"),

  FIELD("CONTENT_LENGTH"),
  FIELD("CONTENT_TYPE"),
  FIELD("HTTP_TRANSFER_ENCODING"),

  FIELD("HTTP_AUTHORIZATION"),
  FIELD("HTTP_ORIGIN"),
  FIELD("HTTP_EXPECT"),

  FIELD("HTTP_IF_MATCH"),
  FIELD("HTTP_IF_NONE_MATCH"),
  FIELD("HTTP_IF_MODIFIED_SINCE"),
  FIELD("HTTP_IF_UNMODIFIED_SINCE"),
  FIELD("HTTP_IF_RANGE"),
  FIELD("HTTP_RANGE"),

  FIELD("HTTP_UPGRADE"),
  FIELD("HTTP_UPGRADE_INSECURE_REQUESTS"),

  FIELD("HTTP_SEC_FETCH_DEST"),
  FIELD("HTTP_SEC_FETCH_MODE"),
  FIELD("HTTP_SEC_FETCH_SITE"),
  FIELD("HTTP_SEC_FETCH_USER"),
  FIELD("HTTP_SEC_CH_UA"),
  FIELD("HTTP_SEC_CH_UA_MOBILE"),
  FIELD("HTTP_SEC_CH_UA_PLATFORM"),
  FIELD("HTTP_DNT"),

  FIELD("HTTP_X_FORWARDED_FOR"),
  FIELD("HTTP_X_FORWARDED_HOST"),
  FIELD("HTTP_X_FORWARDED_PROTO"),
  FIELD("HTTP_X_FORWARDED_SCHEME"),
  FIELD("HTTP_X_FORWARDED_SSL"),
  FIELD("HTTP_X_REAL_IP")
};

#undef FIELD

#define NUM_COMMON_FIELDS (sizeof(common_fields) / sizeof(common_fields[0]))

static VALUE raptor_http_intern_field(const char *buf, size_t len) {
  for (size_t i = 0; i < NUM_COMMON_FIELDS; i++) {
    if (common_fields[i].len == len && memcmp(common_fields[i].name, buf, len) == 0) {
      return common_fields[i].interned;
    }
  }
  return rb_enc_interned_str(buf, len, rb_utf8_encoding());
}

static inline void upcase_header_char(char *c) {
  if (*c >= 'a' && *c <= 'z')
    *c &= ~0x20;
  else if (*c == '-')
    *c = '_';
}

static int contains_chunked(const char *value, long len) {
  static const char chunked[] = "chunked";
  static const long chunked_len = sizeof(chunked) - 1;

  if (len < chunked_len) return 0;
  for (long start = 0; start + chunked_len <= len; start++) {
    long i;
    for (i = 0; i < chunked_len; i++) {
      if ((char)tolower((unsigned char)value[start + i]) != chunked[i]) break;
    }
    if (i == chunked_len) return 1;
  }
  return 0;
}

static const int raptor_parser_start = 1;
static const int raptor_parser_first_final = 46;
static const int raptor_parser_error = 0;

size_t raptor_parser_execute(raptor_parser *parser, const char *buffer, size_t len) {
  const char *p, *pe;
  int cs = parser->cs;

  p = buffer;
  pe = buffer + len;

	{
	if ( p == pe )
		goto _test_eof;
	switch ( cs )
	{
case 1:
	switch( (*p) ) {
		case 36: goto tr0;
		case 95: goto tr0;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto tr0;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto tr0;
	} else
		goto tr0;
	goto st0;
st0:
cs = 0;
	goto _out;
tr0:
	{ MARK(mark, p); }
	goto st2;
st2:
	if ( ++p == pe )
		goto _test_eof2;
case 2:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st27;
		case 95: goto st27;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st27;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st27;
	} else
		goto st27;
	goto st0;
tr2:
	{
    VALUE method = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_method, method);
  }
	goto st3;
st3:
	if ( ++p == pe )
		goto _test_eof3;
case 3:
	switch( (*p) ) {
		case 42: goto tr4;
		case 43: goto tr5;
		case 47: goto tr6;
		case 58: goto tr7;
	}
	if ( (*p) < 65 ) {
		if ( 45 <= (*p) && (*p) <= 57 )
			goto tr5;
	} else if ( (*p) > 90 ) {
		if ( 97 <= (*p) && (*p) <= 122 )
			goto tr5;
	} else
		goto tr5;
	goto st0;
tr4:
	{ MARK(mark, p); }
	goto st4;
st4:
	if ( ++p == pe )
		goto _test_eof4;
case 4:
	switch( (*p) ) {
		case 32: goto tr8;
		case 35: goto tr9;
	}
	goto st0;
tr8:
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st5;
tr31:
	{ MARK(mark, p); }
	{
    VALUE frag = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_fragment, frag);
  }
	goto st5;
tr33:
	{
    VALUE frag = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_fragment, frag);
  }
	goto st5;
tr37:
	{
    VALUE path = rb_str_new(PTR_TO(mark), LEN(mark,p));
    rb_hash_aset(parser->request, global_request_path, path);
  }
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st5;
tr41:
	{ MARK(query_start, p); }
	{
    VALUE query = rb_str_new(PTR_TO(query_start), LEN(query_start, p));
    rb_hash_aset(parser->request, global_query_string, query);
  }
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st5;
tr44:
	{
    VALUE query = rb_str_new(PTR_TO(query_start), LEN(query_start, p));
    rb_hash_aset(parser->request, global_query_string, query);
  }
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st5;
st5:
	if ( ++p == pe )
		goto _test_eof5;
case 5:
	if ( (*p) == 72 )
		goto tr10;
	goto st0;
tr10:
	{ MARK(mark, p); }
	goto st6;
st6:
	if ( ++p == pe )
		goto _test_eof6;
case 6:
	if ( (*p) == 84 )
		goto st7;
	goto st0;
st7:
	if ( ++p == pe )
		goto _test_eof7;
case 7:
	if ( (*p) == 84 )
		goto st8;
	goto st0;
st8:
	if ( ++p == pe )
		goto _test_eof8;
case 8:
	if ( (*p) == 80 )
		goto st9;
	goto st0;
st9:
	if ( ++p == pe )
		goto _test_eof9;
case 9:
	if ( (*p) == 47 )
		goto st10;
	goto st0;
st10:
	if ( ++p == pe )
		goto _test_eof10;
case 10:
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st11;
	goto st0;
st11:
	if ( ++p == pe )
		goto _test_eof11;
case 11:
	if ( (*p) == 46 )
		goto st12;
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st11;
	goto st0;
st12:
	if ( ++p == pe )
		goto _test_eof12;
case 12:
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st13;
	goto st0;
st13:
	if ( ++p == pe )
		goto _test_eof13;
case 13:
	if ( (*p) == 13 )
		goto tr18;
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st13;
	goto st0;
tr18:
	{
    VALUE proto = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_server_protocol, proto);
  }
	goto st14;
tr26:
	{ MARK(mark, p); }
	{
    if (parser->field_len == 0 || parser->field_len > MAX_FIELD_NAME)
      rb_raise(eHttpParserError, "invalid field name length");

    size_t value_len = LEN(mark, p);
    if (value_len > MAX_FIELD_VALUE)
      rb_raise(eHttpParserError, "field value too long");

    const char *field_ptr = PTR_TO(field_start);

    int needs_http_prefix = 1;
    if (parser->field_len == 14 && memcmp(field_ptr, "CONTENT_LENGTH", 14) == 0)
      needs_http_prefix = 0;
    else if (parser->field_len == 12 && memcmp(field_ptr, "CONTENT_TYPE", 12) == 0)
      needs_http_prefix = 0;

    size_t key_len;
    if (needs_http_prefix) {
      memcpy(parser->buf, "HTTP_", 5);
      memcpy(parser->buf + 5, field_ptr, parser->field_len);
      key_len = 5 + parser->field_len;
      parser->buf[key_len] = '\0';
    } else {
      memcpy(parser->buf, field_ptr, parser->field_len);
      key_len = parser->field_len;
      parser->buf[key_len] = '\0';
    }

    VALUE key = raptor_http_intern_field(parser->buf, key_len);
    VALUE value = rb_str_new(PTR_TO(mark), value_len);

    char *value_ptr = RSTRING_PTR(value);
    long value_real_len = RSTRING_LEN(value);
    while (value_real_len > 0 && (value_ptr[value_real_len - 1] == ' ' ||
                                    value_ptr[value_real_len - 1] == '\t'))
      value_real_len--;
    rb_str_set_len(value, value_real_len);

    if (!needs_http_prefix && parser->field_len == 14) {
      parser->content_len = strtoul(RSTRING_PTR(value), NULL, 10);
      if (parser->content_len > 0)
        parser->flags |= FLAG_HAS_BODY;
    } else if (needs_http_prefix && parser->field_len == 17 &&
               memcmp(field_ptr, "TRANSFER_ENCODING", 17) == 0) {
      if (contains_chunked(value_ptr, value_real_len)) {
        parser->flags |= FLAG_CHUNKED | FLAG_HAS_BODY;
        parser->content_len = 0;
      }
    }

    VALUE existing = rb_hash_aref(parser->request, key);
    if (!NIL_P(existing)) {
      rb_str_cat2(existing, ", ");
      rb_str_append(existing, value);
    } else {
      rb_hash_aset(parser->request, key, value);
    }
  }
	goto st14;
tr29:
	{
    if (parser->field_len == 0 || parser->field_len > MAX_FIELD_NAME)
      rb_raise(eHttpParserError, "invalid field name length");

    size_t value_len = LEN(mark, p);
    if (value_len > MAX_FIELD_VALUE)
      rb_raise(eHttpParserError, "field value too long");

    const char *field_ptr = PTR_TO(field_start);

    int needs_http_prefix = 1;
    if (parser->field_len == 14 && memcmp(field_ptr, "CONTENT_LENGTH", 14) == 0)
      needs_http_prefix = 0;
    else if (parser->field_len == 12 && memcmp(field_ptr, "CONTENT_TYPE", 12) == 0)
      needs_http_prefix = 0;

    size_t key_len;
    if (needs_http_prefix) {
      memcpy(parser->buf, "HTTP_", 5);
      memcpy(parser->buf + 5, field_ptr, parser->field_len);
      key_len = 5 + parser->field_len;
      parser->buf[key_len] = '\0';
    } else {
      memcpy(parser->buf, field_ptr, parser->field_len);
      key_len = parser->field_len;
      parser->buf[key_len] = '\0';
    }

    VALUE key = raptor_http_intern_field(parser->buf, key_len);
    VALUE value = rb_str_new(PTR_TO(mark), value_len);

    char *value_ptr = RSTRING_PTR(value);
    long value_real_len = RSTRING_LEN(value);
    while (value_real_len > 0 && (value_ptr[value_real_len - 1] == ' ' ||
                                    value_ptr[value_real_len - 1] == '\t'))
      value_real_len--;
    rb_str_set_len(value, value_real_len);

    if (!needs_http_prefix && parser->field_len == 14) {
      parser->content_len = strtoul(RSTRING_PTR(value), NULL, 10);
      if (parser->content_len > 0)
        parser->flags |= FLAG_HAS_BODY;
    } else if (needs_http_prefix && parser->field_len == 17 &&
               memcmp(field_ptr, "TRANSFER_ENCODING", 17) == 0) {
      if (contains_chunked(value_ptr, value_real_len)) {
        parser->flags |= FLAG_CHUNKED | FLAG_HAS_BODY;
        parser->content_len = 0;
      }
    }

    VALUE existing = rb_hash_aref(parser->request, key);
    if (!NIL_P(existing)) {
      rb_str_cat2(existing, ", ");
      rb_str_append(existing, value);
    } else {
      rb_hash_aset(parser->request, key, value);
    }
  }
	goto st14;
st14:
	if ( ++p == pe )
		goto _test_eof14;
case 14:
	if ( (*p) == 10 )
		goto st15;
	goto st0;
st15:
	if ( ++p == pe )
		goto _test_eof15;
case 15:
	switch( (*p) ) {
		case 13: goto st16;
		case 33: goto tr21;
		case 124: goto tr21;
		case 126: goto tr21;
	}
	if ( (*p) < 45 ) {
		if ( (*p) > 39 ) {
			if ( 42 <= (*p) && (*p) <= 43 )
				goto tr21;
		} else if ( (*p) >= 35 )
			goto tr21;
	} else if ( (*p) > 46 ) {
		if ( (*p) < 65 ) {
			if ( 48 <= (*p) && (*p) <= 57 )
				goto tr21;
		} else if ( (*p) > 90 ) {
			if ( 94 <= (*p) && (*p) <= 122 )
				goto tr21;
		} else
			goto tr21;
	} else
		goto tr21;
	goto st0;
st16:
	if ( ++p == pe )
		goto _test_eof16;
case 16:
	if ( (*p) == 10 )
		goto tr22;
	goto st0;
tr22:
	{
    parser->body_start = p - buffer + 1;
    parser->flags |= FLAG_FINISHED;
    parser->nread = p - buffer + 1;
    goto done;
  }
	goto st46;
st46:
	if ( ++p == pe )
		goto _test_eof46;
case 46:
	goto st0;
tr21:
	{ MARK(field_start, p); }
	{ upcase_header_char((char *)p); }
	goto st17;
tr23:
	{ upcase_header_char((char *)p); }
	goto st17;
st17:
	if ( ++p == pe )
		goto _test_eof17;
case 17:
	switch( (*p) ) {
		case 33: goto tr23;
		case 58: goto tr24;
		case 124: goto tr23;
		case 126: goto tr23;
	}
	if ( (*p) < 45 ) {
		if ( (*p) > 39 ) {
			if ( 42 <= (*p) && (*p) <= 43 )
				goto tr23;
		} else if ( (*p) >= 35 )
			goto tr23;
	} else if ( (*p) > 46 ) {
		if ( (*p) < 65 ) {
			if ( 48 <= (*p) && (*p) <= 57 )
				goto tr23;
		} else if ( (*p) > 90 ) {
			if ( 94 <= (*p) && (*p) <= 122 )
				goto tr23;
		} else
			goto tr23;
	} else
		goto tr23;
	goto st0;
tr24:
	{
    parser->field_len = LEN(field_start, p);
  }
	goto st18;
tr27:
	{ MARK(mark, p); }
	goto st18;
st18:
	if ( ++p == pe )
		goto _test_eof18;
case 18:
	switch( (*p) ) {
		case 13: goto tr26;
		case 32: goto tr27;
		case 127: goto st0;
	}
	if ( (*p) > 8 ) {
		if ( 10 <= (*p) && (*p) <= 31 )
			goto st0;
	} else if ( (*p) >= 0 )
		goto st0;
	goto tr25;
tr25:
	{ MARK(mark, p); }
	goto st19;
st19:
	if ( ++p == pe )
		goto _test_eof19;
case 19:
	switch( (*p) ) {
		case 13: goto tr29;
		case 127: goto st0;
	}
	if ( (*p) > 8 ) {
		if ( 10 <= (*p) && (*p) <= 31 )
			goto st0;
	} else if ( (*p) >= 0 )
		goto st0;
	goto st19;
tr9:
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st20;
tr38:
	{
    VALUE path = rb_str_new(PTR_TO(mark), LEN(mark,p));
    rb_hash_aset(parser->request, global_request_path, path);
  }
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st20;
tr42:
	{ MARK(query_start, p); }
	{
    VALUE query = rb_str_new(PTR_TO(query_start), LEN(query_start, p));
    rb_hash_aset(parser->request, global_query_string, query);
  }
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st20;
tr45:
	{
    VALUE query = rb_str_new(PTR_TO(query_start), LEN(query_start, p));
    rb_hash_aset(parser->request, global_query_string, query);
  }
	{
    if (LEN(mark, p) > MAX_URI_LENGTH)
      rb_raise(eHttpParserError, "URI too long");
    VALUE uri = rb_str_new(PTR_TO(mark), LEN(mark, p));
    rb_hash_aset(parser->request, global_request_uri, uri);
  }
	goto st20;
st20:
	if ( ++p == pe )
		goto _test_eof20;
case 20:
	switch( (*p) ) {
		case 32: goto tr31;
		case 60: goto st0;
		case 62: goto st0;
		case 127: goto st0;
	}
	if ( (*p) > 31 ) {
		if ( 34 <= (*p) && (*p) <= 35 )
			goto st0;
	} else if ( (*p) >= 0 )
		goto st0;
	goto tr30;
tr30:
	{ MARK(mark, p); }
	goto st21;
st21:
	if ( ++p == pe )
		goto _test_eof21;
case 21:
	switch( (*p) ) {
		case 32: goto tr33;
		case 60: goto st0;
		case 62: goto st0;
		case 127: goto st0;
	}
	if ( (*p) > 31 ) {
		if ( 34 <= (*p) && (*p) <= 35 )
			goto st0;
	} else if ( (*p) >= 0 )
		goto st0;
	goto st21;
tr5:
	{ MARK(mark, p); }
	goto st22;
st22:
	if ( ++p == pe )
		goto _test_eof22;
case 22:
	switch( (*p) ) {
		case 43: goto st22;
		case 58: goto st23;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st22;
	} else if ( (*p) > 57 ) {
		if ( (*p) > 90 ) {
			if ( 97 <= (*p) && (*p) <= 122 )
				goto st22;
		} else if ( (*p) >= 65 )
			goto st22;
	} else
		goto st22;
	goto st0;
tr7:
	{ MARK(mark, p); }
	goto st23;
st23:
	if ( ++p == pe )
		goto _test_eof23;
case 23:
	switch( (*p) ) {
		case 32: goto tr8;
		case 34: goto st0;
		case 35: goto tr9;
		case 60: goto st0;
		case 62: goto st0;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto st23;
tr6:
	{ MARK(mark, p); }
	goto st24;
st24:
	if ( ++p == pe )
		goto _test_eof24;
case 24:
	switch( (*p) ) {
		case 32: goto tr37;
		case 34: goto st0;
		case 35: goto tr38;
		case 60: goto st0;
		case 62: goto st0;
		case 63: goto tr39;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto st24;
tr39:
	{
    VALUE path = rb_str_new(PTR_TO(mark), LEN(mark,p));
    rb_hash_aset(parser->request, global_request_path, path);
  }
	goto st25;
st25:
	if ( ++p == pe )
		goto _test_eof25;
case 25:
	switch( (*p) ) {
		case 32: goto tr41;
		case 34: goto st0;
		case 35: goto tr42;
		case 60: goto st0;
		case 62: goto st0;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto tr40;
tr40:
	{ MARK(query_start, p); }
	goto st26;
st26:
	if ( ++p == pe )
		goto _test_eof26;
case 26:
	switch( (*p) ) {
		case 32: goto tr44;
		case 34: goto st0;
		case 35: goto tr45;
		case 60: goto st0;
		case 62: goto st0;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto st26;
st27:
	if ( ++p == pe )
		goto _test_eof27;
case 27:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st28;
		case 95: goto st28;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st28;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st28;
	} else
		goto st28;
	goto st0;
st28:
	if ( ++p == pe )
		goto _test_eof28;
case 28:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st29;
		case 95: goto st29;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st29;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st29;
	} else
		goto st29;
	goto st0;
st29:
	if ( ++p == pe )
		goto _test_eof29;
case 29:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st30;
		case 95: goto st30;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st30;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st30;
	} else
		goto st30;
	goto st0;
st30:
	if ( ++p == pe )
		goto _test_eof30;
case 30:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st31;
		case 95: goto st31;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st31;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st31;
	} else
		goto st31;
	goto st0;
st31:
	if ( ++p == pe )
		goto _test_eof31;
case 31:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st32;
		case 95: goto st32;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st32;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st32;
	} else
		goto st32;
	goto st0;
st32:
	if ( ++p == pe )
		goto _test_eof32;
case 32:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st33;
		case 95: goto st33;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st33;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st33;
	} else
		goto st33;
	goto st0;
st33:
	if ( ++p == pe )
		goto _test_eof33;
case 33:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st34;
		case 95: goto st34;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st34;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st34;
	} else
		goto st34;
	goto st0;
st34:
	if ( ++p == pe )
		goto _test_eof34;
case 34:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st35;
		case 95: goto st35;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st35;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st35;
	} else
		goto st35;
	goto st0;
st35:
	if ( ++p == pe )
		goto _test_eof35;
case 35:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st36;
		case 95: goto st36;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st36;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st36;
	} else
		goto st36;
	goto st0;
st36:
	if ( ++p == pe )
		goto _test_eof36;
case 36:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st37;
		case 95: goto st37;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st37;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st37;
	} else
		goto st37;
	goto st0;
st37:
	if ( ++p == pe )
		goto _test_eof37;
case 37:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st38;
		case 95: goto st38;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st38;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st38;
	} else
		goto st38;
	goto st0;
st38:
	if ( ++p == pe )
		goto _test_eof38;
case 38:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st39;
		case 95: goto st39;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st39;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st39;
	} else
		goto st39;
	goto st0;
st39:
	if ( ++p == pe )
		goto _test_eof39;
case 39:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st40;
		case 95: goto st40;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st40;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st40;
	} else
		goto st40;
	goto st0;
st40:
	if ( ++p == pe )
		goto _test_eof40;
case 40:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st41;
		case 95: goto st41;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st41;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st41;
	} else
		goto st41;
	goto st0;
st41:
	if ( ++p == pe )
		goto _test_eof41;
case 41:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st42;
		case 95: goto st42;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st42;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st42;
	} else
		goto st42;
	goto st0;
st42:
	if ( ++p == pe )
		goto _test_eof42;
case 42:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st43;
		case 95: goto st43;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st43;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st43;
	} else
		goto st43;
	goto st0;
st43:
	if ( ++p == pe )
		goto _test_eof43;
case 43:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st44;
		case 95: goto st44;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st44;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st44;
	} else
		goto st44;
	goto st0;
st44:
	if ( ++p == pe )
		goto _test_eof44;
case 44:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st45;
		case 95: goto st45;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st45;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st45;
	} else
		goto st45;
	goto st0;
st45:
	if ( ++p == pe )
		goto _test_eof45;
case 45:
	if ( (*p) == 32 )
		goto tr2;
	goto st0;
	}
	_test_eof2: cs = 2; goto _test_eof;
	_test_eof3: cs = 3; goto _test_eof;
	_test_eof4: cs = 4; goto _test_eof;
	_test_eof5: cs = 5; goto _test_eof;
	_test_eof6: cs = 6; goto _test_eof;
	_test_eof7: cs = 7; goto _test_eof;
	_test_eof8: cs = 8; goto _test_eof;
	_test_eof9: cs = 9; goto _test_eof;
	_test_eof10: cs = 10; goto _test_eof;
	_test_eof11: cs = 11; goto _test_eof;
	_test_eof12: cs = 12; goto _test_eof;
	_test_eof13: cs = 13; goto _test_eof;
	_test_eof14: cs = 14; goto _test_eof;
	_test_eof15: cs = 15; goto _test_eof;
	_test_eof16: cs = 16; goto _test_eof;
	_test_eof46: cs = 46; goto _test_eof;
	_test_eof17: cs = 17; goto _test_eof;
	_test_eof18: cs = 18; goto _test_eof;
	_test_eof19: cs = 19; goto _test_eof;
	_test_eof20: cs = 20; goto _test_eof;
	_test_eof21: cs = 21; goto _test_eof;
	_test_eof22: cs = 22; goto _test_eof;
	_test_eof23: cs = 23; goto _test_eof;
	_test_eof24: cs = 24; goto _test_eof;
	_test_eof25: cs = 25; goto _test_eof;
	_test_eof26: cs = 26; goto _test_eof;
	_test_eof27: cs = 27; goto _test_eof;
	_test_eof28: cs = 28; goto _test_eof;
	_test_eof29: cs = 29; goto _test_eof;
	_test_eof30: cs = 30; goto _test_eof;
	_test_eof31: cs = 31; goto _test_eof;
	_test_eof32: cs = 32; goto _test_eof;
	_test_eof33: cs = 33; goto _test_eof;
	_test_eof34: cs = 34; goto _test_eof;
	_test_eof35: cs = 35; goto _test_eof;
	_test_eof36: cs = 36; goto _test_eof;
	_test_eof37: cs = 37; goto _test_eof;
	_test_eof38: cs = 38; goto _test_eof;
	_test_eof39: cs = 39; goto _test_eof;
	_test_eof40: cs = 40; goto _test_eof;
	_test_eof41: cs = 41; goto _test_eof;
	_test_eof42: cs = 42; goto _test_eof;
	_test_eof43: cs = 43; goto _test_eof;
	_test_eof44: cs = 44; goto _test_eof;
	_test_eof45: cs = 45; goto _test_eof;

	_test_eof: {}
	_out: {}
	}

done:
  parser->cs = cs;
  parser->nread = p - buffer;

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(parser->nread <= len && "nread longer than length");
  assert(parser->body_start <= len && "body starts after buffer end");

  return parser->nread;
}

int raptor_parser_finished(raptor_parser *parser) {
  return (parser->flags & FLAG_FINISHED) != 0;
}

int raptor_parser_has_body(raptor_parser *parser) {
  return (parser->flags & FLAG_HAS_BODY) != 0;
}

size_t raptor_parser_content_length(raptor_parser *parser) {
  return parser->content_len;
}

int raptor_parser_is_chunked(raptor_parser *parser) {
  return (parser->flags & FLAG_CHUNKED) != 0;
}

int raptor_parser_has_error(raptor_parser *parser) {
  return parser->cs == raptor_parser_error;
}

int raptor_parser_is_finished(raptor_parser *parser) {
  return parser->cs >= raptor_parser_first_final;
}

void raptor_parser_init(raptor_parser *parser) {
  parser->cs = raptor_parser_start;
  parser->mark = 0;
  parser->field_start = 0;
  parser->field_len = 0;
  parser->query_start = 0;
  parser->nread = 0;
  parser->body_start = 0;
  parser->content_len = 0;
  parser->flags = 0;
  parser->request = Qnil;
  parser->body = Qnil;
}

static VALUE cHttpParser;

static void parser_mark(void *ptr) {
  raptor_parser *parser = ptr;
  rb_gc_mark(parser->request);
  rb_gc_mark(parser->body);
}

static void parser_free(void *ptr) {
  xfree(ptr);
}

static size_t parser_memsize(const void *ptr) {
  return sizeof(raptor_parser);
}

static const rb_data_type_t parser_type = {
  "raptor_http_parser",
  { parser_mark, parser_free, parser_memsize },
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE parser_alloc(VALUE klass) {
  raptor_parser *parser;
  VALUE obj = TypedData_Make_Struct(klass, raptor_parser, &parser_type, parser);
  raptor_parser_init(parser);
  return obj;
}

static VALUE parser_execute(VALUE self, VALUE req_hash, VALUE buffer, VALUE start) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);

  Check_Type(buffer, T_STRING);
  parser->request = req_hash;

  size_t from = NUM2SIZET(start);
  const char *data = RSTRING_PTR(buffer);
  size_t len = RSTRING_LEN(buffer);

  if (from >= len)
    rb_raise(eHttpParserError, "start is after buffer end");

  raptor_parser_execute(parser, data + from, len - from);

  return SIZET2NUM(parser->nread);
}

static VALUE parser_finished_p(VALUE self) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);
  return raptor_parser_finished(parser) ? Qtrue : Qfalse;
}

static VALUE parser_has_body_p(VALUE self) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);
  return raptor_parser_has_body(parser) ? Qtrue : Qfalse;
}

static VALUE parser_chunked_p(VALUE self) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);
  return raptor_parser_is_chunked(parser) ? Qtrue : Qfalse;
}

static VALUE parser_content_length(VALUE self) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);
  return SIZET2NUM(raptor_parser_content_length(parser));
}

static VALUE parser_nread(VALUE self) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);
  return SIZET2NUM(parser->nread);
}

static VALUE parser_reset(VALUE self) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);
  raptor_parser_init(parser);
  return Qnil;
}

static VALUE parser_body(VALUE self) {
  raptor_parser *parser;
  TypedData_Get_Struct(self, raptor_parser, &parser_type, parser);
  return parser->body;
}

RUBY_FUNC_EXPORTED void Init_raptor_http(void) {
  rb_ext_ractor_safe(true);

  VALUE mRaptor = rb_define_module("Raptor");
  cHttpParser = rb_define_class_under(mRaptor, "HttpParser", rb_cObject);
  eHttpParserError = rb_define_class_under(mRaptor, "HttpParserError", rb_eStandardError);

  rb_global_variable(&global_request_method);
  rb_global_variable(&global_request_uri);
  rb_global_variable(&global_query_string);
  rb_global_variable(&global_server_protocol);
  rb_global_variable(&global_request_path);
  rb_global_variable(&global_fragment);

  global_request_method = rb_str_new2("REQUEST_METHOD");
  global_request_uri = rb_str_new2("REQUEST_URI");
  global_query_string = rb_str_new2("QUERY_STRING");
  global_server_protocol = rb_str_new2("SERVER_PROTOCOL");
  global_request_path = rb_str_new2("PATH_INFO");
  global_fragment = rb_str_new2("FRAGMENT");

  for (size_t i = 0; i < NUM_COMMON_FIELDS; i++) {
    common_fields[i].interned = rb_enc_interned_str(common_fields[i].name, common_fields[i].len, rb_utf8_encoding());
    rb_global_variable(&common_fields[i].interned);
  }

  rb_define_alloc_func(cHttpParser, parser_alloc);
  rb_define_method(cHttpParser, "execute", parser_execute, 3);
  rb_define_method(cHttpParser, "finished?", parser_finished_p, 0);
  rb_define_method(cHttpParser, "has_body?", parser_has_body_p, 0);
  rb_define_method(cHttpParser, "chunked?", parser_chunked_p, 0);
  rb_define_method(cHttpParser, "content_length", parser_content_length, 0);
  rb_define_method(cHttpParser, "nread", parser_nread, 0);
  rb_define_method(cHttpParser, "reset", parser_reset, 0);
  rb_define_method(cHttpParser, "body", parser_body, 0);
}
