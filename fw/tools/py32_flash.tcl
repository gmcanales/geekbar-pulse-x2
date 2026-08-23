# PY32F030 flash driver, driven entirely from the host over SWD.
#
# OpenOCD 0.12 ships no PY32 flash algorithm, so rather than depend on pyOCD
# plus Puya's DFP pack, this drives the flash controller directly with the
# core halted. With the CPU stopped there is no instruction fetch from flash
# during a program cycle, which is the reason the vendor HAL marks its
# programming routine __RAM_FUNC — that constraint doesn't apply to us.
#
# The sequence below is taken from the vendor HAL in
# ../firmware/PY32F0xx_HAL_Driver/Src/py32f0xx_hal_flash.c, not guessed.
#
# Notable quirks of this part:
#   - Erase is triggered by a *dummy write* into the target page, not by a
#     start bit.
#   - Programming is page-at-a-time: exactly 32 words, with PGSTRT set after
#     the 31st. The final word write commits the page.
#   - Flash timing registers must be loaded from a per-clock-speed factory
#     block in the info area before any erase or program. Wrong values can
#     damage cells, so this is not optional.

set FLASH_R    0x40022000
set RCC_ICSCR  0x40021004

# FLASH register offsets
set F_ACR   0x00
set F_KEYR  0x08
set F_SR    0x10
set F_CR    0x14
set F_OPTR  0x20
set F_SDKR  0x24
set F_WRPR  0x2C
set F_TS0   0x100
set F_TS1   0x104
set F_TS2P  0x108
set F_TPS3  0x10C
set F_TS3   0x110
set F_PERTPE  0x114
set F_SMERTPE 0x118
set F_PRGTPE  0x11C
set F_PRETPE  0x120

set CR_PG     [expr {1 << 0}]
set CR_PER    [expr {1 << 1}]
set CR_MER    [expr {1 << 2}]
set CR_SER    [expr {1 << 11}]
set CR_PGSTRT [expr {1 << 19}]
set CR_LOCK   [expr {1 << 31}]

set SR_EOP     [expr {1 << 0}]
set SR_WRPERR  [expr {1 << 4}]
set SR_OPTVERR [expr {1 << 15}]
set SR_BSY     [expr {1 << 16}]

set FLASH_KEY1 0x45670123
set FLASH_KEY2 0xCDEF89AB

set PAGE_SIZE 128
set PAGE_WORDS 32

# Factory flash-timing blocks, indexed by RCC_ICSCR.HSI_FS. Five real entries
# (4 / 8 / 16 / 22.12 / 24 MHz); the reserved indices fall back to the 4 MHz
# block, matching _FlashTimmingParam[] in the vendor HAL.
set TIMING_TBL {0x1FFF0F1C 0x1FFF0F30 0x1FFF0F44 0x1FFF0F58 0x1FFF0F6C 0x1FFF0F1C 0x1FFF0F1C 0x1FFF0F1C}
set HSI_NAMES  {4MHz 8MHz 16MHz 22.12MHz 24MHz rsvd5 rsvd6 rsvd7}

# --- write guard ------------------------------------------------------------
# Everything below 0x08009000 is the live stock firmware, and 0x0800F000 is a
# 128-byte factory calibration page. Until someone explicitly arms the live
# range, writes are confined to the blank scratch area the stock image leaves
# behind — which is enough to prove the whole path works on a unit that keeps
# running throughout.
set ::PY32_SCRATCH_LO 0x08009000
set ::PY32_SCRATCH_HI 0x0800F000
set ::PY32_ALLOW_LIVE 0

proc py32_arm_live {} {
  set ::PY32_ALLOW_LIVE 1
  echo "!! live range armed — writes to the stock firmware region are now permitted"
}

proc py32_guard {addr len} {
  if {$::PY32_ALLOW_LIVE} { return }
  set end [expr {$addr + $len}]
  if {$addr >= $::PY32_SCRATCH_LO && $end <= $::PY32_SCRATCH_HI} { return }
  error [format "refused: 0x%08X..0x%08X is outside the scratch region 0x%08X..0x%08X (call py32_arm_live to override)" \
         $addr $end $::PY32_SCRATCH_LO $::PY32_SCRATCH_HI]
}

# --- primitives -------------------------------------------------------------
proc fr {off} { global FLASH_R; return [expr {$FLASH_R + $off}] }
proc rd32 {a}    { return [lindex [read_memory $a 32 1] 0] }
proc wr32 {a v}  { write_memory $a 32 [list [expr {$v & 0xffffffff}]] }
proc h32 {v}     { return [format "0x%08X" [expr {$v & 0xffffffff}]] }

