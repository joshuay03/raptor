# frozen_string_literal: true

require "mkmf"

append_cflags("-fvisibility=hidden")

create_makefile("raptor/raptor_native")
