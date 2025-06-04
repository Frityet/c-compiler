CC=gcc
CFLAGS=-Iinclude -Wall -Wextra -g
SRCS=$(wildcard src/*.c)
OBJS=$(SRCS:.c=.o)
BINARY=bin/cc

default: $(BINARY)

$(BINARY): $(OBJS) | bin
	$(CC) $(CFLAGS) -o $@ $(OBJS)

bin:
	mkdir -p bin

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(BINARY)

.PHONY: clean
