# armedit - every line of this project is assembled from .S sources.
#
#   make            build everything buildable on this host
#   make tty        hosted mode, terminal
#   make window     hosted mode, macOS window
#   make kernel     bare-metal aarch64 kernel (ELF, for QEMU virt)
#   make run        run the terminal mode
#   make win        run the window mode
#   make boot       boot the kernel with a framebuffer
#   make boot-tty   boot the kernel headless, serial on this terminal
#
# Two assemblers, one source tree: Mach-O for the host binaries, bare ELF for
# the kernel.  include/asm.inc absorbs every difference between them.

SDK      := $(shell xcrun -sdk macosx --show-sdk-path)
CC       := clang
INC      := -Iinclude
AS_MACHO := $(CC) $(INC) -arch arm64 -c
AS_ELF   := $(CC) $(INC) -target aarch64-none-elf -c
LD_MACHO := ld -lSystem -syslibroot $(SDK) -arch arm64
B        := build

FONT_SRC   := font/font.S font/render.S
# The kernel splits in two: kernel/ is what it does, kernel/arch/<cpu>/ is
# what the machine is.  A port replaces the second half and transliterates the
# first; see kernel/PORTING.md.
KERNEL_ARCH ?= aarch64
# The editor core is shared with the hosted builds without a line of
# difference: OS mode is the same program with the machine underneath it
# removed, not a cut-down version of it.
KERNEL_SRC := kernel/main.S kernel/console.S kernel/edit.S \
              editor/editor.S editor/applet.S gfx/image.S gfx/video.S \
              net/str.S \
              $(wildcard kernel/arch/$(KERNEL_ARCH)/*.S)

BACKEND_SRC := backend/daemon.S backend/page.S backend/util.S backend/aicoin.S \
               backend/aws.S backend/sigv4.S crypto/sha256.S crypto/hmac.S \
               net/str.S net/http.S net/server.S app/env.S
BACKEND_OBJ := $(patsubst %.S,$(B)/macho/%.o,$(BACKEND_SRC))

TTY_OBJ    := $(patsubst %.S,$(B)/macho/%.o,app/tty.S $(FONT_SRC))
NET_SRC    := net/str.S net/http.S
WIN_OBJ    := $(patsubst %.S,$(B)/macho/%.o,app/window.S app/env.S app/clock.S app/async.S app/backend_client.S editor/editor.S editor/applet.S gfx/image.S $(NET_SRC) $(FONT_SRC))
KERNEL_OBJ := $(patsubst %.S,$(B)/elf/%.o,$(KERNEL_SRC) $(FONT_SRC))

QEMU      := qemu-system-aarch64
QEMU_ARGS := -M virt -cpu cortex-a72 -m 256 -kernel $(B)/kernel.elf

.PHONY: all tty window kernel backend app ios ios-run ios-device agent run win boot boot-tty serve clean
all: tty window kernel backend
tty: $(B)/armedit-tty
window: $(B)/armedit-window
kernel: $(B)/kernel.elf
backend: $(B)/armeditd

$(B)/macho/%.o: %.S
	@mkdir -p $(dir $@)
	$(AS_MACHO) $< -o $@

$(B)/elf/%.o: %.S
	@mkdir -p $(dir $@)
	$(AS_ELF) $< -o $@

$(B)/armedit-tty: $(TTY_OBJ)
	$(LD_MACHO) -o $@ $^

$(B)/armedit-window: $(WIN_OBJ)
	$(LD_MACHO) -framework AppKit -framework CoreGraphics -o $@ $^

$(B)/armeditd: $(BACKEND_OBJ)
	$(LD_MACHO) -o $@ $^

$(B)/kernel.elf: $(KERNEL_OBJ) kernel/arch/$(KERNEL_ARCH)/link.ld
	ld.lld -T kernel/arch/$(KERNEL_ARCH)/link.ld -o $@ $(KERNEL_OBJ)

# --- iOS ---------------------------------------------------------------
# The same editor core behind a UIKit front end.  Simulator by default,
# because a device build needs a signing identity this repository has no
# business knowing about.
IOS_SDK   := $(shell xcrun --sdk iphonesimulator --show-sdk-path)
IOS_ARCH  := arm64-apple-ios16.0-simulator
IOS_SRC   := app/ios.S app/env.S app/clock.S app/async.S app/backend_client.S editor/editor.S \
             editor/applet.S gfx/image.S net/str.S net/http.S $(FONT_SRC)
IOS_OBJ   := $(patsubst %.S,$(B)/ios/%.o,$(IOS_SRC))

$(B)/ios/%.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(INC) -target $(IOS_ARCH) -isysroot $(IOS_SDK) -c $< -o $@

ios: $(B)/armedit-ios.app

$(B)/armedit-ios.app: $(IOS_OBJ) app/ios/Info.plist
	@rm -rf $@ && mkdir -p $@
	$(CC) -target $(IOS_ARCH) -isysroot $(IOS_SDK) \
	  -framework UIKit -framework CoreGraphics -framework Foundation \
	  -o $@/armedit $(IOS_OBJ)
	@cp app/ios/Info.plist $@/Info.plist
	@codesign --force --sign - $@ 2>/dev/null || true
	@echo "built $@"

# Boot a simulator, install, launch.  SIM overrides the device.
SIM ?= iPhone 17 Pro
ios-run: $(B)/armedit-ios.app
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@xcrun simctl install "$(SIM)" $(B)/armedit-ios.app
	@xcrun simctl launch "$(SIM)" com.oeaio.armedit
	@open -a Simulator

# --- iOS, on a real phone ----------------------------------------------
# Needs a development identity and a profile that lists the device.  The
# wildcard "iOS Team Provisioning Profile: *" covers any bundle id on the
# team, which is why no per-app profile has to be created for this.
IOSDEV_SDK  := $(shell xcrun --sdk iphoneos --show-sdk-path)
IOSDEV_ARCH := arm64-apple-ios16.0
IOSDEV_OBJ  := $(patsubst %.S,$(B)/iosdev/%.o,$(IOS_SRC))
SIGN_ID     ?= Apple Development: Taras Maslov (F5CZZWQ82V)
PROFILE     ?= $(HOME)/Library/Developer/Xcode/UserData/Provisioning Profiles/1f5ff73a-ead8-4c1c-8acb-a40656c79a1c.mobileprovision
DEVICE      ?= 00008150-0010748636B9401C

$(B)/iosdev/%.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(INC) -target $(IOSDEV_ARCH) -isysroot $(IOSDEV_SDK) -c $< -o $@

ios-device: $(IOSDEV_OBJ) app/ios/Info.plist
	@rm -rf $(B)/armedit-device.app && mkdir -p $(B)/armedit-device.app
	$(CC) -target $(IOSDEV_ARCH) -isysroot $(IOSDEV_SDK) \
	  -framework UIKit -framework CoreGraphics -framework Foundation \
	  -o $(B)/armedit-device.app/armedit $(IOSDEV_OBJ)
	@cp app/ios/Info.plist $(B)/armedit-device.app/Info.plist
	@cp "$(PROFILE)" $(B)/armedit-device.app/embedded.mobileprovision
	@security cms -D -i "$(PROFILE)" | plutil -extract Entitlements xml1 -o $(B)/ent.plist -
	@plutil -replace application-identifier -string "HTS38ZPRVH.com.oeaio.armedit" $(B)/ent.plist
	@codesign --force --sign "$(SIGN_ID)" --entitlements $(B)/ent.plist --timestamp=none $(B)/armedit-device.app
	@xcrun devicectl device install app --device $(DEVICE) $(B)/armedit-device.app
	@echo "installed on $(DEVICE) - unlock the phone, then tap armedit"

# --- the agent ----------------------------------------------------------
# A machine volunteering itself to an account.  Access is a ceiling, not a
# grant: a refused list applies whatever is set here.
ACCESS ?= confirmed
agent:
	@mkdir -p $(B)/agent
	javac -d $(B)/agent agent/src/*.java
	@echo "run: java -cp $(B)/agent ArmeditAgent --key <key> --access $(ACCESS)"

# A double-clickable Mac app: the same binary, in the bundle layout Finder
# and the Dock expect.
app: $(B)/armedit.app

$(B)/armedit.app: $(B)/armedit-window app/macos/Info.plist
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS
	@cp app/macos/Info.plist $@/Contents/Info.plist
	@cp $(B)/armedit-window $@/Contents/MacOS/armedit
	@printf 'APPL????' > $@/Contents/PkgInfo
	@codesign --force --sign - $@ 2>/dev/null || true
	@echo "built $@"

run: $(B)/armedit-tty
	@$(B)/armedit-tty $(TEXT)

win: $(B)/armedit-window
	@$(B)/armedit-window $(TEXT)

serve: $(B)/armeditd
	@$(B)/armeditd

boot: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) -device ramfb -display cocoa

boot-tty: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) -nographic

clean:
	rm -rf $(B)
