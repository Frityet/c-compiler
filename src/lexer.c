#include "token.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *src;
    size_t pos;
    int line;
    int col;
} Lexer;

static char peek(Lexer *lx) {
    return lx->src[lx->pos];
}

static char advance(Lexer *lx) {
    char c = lx->src[lx->pos++];
    if (c == '\n') {
        lx->line++;
        lx->col = 1;
    } else {
        lx->col++;
    }
    return c;
}

static void skip_whitespace(Lexer *lx) {
    char c = peek(lx);
    while (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        advance(lx);
        c = peek(lx);
    }
}

static int is_identifier_start(char c) {
    return isalpha((unsigned char)c) || c == '_';
}

static int is_identifier_part(char c) {
    return isalnum((unsigned char)c) || c == '_';
}

static Token make_token(Lexer *lx, TokenType type, const char *start, size_t len, int line, int col) {
    Token tok;
    tok.type = type;
    tok.lexeme = (char *)malloc(len + 1);
    memcpy(tok.lexeme, start, len);
    tok.lexeme[len] = '\0';
    tok.line = line;
    tok.column = col;
    return tok;
}

void lexer_init(Lexer *lx, const char *source) {
    lx->src = source;
    lx->pos = 0;
    lx->line = 1;
    lx->col = 1;
}

Token lexer_next_token(Lexer *lx) {
    skip_whitespace(lx);
    int line = lx->line;
    int col = lx->col;
    char c = peek(lx);

    if (c == '\0') {
        return make_token(lx, TOKEN_EOF, "", 0, line, col);
    }

    if (is_identifier_start(c)) {
        const char *start = lx->src + lx->pos;
        advance(lx); /* consume first char */
        while (is_identifier_part(peek(lx))) {
            advance(lx);
        }
        size_t len = (lx->src + lx->pos) - start;
        // check for keywords
        if (len == 3 && strncmp(start, "int", 3) == 0) {
            return make_token(lx, TOKEN_INT, start, len, line, col);
        } else if (len == 6 && strncmp(start, "return", 6) == 0) {
            return make_token(lx, TOKEN_RETURN, start, len, line, col);
        }
        return make_token(lx, TOKEN_IDENTIFIER, start, len, line, col);
    }

    if (isdigit((unsigned char)c)) {
        const char *start = lx->src + lx->pos;
        advance(lx);
        while (isdigit((unsigned char)peek(lx))) {
            advance(lx);
        }
        size_t len = (lx->src + lx->pos) - start;
        return make_token(lx, TOKEN_NUMBER, start, len, line, col);
    }

    advance(lx);
    switch (c) {
        case '+': return make_token(lx, TOKEN_PLUS, "+", 1, line, col);
        case '-': return make_token(lx, TOKEN_MINUS, "-", 1, line, col);
        case '*': return make_token(lx, TOKEN_STAR, "*", 1, line, col);
        case '/': return make_token(lx, TOKEN_SLASH, "/", 1, line, col);
        case ';': return make_token(lx, TOKEN_SEMICOLON, ";", 1, line, col);
        case '(': return make_token(lx, TOKEN_LPAREN, "(", 1, line, col);
        case ')': return make_token(lx, TOKEN_RPAREN, ")", 1, line, col);
        case '{': return make_token(lx, TOKEN_LBRACE, "{", 1, line, col);
        case '}': return make_token(lx, TOKEN_RBRACE, "}", 1, line, col);
        default: return make_token(lx, TOKEN_UNKNOWN, &c, 1, line, col);
    }
}

const char *token_type_name(TokenType type) {
    switch (type) {
        case TOKEN_EOF: return "EOF";
        case TOKEN_IDENTIFIER: return "IDENT";
        case TOKEN_NUMBER: return "NUMBER";
        case TOKEN_INT: return "INT";
        case TOKEN_RETURN: return "RETURN";
        case TOKEN_PLUS: return "PLUS";
        case TOKEN_MINUS: return "MINUS";
        case TOKEN_STAR: return "STAR";
        case TOKEN_SLASH: return "SLASH";
        case TOKEN_SEMICOLON: return "SEMICOLON";
        case TOKEN_LPAREN: return "LPAREN";
        case TOKEN_RPAREN: return "RPAREN";
        case TOKEN_LBRACE: return "LBRACE";
        case TOKEN_RBRACE: return "RBRACE";
        case TOKEN_UNKNOWN: return "UNKNOWN";
        default: return "?";
    }
}

void free_token(Token tok) {
    free(tok.lexeme);
}

void print_tokens(const char *source) {
    Lexer lx;
    lexer_init(&lx, source);
    for (;;) {
        Token tok = lexer_next_token(&lx);
        printf("%s:%s (%d,%d)\n", token_type_name(tok.type), tok.lexeme, tok.line, tok.column);
        if (tok.type == TOKEN_EOF) {
            free_token(tok);
            break;
        }
        free_token(tok);
    }
}

