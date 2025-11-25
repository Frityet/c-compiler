#!/bin/sh

TL_DIR="$(pwd)/extern/tl"
./lua\
    -e "package.path=\"$TL_DIR/?.lua;$TL_DIR/?/init.lua;\"..package.path"\
    "$TL_DIR/tl" "$@"
