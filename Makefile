APP      = Vestitel.app
BINARY   = .build/release/Vestitel
CONTENTS = $(APP)/Contents

.PHONY: app build run clean icon

# regenerate Resources/AppIcon.icns from the drawing script
icon:
	swift Tools/make-icon.swift .build/Vestitel.iconset
	iconutil -c icns .build/Vestitel.iconset -o Resources/AppIcon.icns
	rm -rf .build/Vestitel.iconset

app: build
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY) $(CONTENTS)/MacOS/Vestitel
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	codesign --force --sign - $(APP)
	@echo "Built $(APP) — run 'make run' or double-click it."

build:
	swift build -c release

run: app
	open $(APP)

clean:
	swift package clean
	rm -rf $(APP)
