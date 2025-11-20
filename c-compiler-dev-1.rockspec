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
   "lua ~> 5.1"
}
build_dependencies = {
   "cyan",
   "tl",
   "luarocks-build-cyan"
}
build = {
   type = "builtin",
}
test_dependencies = {
   "busted"
}
