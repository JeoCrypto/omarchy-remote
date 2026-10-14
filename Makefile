# omarchy-remote: developed by JeoCrypto
# omarchy-remote
#   make            build the Mac viewer (omarchy-vnc)
#   make install    ./install.sh
#   make uninstall  ./uninstall.sh
#   make test       headless checks of the viewer's login handling
CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra

omarchy-vnc: src/omarchy-vnc.c
	$(CC) $(CFLAGS) $$(pkg-config --cflags sdl3 libvncclient) -o $@ $< $$(pkg-config --libs sdl3 libvncclient)

test/testserver: test/testserver.c
	$(CC) $(CFLAGS) $$(pkg-config --cflags libvncserver) -o $@ $< $$(pkg-config --libs libvncserver)

install:
	./install.sh

uninstall:
	./uninstall.sh

test: omarchy-vnc test/testserver
	./test/run.sh

clean:
	rm -f omarchy-vnc test/testserver

.PHONY: install uninstall test clean
