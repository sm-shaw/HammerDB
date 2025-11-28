#!/bin/tclsh
# maintainer: Pooja Jain
# Maintain compatibility if compare.sh didn't set TMP
if {![info exists ::env(TMP)] || $::env(TMP) eq ""} {
    set ::env(TMP) "[pwd]/TMP"
    file mkdir $::env(TMP)
    puts "TMP not set — defaulting to $::env(TMP)"
}

set tmpdir $::env(TMP)
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-C

# --- NEED PROFILEID FOR COMPARE ---
if {![info exists ::env(PROFILEID)] || $::env(PROFILEID) eq ""} {
    puts "ERROR: PROFILEID not set in environment"
    exit 1
}
set profileid $::env(PROFILEID)
puts "Using PROFILEID = $profileid"
if {![string is integer -strict $profileid]} {
    puts "ERROR: PROFILEID must be an integer, got: '$profileid'"
    exit 1
}
if {[catch { jobs profileid $profileid } jerr]} {
    puts "ERROR: jobs profileid failed: $jerr"
    exit 1
}

giset commandline keepalive_margin 1200
giset timeprofile xt_gather_timeout 1200

diset connection maria_host localhost
diset connection maria_port 3306
diset connection maria_socket /tmp/mariadb.sock

diset tpcc maria_user root
diset tpcc maria_pass maria
diset tpcc maria_dbase tpcc
diset tpcc maria_driver timed
diset tpcc maria_rampup 2
diset tpcc maria_duration 5
diset tpcc maria_allwarehouse false
diset tpcc maria_timeprofile false
diset tpcc maria_purge true
puts "TEST STARTED"
foreach z { 1 8 16 24 32 40 48 56 64 } {
loadscript
vuset vu $z
vuset logtotemp 1
vucreate
tcstart
tcstatus
set jobid [ vurun ]
tcstop
vudestroy
puts "Writing to $tmpdir/maria_tprocc_profile.$profileid"
set of [ open $tmpdir/maria_tprocc_profile.$profileid a ]
puts $of $jobid
close $of
}
puts "TEST COMPLETE"
