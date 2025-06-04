#ifndef AST_H
#define AST_H

#include "token.h"

typedef enum {
    AST_FUNCTION,
    AST_RETURN,
    AST_BINARY,
    AST_INT_LITERAL,
    AST_VAR_DECL,
    AST_IDENTIFIER,
    AST_ASSIGN,
    AST_IF,
    AST_WHILE,
    AST_FOR,
    AST_EXPR_STMT
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
        struct {
            char *name;
            ASTNode *init;
        } var_decl;
        struct {
            char *name;
        } ident;
        struct {
            ASTNode *target;
            ASTNode *value;
        } assign;
        struct {
            ASTNode *cond;
            ASTNode *then_branch;
            ASTNode *else_branch;
        } if_stmt;
        struct {
            ASTNode *cond;
            ASTNode *body;
        } while_stmt;
        struct {
            ASTNode *init;
            ASTNode *cond;
            ASTNode *post;
            ASTNode *body;
        } for_stmt;
        struct {
            ASTNode *expr;
        } expr_stmt;
        int int_value;
    } data;
    ASTNode *next; /* for lists */
};

ASTNode *ast_new_function(const char *name, ASTNode *body);
ASTNode *ast_new_return(ASTNode *expr);
ASTNode *ast_new_binary(TokenType op, ASTNode *left, ASTNode *right);
ASTNode *ast_new_int_literal(int value);
ASTNode *ast_new_var_decl(const char *name, ASTNode *init);
ASTNode *ast_new_identifier(const char *name);
ASTNode *ast_new_assign(ASTNode *target, ASTNode *value);
ASTNode *ast_new_if(ASTNode *cond, ASTNode *then_branch, ASTNode *else_branch);
ASTNode *ast_new_while(ASTNode *cond, ASTNode *body);
ASTNode *ast_new_for(ASTNode *init, ASTNode *cond, ASTNode *post, ASTNode *body);
ASTNode *ast_new_expr_stmt(ASTNode *expr);
void ast_append(ASTNode **list, ASTNode *node);
void ast_free(ASTNode *node);
void ast_print(ASTNode *node, int indent);

#endif /* AST_H */
