return {
   build_dir = "build",
   source_dir = "src",
   include_dir = { "src",  "types/extern/types/luajit", "types/", "types/extern/types/penlight", "types/extern/types/luafilesystem", },
   gen_compat = "required",
   gen_target = "5.1",
   -- Skip pruning entirely; build/ contains vendored binaries (stringzilla) we want to keep.
   dont_prune = { "**" },
}
