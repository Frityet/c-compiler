#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Token parser_take(Parser *p) {
    Token tok = p->current;
    p->current = lexer_next_token(&p->lx);
    return tok;
}

static void parser_advance(Parser *p) {
    free_token(parser_take(p));
}

static int parser_match(Parser *p, TokenType type) {
    if (p->current.type == type) {
        parser_advance(p);
        return 1;
    }
    return 0;
}

static void parser_expect(Parser *p, TokenType type, const char *msg) {
    if (p->current.type != type) {
        fprintf(stderr, "Parse error at %d:%d: expected %s\n", p->current.line, p->current.column, msg);
        exit(EXIT_FAILURE);
    }
    parser_advance(p);
}

void parser_init(Parser *p, const char *source) {
    lexer_init(&p->lx, source);
    p->current = lexer_next_token(&p->lx);
}

static ASTNode *parse_expr(Parser *p);

static ASTNode *parse_primary(Parser *p) {
    if (p->current.type == TOKEN_NUMBER) {
        Token t = parser_take(p);
        int val = atoi(t.lexeme);
        free_token(t);
        return ast_new_int_literal(val);
    } else if (parser_match(p, TOKEN_LPAREN)) {
        ASTNode *e = parse_expr(p);
        parser_expect(p, TOKEN_RPAREN, ")");
        return e;
    } else {
        fprintf(stderr, "Unexpected token %s\n", token_type_name(p->current.type));
        exit(EXIT_FAILURE);
    }
}

static ASTNode *parse_factor(Parser *p) {
    ASTNode *node = parse_primary(p);
    while (p->current.type == TOKEN_STAR || p->current.type == TOKEN_SLASH) {
        TokenType op = p->current.type;
        parser_advance(p);
        ASTNode *right = parse_primary(p);
        node = ast_new_binary(op, node, right);
    }
    return node;
}

static ASTNode *parse_expr(Parser *p) {
    ASTNode *node = parse_factor(p);
    while (p->current.type == TOKEN_PLUS || p->current.type == TOKEN_MINUS) {
        TokenType op = p->current.type;
        parser_advance(p);
        ASTNode *right = parse_factor(p);
        node = ast_new_binary(op, node, right);
    }
    return node;
}

static ASTNode *parse_statement(Parser *p) {
    if (parser_match(p, TOKEN_RETURN)) {
        ASTNode *expr = parse_expr(p);
        parser_expect(p, TOKEN_SEMICOLON, ";");
        return ast_new_return(expr);
    }
    fprintf(stderr, "Unknown statement starting with %s\n", token_type_name(p->current.type));
    exit(EXIT_FAILURE);
}

static ASTNode *parse_block(Parser *p) {
    ASTNode *list = NULL;
    parser_expect(p, TOKEN_LBRACE, "{");
    while (p->current.type != TOKEN_RBRACE && p->current.type != TOKEN_EOF) {
        ASTNode *stmt = parse_statement(p);
        ast_append(&list, stmt);
    }
    parser_expect(p, TOKEN_RBRACE, "}");
    return list;
}

static ASTNode *parse_function(Parser *p) {
    parser_expect(p, TOKEN_INT, "int");
    if (p->current.type != TOKEN_IDENTIFIER) {
        fprintf(stderr, "Expected function name\n");
        exit(EXIT_FAILURE);
    }
    char *name = strdup(p->current.lexeme);
    parser_advance(p);
    parser_expect(p, TOKEN_LPAREN, "(");
    parser_expect(p, TOKEN_RPAREN, ")");
    ASTNode *body = parse_block(p);
    return ast_new_function(name, body);
}

ASTNode *parse_source(const char *source) {
    Parser p;
    parser_init(&p, source);
    ASTNode *func = parse_function(&p);
    free_token(p.current);
    return func;
}

void print_ast(const char *source) {
    ASTNode *root = parse_source(source);
    ast_print(root, 0);
    ast_free(root);
}

