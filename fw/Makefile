# Geek Bar Pulse X2 custom firmware — PY32F030x8
#
#   make            build the default app (beacon)
#   make APP=shell  build the SWD-poke shell
#   make disasm     annotated disassembly
#   make clean
#
# Bare metal: no HAL, no newlib. Only the CMSIS headers vendored under
# ../firmware are used, and only as headers.

APP ?= beacon

CMSIS   := ../firmware/CMSIS
BUILD   := build/$(APP)
TARGET  := $(BUILD)/x2-$(APP)

PREFIX  := arm-none-eabi-
CC      := $(PREFIX)gcc
OBJCOPY := $(PREFIX)objcopy
OBJDUMP := $(PREFIX)objdump
SIZE    := $(PREFIX)size

SRCS := common/startup.c common/beacon.c apps/$(APP)/main.c
OBJS := $(patsubst %.c,$(BUILD)/%.o,$(SRCS))

INCS := -Icommon -isystem $(CMSIS)/Include -isystem $(CMSIS)/Device/PY32F0xx/Include
DEFS := -DPY32F030x8

CFLAGS := -mcpu=cortex-m0plus -mthumb $(DEFS) $(INCS) \
          -Os -g3 -std=gnu11 \
          -ffreestanding -fno-common -ffunction-sections -fdata-sections \
          -Wall -Wextra -Wshadow -Wundef

LDFLAGS := -mcpu=cortex-m0plus -mthumb -nostdlib -T ld/py32f030x8.ld \
           -Wl,--gc-sections -Wl,-Map=$(TARGET).map,--cref \
           -Wl,--print-memory-usage

.PHONY: all clean size disasm test flashtest both verify check
all: $(TARGET).bin $(TARGET).hex size

# The pre-flash checklist: host tests, then both images, then structural
# checks on the linked binaries. Nothing goes near hardware until this passes.
check: test flashtest
	$(MAKE) APP=beacon verify
	$(MAKE) APP=shell  verify
	@echo
	@echo "pre-flash checks passed"

both: check

verify: $(TARGET).bin
	@./tools/verify_image.sh $(APP)

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(TARGET).elf: $(OBJS) ld/py32f030x8.ld
	$(CC) $(OBJS) $(LDFLAGS) -lgcc -o $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O ihex $< $@

size: $(TARGET).elf
	@$(SIZE) $<
	@echo "--- image ---"
	@ls -l $(TARGET).bin

disasm: $(TARGET).elf
	$(OBJDUMP) -d -S $< > $(TARGET).lst
	@echo "wrote $(TARGET).lst"

# -Os inlines the safety logic out of the disassembly, so assert it on the
# host instead: the guard rules in isolation, then the dispatcher that applies
# them, against a fake register map.
HOSTCC ?= cc
HOSTFLAGS := -Wall -Wextra -DHOST_TEST -Icommon -Itest

test:
	@mkdir -p build
	@$(HOSTCC) $(HOSTFLAGS) -o build/test_guards tools/test_guards.c
	@./build/test_guards
	@echo
	@$(HOSTCC) $(HOSTFLAGS) -o build/test_shell test/test_shell.c
	@./build/test_shell

# The flash driver runs the real Tcl against a simulated PY32 flash
# controller, inside OpenOCD's own interpreter.
flashtest:
	@openocd -f tools/test_flash.tcl -c shutdown 2>&1 \
	  | grep -vE "^Open On-Chip|^Licensed|^For bug|openocd.org|shutdown command"

clean:
	rm -rf build

-include $(shell find build -name '*.d' 2>/dev/null)
