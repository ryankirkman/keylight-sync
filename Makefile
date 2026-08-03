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

uninstall:
	-/Applications/$(APP).app/Contents/MacOS/$(APP) --unregister-login-item
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	-defaults delete com.ryankirkman.keylightsync
	@echo "Uninstalled $(APP) (app, login item, and preferences removed)."

clean:
	rm -rf build

.PHONY: all run install uninstall clean
