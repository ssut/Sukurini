APP := Sukurini
BUNDLE_ID := com.suhunhan.sukurini
DIST := dist/$(APP).app
IDENTITY ?= -
VERSION := $(shell tr -d '[:space:]' < VERSION 2>/dev/null)
BUILD ?= 0
ARCH := arm64
SWIFT_RELEASE := swift build -c release --arch $(ARCH)
FIXTURE_SRC := /System/Library/Desktop Pictures/Mac Blue.heic
FIXTURE_DIR := $(HOME)/SukuriniFixtures
TEST_DIR := $(HOME)/SukuriniTest
GOOGLE_PLIST := Support/GoogleService-Info.plist
UPLOAD_SYMBOLS := .build/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols
SPARKLE_NAME := Sparkle.framework
SPARKLE_DEST := $(DIST)/Contents/Frameworks/$(SPARKLE_NAME)
SPARKLE_VERSION_DIR := $(SPARKLE_DEST)/Versions/B
SPARKLE_TOOLS := .build/artifacts/sparkle/Sparkle/bin

.PHONY: build bundle sign run dev logs install fixtures stop clean upload-symbols

build:
	$(SWIFT_RELEASE)

bundle: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources $(DIST)/Contents/Frameworks
	cp -f "$$($(SWIFT_RELEASE) --show-bin-path)/$(APP)" $(DIST)/Contents/MacOS/$(APP)
	cp -f Support/Info.plist $(DIST)/Contents/Info.plist
	cp -f Support/AppIcon.icns $(DIST)/Contents/Resources/AppIcon.icns
	cp -f $(GOOGLE_PLIST) $(DIST)/Contents/Resources/GoogleService-Info.plist
	ditto "$$($(SWIFT_RELEASE) --show-bin-path)/$(SPARKLE_NAME)" $(SPARKLE_DEST)
	printf 'APPL????' > $(DIST)/Contents/PkgInfo
	@test -n "$(VERSION)" || { echo "version missing, VERSION file is empty or absent"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(DIST)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(DIST)/Contents/Info.plist
	@echo "version stamped short=$(VERSION) build=$(BUILD)"
	@ARCHS="$$(lipo -archs $(DIST)/Contents/MacOS/$(APP))"; \
	test "$$ARCHS" = "$(ARCH)" || { echo "arch check failed expected=$(ARCH) actual=$$ARCHS"; exit 1; }; \
	echo "arch check ok archs=$$ARCHS"

sign: bundle
	codesign --force --sign "$(IDENTITY)" --preserve-metadata=entitlements $(SPARKLE_VERSION_DIR)/XPCServices/Downloader.xpc
	codesign --force --sign "$(IDENTITY)" --preserve-metadata=entitlements $(SPARKLE_VERSION_DIR)/XPCServices/Installer.xpc
	codesign --force --sign "$(IDENTITY)" --preserve-metadata=entitlements $(SPARKLE_VERSION_DIR)/Updater.app
	codesign --force --sign "$(IDENTITY)" --preserve-metadata=entitlements $(SPARKLE_VERSION_DIR)/Autoupdate
	codesign --force --sign "$(IDENTITY)" $(SPARKLE_DEST)
	codesign --force --sign "$(IDENTITY)" $(DIST)
	codesign --verify --deep --strict $(DIST)
	codesign -dv $(DIST) 2>&1 | head -5

run: sign
	-pkill -x $(APP)
	open $(DIST)

dev:
	swift build
	-pkill -x $(APP)
	.build/debug/$(APP)

logs:
	log stream --predicate 'subsystem == "sukurini"' --level debug --style compact

install: sign
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	ditto $(DIST) /Applications/$(APP).app
	@echo "installed to /Applications/$(APP).app"

fixtures:
	mkdir -p "$(FIXTURE_DIR)" "$(TEST_DIR)"
	sips -s format png -Z 1200 "$(FIXTURE_SRC)" --out "$(FIXTURE_DIR)/fixture.png" >/dev/null
	printf 'SUKURINI OCR FIXTURE 20260726\n결제완료 영수증 스크린샷\ninvoice total 42000 KRW\n' > /tmp/sukurini-ocr.txt
	qlmanage -t -s 1400 -o "$(FIXTURE_DIR)" /tmp/sukurini-ocr.txt >/dev/null 2>&1
	@ls -1 "$(FIXTURE_DIR)"

upload-symbols: sign
	@test -x "$(UPLOAD_SYMBOLS)" || { echo "upload-symbols missing at $(UPLOAD_SYMBOLS), run 'swift package resolve' first"; exit 1; }
	@DSYM="$$($(SWIFT_RELEASE) --show-bin-path)/$(APP).dSYM"; \
	test -d "$$DSYM" || { echo "dSYM missing at $$DSYM"; exit 1; }; \
	APP_UUID="$$(dwarfdump --uuid $(DIST)/Contents/MacOS/$(APP) | awk '{print $$2}')"; \
	DSYM_UUID="$$(dwarfdump --uuid "$$DSYM" | awk '{print $$2}')"; \
	test -n "$$APP_UUID" -a "$$APP_UUID" = "$$DSYM_UUID" || { echo "uuid mismatch app=$$APP_UUID dsym=$$DSYM_UUID"; exit 1; }; \
	"$(UPLOAD_SYMBOLS)" -gsp "$(GOOGLE_PLIST)" -p mac -val -- "$$DSYM" && \
	"$(UPLOAD_SYMBOLS)" -gsp "$(GOOGLE_PLIST)" -p mac -- "$$DSYM" && \
	echo "uploaded dsym uuid=$$APP_UUID"

stop:
	-pkill -x $(APP)

clean:
	rm -rf .build dist
