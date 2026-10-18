# frozen_string_literal: true

require "mkmf"

# The Ragel-generated parser compares `char` values against 0, which GCC flags
# as always true where `char` is unsigned (e.g. aarch64 Linux).
append_cflags(["-fvisibility=hidden", "-Wno-type-limits"])

create_makefile("raptor/raptor_http")
