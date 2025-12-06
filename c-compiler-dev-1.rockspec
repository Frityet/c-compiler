rockspec_format = "3.0"
package = "c-compiler"
version = "dev-1"
source = {
   url = "git+https://github.com/Frityet/c-compiler.git"
}
description = {
   homepage = "https://github.com/Frityet/c-compiler",
   license = "GPLv3"
}
dependencies = {
   "lua ~> 5.1",
   "argparse",
   "luafilesystem"
}
build_dependencies = {
   "luarocks-build-xmake"
}
build = {
   type = "xmake",

   install = {
      lua = {
         ["tl"] = "extern/tl/tl.lua",
         ["reflect"] = "reflect.lua"
      },
   }
}
test_dependencies = {
   "busted"
}