proc py32_wait {{what "operation"} {tries 400}} {
  global F_SR SR_BSY SR_EOP SR_WRPERR SR_OPTVERR
  for {set i 0} {$i < $tries} {incr i} {
    # While the array is mid-operation the bus stalls, and the debug AP
    # surfaces that as a read fault. Retry rather than give up.
    if {[catch {rd32 [fr $F_SR]} sr]} { continue }
    if {!($sr & $SR_BSY)} {
      if {$sr & $SR_WRPERR} {
        wr32 [fr $F_SR] $SR_WRPERR
        error "$what failed: WRPERR — target is write-protected (check WRPR/SDKR)"
      }
      if {$sr & $SR_OPTVERR} {
        wr32 [fr $F_SR] $SR_OPTVERR
        error "$what failed: OPTVERR — option byte mismatch"
      }
      if {$sr & $SR_EOP} { wr32 [fr $F_SR] $SR_EOP }
      return
    }
  }
  error "$what timed out with BSY still set (SR [h32 [rd32 [fr $F_SR]]])"
}

proc py32_unlock {} {
  global F_CR F_KEYR CR_LOCK FLASH_KEY1 FLASH_KEY2
  if {[rd32 [fr $F_CR]] & $CR_LOCK} {
    wr32 [fr $F_KEYR] $FLASH_KEY1
    wr32 [fr $F_KEYR] $FLASH_KEY2
  }
  if {[rd32 [fr $F_CR]] & $CR_LOCK} {
    error "flash unlock failed — CR.LOCK still set"
  }
}

proc py32_lock {} {
  global F_CR CR_LOCK
  wr32 [fr $F_CR] $CR_LOCK
}

# Load the factory timing block for the current clock. Must run after unlock
# and before any erase or program.
proc py32_timing_apply {} {
  global RCC_ICSCR TIMING_TBL HSI_NAMES
  global F_TS0 F_TS1 F_TS3 F_TS2P F_TPS3 F_PERTPE F_SMERTPE F_PRGTPE F_PRETPE

  set idx  [expr {([rd32 $RCC_ICSCR] >> 13) & 7}]
  set base [lindex $TIMING_TBL $idx]
  set p    [read_memory $base 32 5]
  set e0 [lindex $p 0]; set e1 [lindex $p 1]
  set e2 [lindex $p 2]; set e3 [lindex $p 3]; set e4 [lindex $p 4]

  if {$e0 == 0xFFFFFFFF || $e0 == 0} {
    error "factory timing block at [h32 $base] looks unprogrammed ([h32 $e0]) — refusing to erase/program"
  }

  wr32 [fr $F_TS0]     [expr {$e0 & 0xFF}]
  wr32 [fr $F_TS1]     [expr {($e0 >> 16) & 0x1FF}]
  wr32 [fr $F_TS3]     [expr {($e0 >> 8) & 0xFF}]
  wr32 [fr $F_TS2P]    [expr {$e1 & 0xFF}]
  wr32 [fr $F_TPS3]    [expr {($e1 >> 16) & 0x7FF}]
  wr32 [fr $F_PERTPE]  [expr {$e2 & 0x1FFFF}]
  wr32 [fr $F_SMERTPE] [expr {$e3 & 0x1FFFF}]
  wr32 [fr $F_PRGTPE]  [expr {$e4 & 0xFFFF}]
  wr32 [fr $F_PRETPE]  [expr {($e4 >> 16) & 0x3FFF}]

  return [list $idx [lindex $HSI_NAMES $idx] $base]
}

proc py32_begin {} {
  halt
  py32_unlock
  return [py32_timing_apply]
}

proc py32_end {} {
  global F_CR
  wr32 [fr $F_CR] 0
  py32_lock
}

# The write that starts an erase, or commits a programmed page, stalls the
# AHB bus for the milliseconds the flash array needs. The debug AP reports
# that stall as a transfer fault even though the operation began correctly —
# so swallow the fault here and judge success from SR and a read-back.
proc py32_trigger {addr val} {
  catch {wr32 $addr $val}
}

# Now that the trigger write's bus fault is swallowed, a bad erase can no
# longer announce itself by erroring — so check the precondition directly.
# The timing registers reset to zero, and programming with zero timings is
# what damages cells.
proc py32_timing_check {} {
  global F_PRGTPE F_PERTPE
  if {[rd32 [fr $F_PRGTPE]] == 0 || [rd32 [fr $F_PERTPE]] == 0} {
    error "flash timing registers are not loaded - call py32_begin first"
  }
}

proc py32_erase_page {addr} {
  global F_CR CR_PER PAGE_SIZE
  py32_timing_check
  py32_guard $addr $PAGE_SIZE
  if {$addr % $PAGE_SIZE} { error "erase address [h32 $addr] is not page-aligned" }
  wr32 [fr $F_CR] $CR_PER
  py32_trigger $addr 0xFF   ;# the dummy write is what triggers the erase
  py32_wait "page erase at [h32 $addr]"
  wr32 [fr $F_CR] 0
}

