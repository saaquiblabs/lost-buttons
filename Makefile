PREFIX ?= /usr/local
SWIFTC ?= swiftc
FLAGS = -O -swift-version 5

build/lost-buttons: Sources/*.swift
	@mkdir -p build
	$(SWIFTC) $(FLAGS) Sources/*.swift -o $@

build/tests: Sources/Descriptor.swift Tests/main.swift
	@mkdir -p build
	$(SWIFTC) $(FLAGS) Sources/Descriptor.swift Tests/main.swift -o $@

.PHONY: test install uninstall clean
test: build/tests
	./build/tests

install: build/lost-buttons
	install -d $(PREFIX)/bin
	install -m 755 build/lost-buttons $(PREFIX)/bin/lost-buttons

uninstall:
	rm -f $(PREFIX)/bin/lost-buttons

clean:
	rm -rf build
