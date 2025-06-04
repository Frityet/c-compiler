#ifndef AST_H
#define AST_H

#include "token.h"

typedef enum {
    AST_FUNCTION,
    AST_RETURN,
    AST_BINARY,
    AST_INT_LITERAL
} ASTNodeType;

struct ASTNode;

typedef struct ASTNode ASTNode;

struct ASTNode {
    ASTNodeType type;
    union {
        struct {
            char *name;
            ASTNode *body; /* linked list of statements */
        } func;
        struct {
            ASTNode *expr;
        } ret;
        struct {
            TokenType op;
            ASTNode *left;
            ASTNode *right;
        } binary;
        int int_value;
    } data;
    ASTNode *next; /* for lists */
};

ASTNode *ast_new_function(const char *name, ASTNode *body);
ASTNode *ast_new_return(ASTNode *expr);
ASTNode *ast_new_binary(TokenType op, ASTNode *left, ASTNode *right);
ASTNode *ast_new_int_literal(int value);
void ast_append(ASTNode **list, ASTNode *node);
void ast_free(ASTNode *node);
void ast_print(ASTNode *node, int indent);

#endif /* AST_H */
