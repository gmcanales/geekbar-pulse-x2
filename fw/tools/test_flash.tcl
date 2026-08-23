# Runs the flash driver against a simulated PY32 flash controller, inside
# OpenOCD's own Jim interpreter — so the code under test is the real thing,
# not a transcription.
#
# The simulator models what actually bites on this part: erase triggered by a
# dummy write, the 32-word page buffer, PGSTRT ordering, LOCK enforcement, and
# the fact that programming can only clear bits (so writing over un-erased
# flash silently ANDs rather than failing loudly).
#
#   openocd -f tools/test_flash.tcl -c shutdown

set ::T_PASS 0
set ::T_FAIL 0
proc t_ok {what cond} {
  if {$cond} { incr ::T_PASS; puts "  ok    $what" } \
  else       { incr ::T_FAIL; puts "  FAIL  $what" }
}

# ---------------- simulated hardware ----------------
set ::SIM_MEM   [dict create]   ;# addr -> word (absent = 0xFFFFFFFF)
set ::SIM_CR    0x80000000      ;# LOCK set out of reset
set ::SIM_SR    0
set ::SIM_KEY   0
set ::SIM_BUF   [dict create]
set ::SIM_TIMING [dict create]
set ::SIM_ERASES 0
set ::SIM_PROGS  0
set ::SIM_LOCK_VIOLATIONS 0

# Addresses are dict keys, and Jim compares them as strings — so every key
# goes through K to become a plain decimal, or "0x08000000" and 134217728
# would be two different slots.
proc K {v} { return [expr {$v + 0}] }   ;# +0 forces a number: Jim's expr returns "0x40..." verbatim for a bare hex literal
proc sim_put {a v} { dict set ::SIM_MEM [K $a] [expr {$v + 0}] }

# factory timing block for 24MHz (HSI_FS = 4), plausible field values
sim_put 0x1FFF0F6C 0x01300416
sim_put 0x1FFF0F70 0x02007007
sim_put 0x1FFF0F74 0x00001450
sim_put 0x1FFF0F78 0x0000C350
sim_put 0x1FFF0F7C 0x0BB80078
sim_put 0x40021004 [expr {4 << 13}]   ;# RCC_ICSCR: HSI_FS = 24MHz

proc sim_get {a} {
  set a [K $a]
  if {[dict exists $::SIM_MEM $a]} { return [dict get $::SIM_MEM $a] }
  return 0xFFFFFFFF
}

proc halt {} {}
proc resume {} {}

proc read_memory {addr width count} {
  set out {}
  for {set i 0} {$i < $count} {incr i} {
    set a [expr {$addr + $i*4}]
    if {$a == 0x40022010}     { lappend out $::SIM_SR } \
    elseif {$a == 0x40022014} { lappend out $::SIM_CR } \
    else                      { lappend out [sim_get $a] }
  }
  return $out
}

proc write_memory {addr width words} {
  foreach w $words {
    sim_write $addr $w
    incr addr 4
  }
}

proc sim_write {a v} {
  set v [expr {$v & 0xffffffff}]
  # --- flash controller registers ---
  if {$a == 0x40022008} {                       ;# KEYR
    if {$::SIM_KEY == 0 && $v == 0x45670123} { set ::SIM_KEY 1 } \
    elseif {$::SIM_KEY == 1 && $v == 0xCDEF89AB} {
      set ::SIM_CR [expr {$::SIM_CR & ~0x80000000}]   ;# clear LOCK
      set ::SIM_KEY 0
    } else { set ::SIM_KEY 0 }
    return
  }
  if {$a == 0x40022010} { set ::SIM_SR [expr {$::SIM_SR & ~$v}]; return }   ;# SR: w1c
  if {$a == 0x40022014} {                       ;# CR
    if {$v & 0x80000000} { set ::SIM_CR 0x80000000 } else { set ::SIM_CR $v }
    if {!($v & 0x1)} { set ::SIM_BUF [dict create] }   ;# leaving PG drops the buffer
    return
  }
  if {$a >= 0x40022100 && $a <= 0x40022120} { dict set ::SIM_TIMING [K $a] $v; return }
  if {$a >= 0x40022000 && $a < 0x40022400} { return }

  # --- flash array ---
  if {$a >= 0x08000000 && $a < 0x08010000} {
    if {$::SIM_CR & 0x80000000} { incr ::SIM_LOCK_VIOLATIONS; return }
    if {[llength [dict keys $::SIM_TIMING]] < 9} {
      error "SIM: erase/program attempted before timing registers were loaded"
    }
    if {$::SIM_CR & 0x2} {                      ;# PER — dummy write erases page
      set pb [expr {$a & ~127}]
      for {set i 0} {$i < 32} {incr i} { sim_put [expr {$pb + $i*4}] 0xFFFFFFFF }
      incr ::SIM_ERASES
      set ::SIM_SR [expr {$::SIM_SR | 1}]
      return
    }
    if {$::SIM_CR & 0x1} {                      ;# PG — fill page buffer
      dict set ::SIM_BUF [K $a] $v
      if {$::SIM_CR & 0x80000} {                ;# PGSTRT: this write commits
        dict for {ba bv} $::SIM_BUF {
          sim_put $ba [expr {[sim_get $ba] & $bv}]   ;# can only clear bits
        }
        set ::SIM_BUF [dict create]
        incr ::SIM_PROGS
        set ::SIM_SR [expr {$::SIM_SR | 1}]
      }
      return
    }
    error "SIM: write to flash 0x[format %08X $a] with neither PER nor PG armed"
  }
}

