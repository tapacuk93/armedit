# asmedit - every line of this project is assembled from .S sources.
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
KERNEL_SRC := kernel/main.S kernel/console.S \
              $(wildcard kernel/arch/$(KERNEL_ARCH)/*.S)

BACKEND_SRC := backend/daemon.S backend/page.S backend/util.S backend/aicoin.S \
               backend/aws.S backend/sigv4.S crypto/sha256.S crypto/hmac.S \
               net/str.S net/http.S net/server.S app/env.S
BACKEND_OBJ := $(patsubst %.S,$(B)/macho/%.o,$(BACKEND_SRC))

TTY_OBJ    := $(patsubst %.S,$(B)/macho/%.o,app/tty.S $(FONT_SRC))
NET_SRC    := net/str.S net/http.S
WIN_OBJ    := $(patsubst %.S,$(B)/macho/%.o,app/window.S app/env.S app/backend_client.S editor/editor.S editor/applet.S $(NET_SRC) $(FONT_SRC))
KERNEL_OBJ := $(patsubst %.S,$(B)/elf/%.o,$(KERNEL_SRC) $(FONT_SRC))

QEMU      := qemu-system-aarch64
QEMU_ARGS := -M virt -cpu cortex-a72 -m 256 -kernel $(B)/kernel.elf

.PHONY: all tty window kernel backend app ios ios-run run win boot boot-tty serve clean
all: tty window kernel backend
tty: $(B)/asmedit-tty
window: $(B)/asmedit-window
kernel: $(B)/kernel.elf
backend: $(B)/asmeditd

$(B)/macho/%.o: %.S
	@mkdir -p $(dir $@)
	$(AS_MACHO) $< -o $@

$(B)/elf/%.o: %.S
	@mkdir -p $(dir $@)
	$(AS_ELF) $< -o $@

$(B)/asmedit-tty: $(TTY_OBJ)
	$(LD_MACHO) -o $@ $^

$(B)/asmedit-window: $(WIN_OBJ)
	$(LD_MACHO) -framework AppKit -framework CoreGraphics -o $@ $^

$(B)/asmeditd: $(BACKEND_OBJ)
	$(LD_MACHO) -o $@ $^

$(B)/kernel.elf: $(KERNEL_OBJ) kernel/arch/$(KERNEL_ARCH)/link.ld
	ld.lld -T kernel/arch/$(KERNEL_ARCH)/link.ld -o $@ $(KERNEL_OBJ)

# --- iOS ---------------------------------------------------------------
# The same editor core behind a UIKit front end.  Simulator by default,
# because a device build needs a signing identity this repository has no
# business knowing about.
IOS_SDK   := $(shell xcrun --sdk iphonesimulator --show-sdk-path)
IOS_ARCH  := arm64-apple-ios16.0-simulator
IOS_SRC   := app/ios.S app/env.S app/backend_client.S editor/editor.S \
             editor/applet.S net/str.S net/http.S $(FONT_SRC)
IOS_OBJ   := $(patsubst %.S,$(B)/ios/%.o,$(IOS_SRC))

$(B)/ios/%.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(INC) -target $(IOS_ARCH) -isysroot $(IOS_SDK) -c $< -o $@

ios: $(B)/asmedit-ios.app

$(B)/asmedit-ios.app: $(IOS_OBJ) app/ios/Info.plist
	@rm -rf $@ && mkdir -p $@
	$(CC) -target $(IOS_ARCH) -isysroot $(IOS_SDK) \
	  -framework UIKit -framework CoreGraphics -framework Foundation \
	  -o $@/asmedit $(IOS_OBJ)
	@cp app/ios/Info.plist $@/Info.plist
	@codesign --force --sign - $@ 2>/dev/null || true
	@echo "built $@"

# Boot a simulator, install, launch.  SIM overrides the device.
SIM ?= iPhone 17 Pro
ios-run: $(B)/asmedit-ios.app
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@xcrun simctl install "$(SIM)" $(B)/asmedit-ios.app
	@xcrun simctl launch "$(SIM)" com.oeaio.asmedit
	@open -a Simulator

# A double-clickable Mac app: the same binary, in the bundle layout Finder
# and the Dock expect.
app: $(B)/asmedit.app

$(B)/asmedit.app: $(B)/asmedit-window app/macos/Info.plist
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS
	@cp app/macos/Info.plist $@/Contents/Info.plist
	@cp $(B)/asmedit-window $@/Contents/MacOS/asmedit
	@printf 'APPL????' > $@/Contents/PkgInfo
	@codesign --force --sign - $@ 2>/dev/null || true
	@echo "built $@"

run: $(B)/asmedit-tty
	@$(B)/asmedit-tty $(TEXT)

win: $(B)/asmedit-window
	@$(B)/asmedit-window $(TEXT)

serve: $(B)/asmeditd
	@$(B)/asmeditd

boot: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) -device ramfb -display cocoa

boot-tty: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) -nographic

clean:
	rm -rf $(B)
