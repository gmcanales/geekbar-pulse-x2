# Host-side helpers for talking to the beacon / shell firmware over SWD.
# Field offsets mirror beacon_t in common/beacon.h (BEACON_VERSION 1).

set B_BASE   0x20000000
set B_MAGIC  0x32584247

set B_OFF_MAGIC   0x00
set B_OFF_VERSION 0x04
set B_OFF_APPID   0x08
set B_OFF_BOOTS   0x0C
set B_OFF_HEART   0x10
set B_OFF_TICKLO  0x14
set B_OFF_TICKHI  0x18
set B_OFF_RESET   0x1C
set B_OFF_CMD     0x20
set B_OFF_CMDSEQ  0x24
set B_OFF_ACKSEQ  0x28
set B_OFF_ARG0    0x2C
set B_OFF_ARG1    0x30
set B_OFF_RET0    0x34
set B_OFF_RET1    0x38
set B_OFF_STATUS  0x3C

proc hex32 {v} { return [format "0x%08x" [expr {$v & 0xffffffff}]] }

proc rd {addr {count 1}} { return [read_memory $addr 32 $count] }
proc wr {addr val}       { write_memory $addr 32 [list [expr {$val & 0xffffffff}]] }

proc status_name {s} {
  switch -- $s {
    0 { return "OK" }
    1 { return "BAD_CMD" }
    2 { return "BAD_PORT" }
    3 { return "BAD_PIN" }
    4 { return "PIN_LOCKED (refused: SWDIO/SWCLK)" }
    5 { return "ADDR_DENIED (refused: outside write allowlist)" }
    default { return "unknown($s)" }
  }
}

# Snapshot the whole beacon in one halt, so the numbers are self-consistent.
proc x2_beacon {} {
  global B_BASE B_MAGIC
  halt
  set w [rd $B_BASE 16]
  resume

  set magic [lindex $w 0]
  if {$magic != $B_MAGIC} {
    echo "no beacon at [hex32 $B_BASE] — magic is [hex32 $magic], expected [hex32 $B_MAGIC]"
    echo "(stock firmware is probably still flashed, or the app never reached main)"
    return
  }
  set app [lindex $w 2]
  set appname [expr {$app == 1 ? "beacon" : ($app == 2 ? "shell" : "unknown")}]

  echo "beacon      magic ok, version [lindex $w 1], app $app ($appname)"
  echo "boots       [lindex $w 3]"
  echo "heartbeat   [lindex $w 4]"
  echo "ticks       [hex32 [lindex $w 6]][format %08x [lindex $w 5]]  (raw SysTick)"
  echo "reset_cause [hex32 [lindex $w 7]]  (RCC_CSR latched at boot)"
  echo "cmd/seq/ack [hex32 [lindex $w 8]] / [lindex $w 9] / [lindex $w 10]"
  echo "ret0/ret1   [hex32 [lindex $w 13]] / [hex32 [lindex $w 14]]"
  echo "status      [status_name [lindex $w 15]]"
}

# Two reads separated by a known wall-clock gap. Heartbeat proves the loop is
# running; the tick delta gives the real core clock, which we cannot know up
# front because HSIFS is an option byte (4 / 8 / 16 / 22.12 / 24 MHz).
proc x2_alive {{gap_ms 2000}} {
  global B_BASE B_OFF_HEART
  halt; set a [rd [expr {$B_BASE + $B_OFF_HEART}] 3]; resume
  sleep $gap_ms
  halt; set b [rd [expr {$B_BASE + $B_OFF_HEART}] 3]; resume

  set dh [expr {[lindex $b 0] - [lindex $a 0]}]
  set ta [expr {[lindex $a 2] * 65536 * 65536 + [lindex $a 1]}]
  set tb [expr {[lindex $b 2] * 65536 * 65536 + [lindex $b 1]}]
  set dt [expr {$tb - $ta}]

  echo "over ${gap_ms} ms: heartbeat +$dh, systick wraps +$dt"
  if {$dh <= 0} {
    echo "NOT RUNNING — heartbeat did not advance"
  } else {
    # each wrap is 2^24 core cycles
    set hz [expr {double($dt) * 16777216.0 / (double($gap_ms) / 1000.0)}]
    echo "core clock  ~[format %.2f [expr {$hz / 1e6}]] MHz"
  }
}

