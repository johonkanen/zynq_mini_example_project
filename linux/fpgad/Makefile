# fpgad - FPGA access daemon + fpgactl + libfpgad-client.a
# Built by Buildroot (linux/br2-external/package/fpgad), or natively: make
CFLAGS  ?= -O2
CFLAGS  += -Wall -Wextra -std=gnu11
AR      ?= ar

all: fpgad fpgactl libfpgad-client.a

fpgad: fpgad.o
	$(CC) $(LDFLAGS) -o $@ $^ -lpthread -lm

fpgactl: fpgactl.o libfpgad-client.a
	$(CC) $(LDFLAGS) -o $@ fpgactl.o -L. -lfpgad-client

libfpgad-client.a: fpgad_client.o
	$(AR) rcs $@ $^

%.o: %.c fpgad_client.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

clean:
	rm -f fpgad fpgactl libfpgad-client.a *.o

.PHONY: all clean
