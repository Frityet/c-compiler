#include "ast.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

ASTNode *ast_new_function(const char *name, ASTNode *body) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_FUNCTION;
    node->data.func.name = strdup(name);
    node->data.func.body = body;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_return(ASTNode *expr) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_RETURN;
    node->data.ret.expr = expr;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_binary(TokenType op, ASTNode *left, ASTNode *right) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_BINARY;
    node->data.binary.op = op;
    node->data.binary.left = left;
    node->data.binary.right = right;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_int_literal(int value) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_INT_LITERAL;
    node->data.int_value = value;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_var_decl(const char *name, ASTNode *init) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_VAR_DECL;
    node->data.var_decl.name = strdup(name);
    node->data.var_decl.init = init;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_identifier(const char *name) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_IDENTIFIER;
    node->data.ident.name = strdup(name);
    node->next = NULL;
    return node;
}

ASTNode *ast_new_assign(ASTNode *target, ASTNode *value) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_ASSIGN;
    node->data.assign.target = target;
    node->data.assign.value = value;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_if(ASTNode *cond, ASTNode *then_branch, ASTNode *else_branch) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_IF;
    node->data.if_stmt.cond = cond;
    node->data.if_stmt.then_branch = then_branch;
    node->data.if_stmt.else_branch = else_branch;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_while(ASTNode *cond, ASTNode *body) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_WHILE;
    node->data.while_stmt.cond = cond;
    node->data.while_stmt.body = body;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_for(ASTNode *init, ASTNode *cond, ASTNode *post, ASTNode *body) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_FOR;
    node->data.for_stmt.init = init;
    node->data.for_stmt.cond = cond;
    node->data.for_stmt.post = post;
    node->data.for_stmt.body = body;
    node->next = NULL;
    return node;
}

ASTNode *ast_new_expr_stmt(ASTNode *expr) {
    ASTNode *node = malloc(sizeof(ASTNode));
    node->type = AST_EXPR_STMT;
    node->data.expr_stmt.expr = expr;
    node->next = NULL;
    return node;
}

void ast_append(ASTNode **list, ASTNode *node) {
    if (*list == NULL) {
        *list = node;
    } else {
        ASTNode *cur = *list;
        while (cur->next) cur = cur->next;
        cur->next = node;
    }
}

void ast_free(ASTNode *node) {
    while (node) {
        ASTNode *next = node->next;
        switch (node->type) {
            case AST_FUNCTION:
                free(node->data.func.name);
                ast_free(node->data.func.body);
                break;
            case AST_RETURN:
                ast_free(node->data.ret.expr);
                break;
            case AST_BINARY:
                ast_free(node->data.binary.left);
                ast_free(node->data.binary.right);
                break;
            case AST_INT_LITERAL:
                break;
            case AST_VAR_DECL:
                free(node->data.var_decl.name);
                if (node->data.var_decl.init) ast_free(node->data.var_decl.init);
                break;
            case AST_IDENTIFIER:
                free(node->data.ident.name);
                break;
            case AST_ASSIGN:
                ast_free(node->data.assign.target);
                ast_free(node->data.assign.value);
                break;
            case AST_IF:
                ast_free(node->data.if_stmt.cond);
                ast_free(node->data.if_stmt.then_branch);
                ast_free(node->data.if_stmt.else_branch);
                break;
            case AST_WHILE:
                ast_free(node->data.while_stmt.cond);
                ast_free(node->data.while_stmt.body);
                break;
            case AST_FOR:
                ast_free(node->data.for_stmt.init);
                ast_free(node->data.for_stmt.cond);
                ast_free(node->data.for_stmt.post);
                ast_free(node->data.for_stmt.body);
                break;
            case AST_EXPR_STMT:
                ast_free(node->data.expr_stmt.expr);
                break;
        }
        free(node);
        node = next;
    }
}

static void print_indent(int n) {
    for (int i = 0; i < n; i++) putchar(' ');
}

void ast_print(ASTNode *node, int indent) {
    for (; node; node = node->next) {
        print_indent(indent);
        switch (node->type) {
            case AST_FUNCTION:
                printf("FUNC:%s\n", node->data.func.name);
                ast_print(node->data.func.body, indent + 2);
                break;
            case AST_RETURN:
                printf("RETURN\n");
                ast_print(node->data.ret.expr, indent + 2);
                break;
            case AST_BINARY:
                printf("BIN:%s\n", token_type_name(node->data.binary.op));
                ast_print(node->data.binary.left, indent + 2);
                ast_print(node->data.binary.right, indent + 2);
                break;
            case AST_INT_LITERAL:
                printf("NUMBER:%d\n", node->data.int_value);
                break;
            case AST_VAR_DECL:
                printf("VAR:%s\n", node->data.var_decl.name);
                if (node->data.var_decl.init) {
                    print_indent(indent + 2);
                    printf("INIT\n");
                    ast_print(node->data.var_decl.init, indent + 4);
                }
                break;
            case AST_IDENTIFIER:
                printf("IDENT:%s\n", node->data.ident.name);
                break;
            case AST_ASSIGN:
                printf("ASSIGN\n");
                ast_print(node->data.assign.target, indent + 2);
                ast_print(node->data.assign.value, indent + 2);
                break;
            case AST_IF:
                printf("IF\n");
                print_indent(indent + 2);
                printf("COND\n");
                ast_print(node->data.if_stmt.cond, indent + 4);
                print_indent(indent + 2);
                printf("THEN\n");
                ast_print(node->data.if_stmt.then_branch, indent + 4);
                if (node->data.if_stmt.else_branch) {
                    print_indent(indent + 2);
                    printf("ELSE\n");
                    ast_print(node->data.if_stmt.else_branch, indent + 4);
                }
                break;
            case AST_WHILE:
                printf("WHILE\n");
                print_indent(indent + 2);
                printf("COND\n");
                ast_print(node->data.while_stmt.cond, indent + 4);
                print_indent(indent + 2);
                printf("BODY\n");
                ast_print(node->data.while_stmt.body, indent + 4);
                break;
            case AST_FOR:
                printf("FOR\n");
                if (node->data.for_stmt.init) {
                    print_indent(indent + 2);
                    printf("INIT\n");
                    ast_print(node->data.for_stmt.init, indent + 4);
                }
                if (node->data.for_stmt.cond) {
                    print_indent(indent + 2);
                    printf("COND\n");
                    ast_print(node->data.for_stmt.cond, indent + 4);
                }
                if (node->data.for_stmt.post) {
                    print_indent(indent + 2);
                    printf("POST\n");
                    ast_print(node->data.for_stmt.post, indent + 4);
                }
                print_indent(indent + 2);
                printf("BODY\n");
                ast_print(node->data.for_stmt.body, indent + 4);
                break;
            case AST_EXPR_STMT:
                printf("EXPR\n");
                ast_print(node->data.expr_stmt.expr, indent + 2);
                break;
        }
    }
}

