#include "ruby.h"
#include "ruby/io.h"
#include <sys/uio.h>
#include <errno.h>
#include <limits.h>

static VALUE eEAGAINWaitWritable;

static VALUE raptor_native_writev_nonblock(VALUE self, VALUE io, VALUE strings) {
  Check_Type(strings, T_ARRAY);
  long len = RARRAY_LEN(strings);
  if (len == 0) return LONG2NUM(0);
  if (len > IOV_MAX) len = IOV_MAX;

  int fd = rb_io_descriptor(io);
  struct iovec *iov = alloca(len * sizeof(struct iovec));

  for (long i = 0; i < len; i++) {
    VALUE str = RARRAY_AREF(strings, i);
    Check_Type(str, T_STRING);
    iov[i].iov_base = RSTRING_PTR(str);
    iov[i].iov_len = RSTRING_LEN(str);
  }

  ssize_t written;
  while ((written = writev(fd, iov, (int)len)) < 0) {
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) rb_raise(eEAGAINWaitWritable, "writev would block");
    rb_sys_fail("writev");
  }

  return LONG2NUM((long)written);
}

RUBY_FUNC_EXPORTED void Init_raptor_native(void) {
  rb_ext_ractor_safe(true);

  VALUE mRaptor = rb_define_module("Raptor");
  VALUE mVectorIO = rb_define_module_under(mRaptor, "VectorIO");

  rb_define_singleton_method(mVectorIO, "writev_nonblock", raptor_native_writev_nonblock, 2);

  eEAGAINWaitWritable = rb_const_get(rb_cIO, rb_intern("EAGAINWaitWritable"));
  rb_global_variable(&eEAGAINWaitWritable);
}
