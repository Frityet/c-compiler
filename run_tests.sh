#!/bin/sh
set -e
make clean >/dev/null
make >/dev/null
python3 -m unittest discover -s tests
