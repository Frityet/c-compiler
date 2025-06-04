#!/bin/sh
set -e
input='int main() { return 1+2; }'
output=$(echo "$input" | ../bin/cc --ast)
expected="FUNC:main
  RETURN
    BIN:PLUS
      NUMBER:1
      NUMBER:2"
if [ "$output" != "$expected\n" ] && [ "$output" != "$expected" ]; then
  echo "AST output mismatch" >&2
  echo "Expected:\n$expected" >&2
  echo "Got:\n$output" >&2
  exit 1
fi
