#!/bin/sh
set -e
make clean >/dev/null
make >/dev/null
cd tests
./test_version.sh
cd ..
