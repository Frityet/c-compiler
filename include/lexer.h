#ifndef LEXER_H
#define LEXER_H

#include "token.h"

typedef struct {
    const char *src;
    size_t pos;
    int line;
    int col;
} Lexer;

void lexer_init(Lexer *lx, const char *source);
Token lexer_next_token(Lexer *lx);
void print_tokens(const char *source);

#endif /* LEXER_H */
