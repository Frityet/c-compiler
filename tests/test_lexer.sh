#!/bin/sh
set -e
input='int main() { return 1+2; }'
output=$(echo "$input" | ../bin/cc --tokens)
expected=$(cat <<'EOF'
INT:int
IDENT:main
LPAREN:(
RPAREN:)
LBRACE:{
RETURN:return
NUMBER:1
PLUS:+
NUMBER:2
SEMICOLON:;
RBRACE:}
EOF:
EOF
)
trim() { echo "$1" | sed 's/ ([0-9]*,[0-9]*)//'; }
if [ "$(trim "$output")" != "$(trim "$expected")" ]; then
  echo "Tokenization output mismatch" >&2
  echo "Expected:\n$expected" >&2
  echo "Got:\n$output" >&2
  exit 1
fi

