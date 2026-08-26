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
KERNEL_SRC := kernel/boot.S kernel/uart.S kernel/fwcfg.S kernel/console.S kernel/main.S

TTY_OBJ    := $(patsubst %.S,$(B)/macho/%.o,app/tty.S $(FONT_SRC))
NET_SRC    := net/str.S net/http.S
WIN_OBJ    := $(patsubst %.S,$(B)/macho/%.o,app/window.S app/env.S app/backend_client.S editor/editor.S $(NET_SRC) $(FONT_SRC))
KERNEL_OBJ := $(patsubst %.S,$(B)/elf/%.o,$(KERNEL_SRC) $(FONT_SRC))

QEMU      := qemu-system-aarch64
QEMU_ARGS := -M virt -cpu cortex-a72 -m 256 -kernel $(B)/kernel.elf

.PHONY: all tty window kernel run win boot boot-tty clean
all: tty window kernel
tty: $(B)/asmedit-tty
window: $(B)/asmedit-window
kernel: $(B)/kernel.elf

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

$(B)/kernel.elf: $(KERNEL_OBJ) kernel/link.ld
	ld.lld -T kernel/link.ld -o $@ $(KERNEL_OBJ)

run: $(B)/asmedit-tty
	@$(B)/asmedit-tty $(TEXT)

win: $(B)/asmedit-window
	@$(B)/asmedit-window $(TEXT)

boot: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) -device ramfb -display cocoa

boot-tty: $(B)/kernel.elf
	$(QEMU) $(QEMU_ARGS) -nographic

clean:
	rm -rf $(B)
