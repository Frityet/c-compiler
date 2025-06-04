#include "cc.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        printf("cc version 0.1\n");
        return 0;
    }
    printf("Minimal C compiler placeholder\n");
    return 0;
}
