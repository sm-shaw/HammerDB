proc tcount_mssqls {bm interval masterthread} {
    global tc_threadID
    upvar #0 dbdict dbdict
    if {[dict exists $dbdict mssqlserver library ]} {
        set library [ dict get $dbdict mssqlserver library ]
    } else { set library "tdbc::odbc 1.0.6" }
    if { [ llength $library ] > 1 } { 
        set version [ lindex $library 1 ]
        set library [ lindex $library 0 ]
    }
    #Setup Transaction Counter Thread
    set tc_threadID [thread::create {
        proc read_more { MASTER library version mssqls_server mssqls_port mssqls_authentication mssqls_odbc_driver mssqls_uid mssqls_pass mssqls_tcp mssqls_azure mssqls_encrypt_connection mssqls_trust_server_cert msi_object_id db interval old tce bm } {
            set timeout 0
            set iconflag 0
            proc connect_string { server port odbc_driver authentication uid pwd tcp azure db encrypt trust_cert msi_object_id} {
                 if { $tcp eq "true" } { set server tcp:$server,$port }
                 if {[ string toupper $authentication ] eq "WINDOWS" } {
                     set connection "DRIVER=$odbc_driver;SERVER=$server;TRUSTED_CONNECTION=YES"
               } else {
                 if {[ string toupper $authentication ] eq "SQL" } {
                     set connection "DRIVER=$odbc_driver;SERVER=$server;UID=$uid;PWD=$pwd"
               } else {
                 if {[ string toupper $authentication ] eq "ENTRA" } {
                 if {[ regexp {[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}} $msi_object_id ] } {
                     set connection "DRIVER=$odbc_driver;SERVER=$server;AUTHENTICATION=ActiveDirectoryMsi;UID=$msi_object_id"
	       } else {
                     set connection "DRIVER=$odbc_driver;SERVER=$server;AUTHENTICATION=ActiveDirectoryInteractive"
	       }
               } else {
                     puts stderr "Error: neither WINDOWS, ENTRA or SQL Authentication has been specified"
                     set connection "DRIVER=$odbc_driver;SERVER=$server"
               }
              }
             }
                if { $azure eq "true" } { append connection ";" "DATABASE=$db" }
                if { $encrypt eq "true" } { append connection ";" "ENCRYPT=yes" } else { append connection ";" "ENCRYPT=no" }
                if { $trust_cert eq "true" } { append connection ";" "TRUSTSERVERCERTIFICATE=yes" }
                return $connection
             }
            if { $interval <= 0 } { set interval 10 } 
            set gcol "yellow"
            if { ![ info exists tcdata ] } { set tcdata {} }
            if { ![ info exists timedata ] } { set timedata {} }
            if { $bm eq "TPC-C" } {
                set tval 60
            } else {
                set tval 3600
            }
            set mplier [ expr {$tval / $interval} ]
            if {[catch {package require $library $version} message]} {
                tsv::set application tc_errmsg "failed to load library $message"
                eval [subst {thread::send $MASTER show_tc_errmsg}]
                thread::release
                return
            }
            if [catch {package require tcountcommon} message ] {
                tsv::set application tc_errmsg "failed to load common transaction counter functions $message"
                eval [subst {thread::send $MASTER show_tc_errmsg}]
                thread::release
                return
            } else {
                namespace import tcountcommon::*
            }
            set connection [ connect_string $mssqls_server $mssqls_port $mssqls_odbc_driver $mssqls_authentication $mssqls_uid $mssqls_pass $mssqls_tcp $mssqls_azure $db $mssqls_encrypt_connection $mssqls_trust_server_cert $msi_object_id ]
            if [catch {tdbc::odbc::connection create tc_odbc $connection} message ] {
                tsv::set application tc_errmsg "connection failed $message"
                eval [subst {thread::send $MASTER show_tc_errmsg}]
                thread::release
                return
            } 
            #Enter loop until stop button pressed
            while { $timeout eq 0 } {
                set timeout [ tsv::get application timeout ]
                if { $timeout != 0 } { break }
                if {[catch {set rows [ tc_odbc allrows "select cntr_value from sys.dm_os_performance_counters where counter_name = 'Batch Requests/sec'" ]} message]} {
                    tsv::set application tc_errmsg "sql failed $message"
                    eval [subst {thread::send $MASTER show_tc_errmsg}]
                    catch { tc_odbc close }
                    break
                } else {
                    set tc_trans [ lindex {*}$rows 1 ]
                    if { $bm eq "TPC-C" || $bm eq "TPC-H" } {
                        if { [ string is entier -strict $tc_trans ] } {
                            set outc $tc_trans
                        } else {
                            #SQL Server returned invalid transcount data setting to 0
                            set outc 0
                        }
                    }
                }
                set new $outc
                set tstamp [ clock format [ clock seconds ] -format %H:%M:%S ]
                set tcsize [ llength $tcdata ]
                if { $tcsize eq 0 } { 
                    set newtick 1 
                    lappend tcdata $newtick 0
                    lappend timedata $newtick $tstamp
                    if { [ catch {thread::send -async $MASTER {::showLCD 0 }}] } { break } 
                } else { 
                    if { $tcsize >= 40 } {
                        set tcdata [ downshift $tcdata ]
                        set timedata [ downshift $timedata ]
                        set newtick 20
                    } else {
                        set newtick [ expr {$tcsize / 2 + 1} ] 
                        if { $newtick eq 2 } {
                            set tcdata [ lreplace $tcdata 0 1 1 [expr {[expr {abs($new - $old)}] * $mplier}] ]
                        }
                    }
                    lappend tcdata $newtick [expr {[expr {abs($new - $old)}] * $mplier}]
                    lappend timedata $newtick $tstamp
                    if { ![ isdiff $tcdata ] } {
                        set tcdata [ lreplace $tcdata 1 1 0 ]
                    }
                    set transval [expr {[expr {abs($new - $old)}] * $mplier}]
                if { [ catch [ subst {thread::send -async $MASTER {::showLCD $transval }} ] ] } { break }} 
                if { $tcsize >= 2 } { 
                    if { $iconflag eq 0 } {
                        if { [ catch [ subst {thread::send -async $MASTER { .ed_mainFrame.tc.g delete "all" }} ] ] } { break }
                        set iconflag 1
                    }
                    if { [ zeroes $tcdata ] eq 0 } {
                        set tcdata {}
                        set timedata {}
                        if { [ catch {thread::send -async $MASTER { tce destroy }}]} { break }
                    } else {
                        if { [ catch [ subst {thread::send -async $MASTER { tce data d1 -colour $gcol -points 0 -lines 1 -coords {$tcdata} -time {$timedata} }} ] ] } { break } 
                    }
                }
                set old $new
                set pauseval $interval
                for {set pausecount $pauseval} {$pausecount > 0} {incr pausecount -1} {
                    if { [ tsv::get application timeout ] } { break } else { after 1000 }
                }
            }
            eval  [ subst {thread::send -async $MASTER { post_kill_transcount_cleanup }} ]
            thread::release
        }
        thread::wait 
    }]
    #Setup Transaction Counter Connection Variables
    upvar #0 configmssqlserver configmssqlserver
    setlocaltcountvars $configmssqlserver 1
    if {![string match windows $::tcl_platform(platform)]} {
        set mssqls_server $mssqls_linux_server 
        set mssqls_odbc_driver $mssqls_linux_odbc
        set mssqls_authentication $mssqls_linux_authent 
    }
    if { $bm eq "TPC-C" } {
        set db $mssqls_dbase
    } else {
        set db $mssqls_tpch_dbase
    }
    set old 0
    #add zipfs paths to thread
    catch {eval [ subst {thread::send $tc_threadID {lappend ::auto_path [zipfs root]app/lib}}]}
    catch {eval [ subst {thread::send $tc_threadID {::tcl::tm::path add [zipfs root]app/modules modules}}]}
    #Call Transaction Counter to start read_more loop
    eval [ subst {thread::send -async $tc_threadID { read_more $masterthread $library $version {$mssqls_server} $mssqls_port $mssqls_authentication {$mssqls_odbc_driver} $mssqls_uid [ quotemeta $mssqls_pass ] $mssqls_tcp $mssqls_azure $mssqls_encrypt_connection $mssqls_trust_server_cert $mssqls_msi_object_id $db $interval $old tce $bm }}]
} 
