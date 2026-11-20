PREFIX ?= /usr/local
SWIFTC ?= swiftc
FLAGS = -O -swift-version 5
VERSION := $(shell sed -n 's/^let version = "\(.*\)"/\1/p' Sources/main.swift)
APP = build/Lost Buttons.app
BUNDLE_ID = com.saaquiblabs.lost-buttons

build/lost-buttons: Sources/*.swift
	@mkdir -p build
	$(SWIFTC) $(FLAGS) Sources/*.swift -o $@

build/tests: Sources/Descriptor.swift Tests/main.swift
	@mkdir -p build
	$(SWIFTC) $(FLAGS) Sources/Descriptor.swift Tests/main.swift -o $@

# The app bundle: same binary, plus a name and icon macOS shows in Login Items and Privacy lists.
# Signed ad hoc (no Apple account needed) so the signature carries our bundle ID.
app: build/lost-buttons Resources/Info.plist Resources/AppIcon.icns Resources/com.saaquiblabs.lost-buttons.plist
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Library/LaunchAgents"
	cp build/lost-buttons "$(APP)/Contents/MacOS/lost-buttons"
	sed 's/@VERSION@/$(VERSION)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp Resources/com.saaquiblabs.lost-buttons.plist "$(APP)/Contents/Library/LaunchAgents/"
	codesign --force --sign - --identifier $(BUNDLE_ID) "$(APP)"

# Rebuilds Resources/AppIcon.icns from the logo PNGs (only needed when the logo changes).
icon:
	rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	for pair in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 \
	            256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do \
	  cp docs/logo/lost-buttons-$${pair#*:}.png build/AppIcon.iconset/icon_$${pair%%:*}.png; done
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

.PHONY: test app icon install uninstall clean
test: build/tests
	./build/tests

install: app
	rm -rf "$(PREFIX)/Lost Buttons.app"
	install -d $(PREFIX)/bin
	cp -R "$(APP)" "$(PREFIX)/Lost Buttons.app"
	ln -sf "$(PREFIX)/Lost Buttons.app/Contents/MacOS/lost-buttons" $(PREFIX)/bin/lost-buttons

uninstall:
	rm -rf "$(PREFIX)/Lost Buttons.app" $(PREFIX)/bin/lost-buttons

clean:
	rm -rf build
