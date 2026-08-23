# Link reliability characterisation.
#
# The physical link is hand-held dupont wire onto USB-C contacts, at battery
# voltage rather than a clean 3.3 V. Earlier sessions saw not just dropped
# reads but *corrupted* ones — garbled DPIDR values like 0x003E133F that came
# back as if they were valid. A read that silently returns garbage is far more
# dangerous than one that errors, because flash verification would accept it.
#
# So this doesn't just count failures: every read is checked against a value
# we already know. CPUID must be 0x410CC601, and the first 32 words of flash
# must match the stock dump we captured. Anything else is corruption.
#
# Speed matters for the write plan too. The vendor fills the flash page buffer
# from RAM at full clock; we fill it over SWD. If that buffer has an
# undocumented timeout, the fastest reliable speed is what makes programming
# possible.

set ::LT_CPUID      0xE000ED00
set ::LT_CPUID_EXP  0x410CC601

proc lt_pct {n d} {
  if {$d == 0} { return "  -  " }
  return [format "%5.1f%%" [expr {100.0 * $n / $d}]]
}

# One word. Returns the value, or the string ERR if the link faulted.
proc lt_read1 {addr} {
  if {[catch {read_memory $addr 32 1} r]} { return "ERR" }
  return [lindex $r 0]
}

# Confirm the link is alive at a known-good speed. Used to recover after a
# speed that breaks it, so one bad rung doesn't poison the rest of the sweep.
proc lt_recover {{spd 100}} {
  adapter speed $spd
  for {set i 0} {$i < 5} {incr i} {
    if {[lt_read1 $::LT_CPUID] == $::LT_CPUID_EXP} { return 1 }
  }
  return 0
}

proc x2_linktest {{speeds {25 50 100 200 500 1000 2000}} {trials 40} {bulks 20}} {
  if {![info exists ::REF_WORDS]} {
    error "no reference data — generate it with bin2tcl.py --var REF"
  }
  set nref [llength $::REF_WORDS]

  echo "link test: $trials single reads + $bulks bulk reads ($nref words) per speed"
  echo "reference: CPUID [format 0x%08X $::LT_CPUID_EXP] and [format 0x%08X $::REF_ADDR] from the stock dump"
  echo ""
  echo "  speed    single-word      bulk-read        bad words     KB/s   verdict"
  echo "  ------------------------------------------------------------------------"

  set results {}

  foreach spd $speeds {
    adapter speed $spd
    catch {lt_read1 $::LT_CPUID}          ;# settle, result ignored

    # --- single-word integrity ---
    set ok1 0; set bad1 0; set err1 0; set firstbad ""
    for {set i 0} {$i < $trials} {incr i} {
      set v [lt_read1 $::LT_CPUID]
      if {$v eq "ERR"} {
        incr err1
      } elseif {$v == $::LT_CPUID_EXP} {
        incr ok1
      } else {
        incr bad1
        if {$firstbad eq ""} { set firstbad [format 0x%08X $v] }
      }
    }

    # --- bulk integrity, the transfer shape flash verification uses ---
    set okb 0; set badb 0; set errb 0; set wbad 0
    set t0 [clock milliseconds]
    for {set i 0} {$i < $bulks} {incr i} {
      if {[catch {read_memory $::REF_ADDR 32 $nref} got]} {
        incr errb
        continue
      }
      set wrong 0
      for {set j 0} {$j < $nref} {incr j} {
        if {[lindex $got $j] != [lindex $::REF_WORDS $j]} { incr wrong }
      }
      if {$wrong} { incr badb; incr wbad $wrong } else { incr okb }
    }
    set dt [expr {[clock milliseconds] - $t0}]
    set kbs 0.0
    if {$dt > 0} { set kbs [expr {($bulks * $nref * 4.0) / $dt}] }

    set clean [expr {$ok1 == $trials && $okb == $bulks}]
    set dead  [expr {$ok1 == 0 && $okb == 0}]
    if {$clean}     { set verdict "clean" } \
    elseif {$dead}  { set verdict "DEAD" } \
    else            { set verdict "UNRELIABLE" }

    echo [format "  %4dk    %2d/%-2d %s   %2d/%-2d %s   %4d/%-5d  %6.1f   %s" \
          $spd $ok1 $trials [lt_pct $ok1 $trials] \
          $okb $bulks [lt_pct $okb $bulks] \
          $wbad [expr {$bulks * $nref}] $kbs $verdict]

    if {$bad1 > 0} {
      echo "           !! $bad1 CORRUPT single reads (first: $firstbad) - silent corruption, not just dropouts"
    }
    if {$err1 > 0 || $errb > 0} {
      echo "           .. $err1 single / $errb bulk reads faulted outright"
    }

    lappend results [list $spd $clean $kbs]

    if {$dead} {
      echo "           .. link dead at this speed; recovering at 100k..."
      if {![lt_recover]} {
        echo ""
        echo "  LINK LOST. Re-seat the probe leads and run again."
        return
      }
    }
  }

  # --- recommendation ---
  echo ""
  set best 0; set bestkbs 0.0
  foreach r $results {
    if {[lindex $r 1] && [lindex $r 0] > $best} {
      set best [lindex $r 0]; set bestkbs [lindex $r 2]
    }
  }
  if {$best == 0} {
    echo "  No speed was clean. Do NOT flash. Improve the physical contact first:"
    echo "  the usual cause is ground, not the signal lines."
  } else {
    echo [format "  Fastest fully clean speed: %dk (%.1f KB/s)" $best $bestkbs]
    set safe [expr {$best >= 200 ? $best / 2 : $best}]
    echo [format "  Suggested for flashing:    %dk  (one step back for margin)" $safe]
    echo ""
    echo "  Set it with:  ADAPTER_SPEED=$safe ./tools/x2.sh <command>"
  }
  echo ""
  echo "  Note: the stock firmware sleeps when idle, and STOP mode kills the"
  echo "  debug port. If results degrade partway through, check it is still"
  echo "  charging before blaming the speed."

  adapter speed 100
}