# Exactly 32 words. Words 0..30 go as one bulk transfer, then PGSTRT is set,
# then word 31 commits the page — matching the HAL's ordering while keeping
# the number of SWD round-trips low.
proc py32_program_page {addr words} {
  global F_CR CR_PG CR_PGSTRT PAGE_SIZE PAGE_WORDS
  py32_timing_check
  py32_guard $addr $PAGE_SIZE
  if {$addr % $PAGE_SIZE} { error "program address [h32 $addr] is not page-aligned" }
  if {[llength $words] != $PAGE_WORDS} {
    error "program page needs exactly $PAGE_WORDS words, got [llength $words]"
  }
  wr32 [fr $F_CR] $CR_PG
  write_memory $addr 32 [lrange $words 0 30]
  wr32 [fr $F_CR] [expr {$CR_PG | $CR_PGSTRT}]
  py32_trigger [expr {$addr + 124}] [lindex $words 31]
  py32_wait "page program at [h32 $addr]"
  wr32 [fr $F_CR] 0
}

# --- readiness report (pure reads, safe against stock firmware) -------------
proc py32_info {} {
  global F_ACR F_SR F_CR F_OPTR F_SDKR F_WRPR RCC_ICSCR
  global F_TS0 F_TS1 F_TS2P F_TPS3 F_TS3 F_PERTPE F_SMERTPE F_PRGTPE F_PRETPE
  global TIMING_TBL HSI_NAMES CR_LOCK

  halt
  set icscr [rd32 $RCC_ICSCR]
  set idx   [expr {($icscr >> 13) & 7}]
  set base  [lindex $TIMING_TBL $idx]

  echo "clock"
  echo "  RCC_ICSCR   [h32 $icscr]   HSI_FS = $idx ([lindex $HSI_NAMES $idx])"
  echo "  timing block at [h32 $base]"

  echo "flash controller"
  echo "  ACR  [h32 [rd32 [fr $F_ACR]]]    SR   [h32 [rd32 [fr $F_SR]]]"
  set cr [rd32 [fr $F_CR]]
  echo "  CR   [h32 $cr]    (LOCK [expr {($cr & $CR_LOCK) ? "set - normal" : "CLEAR - already unlocked"}])"

  echo "protection"
  # Decode rather than dump: each of these has an encoding where the "safe"
  # value is not the obvious one.
  set optr [rd32 [fr $F_OPTR]]
  set sdkr [rd32 [fr $F_SDKR]]
  set wrpr [rd32 [fr $F_WRPR]]

  set rdp [expr {$optr & 0xFF}]
  echo "  OPTR [h32 $optr]   RDP=[format 0x%02X $rdp] [expr {$rdp == 0xAA ? "- level 0, no readout protection" : "- READOUT PROTECTED"}]"

  # SDK_STRT (bits 0-4) > SDK_END (bits 8-12) encodes an empty range.
  set sstrt [expr {$sdkr & 0x1F}]
  set send  [expr {($sdkr >> 8) & 0x1F}]
  echo "  SDKR [h32 $sdkr]   start=$sstrt end=$send [expr {$sstrt > $send ? "- empty range, SDK protection off" : "- SDK PROTECTED"}]"

  # 16 sectors of 4K in 64K flash, one bit each, 1 = unprotected. So the
  # all-clear value here is 0x0000FFFF, not 0xFFFFFFFF.
  set unprot [expr {$wrpr & 0xFFFF}]
  echo "  WRPR [h32 $wrpr]   [expr {$unprot == 0xFFFF ? "all 16 sectors writable" : "SOME SECTORS WRITE-PROTECTED"}]"

  echo "factory timing block contents"
  set p [read_memory $base 32 5]
  for {set i 0} {$i < 5} {incr i} {
    echo "  EPPARA$i [h32 [lindex $p $i]]"
  }
  if {[lindex $p 0] == 0xFFFFFFFF} {
    echo "  !! block reads as erased — flash writes would be unsafe"
  }

  echo "live timing registers"
  echo "  TS0 [h32 [rd32 [fr $F_TS0]]]  TS1 [h32 [rd32 [fr $F_TS1]]]  TS3 [h32 [rd32 [fr $F_TS3]]]"
  echo "  TS2P [h32 [rd32 [fr $F_TS2P]]]  TPS3 [h32 [rd32 [fr $F_TPS3]]]"
  echo "  PERTPE [h32 [rd32 [fr $F_PERTPE]]]  SMERTPE [h32 [rd32 [fr $F_SMERTPE]]]"
  echo "  PRGTPE [h32 [rd32 [fr $F_PRGTPE]]]  PRETPE [h32 [rd32 [fr $F_PRETPE]]]"
  resume
}

