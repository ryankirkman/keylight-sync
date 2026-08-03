APP      := KeyLightSync
BUNDLE   := build/$(APP).app
BINARY   := $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES  := $(wildcard Sources/*.swift)

all: $(BINARY)

$(BINARY): $(SOURCES) Info.plist AppIcon.icns
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	swiftc -O $(SOURCES) -o $(BINARY)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)

# Regenerate AppIcon.icns from the drawing script (output is committed, so
# this only needs re-running when scripts/makeicon.swift changes).
icon:
	swift scripts/makeicon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o AppIcon.icns

run: all
	$(BINARY)

install: all
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	@echo "Installed to /Applications/$(APP).app — launch it with: open /Applications/$(APP).app"

# Update flow: rebuild from the current checkout, swap the installed app,
# and relaunch. Settings and login-item registration are preserved.
reinstall: all
	-pkill -x $(APP)
	$(MAKE) install
	open /Applications/$(APP).app
	@echo "Reinstalled and relaunched $(APP)."

uninstall:
	-/Applications/$(APP).app/Contents/MacOS/$(APP) --unregister-login-item
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	-defaults delete com.ryankirkman.keylightsync
	@echo "Uninstalled $(APP) (app, login item, and preferences removed)."

clean:
	rm -rf build

.PHONY: all run install reinstall uninstall icon clean