# ---------------- run the real driver against it ----------------
source [file dirname [info script]]/py32_flash.tcl

puts "flash driver against a simulated controller:"

# --- unlock + timing ---
set r [py32_begin]
t_ok "unlock clears CR.LOCK"            [expr {!($::SIM_CR & 0x80000000)}]
t_ok "clock detected as 24MHz"          [expr {[lindex $r 1] eq "24MHz"}]
t_ok "timing block chosen = 0x1FFF0F6C" [expr {[lindex $r 2] == 0x1FFF0F6C}]
t_ok "all 9 timing registers written"   [expr {[llength [dict keys $::SIM_TIMING]] == 9}]
t_ok "  TS0  = EPPARA0 & 0xFF"          [expr {[dict get $::SIM_TIMING [K 0x40022100]] == 0x16}]
t_ok "  TS1  = EPPARA0>>16 & 0x1FF"     [expr {[dict get $::SIM_TIMING [K 0x40022104]] == 0x130}]
t_ok "  TS3  = EPPARA0>>8 & 0xFF"       [expr {[dict get $::SIM_TIMING [K 0x40022110]] == 0x04}]
t_ok "  PRETPE = EPPARA4>>16 & 0x3FFF"  [expr {[dict get $::SIM_TIMING [K 0x40022120]] == 0x0BB8}]

# --- erase + program a scratch page ---
set A 0x0800C000
sim_put $A 0x00000000        ;# dirty it so erase is observable
py32_erase_page $A
t_ok "erase ran once"                   [expr {$::SIM_ERASES == 1}]
t_ok "page reads blank after erase"     [expr {[sim_get $A] == 0xFFFFFFFF}]

set pat {}
for {set i 0} {$i < 32} {incr i} { lappend pat [expr {0xA5A50000 | $i}] }
py32_program_page $A $pat
t_ok "program ran once"                 [expr {$::SIM_PROGS == 1}]
t_ok "page buffer fully drained"        [expr {[dict size $::SIM_BUF] == 0}]
set got [read_memory $A 32 32]
set match 1
for {set i 0} {$i < 32} {incr i} {
  if {[lindex $got $i] != [lindex $pat $i]} { set match 0 }
}
t_ok "all 32 words landed"              $match
t_ok "  last word committed (PGSTRT)"   [expr {[sim_get [expr {$A+124}]] == [lindex $pat 31]}]

py32_end
t_ok "lock restored after operations"   [expr {$::SIM_CR & 0x80000000}]
t_ok "no writes attempted while locked" [expr {$::SIM_LOCK_VIOLATIONS == 0}]

# --- the write guard ---
puts "\nwrite guard keeps the stock firmware safe by default:"
t_ok "vector table refused"   [catch {py32_erase_page 0x08000000}]
t_ok "live code refused"      [catch {py32_erase_page 0x08004000}]
t_ok "calibration page refused" [catch {py32_erase_page 0x0800F000}]
t_ok "scratch page allowed"   [expr {![catch {py32_guard 0x0800C000 128}]}]
t_ok "misaligned refused"     [catch {py32_erase_page 0x0800C001}]
t_ok "short page refused"     [catch {py32_program_page 0x0800C000 {1 2 3}}]
py32_arm_live
t_ok "arming permits vector table" [expr {![catch {py32_guard 0x08000000 128}]}]
set ::PY32_ALLOW_LIVE 0

# --- multi-page image write, with a short final page ---
puts "\nimage write:"
set ::SIM_ERASES 0; set ::SIM_PROGS 0
set ::IMG_ADDR 0x0800C000
set ::IMG_WORDS {}
for {set i 0} {$i < 70} {incr i} { lappend ::IMG_WORDS [expr {0xC0DE0000 | $i}] }
py32_write_image
t_ok "3 pages erased (70 words)"    [expr {$::SIM_ERASES == 3}]
t_ok "3 pages programmed"           [expr {$::SIM_PROGS == 3}]
t_ok "first word correct"           [expr {[sim_get 0x0800C000] == 0xC0DE0000}]
t_ok "last real word correct"       [expr {[sim_get [expr {0x0800C000 + 69*4}]] == 0xC0DE0045}]
t_ok "short page padded with 0xFF"  [expr {[sim_get [expr {0x0800C000 + 70*4}]] == 0xFFFFFFFF}]
t_ok "lock restored"                [expr {$::SIM_CR & 0x80000000}]

# --- timing enforcement ---
puts "\ntiming registers are mandatory:"
set ::SIM_TIMING [dict create]
set ::SIM_CR [expr {$::SIM_CR & ~0x80000000}]
t_ok "erase without timing is caught" [catch {py32_erase_page 0x0800C000}]

puts ""
puts "[expr {$::T_FAIL ? "FAILED" : "flash driver behaves"}] ($::T_PASS passed, $::T_FAIL failed)"