# --- self-test: prove the whole path on flash nothing depends on -----------
# The stock image leaves 0x0800849C..0x0800F000 erased. Writing there exercises
# unlock, timing load, erase, program and verify without touching the running
# firmware, so a failure costs nothing and the vape keeps working throughout.
proc py32_selftest {{addr 0x0800C000}} {
  global PAGE_WORDS
  echo "self-test at [h32 $addr] (scratch flash — stock firmware untouched)"

  halt
  set before [read_memory $addr 32 $PAGE_WORDS]
  set blank 1
  foreach w $before { if {$w != 0xFFFFFFFF} { set blank 0 } }
  if {!$blank} {
    echo "  !! page is not blank — refusing. Pick another scratch page."
    resume
    return
  }
  echo "  page is blank: ok"

  set t [py32_begin]
  echo "  unlocked, timing loaded for [lindex $t 1] from [h32 [lindex $t 2]]"

  py32_erase_page $addr
  echo "  erase: ok"

  set pat {}
  for {set i 0} {$i < $PAGE_WORDS} {incr i} {
    lappend pat [expr {(0xA5A50000 | ($i << 8) | $i) & 0xffffffff}]
  }
  py32_program_page $addr $pat
  echo "  program: ok"

  set back [read_memory $addr 32 $PAGE_WORDS]
  set bad 0
  for {set i 0} {$i < $PAGE_WORDS} {incr i} {
    if {[lindex $back $i] != [lindex $pat $i]} {
      if {$bad < 4} {
        echo "    word $i: wrote [h32 [lindex $pat $i]] read [h32 [lindex $back $i]]"
      }
      incr bad
    }
  }
  if {$bad} {
    echo "  VERIFY FAILED: $bad/$PAGE_WORDS words wrong"
    py32_end; resume
    return
  }
  echo "  verify: ok — all $PAGE_WORDS words match"

  py32_erase_page $addr
  set back [read_memory $addr 32 $PAGE_WORDS]
  set clean 1
  foreach w $back { if {$w != 0xFFFFFFFF} { set clean 0 } }
  echo "  re-erase: [expr {$clean ? "ok — scratch page left blank" : "FAILED, page not blank"}]"

  py32_end
  resume
  echo ""
  echo [expr {$bad == 0 && $clean ? "WRITE PATH WORKS" : "write path NOT proven"}]
}

# --- image writing ----------------------------------------------------------
# Expects ::IMG_ADDR and ::IMG_WORDS, produced by tools/bin2tcl.py.
proc py32_write_image {} {
  global PAGE_WORDS PAGE_SIZE
  if {![info exists ::IMG_WORDS]} { error "no image loaded (source the file from bin2tcl.py first)" }
  set addr $::IMG_ADDR
  set words $::IMG_WORDS
  set nwords [llength $words]
  set npages [expr {($nwords + $PAGE_WORDS - 1) / $PAGE_WORDS}]

  echo "writing $nwords words ([expr {$nwords*4}] bytes, $npages pages) to [h32 $addr]"
  py32_guard $addr [expr {$npages * $PAGE_SIZE}]

  set t [py32_begin]
  echo "  timing loaded for [lindex $t 1]"

  for {set p 0} {$p < $npages} {incr p} {
    set pa [expr {$addr + $p * $PAGE_SIZE}]
    set lo [expr {$p * $PAGE_WORDS}]
    set chunk [lrange $words $lo [expr {$lo + $PAGE_WORDS - 1}]]
    # pad the final short page with 0xFFFFFFFF so it programs as erased
    while {[llength $chunk] < $PAGE_WORDS} { lappend chunk 0xFFFFFFFF }
    py32_erase_page $pa
    py32_program_page $pa $chunk
    if {$p % 8 == 0 || $p == $npages - 1} {
      echo "  page [expr {$p+1}]/$npages at [h32 $pa]"
    }
  }
  py32_end

  # verify
  set bad 0
  for {set p 0} {$p < $npages} {incr p} {
    set pa [expr {$addr + $p * $PAGE_SIZE}]
    set lo [expr {$p * $PAGE_WORDS}]
    set want [lrange $words $lo [expr {$lo + $PAGE_WORDS - 1}]]
    while {[llength $want] < $PAGE_WORDS} { lappend want 0xFFFFFFFF }
    set got [read_memory $pa 32 $PAGE_WORDS]
    for {set i 0} {$i < $PAGE_WORDS} {incr i} {
      if {[lindex $got $i] != [lindex $want $i]} {
        if {$bad < 4} {
          echo "  mismatch at [h32 [expr {$pa + $i*4}]]: wrote [h32 [lindex $want $i]] read [h32 [lindex $got $i]]"
        }
        incr bad
      }
    }
  }
  resume
  echo [expr {$bad ? "VERIFY FAILED: $bad words wrong" : "verified: image matches"}]
}
