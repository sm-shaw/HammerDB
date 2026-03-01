# CI configuration: load ci.xml -> cidict and mirror into SQLite
# Escape single quotes for SQLite literals
proc CI_SQLEscape {s} {
    # Double up single quotes: '  →  ''
    return [string map {' ''} $s]
}

# CI-only: write CI dict to SQLite
proc CIDict2SQLite {dbname dbdict} {
    set sqlitedb [CheckSQLiteDB $dbname]

    if {[catch {sqlite3 hdb $sqlitedb} message]} {
        putscli "CI CONFIG: error initializing SQLite database: $message"
        return 0
    }

    catch {hdb timeout 30000}

    if {$sqlitedb eq ""} {
        putscli "CI CONFIG: empty SQLite DB path"
        return 0
    }

    # For safety, quote table names
    dict for {key attributes} $dbdict {
        set tablename $key

        # Drop and recreate table
        set sqlcmd "DROP TABLE IF EXISTS \"$tablename\""
        catch {hdb eval $sqlcmd}

        set sqlcmd "CREATE TABLE \"$tablename\"(key TEXT, val TEXT)"
        if {[catch {hdb eval $sqlcmd} message]} {
            putscli "CI CONFIG: error creating table $tablename in $sqlitedb : $message"
            return 0
        }

        # Insert rows with safely escaped values
        dict for {subkey subattributes} $attributes {
            set k [CI_SQLEscape $subkey]
            set v [CI_SQLEscape $subattributes]
            set sqlcmd "INSERT INTO \"$tablename\"(key, val) VALUES('$k', '$v')"
            if {[catch {hdb eval $sqlcmd} message]} {
                putscli "CI CONFIG: error inserting into $tablename in $sqlitedb : $message"
                return 0
            }
        }
    }

    return 1
}

# CI-only: read overrides from ci.db and return a nested dict:
#   common           -> common {k v ...}
#   MariaDB_pipeline -> MariaDB {pipeline {k v ...}}
#   MariaDB_install  -> MariaDB {install  {k v ...}}
proc SQLite2Dict_ci {dbname} {
    set sqlitedb [CheckSQLiteDB $dbname]

    if {$sqlitedb eq "" || ![file exists $sqlitedb]} {
        return ""
    }

    if {[catch {sqlite3 cih $sqlitedb} message]} {
        putscli "CI ERROR: Cannot open SQLite database $sqlitedb : $message"
        return ""
    }

    catch {cih timeout 30000}

    set overrides [dict create]

    if {[catch {set tbllist [cih eval {SELECT name FROM sqlite_master WHERE type='table'}]} err]} {
        putscli "CI ERROR: Failed to read CI table list from $sqlitedb : $err"
        catch {cih close}
        return ""
    }

    foreach tbl $tbllist {
        # common: flat key/val overrides
        if {$tbl eq "common"} {
            set subdict [dict create]
            if {[catch {
                cih eval "SELECT key, val FROM \"$tbl\"" {
                    dict set subdict $key $val
                }
            } qerr]} {
                putscli "CI WARN: Skipping table '$tbl' in CI SQLite: $qerr"
                continue
            }
            dict set overrides common $subdict
            continue
        }

        # Top_section form, e.g. "MariaDB_pipeline"
        if {![regexp {^([^_]+)_(.+)$} $tbl -> top section]} {
            # Ignore other tables (e.g. "MariaDB" created by initial CIDict2SQLite)
            continue
        }

        set secdict [dict create]
        if {[catch {
            cih eval "SELECT key, val FROM \"$tbl\"" {
                dict set secdict $key $val
            }
        } qerr]} {
            putscli "CI WARN: Skipping table '$tbl' in CI SQLite: $qerr"
            continue
        }

        dict set overrides $top $section $secdict
    }

    catch {cih close}

    if {[dict size $overrides] == 0} {
        return ""
    }
    return $overrides
}

proc find_ciplan_dir {} {
    if {[catch {
        set ISConfigDir [file join {*}[lrange [file split [file normalize [file dirname [info script]]]] 0 end-2] config]
    }]} {
        set ISConfigDir ""
    }
    set PWConfigDir [file join [pwd] config]
    foreach CD {ISConfigDir PWConfigDir} {
        if {[file isdirectory [set $CD]]} {
            if {[file exists [file join [set $CD] ci.xml]]} {
                return [set $CD]
            }
        }
    }
    return "FNF"
}

proc get_ciplan_xml {} {
    if {[catch {package require xml}]} {
        error "Failed to load xml package in CI"
    }
    set ciplandir [find_ciplan_dir]
    if {$ciplandir eq "FNF"} {
        error "Cannot find config directory or ci.xml"
    }
    set ciplanxml "$ciplandir/ci.xml"
    if {![file exists $ciplanxml]} {
        error "CI plan specified but file $ciplanxml does not exist"
    }
    set ciplan [::XML::To_Dict_Ml $ciplanxml]
    return $ciplan
}

# Global CI config dict
global cidict
set cidict [dict create]

# Initialise CI config:
#  - Always start from ci.xml
#  - Overlay any overrides found in ci.db (common + Top_section tables)
#  - Seed ci.db from XML on first run
proc ci_init_config {} {
    global cidict

    # 1) Base config from XML
    if {[catch { set xml_cfg [get_ciplan_xml] } err]} {
        putscli "CI CONFIG: could not load ci.xml ($err)"
        set cidict [dict create]
        return
    }

    # 2) Load overrides from ci.db (if any)
    set override_cfg [SQLite2Dict_ci "ci"]

    if {$override_cfg eq ""} {
        # First run or no usable overrides: commit XML to memory and seed SQLite
        set cidict $xml_cfg
        if {[catch { CIDict2SQLite "ci" $cidict } derr]} {
            putscli "CI CONFIG: failed to save CI config to SQLite ($derr)"
        }
        return
    }

    # 3) Merge: XML as base, SQLite overrides on top
    set merged $xml_cfg

    foreach top [dict keys $override_cfg] {
        if {$top eq "common"} {
            # common {listen_port 5000 ...}
            set sub [dict get $override_cfg common]
            foreach k [dict keys $sub] {
                dict set merged common $k [dict get $sub $k]
            }
        } else {
            # MariaDB, MySQL, PostgreSQL, etc. with sub-sections: build/install/test/pipeline...
            set topdict [dict get $override_cfg $top]
            foreach section [dict keys $topdict] {
                set secdict [dict get $topdict $section]
                foreach k [dict keys $secdict] {
                    dict set merged $top $section $k [dict get $secdict $k]
                }
            }
        }
    }

    set cidict $merged
}

# CI-specific SQLite updater: auto-create table and upsert key/value
proc SQLiteUpdateKeyValue_ci {dbname table keyname value} {
    # Resolve DB path (ci.db)
    set sqlitedb [CheckSQLiteDB $dbname]

    if {$sqlitedb eq ""} {
        putscli "CI ERROR: SQLite DB path for '$dbname' is empty"
        return
    }

    # Open separate CI handle so we don't interfere with hdb jobs handle
    if {[catch {sqlite3 hci $sqlitedb} err]} {
        putscli "CI ERROR: Failed to open SQLite DB '$sqlitedb': $err"
        return
    }
    catch {hci timeout 30000}

    # Ensure table exists: CREATE TABLE IF NOT EXISTS "<table>"(key TEXT, val TEXT)
    set create_sql [format {CREATE TABLE IF NOT EXISTS "%s"(key TEXT, val TEXT)} $table]
    if {[catch {hci eval $create_sql} err]} {
        putscli "CI ERROR: Failed to ensure table '$table' in '$sqlitedb': $err"
        catch {hci close}
        return
    }

    # Escape single quotes in key and value
    set esckey [string map {' ''} $keyname]
    set escval [string map {' ''} $value]

    # UPDATE first
    set update_sql [format {UPDATE "%s" SET val = '%s' WHERE key = '%s'} \
                        $table $escval $esckey]
    if {[catch {hci eval $update_sql} err]} {
        putscli "CI ERROR: Failed to update SQLite: $err"
        catch {hci close}
        return
    }

    # Did UPDATE change anything?
    set changed 0
    catch { set changed [hci eval {SELECT changes()}] }

    # If no row updated, INSERT
    if {$changed == 0} {
        set insert_sql [format {INSERT INTO "%s"(key,val) VALUES('%s','%s')} \
                            $table $esckey $escval]
        if {[catch {hci eval $insert_sql} err]} {
            putscli "CI ERROR: Failed to insert into SQLite: $err"
            catch {hci close}
            return
        }
    }

    catch {hci close}
}

proc ciset {args} {
    global cidict

    # Accept either:
    #   ciset top section key value   (nested)
    # or
    #   ciset top key value           (flat, e.g. common)
    set argc [llength $args]
    if {$argc != 4 && $argc != 3} {
        putscli "Error: Invalid number of arguments"
        putscli "Usage: ciset top section key value"
        putscli "   or: ciset top key value"
        putscli "Example: ciset MariaDB build repo_url https://github.com/new/repo.git"
        putscli "Example: ciset common diff_threshold 0.03"
        return
    }

    if {$argc == 4} {
        set top     [lindex $args 0]
        set section [lindex $args 1]
        set key     [lindex $args 2]
        set val     [lindex $args 3]
    } else {
        # 3-arg form: top key value (flat table like common)
        set top     [lindex $args 0]
        set section ""
        set key     [lindex $args 1]
        set val     [lindex $args 2]
    }

    # --- Case-insensitive match for top-level (common / MariaDB / MySQL / PostgreSQL etc.) ---
    set matchTop ""
    foreach k [dict keys $cidict] {
        if {[string equal -nocase $k $top]} {
            set matchTop $k
            break
        }
    }

    if {$matchTop eq ""} {
        putscli "CI ERROR: Top-level '$top' does not exist"
        putscli "Available: [join [dict keys $cidict] ,]"
        return
    }

    # Normalise to canonical key from cidict (e.g. MariaDB, not mariadb)
    set top $matchTop

    if {$argc == 3} {
        # Flat: validate key under top
        if {![dict exists $cidict $top $key]} {
            putscli "CI ERROR: Key '$key' not found under '$top'"
            putscli "Available: [join [dict keys [dict get $cidict $top]] ,]"
            return
        }

        set previous [dict get $cidict $top $key]
        if {$previous eq $val} {
            putscli "Value unchanged ($val) — no update needed."
            return
        }

        dict set cidict $top $key $val
        putscli "Changed $top/$key from \"$previous\" to \"$val\""

        # Persist to SQLite: table = top (e.g. common)
        if {[catch {
            SQLiteUpdateKeyValue_ci "ci" $top $key $val
        } err]} {
            putscli "CI ERROR: Failed to update SQLite: $err"
        }

        remote_command [concat ciset $top $key [list \{$val\}]]
        return
    }

    # ---- existing 4-arg behaviour (nested) ----

    # Validate level 2
    if {![dict exists $cidict $top $section]} {
        putscli "CI ERROR: Section '$section' not found under '$top'"
        putscli "Available: [join [dict keys [dict get $cidict $top]] ,]"
        return
    }

    # Validate level 3
    if {![dict exists $cidict $top $section $key]} {
        putscli "CI ERROR: Key '$key' not found under '$top/$section'"
        putscli "Available: [join [dict keys [dict get $cidict $top $section]] ,]"
        return
    }

    set previous [dict get $cidict $top $section $key]
    if {$previous eq $val} {
        putscli "Value unchanged ($val) — no update needed."
        return
    }

    dict set cidict $top $section $key $val
    putscli "Changed $top/$section/$key from \"$previous\" to \"$val\""

    # Persist change in TWO places:
    #  1) Override table (Top_section) used by ci_init_config overlay logic.
    #  2) Canonical top-level table (e.g. "MariaDB") so generic SQLite2Dict "ci"
    #     also reflects the effective config.
    if {[catch {
        # (1) override table, e.g. MariaDB_build
        SQLiteUpdateKeyValue_ci "ci" "${top}_${section}" $key $val

        # (2) canonical table, e.g. MariaDB : key=build val=<dict-string>
        #     This mirrors CIDict2SQLite behaviour where section values are stored
        #     as dict-encoded strings.
        set secdict_str [dict get $cidict $top $section]
        SQLiteUpdateKeyValue_ci "ci" $top $section $secdict_str
    } err]} {
        putscli "CI ERROR: Failed to update SQLite: $err"
    }

    remote_command [concat ciset $top $section $key [list \{$val\}]]
}

# One-time CI config init on load
if {![info exists ::ci_config_inited]} {
    set ::ci_config_inited 1
    ci_init_config
}

proc ci_check_tmp {} {
    if {![info exists ::env(TMP)] || $::env(TMP) eq ""} {
        putscli "CI TMP WARNING: ::env(TMP) not set; jobs DB will default to /tmp/hammer.DB"
    } else {
        putscli "CI TMP INFO: ::env(TMP) = $::env(TMP)"
        putscli "CI TMP INFO: Jobs on-disk DB = $::env(TMP)/hammer.DB"
    }
}

proc citmp {} {
    if {[info exists ::env(TMP)] && $::env(TMP) ne ""} {
        putscli "TMP = $::env(TMP)"
        putscli "Jobs DB file = $::env(TMP)/hammer.DB"
    } else {
        putscli "TMP not set; default jobs DB = /tmp/hammer.DB"
    }
}

proc ci_latest_id {refname} {
    set ci_id ""
    if {[catch {
        set ci_id [hdbjobs eval {
            SELECT ci_id
            FROM JOBCI
            WHERE refname=$refname
              AND status != 'PENDING'
            ORDER BY ci_id DESC
            LIMIT 1
        }]
    } err]} {
        putscli "Warning: failed to query latest ci_id for refname $refname: $err"
        return ""
    }
    return $ci_id
}

proc cilisten {args} {
    global cidict

    if {[info exists ::listen_socket]} {
        putscli "CI listener already running; run cistop to stop"
        return
    }

    if {[llength $args] != 0} {
        putscli "Usage: cilisten"
        return
    }

    if {[catch {package require json}]} {
        error "Failed to load json package"
        return
    }

    if {![dict exists $cidict common listen_port]} {
        ci_init_config
    }
    if {![dict exists $cidict common listen_port]} {
        putscli "CI CONFIG: <common>/<listen_port> missing in CI config"
        return
    }

    set port [dict get $cidict common listen_port]
    putscli "Starting CI GitHub webhook listener on port $port..."

    proc handle_connection {sock addr port} {
        global cidict
        fconfigure $sock -translation crlf -buffering line -blocking 1
        fileevent $sock readable [list read_request $sock $cidict]
    }

    proc read_request {sock cidict} {
        variable headers
        variable body
        variable state
        variable content_length

        if {[eof $sock]} {
            close $sock
            return
        }

        if {![info exists state]} {
            set state headers
            set headers {}
            set body ""
            set content_length 0
        }

        if {$state eq "headers"} {
            while {[gets $sock line] >= 0} {
                if {$line eq ""} {
                    set state body
                    break
                }
                lappend headers $line
                if {[regexp -nocase {Content-Length:\s*(\d+)} $line -> cl]} {
                    set content_length $cl
                }
            }
        }

        if {$state eq "body"} {
            set body [read $sock $content_length]
            process_request $sock $headers $body $cidict
            unset state headers body content_length
        }
    }

proc http_reply {sock code body} {
    if {[lsearch -exact [chan names] $sock] == -1} { return }
    puts $sock "HTTP/1.1 $code"
    puts $sock "Content-Type: text/plain"
    puts $sock "Content-Length: [string length $body]"
    puts $sock "Connection: close"
    puts $sock ""
    puts $sock $body
    flush $sock
    close $sock
}

proc process_request {sock headers body cidict} {
    global rdbms

    # --------------------------------------------------
    # Parse JSON
    # --------------------------------------------------
    if {[catch {set json_data [json::json2dict $body]} err]} {
        putscli "Invalid JSON payload: $err"
        http_reply $sock "400 Bad Request" "Invalid JSON"
        return
    }

    # --------------------------------------------------
    # Required: database
    # --------------------------------------------------
    if {![dict exists $json_data database]} {
        putscli "CI payload missing database"
        http_reply $sock "400 Bad Request" "Missing database"
        return
    }

    set dbprefix [string tolower [string trim [dict get $json_data database]]]
    if {$dbprefix eq ""} {
        putscli "CI payload database empty"
        http_reply $sock "400 Bad Request" "Empty database"
        return
    }

    # Resolve dbprefix → rdbms using dbdict
    upvar #0 dbdict dbdict
    set dbl {}
    set prefixl {}
    dict for {database attributes} $dbdict {
        dict with attributes {
            lappend dbl $name
            lappend prefixl $prefix
        }
    }

    set ind [lsearch -exact $prefixl $dbprefix]
    if {$ind eq -1} {
        putscli "Unknown prefix $dbprefix (valid: $prefixl)"
        http_reply $sock "400 Bad Request" "Unknown database prefix"
        return
    }

    set resolved_rdbms [lindex $dbl $ind]

    # Ensure enabled in CI config
    set enabled_dbs {}
    foreach k [dict keys $cidict] {
        if {$k eq "common"} continue
        lappend enabled_dbs $k
    }

    if {[lsearch -exact $enabled_dbs $resolved_rdbms] == -1} {
        putscli "$resolved_rdbms not enabled for CI"
        http_reply $sock "400 Bad Request" "Database not enabled"
        return
    }

    # Switch DB context
    unset -nocomplain rdbms
    dbset db $dbprefix
    if {![info exists rdbms] || $rdbms eq ""} {
        putscli "Failed to dbset db $dbprefix"
        http_reply $sock "500 Internal Server Error" "Failed to set database context"
        return
    }

    # --------------------------------------------------
    # Optional: pipeline / workload
    # --------------------------------------------------
    set pipeline "single"
    if {[dict exists $json_data pipeline]} {
        set pipeline [string tolower [string trim [dict get $json_data pipeline]]]
    }

    set workload "C"
    if {[dict exists $json_data workload]} {
        set workload [string toupper [string trim [dict get $json_data workload]]]
    }

    # Map single workload
    if {$pipeline eq "single"} {
        if {$workload eq "H"} {
            set pipeline "single_h"
        } else {
            set pipeline "single_c"
        }
    }

    # --------------------------------------------------
    # Required: ref
    # --------------------------------------------------
    if {![dict exists $json_data ref]} {
        putscli "CI payload missing ref"
        http_reply $sock "400 Bad Request" "Missing ref"
        return
    }

    set ref [dict get $json_data ref]

    set ref_regexp [string map {\" {}} [dict get $cidict $rdbms build ref_regexp]]
    set overwrite  [dict get $cidict $rdbms build overwrite]

    set matched 0

    if {[regexp [subst {$ref_regexp}] $ref -> type name]} {
        set matched 1
    } elseif {[regexp {^[0-9a-fA-F]{7,40}$} $ref]} {
        set type "sha"
        set name $ref
        set matched 1
    }

    if {!$matched} {
        putscli "Ref did not match CI rules: $ref"
        http_reply $sock "400 Bad Request" "Invalid ref"
        return
    }

    # --------------------------------------------------
    # Insert into JOBCI
    # --------------------------------------------------
    if {$overwrite} {
        catch {hdbjobs eval {DELETE FROM JOBCI WHERE refname=$name}}
    }

    if {[catch {
        hdbjobs eval {INSERT INTO JOBCI (refname,dbprefix,pipeline,cidict)
                      VALUES ($name,$dbprefix,$pipeline,$cidict)}
    } err]} {
        putscli "Error inserting JOBCI row: $err"
        http_reply $sock "500 Internal Server Error" "Insert failed"
        return
    }

    putscli "Recorded: $name db=$dbprefix pipeline=$pipeline"

    # --------------------------------------------------
    # HTTP 200 response
    # --------------------------------------------------
    if {[lsearch -exact [chan names] $sock] != -1} {
        puts $sock "HTTP/1.1 200 OK"
        puts $sock "Content-Type: text/plain"
        puts $sock "Content-Length: 2"
        puts $sock "Connection: close"
        puts $sock ""
        puts $sock "OK"
        flush $sock
        close $sock
    }
}
    set listen_socket [socket -server handle_connection $port]
    putscli "CI webhook listening on port $port"
    initwatcher $listen_socket
}

proc cistop {} {
    if {![info exists ::listen_socket]} {
        putscli "CI listener not running; run cilisten"
        return
    }
    putscli "Stopping CI webhook listener"
    if {[lsearch -exact [chan names] $::listen_socket] != -1} {
        catch {close $::listen_socket}
        unset -nocomplain ::listen_socket
        stopwatcher
    }
}

proc cistatus {} {
    if {![info exists ::listen_socket]} {
        putscli "CI listener not running"
    } else {
        putscli "CI listener running"
        if {$::watcher_running} {
            putscli "CI watcher running"
        } else {
            putscli "CI watcher not running"
        }
    }
}

proc cipush {refname {pipeline single} {workload C} {dbprefix ""}} {
    global rdbms cidict

    # --------------------------------------------------
    # Resolve dbprefix
    # --------------------------------------------------
    if {$dbprefix eq ""} {
        if {![info exists rdbms]} {
            putscli "Error: RDBMS not set (pass dbprefix or run: dbset db <prefix>)"
            return
        }
        set dbprefix [find_prefix $rdbms]
    }

    set dbprefix [string tolower [string trim $dbprefix]]
    if {$dbprefix eq ""} {
        putscli "Error: dbprefix empty"
        return
    }

    # --------------------------------------------------
    # Ensure listener running
    # --------------------------------------------------
    if {![info exists ::listen_socket]} {
        putscli "CI listener not running; starting listener"
        cilisten
    }

    if {![dict exists $cidict common listen_port]} {
        putscli "Error: CI config missing required keys"
        return
    }

    # --------------------------------------------------
    # Validate ref
    # --------------------------------------------------
    if {[string match "refs/tags/*"  $refname]} {
        set ref_type "tag"
    } elseif {[string match "refs/heads/*" $refname]} {
        set ref_type "branch"
    } elseif {[regexp {^[0-9a-fA-F]{7,40}$} $refname]} {
        set ref_type "sha"
    } else {
        putscli "Error: refname must start with 'refs/tags/' or 'refs/heads/' or be a commit SHA"
        return
    }

    set pipeline [string tolower [string trim $pipeline]]
    if {$pipeline eq ""} { set pipeline "single" }

    set workload [string toupper [string trim $workload]]
    if {$workload ni {"C" "H"}} {
        putscli "Error: workload must be C or H"
        return
    }

    # --------------------------------------------------
    # Build JSON payload (no ref_type anymore)
    # --------------------------------------------------
    set body "{\"ref\":\"$refname\",\"database\":\"$dbprefix\",\"pipeline\":\"$pipeline\",\"workload\":\"$workload\"}"

    set headers [dict create X-GitHub-Event "create"]

    # Direct dispatch
    process_request dummy_sock $headers $body $cidict

    putscli "Simulated webhook for $refname db=$dbprefix pipeline=$pipeline workload=$workload"
}

# Line-oriented output reader; sets ::pipe_done on EOF
proc handle_output {pipe} {
    if {[eof $pipe]} {
        fileevent $pipe readable {}
        putscli "command complete."
        set ::pipe_done 1
        return
    }

    if {[gets $pipe line] >= 0} {
        putscli $line
        if {[info exists ::pipe_output]} { append ::pipe_output "$line\n" }
    }
}

# Raw output reader for tests; line-oriented, completion signaled via doneVar
proc handle_test_output {pipe doneVar} {
    # EOF: stop watching and signal done
    if {[eof $pipe]} {
        fileevent $pipe readable {}
        upvar #0 $doneVar done
        set done 1
        return
    }

    # Ensure we are in line mode and non-blocking
    fconfigure $pipe -translation lf -buffering line -blocking 0

    # Drain all available complete lines
    while {[gets $pipe line] >= 0} {
        putscli $line
    }
}

proc system_memory_mb {} {
    set mem_kb 0
    if {[catch {
        set f [open "/proc/meminfo" r]
        while {[gets $f line] >= 0} {
            if {[regexp {^MemTotal:\s+(\d+)\s+kB} $line -> kb]} {
                set mem_kb $kb
                break
            }
        }
        close $f
    }]} {
        return 0
    }
    return [expr {$mem_kb / 1024}]
}

proc calc_buffer_pool_mb {} {
    set mem_mb [system_memory_mb]
    if {$mem_mb <= 0} { return 0 }

    set bp_mb [expr {int($mem_mb / 2)}]

    if {$bp_mb < 1024}   { set bp_mb 1024 }
    if {$bp_mb > 262144} { set bp_mb 262144 }

    return $bp_mb
}

# Periodic watcher
proc job_watcher {} {
    if {$::watcher_running} {
        run_next_pending_job
        if {$::watcher_running} {
            catch { after 10000 job_watcher }
        }
    } else {
        set ::watcher_running 0
    }
}

proc stopwatcher {} {
    putscli "Job watcher stop."
    set ::watcher_running 0
    return
}

proc startwatcher {} {
    putscli "Job watcher start."
    set ::watcher_running 1
    job_watcher
    return
}

proc initwatcher {listen_socket} {
    set ::listen_socket $listen_socket
    startwatcher
    return
}

# Execute next pending job
proc run_next_pending_job {} {
    global rdbms cidict

    set ci_id    ""
    set refname  ""
    set pipeline ""
    set dbprefix ""

    # --------------------------------------------------
    # Find oldest PENDING job
    # --------------------------------------------------
    if {[catch {
        set ci_id [hdbjobs eval {
            SELECT ci_id
            FROM JOBCI
            WHERE status = 'PENDING'
            ORDER BY timestamp ASC
            LIMIT 1
        }]

        if {$ci_id ne ""} {
            set refname  [hdbjobs eval { SELECT refname  FROM JOBCI WHERE ci_id = $ci_id }]
            set pipeline [hdbjobs eval { SELECT pipeline FROM JOBCI WHERE ci_id = $ci_id }]
            set dbprefix [hdbjobs eval { SELECT dbprefix FROM JOBCI WHERE ci_id = $ci_id }]
        }
    } err]} {
        putscli "Error querying JOBCI: $err"
        return
    }

    if {$ci_id eq "" || $refname eq ""} {
        return
    }

    # --------------------------------------------------
    # Validate and switch DB context (multi-db support)
    # --------------------------------------------------
    if {$dbprefix eq ""} {
        putscli "Job $ci_id missing dbprefix"
        return
    }

    upvar #0 dbdict dbdict
    set dbl {}
    set prefixl {}
    dict for {database attributes} $dbdict {
        dict with attributes {
            lappend dbl $name
            lappend prefixl $prefix
        }
    }

    set ind [lsearch -exact $prefixl $dbprefix]
    if {$ind eq -1} {
        putscli "Job $ci_id has invalid dbprefix '$dbprefix'"
        return
    }

    unset -nocomplain rdbms
    dbset db $dbprefix

    if {![info exists rdbms] || $rdbms eq ""} {
        putscli "Failed to dbset db $dbprefix for job $ci_id"
        return
    }

    putscli "Found pending job: $refname (db=$dbprefix)"
    putscli "Pausing watcher for run"
    stopwatcher

    # --------------------------------------------------
    # Mark as BUILDING immediately (UI feedback)
    # --------------------------------------------------
    if {[catch {
        hdbjobs eval { UPDATE JOBCI SET status = 'BUILDING' WHERE ci_id = $ci_id }
    } err]} {
        putscli "Error updating status to BUILDING: $err"
        startwatcher
        return
    }

    # --------------------------------------------------
    # PIPELINE DISPATCH
    # --------------------------------------------------
    switch -exact -- [string toupper $pipeline] {

        PROFILE {
            putscli "Dispatching pipeline='profile' for $refname"
            if {[catch {
                cisteps $cidict $refname profile
            } err]} {
                putscli "CI PROFILE pipeline failed: $err"
            }
            startwatcher
            return
        }

        COMPARE {
            putscli "Dispatching pipeline='compare' for $refname"
            if {[catch {
                cisteps $cidict $refname compare
            } err]} {
                putscli "CI COMPARE pipeline failed: $err"
            }
            startwatcher
            return
        }

        default {
            putscli "Dispatching pipeline='$pipeline' for $refname"
            if {[catch {
                cisteps $cidict $refname [string tolower $pipeline]
            } err]} {
                putscli "CI pipeline '$pipeline' failed: $err"
            }
            startwatcher
            return
        }
    }
}

# Run pipeline defined under <$rdbms>/<pipeline>/<name>
proc cisteps {cidict refname pipeline_name} {
    global rdbms
    set r [string tolower $rdbms]

    if {![dict exists $cidict $rdbms pipeline $pipeline_name]} {
        putscli "CI: unknown pipeline '$pipeline_name' under <$rdbms>/<pipeline>"
        return
    }
    set steps     [dict get $cidict $rdbms pipeline $pipeline_name]
    set step_list [split $steps " "]

    putscli "CI: running pipeline '$pipeline_name' → $steps"

    foreach step $step_list {
        if {$step eq ""} continue
        switch -glob -- $step {
            clone {
                set cmd "${r}_clone"
                set st [$cmd $cidict $refname]
                putscli $st
                if {$st eq "CLONE FAILED"} { return }
            }
            build {
                set cmd "${r}_build"
                set st [$cmd $cidict $refname]
                putscli $st
                if {$st eq "BUILD FAILED"} { return }
            }
            package {
                set cmd "${r}_package"
                set st [$cmd $cidict $refname]
                putscli $st
                if {$st eq "PACKAGE FAILED"} { return }
            }
            commit_msg {
                set cmd "${r}_commit_msg"
                putscli [$cmd $cidict $refname]
            }
            install {
                set cmd "${r}_install"
                set st [$cmd $cidict $refname]
                putscli $st
                if {$st eq "INSTALL FAILED"} { return }
            }
            init {
                set cmd "${r}_init"
                set st [$cmd $cidict $refname]
                putscli $st
                if {$st eq "INIT FAILED"} { return }
            }
            start {
                set cmd "${r}_start"
                set st [$cmd $cidict $refname]
                putscli $st
                if {$st eq "START FAILED"} { return }
            }
            restart {
                set cmd "${r}_start"
                set st [$cmd $cidict $refname]
                putscli $st
                if {$st eq "START FAILED"} { return }
            }
            run_sql:* {
                set arg [lindex [split $step ":"] 1]
                if {$arg eq ""} { putscli "CI: run_sql missing argument"; return }
                set cmd "${r}_run_sql"
                set st [$cmd $cidict $refname $arg]
                putscli $st
                if {$st eq "[string toupper $arg] FAILED"} { return }
            }
            start_tests:* {
                set workload [lindex [split $step ":"] 1]
                if {$workload eq ""} { putscli "CI: start_tests missing workload"; return }
                set cmd "${r}_start_tests"
                set st  [$cmd $cidict $refname $workload]
                putscli $st
                if {$st eq "TEST FAILED"} { return }
            }
            profile {
                set cmd "[string tolower $rdbms]_profile"
                set st  [$cmd $cidict $refname]
                putscli $st
                if {$st eq "PROFILE FAILED"} { return }
            }
            compare {
                set cmd "[string tolower $rdbms]_compare"
                set st  [$cmd $cidict $refname]
                putscli $st
                if {$st eq "COMPARE FAILED"} { return }
            }
            default {
                putscli "CI: unknown step token '$step' — skipping"
            }
        }
    }
    putscli "CI: pipeline '$pipeline_name' completed"
}

# CI platform guard: only enable CI commands on Unix/Linux
if {![info exists ::tcl_platform(platform)] || $::tcl_platform(platform) ne "unix"} {
    # Entry-point CI commands that a user might call directly
    foreach p {citmp cilisten cistop cistatus cipush cistep ciset} {
        # If the real command exists…
        if {[info procs $p] ne ""} {
            # …and we haven't already renamed it, move it aside
            if {[info procs _$p] eq ""} {
                rename $p _$p
            }
            # Replace with a stub that just warns
            proc $p {args} {
                putscli "CI WARNING: CI commands are only supported on Linux/Unix platforms in this release."
            }
        }
    }
}
