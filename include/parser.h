#ifndef PARSER_H
#define PARSER_H

#include "lexer.h"
#include "ast.h"

typedef struct {
    Lexer lx;
    Token current;
} Parser;

void parser_init(Parser *p, const char *source);
ASTNode *parse_source(const char *source);
void print_ast(const char *source);

#endif /* PARSER_H */
