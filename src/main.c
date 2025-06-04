#include "cc.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static char *read_stdin(void) {
    size_t size = 0;
    size_t cap = 1024;
    char *buf = malloc(cap);
    if (buf == NULL) {
        fprintf(stderr, "Error: Memory allocation failed\n");
        exit(EXIT_FAILURE);
    }
    int c;
    while ((c = getchar()) != EOF) {
        if (size + 1 >= cap) {
            cap *= 2;
            char *new_buf = realloc(buf, cap);
            if (new_buf == NULL) {
                fprintf(stderr, "Error: Memory reallocation failed\n");
                free(buf);
                exit(EXIT_FAILURE);
            }
            buf = new_buf;
        }
        buf[size++] = (char)c;
    }
    buf[size] = '\0';
    return buf;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        printf("cc version 0.1\n");
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "--tokens") == 0) {
        char *src = read_stdin();
        print_tokens(src);
        free(src);
        return 0;
    }
    printf("Minimal C compiler placeholder\n");
    return 0;
}
