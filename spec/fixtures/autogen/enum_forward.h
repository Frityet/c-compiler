enum Kind;

int get_kind(enum Kind value);

typedef struct Later Later;

enum Kind {
    KIND_A,
    KIND_B
};

struct Later {
    int field;
};

struct Later;

enum Kind make_kind(void);
int use_later(Later *ptr);
