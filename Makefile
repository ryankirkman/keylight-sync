APP      := KeyLightSync
BUNDLE   := build/$(APP).app
BINARY   := $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES  := $(wildcard Sources/*.swift)

all: $(BINARY)

$(BINARY): $(SOURCES) Info.plist
	mkdir -p $(BUNDLE)/Contents/MacOS
	swiftc -O $(SOURCES) -o $(BINARY)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

run: all
	$(BINARY)

install: all
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	@echo "Installed to /Applications/$(APP).app — launch it with: open /Applications/$(APP).app"

clean:
	rm -rf build

.PHONY: all run install clean
