/* Geek Bar Pulse X2 - PY32F030x8
 *
 * 64K flash @ 0x08000000, 8K RAM @ 0x20000000.
 *
 * Differs from the vendored VapeRE script in one way that matters: a .beacon
 * section is pinned to the very start of RAM (0x20000000) and marked NOLOAD,
 * so the host can read firmware state over SWD from a fixed, known address
 * without needing the .elf. Startup deliberately does not clear it, which
 * lets it survive a warm reset and count reboots.
 */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 64k
  RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 8k
}

ENTRY(Reset_Handler)

SECTIONS
{
  .text :
  {
    KEEP(*(.vectors))
    *(.text*)
    *(.rodata*)
    . = ALIGN(4);
  } > FLASH

  __etext = .;

  /* Pinned to 0x20000000. NOLOAD: no initialiser in flash, and startup
   * must not zero it. */
  .beacon (NOLOAD) :
  {
    . = ALIGN(4);
    KEEP(*(.beacon))
    . = ALIGN(4);
  } > RAM

  .data : AT (__etext)
  {
    . = ALIGN(4);
    __data_start__ = .;
    *(.data*)
    . = ALIGN(4);
    __data_end__ = .;
  } > RAM

  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    __bss_start__ = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end__ = .;
  } > RAM

  __StackTop   = ORIGIN(RAM) + LENGTH(RAM);
  __StackLimit = __StackTop - 1024;
  PROVIDE(__stack = __StackTop);

  ASSERT(__StackLimit >= __bss_end__, "RAM overflowed: .bss collides with stack")

  /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) }
}
