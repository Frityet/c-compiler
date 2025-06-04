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
        }
    }
}