# Fire one shell command and wait for the firmware to acknowledge it.
# cmd/arg0/arg1 are written first, cmd_seq last — the sequence bump is what
# makes the command visible, so a partially-written command can never run.
proc x2_cmd {cmd {a0 0} {a1 0}} {
  global B_BASE B_OFF_CMD B_OFF_CMDSEQ B_OFF_ACKSEQ B_OFF_ARG0 B_OFF_ARG1
  global B_OFF_RET0 B_OFF_RET1 B_OFF_STATUS B_MAGIC

  halt
  if {[lindex [rd $B_BASE 1] 0] != $B_MAGIC} {
    resume
    echo "no beacon — is the shell app flashed?"
    return
  }
  set seq  [lindex [rd [expr {$B_BASE + $B_OFF_CMDSEQ}] 1] 0]
  set nseq [expr {($seq + 1) & 0xffffffff}]
  wr [expr {$B_BASE + $B_OFF_CMD}]  $cmd
  wr [expr {$B_BASE + $B_OFF_ARG0}] $a0
  wr [expr {$B_BASE + $B_OFF_ARG1}] $a1
  wr [expr {$B_BASE + $B_OFF_CMDSEQ}] $nseq
  resume

  for {set i 0} {$i < 40} {incr i} {
    sleep 25
    halt
    set ack [lindex [rd [expr {$B_BASE + $B_OFF_ACKSEQ}] 1] 0]
    if {$ack == $nseq} {
      set r [rd [expr {$B_BASE + $B_OFF_RET0}] 3]
      resume
      echo "status [status_name [lindex $r 2]]   ret0 [hex32 [lindex $r 0]]   ret1 [hex32 [lindex $r 1]]"
      return
    }
    resume
  }
  echo "timed out waiting for ack (wanted seq $nseq)"
}

# Pure read of the GPIO config registers. Safe against stock firmware too —
# same risk class as the flash dump — which makes this the tool for checking
# whether the BD0061 pin mapping actually carries over to the X2.
proc x2_gpio {{port A}} {
  set bases [dict create A 0x50000000 B 0x50000400 F 0x50001400]
  set p [string toupper $port]
  if {![dict exists $bases $p]} { echo "port must be A, B or F"; return }
  set base [dict get $bases $p]

  halt
  set moder  [lindex [rd [expr {$base + 0x00}] 1] 0]
  set otyper [lindex [rd [expr {$base + 0x04}] 1] 0]
  set pupdr  [lindex [rd [expr {$base + 0x0C}] 1] 0]
  set idr    [lindex [rd [expr {$base + 0x10}] 1] 0]
  set odr    [lindex [rd [expr {$base + 0x14}] 1] 0]
  set afrl   [lindex [rd [expr {$base + 0x20}] 1] 0]
  set afrh   [lindex [rd [expr {$base + 0x24}] 1] 0]
  resume

  echo "GPIO$p @ [hex32 $base]"
  echo "  MODER [hex32 $moder]  OTYPER [hex32 $otyper]  PUPDR [hex32 $pupdr]"
  echo "  IDR   [hex32 $idr]  ODR    [hex32 $odr]"
  echo "  AFRL  [hex32 $afrl]  AFRH   [hex32 $afrh]"
  echo ""
  echo "  pin  mode      pull     in out  af"
  for {set i 15} {$i >= 0} {incr i -1} {
    set m [expr {($moder >> ($i*2)) & 3}]
    set u [expr {($pupdr >> ($i*2)) & 3}]
    set af [expr {$i < 8 ? (($afrl >> ($i*4)) & 0xf) : (($afrh >> (($i-8)*4)) & 0xf)}]
    set mn [lindex {input output alt-fn analog} $m]
    set un [lindex {none pull-up pull-dn rsvd} $u]
    echo [format "  P%s%-3d %-9s %-8s %d   %d   %s" $p $i $mn $un \
            [expr {($idr >> $i) & 1}] [expr {($odr >> $i) & 1}] \
            [expr {$m == 2 ? "AF$af" : "-"}]]
  }
}
