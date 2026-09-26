# fpga-webstream - built by Buildroot (linux/br2-external), or natively for a
# quick test on a PC:  make CIVETWEB_SRC=<civetweb checkout>/src ... (see README)
CFLAGS  ?= -O2
CFLAGS  += -Wall -Wextra -std=gnu11
LDLIBS  += -lcivetweb -lpthread

fpga-webstream: main.o page.o
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

main.o: main.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

page.o: page.S index.html
	$(CC) $(CPPFLAGS) -c -o $@ page.S

clean:
	rm -f fpga-webstream *.o

.PHONY: clean
