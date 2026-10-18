#ifdef __linux__
#define _GNU_SOURCE 1
#endif

#include "ruby.h"
#include "ruby/io.h"
#include <errno.h>
#include <limits.h>
#include <sys/uio.h>

#ifdef __linux__
#include <sched.h>
#include <sys/prctl.h>
#endif

static VALUE eEAGAINWaitWritable;

static VALUE vector_io_writev_nonblock(VALUE self, VALUE io, VALUE strings) {
  Check_Type(strings, T_ARRAY);
  long len = RARRAY_LEN(strings);
  if (len == 0) return LONG2NUM(0);
  if (len > IOV_MAX) len = IOV_MAX;

  int fd = rb_io_descriptor(io);
  struct iovec *iov = ALLOCA_N(struct iovec, len);

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

// Pins the calling thread to the Nth CPU of its current affinity mask, so
// worker indexes map onto the CPUs the process is actually allowed to use.
static VALUE cpu_pin(VALUE self, VALUE cpu) {
#ifdef __linux__
  int worker_index = NUM2INT(cpu);
  cpu_set_t current;
  CPU_ZERO(&current);
  if (sched_getaffinity(0, sizeof(current), &current) < 0) rb_sys_fail("sched_getaffinity");

  int cpu_id = -1;
  int seen = 0;
  for (int candidate = 0; candidate < CPU_SETSIZE; candidate++) {
    if (!CPU_ISSET(candidate, &current)) continue;
    if (seen == worker_index) {
      cpu_id = candidate;
      break;
    }
    seen++;
  }
  if (cpu_id < 0) return Qfalse;

  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu_id, &set);
  if (sched_setaffinity(0, sizeof(set), &set) < 0) rb_sys_fail("sched_setaffinity");
  return Qtrue;
#else
  return Qfalse;
#endif
}

static VALUE cpu_count(VALUE self) {
#ifdef __linux__
  cpu_set_t set;
  CPU_ZERO(&set);
  if (sched_getaffinity(0, sizeof(set), &set) < 0) rb_sys_fail("sched_getaffinity");
  return LONG2NUM((long)CPU_COUNT(&set));
#else
  return LONG2NUM(0);
#endif
}

static VALUE subreaper_enable(VALUE self) {
#if defined(__linux__) && defined(PR_SET_CHILD_SUBREAPER)
  if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) < 0) rb_sys_fail("prctl");
  return Qtrue;
#else
  return Qfalse;
#endif
}

RUBY_FUNC_EXPORTED void Init_raptor_native(void) {
  rb_ext_ractor_safe(true);

  rb_global_variable(&eEAGAINWaitWritable);
  eEAGAINWaitWritable = rb_const_get(rb_cIO, rb_intern("EAGAINWaitWritable"));

  VALUE mRaptor = rb_define_module("Raptor");

  VALUE mVectorIO = rb_define_module_under(mRaptor, "VectorIO");
  rb_define_singleton_method(mVectorIO, "writev_nonblock", vector_io_writev_nonblock, 2);

  VALUE mCPU = rb_define_module_under(mRaptor, "CPU");
  rb_define_singleton_method(mCPU, "pin", cpu_pin, 1);
  rb_define_singleton_method(mCPU, "count", cpu_count, 0);

  VALUE mSubreaper = rb_define_module_under(mRaptor, "Subreaper");
  rb_define_singleton_method(mSubreaper, "enable", subreaper_enable, 0);
}
