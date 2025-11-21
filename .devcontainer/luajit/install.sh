#!/bin/sh
set -e

echo "Cloning LuaJIT repository"
git clone https://github.com/LuaJIT/LuaJIT.git
cd LuaJIT

# Build LuaJIT
echo "Building LuaJIT"
make CC=clang
sudo make install

echo "Cleaning up"
cd ..
rm -rf LuaJIT
