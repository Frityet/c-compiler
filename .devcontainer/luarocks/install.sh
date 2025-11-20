#!/bin/sh
set -e

execho() {
    local prog="$1"
    shift
    echo -e "$ \e[32m$prog\e[0m $*"
    "$prog" "$@"
	return $?
}

LUAROCKS_URL="http://luarocks.github.io/luarocks/releases/luarocks-$VERSION.tar.gz"

execho curl -fL "$LUAROCKS_URL" -o /tmp/luarocks.tar.gz
execho tar -C /tmp/ -xzf /tmp/luarocks.tar.gz
BUILD_DIR="/tmp/luarocks-$VERSION"

cd "$BUILD_DIR"
INSTALL_DIR="/usr/local"
execho ./configure --with-lua-include="$INSTALL_DIR/include/luajit-2.1"
execho make
execho su vscode -c 'sudo make install'
execho su vscode -c 'luarocks config local_by_default true'
