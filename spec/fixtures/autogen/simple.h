typedef struct Foo {
    int x;
} Foo;

typedef int (*Callback)(int a);

int foo(Foo* f, Callback cb);
