#define Array_t(T, N) struct { T data[N]; }

extern int printf(const char *format, ...);

int fill_arr(Array_t(int, 5) *arr) {
    for (int i = 0; i < 5; i++) {
        arr->data[i] = i * 10;
    }
    return 0;
}

int main()
{
    Array_t(int, 5) my_array;
    fill_arr(&my_array);
    for (int i = 0; i < 5; i++) {
        printf("%d\n", my_array.data[i]);
    }
    return 0;
}
