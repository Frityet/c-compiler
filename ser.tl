local ffi = require("ffi")
ffi.cdef [[
    int printf(const char *format, ...);
]]

local pf = ffi.C.printf as ffi.Function<function(ffi.Function<nil>, fmt: string, ...: any)>

pf("hello %s\n", "world")
