# frozen_string_literal: true

require "mkmf"

append_cflags(["-fvisibility=hidden", "-Wno-type-limits"])

create_makefile("raptor/raptor_http")
