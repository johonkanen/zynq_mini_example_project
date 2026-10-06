# fpga-web - web UI for the FPGA (talks to fpgad; never maps the hardware).
# Built by Buildroot (linux/br2-external/package/fpga-web).
CFLAGS  ?= -O2
CFLAGS  += -Wall -Wextra -std=gnu11
LDLIBS  += -lfpgad-client -lcivetweb -lpthread

fpga-web: main.o page.o
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

main.o: main.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

page.o: page.S index.html vendor/uPlot.iife.min.js vendor/uPlot.min.css
	$(CC) $(CPPFLAGS) -c -o $@ page.S

clean:
	rm -f fpga-web *.o

.PHONY: clean
