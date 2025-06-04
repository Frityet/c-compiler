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
static ASTNode *parse_block(Parser *p);
static ASTNode *parse_statement_or_block(Parser *p);
static void skip_declaration(Parser *p);
static int is_function_start(Parser *p);

static ASTNode *parse_primary(Parser *p) {
    if (p->current.type == TOKEN_NUMBER) {
        Token t = parser_take(p);
        int val = atoi(t.lexeme);
        free_token(t);
        return ast_new_int_literal(val);
    } else if (p->current.type == TOKEN_IDENTIFIER) {
        char *name = strdup(p->current.lexeme);
        parser_advance(p);
        return ast_new_identifier(name);
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

static ASTNode *parse_term(Parser *p) {
    ASTNode *node = parse_factor(p);
    while (p->current.type == TOKEN_PLUS || p->current.type == TOKEN_MINUS) {
        TokenType op = p->current.type;
        parser_advance(p);
        ASTNode *right = parse_factor(p);
        node = ast_new_binary(op, node, right);
    }
    return node;
}

static ASTNode *parse_relational(Parser *p) {
    ASTNode *node = parse_term(p);
    while (p->current.type == TOKEN_LT || p->current.type == TOKEN_GT ||
           p->current.type == TOKEN_LEQ || p->current.type == TOKEN_GEQ) {
        TokenType op = p->current.type;
        parser_advance(p);
        ASTNode *right = parse_term(p);
        node = ast_new_binary(op, node, right);
    }
    return node;
}

static ASTNode *parse_equality(Parser *p) {
    ASTNode *node = parse_relational(p);
    while (p->current.type == TOKEN_EQ || p->current.type == TOKEN_NEQ) {
        TokenType op = p->current.type;
        parser_advance(p);
        ASTNode *right = parse_relational(p);
        node = ast_new_binary(op, node, right);
    }
    return node;
}

static ASTNode *parse_assignment(Parser *p) {
    ASTNode *node = parse_equality(p);
    if (p->current.type == TOKEN_ASSIGN) {
        if (node->type != AST_IDENTIFIER) {
            fprintf(stderr, "Left side of assignment must be identifier\n");
            exit(EXIT_FAILURE);
        }
        parser_advance(p);
        ASTNode *value = parse_assignment(p);
        node = ast_new_assign(node, value);
    }
    return node;
}

static ASTNode *parse_expr(Parser *p) {
    return parse_assignment(p);
}

static ASTNode *parse_statement(Parser *p) {
    if (parser_match(p, TOKEN_RETURN)) {
        ASTNode *expr = parse_expr(p);
        parser_expect(p, TOKEN_SEMICOLON, ";");
        return ast_new_return(expr);
    } else if (parser_match(p, TOKEN_INT)) {
        if (p->current.type != TOKEN_IDENTIFIER) {
            fprintf(stderr, "Expected variable name\n");
            exit(EXIT_FAILURE);
        }
        char *name = strdup(p->current.lexeme);
        parser_advance(p);
        ASTNode *init = NULL;
        if (parser_match(p, TOKEN_ASSIGN)) {
            init = parse_expr(p);
        }
        parser_expect(p, TOKEN_SEMICOLON, ";");
        return ast_new_var_decl(name, init);
    } else if (parser_match(p, TOKEN_IF)) {
        parser_expect(p, TOKEN_LPAREN, "(");
        ASTNode *cond = parse_expr(p);
        parser_expect(p, TOKEN_RPAREN, ")");
        ASTNode *then_branch = parse_statement_or_block(p);
        ASTNode *else_branch = NULL;
        if (parser_match(p, TOKEN_ELSE)) {
            else_branch = parse_statement_or_block(p);
        }
        return ast_new_if(cond, then_branch, else_branch);
    } else if (parser_match(p, TOKEN_WHILE)) {
        parser_expect(p, TOKEN_LPAREN, "(");
        ASTNode *cond = parse_expr(p);
        parser_expect(p, TOKEN_RPAREN, ")");
        ASTNode *body = parse_statement_or_block(p);
        return ast_new_while(cond, body);
    } else if (parser_match(p, TOKEN_FOR)) {
        parser_expect(p, TOKEN_LPAREN, "(");
        ASTNode *init = NULL;
        if (p->current.type != TOKEN_SEMICOLON) {
            init = parse_expr(p);
        }
        parser_expect(p, TOKEN_SEMICOLON, ";");
        ASTNode *cond = NULL;
        if (p->current.type != TOKEN_SEMICOLON) {
            cond = parse_expr(p);
        }
        parser_expect(p, TOKEN_SEMICOLON, ";");
        ASTNode *post = NULL;
        if (p->current.type != TOKEN_RPAREN) {
            post = parse_expr(p);
        }
        parser_expect(p, TOKEN_RPAREN, ")");
        ASTNode *body = parse_statement_or_block(p);
        return ast_new_for(init, cond, post, body);
    } else if (p->current.type == TOKEN_LBRACE) {
        return parse_block(p);
    } else {
        ASTNode *expr = parse_expr(p);
        parser_expect(p, TOKEN_SEMICOLON, ";");
        return ast_new_expr_stmt(expr);
    }
}

static ASTNode *parse_statement_or_block(Parser *p) {
    if (p->current.type == TOKEN_LBRACE) {
        return parse_block(p);
    }
    return parse_statement(p);
}

static void skip_declaration(Parser *p) {
    int brace_depth = 0;
    while (p->current.type != TOKEN_EOF) {
        if (p->current.type == TOKEN_SEMICOLON && brace_depth == 0) {
            parser_advance(p);
            break;
        }
        if (p->current.type == TOKEN_LBRACE) {
            brace_depth++;
        } else if (p->current.type == TOKEN_RBRACE) {
            if (brace_depth > 0) brace_depth--;
        }
        parser_advance(p);
    }
}

static int is_function_start(Parser *p) {
    if (p->current.type != TOKEN_INT)
        return 0;
    Lexer tmp = p->lx;
    Token t1 = lexer_next_token(&tmp);
    Token t2 = lexer_next_token(&tmp);
    int ok = (t1.type == TOKEN_IDENTIFIER && t2.type == TOKEN_LPAREN);
    free_token(t1);
    free_token(t2);
    return ok;
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
    ASTNode *list = NULL;
    while (p.current.type != TOKEN_EOF) {
        if (is_function_start(&p)) {
            ASTNode *func = parse_function(&p);
            ast_append(&list, func);
        } else {
            skip_declaration(&p);
        }
    }
    free_token(p.current);
    return list;
}

void print_ast(const char *source) {
    ASTNode *root = parse_source(source);
    ast_print(root, 0);
    ast_free(root);
}

