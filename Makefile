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
KERNEL_DEFS ?=
AS_ELF   := $(CC) $(INC) $(KERNEL_DEFS) -target aarch64-none-elf -c
LD_MACHO := ld -lSystem -syslibroot $(SDK) -arch arm64
B        := build
, := ,

FONT_SRC   := font/font.S font/render.S
# The kernel splits in two: kernel/ is what it does, kernel/arch/<cpu>/ is
# what the machine is.  A port replaces the second half and transliterates the
# first; see kernel/PORTING.md.
KERNEL_ARCH ?= aarch64
# The editor core is shared with the hosted builds without a line of
# difference: OS mode is the same program with the machine underneath it
# removed, not a cut-down version of it.
KERNEL_SRC := kernel/main.S kernel/console.S kernel/edit.S app/ops.S \
              kernel/net.S kernel/tcp.S kernel/sock.S \
              net/http.S app/backend_client.S app/env.S \
              editor/editor.S editor/applet.S gfx/image.S gfx/video.S gfx/demo_clip.S \
              net/str.S app/localops.S net/html.S net/browse.S kernel/dns.S \
              kernel/dtb.S kernel/pci.S kernel/screen.S \
              $(wildcard kernel/arch/$(KERNEL_ARCH)/*.S)

# The approved operations, turned into a table the linker can place. Generated
# rather than written: ops/ is the source of truth, and a hand-kept copy of it
# would be wrong the first time one is added.
OPS_TABLE := $(B)/ops_table.S

$(OPS_TABLE): $(wildcard ops/*.op) $(wildcard ops/*.bin) tools/mkops.py
	@mkdir -p $(B)
	@python3 tools/mkops.py ops $@

BACKEND_SRC := backend/daemon.S backend/page.S backend/util.S backend/aicoin.S \
               backend/aws.S backend/sigv4.S crypto/sha256.S crypto/hmac.S \
               net/str.S net/http.S net/server.S app/env.S
BACKEND_OBJ := $(patsubst %.S,$(B)/macho/%.o,$(BACKEND_SRC))

TTY_OBJ    := $(patsubst %.S,$(B)/macho/%.o,app/tty.S $(FONT_SRC))
NET_SRC    := net/str.S net/http.S net/sock.S
WIN_OBJ    := $(B)/macho/ops_table.o $(patsubst %.S,$(B)/macho/%.o,app/window.S app/env.S app/clock.S app/async.S app/backend_client.S app/ops.S app/localops.S app/reboot.S editor/editor.S editor/applet.S gfx/image.S gfx/video.S gfx/demo_clip.S $(NET_SRC) net/dns.S net/html.S net/browse.S $(FONT_SRC))
KERNEL_OBJ := $(patsubst %.S,$(B)/elf/%.o,$(KERNEL_SRC) $(FONT_SRC)) $(B)/elf/ops_table.o

QEMU      := qemu-system-aarch64
QEMU_ARGS := -M virt -cpu cortex-a72 -m 256 -kernel $(B)/kernel.elf
# A keyboard for the display window. force-legacy=false is not optional: QEMU's
# virtio-mmio transport reports version 1 by default, and the legacy queue
# layout is a different driver - one this kernel does not have.
QEMU_KBD  := -global virtio-mmio.force-legacy=false -device virtio-keyboard-device
# A network card, and QEMU's user-mode network behind it. The guest is
# 10.0.2.15 and the gateway 10.0.2.2, which is also how it reaches a server on
# the host - those addresses are fixed and documented, which is why this kernel
# can be told them rather than having to discover them with DHCP.
QEMU_NET  := -netdev user,id=n0 -device virtio-net-device,netdev=n0
# A kernel has no environment, so the one thing it must be told arrives through
# fw_cfg:  make boot KEY=<key>@10.0.2.2:8090
KEY       ?=
QEMU_KEY  := $(if $(KEY),-fw_cfg name=opt/armedit/key$(,)string=$(KEY),)

.PHONY: all tty window kernel kernel-img backend app ios ios-run ios-device agent run win boot boot-tty serve test treefb reboot-path clean
all: tty window kernel backend
tty: $(B)/armedit-tty
window: $(B)/armedit-window
kernel: $(B)/kernel.elf
backend: $(B)/armeditd

$(B)/macho/%.o: %.S
	@mkdir -p $(dir $@)
	$(AS_MACHO) $< -o $@

$(B)/macho/ops_table.o: $(OPS_TABLE)
	@mkdir -p $(dir $@)
	$(AS_MACHO) $< -o $@

$(B)/elf/ops_table.o: $(OPS_TABLE)
	@mkdir -p $(dir $@)
	$(AS_ELF) $< -o $@

$(B)/elf/%.o: %.S
	@mkdir -p $(dir $@)
	$(AS_ELF) $< -o $@

$(B)/armedit-tty: $(TTY_OBJ)
	$(LD_MACHO) -o $@ $^

$(B)/armedit-window: $(WIN_OBJ)
	$(LD_MACHO) -framework AppKit -framework CoreGraphics -o $@ $^

$(B)/armeditd: $(BACKEND_OBJ)
	$(LD_MACHO) -o $@ $^

# The flat image every real loader wants. See tools/mkimg.py.
kernel-img: $(B)/kernel.img
$(B)/kernel.img: $(B)/kernel.elf tools/mkimg.py
	@python3 tools/mkimg.py $< $@

$(B)/kernel.elf: $(KERNEL_OBJ) kernel/arch/$(KERNEL_ARCH)/link.ld
	ld.lld -T kernel/arch/$(KERNEL_ARCH)/link.ld -o $@ $(KERNEL_OBJ)

# --- iOS ---------------------------------------------------------------
# The same editor core behind a UIKit front end.  Simulator by default,
# because a device build needs a signing identity this repository has no
# business knowing about.
IOS_SDK   := $(shell xcrun --sdk iphonesimulator --show-sdk-path)
IOS_ARCH  := arm64-apple-ios16.0-simulator
IOS_SRC   := app/ios.S app/env.S app/clock.S app/async.S app/backend_client.S app/ops.S app/localops.S app/reboot.S editor/editor.S \
             editor/applet.S gfx/image.S gfx/video.S gfx/demo_clip.S net/str.S net/http.S \
             net/sock.S \
             net/dns.S net/html.S net/browse.S $(FONT_SRC)
# The same table the other targets get: an iPhone with no signal is exactly the
# machine that should still answer what this build already knows.
IOS_OBJ   := $(B)/ios/ops_table.o $(patsubst %.S,$(B)/ios/%.o,$(IOS_SRC))

$(B)/ios/ops_table.o: $(OPS_TABLE)
	@mkdir -p $(dir $@)
	$(CC) $(INC) -target $(IOS_ARCH) -isysroot $(IOS_SDK) -c $< -o $@

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

# zoom-to-fit lets the window be dragged to any size: ramfb has one fixed
# resolution, so the alternative is a window you cannot resize at all.
#
# -serial mon:stdio is not optional. The kernel's keyboard is the UART, and
# without this QEMU sends the serial line to a virtual console the cocoa
# display does not show - which is a window that draws correctly and cannot be
# typed into at all. So: this terminal is the keyboard, and the window is the
# screen. (Ctrl+A X quits, since the monitor shares this line.)
boot: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) $(QEMU_KBD) $(QEMU_NET) $(QEMU_KEY) -device ramfb \
	  -display cocoa,zoom-to-fit=on,left-command-key=on -serial mon:stdio

# Prove the fault handler by faulting: builds a kernel that takes an unaligned
# load on the way up, and expects a report rather than a silence.
# End to end, in a virtual machine, on the features as somebody would use them.
# The offline case needs nothing; the rest need a backend, and say so when
# there is not one.
.PHONY: e2e
e2e: $(B)/kernel.img
	@python3 tests/e2e.py

# The bare-metal display path: a framebuffer the kernel is given rather than
# one it asks for. QEMU offers no such thing, so tools/loadertree.py puts the node a
# real loader would have left into QEMU's own tree, and the test reads the
# pixels back out of guest memory afterwards.
.PHONY: treefb
treefb: $(B)/kernel.img
	@python3 tests/treefb.py

# Restarting a machine that has no PSCI, which is the one this is aimed at.
# Builds a kernel that reboots on purpose, hands it a tree with a watchdog in
# it, and reads back the three words it wrote.
.PHONY: reboot-path
reboot-path:
	@python3 tests/rebootpath.py

.PHONY: boot-fault
boot-fault:
	@$(MAKE) --no-print-directory clean-kernel
	@$(MAKE) --no-print-directory kernel KERNEL_DEFS=-DARMEDIT_FAULT_TEST
	@echo "--- booting a kernel that faults on purpose:"
	@$(QEMU) $(QEMU_ARGS) -nographic > $(B)/fault.log 2>&1 & \
	 P=$$!; sleep 5; kill $$P 2>/dev/null; true
	@grep -q "KERNEL FAULT" $(B)/fault.log \
	  && sed -n '1,8p' $(B)/fault.log \
	  || (echo "    the kernel faulted and said nothing - the vectors are not installed"; \
	      cat $(B)/fault.log; exit 1)
	@$(MAKE) --no-print-directory clean-kernel

# What the machine says about itself. The first question on any unfamiliar
# board is whether the addresses came out right, and this is how a kernel with
# no debugger answers it.
# armedit under macOS's Virtualization framework: a real Apple CPU at EL1,
# which is the closest test bed to the eventual bare-metal target. Needs the
# virtualization entitlement, so it is ad-hoc signed with one.
$(B)/vzrun: tools/vzrun.swift tools/vz.plist
	swiftc -O -o $@ tools/vzrun.swift
	@codesign --entitlements tools/vz.plist -s - $@

.PHONY: vz
vz: $(B)/vzrun $(B)/kernel.img
	VZRUN_SECONDS=$${VZRUN_SECONDS:-10} $(B)/vzrun $(B)/kernel.img

# A reference: boot somebody else's kernel under the same host and see whether
# the framework's console carries anything. It does - which is how we know the
# silence is ours. Needs a distribution vmlinuz; see tools/refkernel.py.
# armedit as an EFI application, and a disk for the firmware to find it on.
#
# This is the way into the Virtualization framework: EFI firmware brings up a
# console and a framebuffer itself and hands them to an application, so a guest
# can say something before it knows what it is running on - which the virtio
# console on that machine will not let it do.
EFI_OBJ := $(B)/efi/efi.obj

$(B)/efi/%.obj: boot/%.S
	@mkdir -p $(dir $@)
	$(CC) -target aarch64-unknown-windows -ffreestanding -c $< -o $@

$(B)/BOOTAA64.EFI: $(EFI_OBJ)
	lld-link -subsystem:efi_application -entry:efi_main -nodefaultlib -out:$@ $(EFI_OBJ)

.PHONY: efi
efi: $(B)/esp.img

# A FAT volume with /EFI/BOOT/BOOTAA64.EFI on it, which is where EFI looks.
$(B)/esp.img: $(B)/BOOTAA64.EFI tools/mkesp.sh
	@sh tools/mkesp.sh $(B)/BOOTAA64.EFI $@

$(B)/vzefi: tools/vzefi.swift tools/vz.plist
	swiftc -O -o $@ tools/vzefi.swift
	@codesign --entitlements tools/vz.plist -s - $@

$(B)/vzgui: tools/vzgui.swift tools/vz.plist
	swiftc -O -o $@ tools/vzgui.swift
	@codesign --entitlements tools/vz.plist -s - $@

# EFI's console is a framebuffer one, so seeing it means having a window.
.PHONY: vz-efi
vz-efi: $(B)/vzgui $(B)/esp.img
	$(B)/vzgui $(B)/esp.img

.PHONY: vz-reference
vz-reference: $(B)/vzrun
	@test -n "$(VMLINUZ)" || (echo "give it a kernel: make vz-reference VMLINUZ=path"; exit 1)
	@python3 tools/refkernel.py $(VMLINUZ) $(B)/reference.Image
	@VZRUN_SECONDS=$${VZRUN_SECONDS:-25} VZRUN_OUT=$(B)/reference.log 	   $(B)/vzrun $(B)/reference.Image "console=hvc0" >/dev/null 2>&1 || true
	@echo "--- what the reference kernel put on the console:"
	@head -c 600 $(B)/reference.log; echo

.PHONY: boot-dtb
boot-dtb:
	@$(MAKE) --no-print-directory clean-kernel
	@$(MAKE) --no-print-directory kernel KERNEL_DEFS=-DARMEDIT_DTB_DUMP
	@$(QEMU) $(QEMU_ARGS) $(QEMU_KBD) $(QEMU_NET) -nographic > $(B)/dtb.log 2>&1 & \
	 P=$$!; sleep 5; kill $$P 2>/dev/null; true
	@sed -n '1,10p' $(B)/dtb.log
	@$(MAKE) --no-print-directory clean-kernel

.PHONY: clean-kernel
clean-kernel:
	@rm -rf $(B)/elf $(B)/kernel.elf

boot-tty: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) -nographic

clean:
	rm -rf $(B)

# ---------------------------------------------------------------- tests
# Two halves of the same claim. The Java side proves an appearance change
# survives every stage the server can answer from - model, cache, script,
# compiler. The assembly side takes the aarch64 the compiler emitted and
# actually runs it, because "it compiled" and "it works" are different
# statements and only one of them is worth making.
TEST_OBJ := $(B)/macho/tests/optest.o $(B)/macho/app/ops.o \
            $(B)/macho/net/str.o $(B)/macho/app/env.o
LOCAL_OBJ := $(B)/macho/tests/localtest.o $(B)/macho/app/localops.o \
             $(B)/macho/app/ops.o $(B)/macho/net/str.o $(B)/macho/app/env.o \
             $(B)/macho/ops_table.o

$(B)/optest: $(TEST_OBJ)
	$(LD_MACHO) -o $@ $(TEST_OBJ)

$(B)/localtest: $(LOCAL_OBJ)
	$(LD_MACHO) -o $@ $(LOCAL_OBJ)

BROWSE_OBJ := $(B)/macho/tests/browsetest.o $(B)/macho/net/browse.o \
              $(B)/macho/net/html.o $(B)/macho/net/dns.o $(B)/macho/net/sock.o \
              $(B)/macho/net/str.o $(B)/macho/app/env.o $(B)/macho/net/http.o \
              $(B)/macho/app/backend_client.o $(B)/macho/app/ops.o \
              $(B)/macho/app/localops.o $(B)/macho/ops_table.o \
              $(B)/macho/editor/editor.o $(B)/macho/editor/applet.o \
              $(B)/macho/gfx/image.o $(B)/macho/gfx/video.o \
              $(B)/macho/gfx/demo_clip.o $(B)/macho/font/font.o \
              $(B)/macho/font/render.o $(B)/macho/app/clock.o

$(B)/fdt_sample.S: tools/mkfdt.py
	@mkdir -p $(B)
	@python3 tools/mkfdt.py $@

$(B)/fdt_apple.S: tools/mkfdt.py
	@mkdir -p $(B)
	@python3 tools/mkfdt.py $@ --apple

$(B)/macho/fdt_apple.o: $(B)/fdt_apple.S
	@mkdir -p $(dir $@)
	$(AS_MACHO) $< -o $@

$(B)/macho/fdt_sample.o: $(B)/fdt_sample.S
	@mkdir -p $(dir $@)
	$(AS_MACHO) $< -o $@

BOOTARGS_OBJ := $(B)/macho/tests/bootargstest.o \
                $(B)/macho/kernel/arch/aarch64/bootargs.o \
                $(B)/macho/kernel/screen.o $(B)/macho/kernel/dtb.o \
                $(B)/macho/fdt_sample.o $(B)/macho/fdt_apple.o \
                $(B)/macho/kernel/arch/aarch64/uart.o $(B)/macho/net/str.o \
                $(B)/macho/kernel/arch/aarch64/wdt.o

$(B)/bootargstest: $(BOOTARGS_OBJ)
	$(LD_MACHO) -o $@ $(BOOTARGS_OBJ)

$(B)/browsetest: $(BROWSE_OBJ)
	$(LD_MACHO) -o $@ $(BROWSE_OBJ)

.PHONY: test
test: $(B)/optest $(B)/localtest $(B)/bootargstest
	@cd backend-java && ./gradlew -q installDist
	@javac -cp backend-java/build/classes/java/main -d $(B)/tests \
	   tests/ColourTest.java tests/ConsortiumTest.java tests/WaitingTest.java
	@java -cp "backend-java/build/classes/java/main:$(shell ls backend-java/build/install/armeditd/lib/*.jar | tr '\n' ':')$(B)/tests" \
	   ColourTest $(B)/tests/colour.bin $(B)/tests/shout.bin
	@java -cp "backend-java/build/classes/java/main:$(shell ls backend-java/build/install/armeditd/lib/*.jar | tr '\n' ':')$(B)/tests" \
	   ConsortiumTest
	@java -cp "backend-java/build/classes/java/main:$(shell ls backend-java/build/install/armeditd/lib/*.jar | tr '\n' ':')$(B)/tests" \
	   WaitingTest
	@echo "  --- and the aarch64 it emitted, executed:"
	@for c in blue red green chartreuse; do \
	   printf "    set-colour %-11s -> [%s]\n" "$$c" \
	     "$$(ARMEDIT_TAG=1 $(B)/optest $(B)/tests/colour.bin "$$c" "a document" "" "")"; \
	 done
	@printf "    shout %-17s -> [%s]\n" "(screen only)" \
	   "$$(ARMEDIT_TAG=1 $(B)/optest $(B)/tests/shout.bin "hello" "" "")"
	@echo "  --- and what m1n1 would hand over on a real machine:"
	@$(B)/bootargstest
	@echo "  --- and the operations this build ships with, answering offline:"
	@$(B)/localtest "colours blue" "colours red" "COLOURS Blue" \
	   "$$(printf 'colours blue\n')" "  colours   blue  " \
	   "colours chartreuse" "colours" "colours blue please" "hello" \
	   "arrived at runtime" \
	   | sed 's/^/    /' 
