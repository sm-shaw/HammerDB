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

    # We need exactly 4 arguments: top section key value
    if {[llength $args] != 4} {
        putscli "Error: Invalid number of arguments"
        putscli "Usage: ciset top section key value"
        putscli "Example: ciset MariaDB build repo_url https://github.com/new/repo.git"
        return
    }

    set top     [lindex $args 0]
    set section [lindex $args 1]
    set key     [lindex $args 2]
    set val     [lindex $args 3]

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

    # Get previous value
    set previous [dict get $cidict $top $section $key]

    # Check if unchanged
    if {$previous eq $val} {
        putscli "Value unchanged ($val) — no update needed."
        return
    }

    # Update dict
    dict set cidict $top $section $key $val

    putscli "Changed $top/$section/$key from \"$previous\" to \"$val\""

    # Persist to SQLite: namespace "ci"
    if {[catch {
        SQLiteUpdateKeyValue_ci "ci" "${top}_${section}" $key $val
    } err]} {
        putscli "CI ERROR: Failed to update SQLite: $err"
    } else {
        # putscli "Saved to SQLite: table=${top}_${section}, key=$key"
    }

    # Broadcast remotely
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

proc cilisten {} {
    global rdbms cidict
    if {[info exists ::listen_socket]} {
        putscli "CI listener already running; run cistop to stop"
        return
    }
    if {[catch {package require json}]} {
        error "Failed to load json package"
        return
    }

    if {[info exists rdbms]} {
        # Validate RDBMS
        set valid_opensource_list {MySQL PostgreSQL MariaDB}
        if {[lsearch -exact $valid_opensource_list $rdbms] == -1} {
            putscli "$rdbms is not supported for open-source cilisten"
            return
        } else {
            putscli "CI listen for $rdbms"
        }
    } else {
        putscli "Database not defined for open-source cilisten"
        return
    }

    # Ensure we have CI config loaded
    if {![dict exists $cidict common listen_port]} {
        ci_init_config
    }
    if {![dict exists $cidict common listen_port]} {
        putscli "CI CONFIG: <common>/<listen_port> missing in CI config"
        return
    }

    set port [dict get $cidict common listen_port]
    putscli "Starting CI GitHub webhook listener on port $port..."

    # Ensure JOBTEST table exists
    if {[catch {
        hdbjobs eval {
            CREATE TABLE IF NOT EXISTS JOBTEST (
                refname TEXT PRIMARY KEY,
                jobid TEXT,
                clone_cmd TEXT,
                clone_output TEXT,
                build_cmd TEXT,
                build_output TEXT,
                install_cmd TEXT,
                install_output TEXT,
                package_cmd TEXT,
                commit_msg TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                timestamp DATETIME NOT NULL DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime')),
                FOREIGN KEY(jobid) REFERENCES JOBMAIN(jobid)
            );
        }
    } err]} {
        putscli "Error creating JOBTEST table: $err"
        return
    }

    # Accept new connections
    proc handle_connection {sock addr port} {
        global cidict
        puts "$sock $addr $port"
        fconfigure $sock -translation crlf -buffering line -blocking 1
        fileevent $sock readable [list read_request $sock $cidict]
    }

    # Read HTTP request (headers + body)
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

    # Process webhook payload and enqueue job
    proc process_request {sock headers body cidict} {
        global rdbms
        set ref_regexp [string map {\" {}} [dict get $cidict $rdbms build ref_regexp]]
        set overwrite  [dict get $cidict $rdbms build overwrite]
        set json_data  [json::json2dict $body]
        set inserted   0

        if {[dict exists $json_data ref]} {
            set ref [dict get $json_data ref]
            if {[regexp [subst {$ref_regexp}] $ref -> type name]} {

                set exists 0
                hdbjobs eval "SELECT * FROM JOBTEST WHERE refname = '$name'" values {
                    if {!$overwrite} {
                        set exists 1
                        putscli "Ref $name already present with status $values(status)"
                        putscli "Overwrite=false; ignoring"
                    } else {
                        set exists 0
                        putscli "Ref $name already present with status $values(status)"
                        putscli "Overwrite=true; deleting existing record"
                        hdbjobs eval "DELETE FROM JOBTEST WHERE refname = '$name'"
                    }
                }
                if {$exists eq 0} {
                    if {[catch {
                        hdbjobs eval {
                            INSERT OR IGNORE INTO JOBTEST (refname) VALUES ($name);
                        }
                    } err]} {
                        putscli "Error inserting into JOBTEST: $err"
                    } else {
                        set inserted 1
                        putscli "Recorded: $name ($type)\r"
                    }
                }
            }
        }

        # HTTP 200 response
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

proc cipush {refname} {
    global rdbms cidict
    if {![info exists ::listen_socket]} {
        putscli "CI listener not running; starting listener"
        cilisten
    }

    if {![info exists rdbms]} {
        puts "Error: RDBMS not set"
        return
    }
    if {![dict exists $cidict common listen_port] || ![dict exists $cidict $rdbms build repo_url]} {
        puts "Error: CI config missing required keys"
        return
    }

    if {[string match "refs/tags/*"  $refname]} {
        set ref_type "tag"
    } elseif {[string match "refs/heads/*" $refname]} {
        set ref_type "branch"
    } else {
        puts "Error: refname must start with 'refs/tags/' or 'refs/heads/'"
        return
    }

    # Build JSON payload
    set body "{\"ref\": \"$refname\", \"ref_type\": \"$ref_type\"}"
    set headers [dict create X-GitHub-Event "create"]

    # Direct dispatch to request processor
    process_request dummy_sock $headers $body $cidict

    puts "Simulated webhook for $refname"
}

# Line-oriented output reader; sets ::pipe_done on EOF
proc handle_output {pipe} {
    if {[eof $pipe]} {
        fileevent $pipe readable {}
        putscli "command complete."
        set ::pipe_done 1
        return
    } else {
        gets $pipe line
        putscli "$line"
    }
}

# Raw output reader for tests; no extra newlines; completion signaled via doneVar
proc handle_test_output_orig {pipe doneVar} {
    fconfigure $pipe -translation binary -buffering none -blocking 0
    if {[eof $pipe]} {
        fileevent $pipe readable {}
        upvar #0 $doneVar done
        set done 1
        return
    }
    set chunk [read $pipe]
    if {$chunk ne ""} {
        puts -nonewline $chunk
    }
    flush stdout
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

proc mariadb_clone {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set repo_url       [string map {\" {}} [dict get $cidict $rdbms build repo_url]]
    set local_dir "$local_dir_root/[string map {/ _} $refname]"
    file mkdir $local_dir

    # --- Determine clone mode (tag/branch vs commit) ---
    set is_commit 0
    set ref_trim [string trim $refname]

    # Detect commit: 7–40 hex characters
    if {[regexp {^[0-9a-fA-F]{7,40}$} $ref_trim]} {
        set is_commit 1
    }

    if {$is_commit} {
        putscli "Cloning repository for commit $ref_trim into $local_dir"
    } else {
        set branch [file tail $ref_trim]
        putscli "Cloning branch $branch into $local_dir"
    }
    putscli "repo_url is $repo_url"

    # --- Build clone command ---
    if {$is_commit} {
        #
        # Full clone + checkout specific commit
        #
        set shell_cmd "cd \"$local_dir\" && git clone \"$repo_url\" . && git checkout $ref_trim 2>&1"
    } else {
        #
        # Branch or tag clone
        #
        set raw_cmd  [dict get $cidict common clone_cmd]
        set raw_args [dict get $cidict common clone_cmd_args]
        set branch   [file tail $ref_trim]
        set args_sub [string map [list ":branch" $branch ":repo_url" $repo_url] $raw_args]
        set cmd_full "$raw_cmd $args_sub"
        set shell_cmd "cd \"$local_dir\" && $cmd_full 2>&1"
    }

    # Save command
    if {[catch {
        hdbjobs eval { UPDATE JOBTEST SET clone_cmd = $shell_cmd WHERE refname = $refname; }
    } err]} {
        putscli "Error saving clone_cmd: $err"
    }

    putscli "Running clone command..."
    putscli $shell_cmd

    # Escape quotes for bash
    set safe_cmd [string map {\" \\\"} $shell_cmd]

    set pipe_output ""
    set clone_status "CLONE SUCCEEDED"

    # --- Run command and capture output ---
    if {[catch {
        set pipe [open "|bash -c \"$safe_cmd\"" "r"]
        fconfigure $pipe -blocking 1 -buffering line
        while {[gets $pipe line] >= 0} {
            append pipe_output "$line\n"
            putscli $line
            if {[regexp -nocase {fatal:|error:} $line]} {
                # Real failure detected
                set clone_status "CLONE FAILED"
            }
        }

        #
        # FIXED BLOCK — DO NOT FORCE FAILURE ON CLOSE NOISE
        #
        if {[catch {close $pipe} close_err]} {
            append pipe_output "\rError closing pipe: $close_err\n"
            # DO NOT: set clone_status "CLONE FAILED"
        }

    } clone_err]} {
        set clone_status "CLONE FAILED"
        append pipe_output "\rFailed to start clone: $clone_err\n"
    }

    # --- Save result ---
    if {$clone_status eq "CLONE FAILED"} {
        putscli "Clone failed."
        putscli "Full clone output:"
        putscli $pipe_output
        catch {
            hdbjobs eval {
                UPDATE JOBTEST
                SET status = 'CLONE FAILED',
                    clone_output = $pipe_output
                WHERE refname = $refname;
            }
        }
    } else {
        putscli "Clone succeeded."
        catch {
            hdbjobs eval {
                UPDATE JOBTEST
                SET clone_output = $pipe_output
                WHERE refname = $refname;
            }
        }
    }

    return $clone_status
}

proc mariadb_build {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set local_dir      "$local_dir_root/[string map {/ _} $refname]"

    # Prepare build command
    set raw_cmd  [dict get $cidict $rdbms build build_cmd]
    set raw_args [dict get $cidict $rdbms build build_cmd_args]
    set cmd_full "$raw_cmd $raw_args"
    set shell_cmd "cd \"$local_dir\" && $cmd_full 2>&1"

    # Persist command
    if {[catch {
        hdbjobs eval { UPDATE JOBTEST SET build_cmd = $shell_cmd WHERE refname = $refname; }
    } err]} {
        putscli "Error saving build_cmd: $err"
    }

    putscli "Running build command..."
    putscli $shell_cmd

    set safe_cmd [string map {\" \\\"} $shell_cmd]

    set pipe_output ""
    set build_status "BUILD SUCCEEDED"

    if {[catch {
        set pipe [open "|bash -c \"$safe_cmd\"" "r"]
        fconfigure $pipe -blocking 1 -buffering line
        while {[gets $pipe line] >= 0} {
            append pipe_output "$line"
            putscli $line
            if {![regexp {^troff:} $line] && [regexp -nocase {fatal:|error:} $line]} {
                set build_status "BUILD FAILED"
                set failed_line $line
            }
        }
        if {[catch {close $pipe} close_err]} {
            if {![regexp -nocase {warning} $close_err]} {
                append pipe_output "Error closing pipe: $close_err"
                set failed_line "Error closing pipe: $close_err"
                set build_status "BUILD FAILED"
            }
        }
    } build_err]} {
        append pipe_output "Failed to start build: $build_err"
        set failed_line "Failed to start build: $build_err"
        set build_status "BUILD FAILED"
    }

    if {$build_status eq "BUILD FAILED"} {
        putscli "Build failed at line: $failed_line"
        catch {
            hdbjobs eval {
                UPDATE JOBTEST
                SET status = 'BUILD FAILED',
                    build_output = $pipe_output
                WHERE refname = $refname;
            }
        }
    } else {
        putscli "Build succeeded."
        catch {
            hdbjobs eval {
                UPDATE JOBTEST
                SET build_output = $pipe_output
                WHERE refname = $refname;
            }
        }
    }
    return $build_status
}

proc mariadb_package {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set local_dir      "$local_dir_root/[string map {/ _} $refname]"

    # Prepare package command
    set raw_cmd   [dict get $cidict $rdbms build package_cmd]
    set shell_cmd "cd \"$local_dir\" && $raw_cmd 2>&1"

    # Persist command
    if {[catch {
        hdbjobs eval { UPDATE JOBTEST SET package_cmd = $shell_cmd WHERE refname = $refname; }
    } err]} {
        putscli "Error saving package_cmd: $err"
    }

    putscli "Running package command..."
    putscli $shell_cmd

    set safe_cmd [string map {\" \\\"} $shell_cmd]

    set pipe_output ""
    set package_status "PACKAGE SUCCEEDED"

    if {[catch {
        set pipe [open "|bash -c \"$safe_cmd\"" "r"]
        fconfigure $pipe -blocking 1 -buffering line
        while {[gets $pipe line] >= 0} {
            append pipe_output "$line\n"
            putscli $line
        }
        if {[catch {close $pipe} close_err]} {
            append pipe_output "Packaging command exited with error: $close_err\n"
            set failed_line "Packaging failed: $close_err"
            set package_status "PACKAGE FAILED"
        }
    } package_err]} {
        append pipe_output "Failed to start packaging command: $package_err\n"
        set failed_line "Failed to start packaging command: $package_err"
        set package_status "PACKAGE FAILED"
    }

    if {$package_status eq "PACKAGE FAILED"} {
        putscli "Packaging failed at line: $failed_line"
        catch {
            hdbjobs eval {
                UPDATE JOBTEST
                SET status = 'PACKAGE FAILED',
                    package_output = $pipe_output
                WHERE refname = $refname;
            }
        }
    } else {
        putscli "Packaging succeeded."
        catch {
            hdbjobs eval {
                UPDATE JOBTEST
                SET package_output = $pipe_output
                WHERE refname = $refname;
            }
        }
    }
    return $package_status
}

proc mariadb_commit_msg {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set local_dir      "$local_dir_root/[string map {/ _} $refname]"
    set commit_msg ""

    set raw_commit_cmd [dict get $cidict common commit_msg_cmd]
    set commit_cmd     "cd \"$local_dir\" && $raw_commit_cmd"
    if {[catch {
        set commit_msg [exec bash -c $commit_cmd]
        hdbjobs eval {
            UPDATE JOBTEST SET commit_msg = $commit_msg WHERE refname = $refname;
        }
    } err]} {
        set comm_msg "Could not fetch commit message: $err"
    } else {
        set comm_msg "Commit message: $commit_msg"
    }
    return $comm_msg
}

proc mariadb_install {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set local_dir      "$local_dir_root/[string map {/ _} $refname]"
    set install_dir    [dict get $cidict $rdbms install install_dir]

    # Validate target directory
    if {![file exists $install_dir] || ![file isdirectory $install_dir] || ![file writable $install_dir]} {
        putscli "Error: $install_dir missing, not a directory, or not writable"
        return "INSTALL FAILED"
    }

    # Select package file
    set files [glob -nocomplain -directory $local_dir *.tar.gz]
    if {[llength $files] > 0} {
        set first_file [file tail [lindex $files 0]]
    } else {
        return "INSTALL FAILED"
    }

    # Build command
    set raw_cmd   [dict get $cidict $rdbms install install_package]
    set shell_cmd "cd \"$local_dir\" && $raw_cmd $first_file -C $install_dir 2>&1"
    set safe_cmd  [string map {\" \\\"} $shell_cmd]

    putscli "Installing package $first_file to $install_dir"

    set ::pipe_done 0
    if {[catch {
        set pipe [open "|bash -c \"$safe_cmd\"" "r"]
        fconfigure $pipe -blocking 0 -buffering line
        fileevent $pipe readable [list handle_output $pipe]
        vwait ::pipe_done
        close $pipe
    } install_err]} {
        putscli "Install failed: $install_err"
        hdbjobs eval { UPDATE JOBTEST SET status = 'INSTALL FAILED' WHERE refname = $refname; }
        return "INSTALL FAILED"
    } else {
        catch {
            hdbjobs eval { UPDATE JOBTEST SET status = 'installed' WHERE refname = $refname; }
        }
        return "INSTALL SUCCEEDED"
    }
}

proc mariadb_init {cidict refname} {
    global rdbms
    set install_section [dict get $cidict $rdbms install]

    # Discover basedir
    if {![dict exists $install_section install_dir]} {
        putscli "DB init failed: <install_dir> missing in XML"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'INIT FAILED' WHERE refname = '$refname';"}
        return "INIT FAILED"
    }
    set parent [dict get $install_section install_dir]
    set candidates [glob -nocomplain -types d -directory $parent mariadb-*]
    if {[llength $candidates] == 0} {
        putscli "DB init failed: no mariadb-* directories under $parent"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'INIT FAILED' WHERE refname = '$refname';"}
        return "INIT FAILED"
    }
    set basedir ""; set newest -1
    foreach d $candidates {
        set m [file mtime $d]
        if {$m > $newest} { set newest $m ; set basedir $d }
    }

    # Validate installer
    if {![dict exists $install_section installer]} {
        putscli "DB init failed: <installer> missing in XML"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'INIT FAILED' WHERE refname = '$refname';"}
        return "INIT FAILED"
    }
    set installer      [dict get $install_section installer]
    set installer_path [file join $basedir $installer]
    if {![file exists $installer_path]} {
        putscli "DB init failed: installer not found at $installer_path"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'INIT FAILED' WHERE refname = '$refname';"}
        return "INIT FAILED"
    }

    # Copy base config
    if {![dict exists $install_section base_config_file]} {
        putscli "DB init failed: <base_config_file> missing in XML"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'INIT FAILED' WHERE refname = '$refname';"}
        return "INIT FAILED"
    }
    set defaults_src [dict get $install_section base_config_file]
    set defaults_name "maria.cnf"
    if {[dict exists $install_section defaults_file]} {
        set defaults_name [file tail [dict get $install_section defaults_file]]
    }
    set defaults_dst [file join $basedir $defaults_name]
    if {![file exists [file dirname $defaults_dst]]} {
        catch {file mkdir [file dirname $defaults_dst]}
    }
    catch {file copy -force $defaults_src $defaults_dst}
    putscli "Copied base config file $defaults_src to $defaults_dst"

    # Prepare directories for data and redo
    set datadir_val ""
    if {[dict exists $install_section datadir]} { set datadir_val [dict get $install_section datadir] }
    if {$datadir_val ne "" && [file pathtype $datadir_val] ne "absolute"} {
        set datadir_val [file join $basedir $datadir_val]
    }
    if {$datadir_val ne ""} { catch {file mkdir $datadir_val} }

    set redo_val ""
    if {[dict exists $install_section innodb_log_group_home_dir]} {
        set redo_val [dict get $install_section innodb_log_group_home_dir]
    }
    if {$redo_val ne "" && [file pathtype $redo_val] ne "absolute"} {
        set redo_val [file join $basedir $redo_val]
    }
    if {$redo_val ne ""} { catch {file mkdir $redo_val} }

    # Build installer args
    set arglist {}
    set want_basedir 1
    if {[dict exists $install_section init_args]} {
        foreach argname [dict get $install_section init_args] {
            set lname [string tolower $argname]
            if {$lname eq "basedir"} {
                lappend arglist "--basedir=\"$basedir\""
                set want_basedir 0
                continue
            }
            set val ""
            if {$lname eq "defaults_file"} {
                set val $defaults_dst
            } elseif {$lname eq "datadir"} {
                if {$datadir_val ne ""} { set val $datadir_val }
            } elseif {$lname eq "innodb_log_group_home_dir"} {
                if {$redo_val ne ""} { set val $redo_val }
            } else {
                if {[dict exists $install_section $argname]} {
                    set val [dict get $install_section $argname]
                } elseif {[dict exists $install_section [string map {- _} $argname]]} {
                    set val [dict get $install_section [string map {- _} $argname]]
                } elseif {[dict exists $install_section [string map {_ -} $argname]]} {
                    set val [dict get $install_section [string map {_ -} $argname]]
                }
            }
            if {$val eq ""} {
                putscli "Warning: init_args '$argname' has no value in XML"
                continue
            }
            set flag "--[string map {_ -} $argname]=\"[string map {\" \\\"} $val]\""
            lappend arglist $flag
        }
    }
    if {$want_basedir} {
        lappend arglist "--basedir=\"$basedir\""
    }

    # Execute installer
    set args_str  [join $arglist " "]
    set init_cmd  "cd \"$basedir\" && ./[dict get $install_section installer] $args_str 2>&1"
    set safe_cmd  [string map {\" \\\"} $init_cmd]

    putscli "Initializing MariaDB with command:"
    putscli $init_cmd

    set ::pipe_done 0
    set init_status "INIT SUCCEEDED"
    if {[catch {
        set pipe [open "|bash -c \"$safe_cmd\"" "r"]
        fconfigure $pipe -blocking 0 -buffering line
        fileevent $pipe readable [list handle_output $pipe]
        vwait ::pipe_done
    } open_err]} {
        putscli "DB init failed to start: $open_err"
        set init_status "INIT FAILED"
    } else {
        if {[lsearch -exact [chan names] $pipe] != -1} {
            if {[catch {close $pipe} close_err]} {
                putscli "Init command exited with error: $close_err"
                set init_status "INIT FAILED"
            }
        }
    }
    if {$init_status eq "INIT FAILED"} {
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'INIT FAILED' WHERE refname = '$refname';"}
    } else {
        set init_status "INIT SUCCEEDED"
        catch {hdbjobs eval { UPDATE JOBTEST SET status = 'initialized' WHERE refname = $refname; }}
    }
    return $init_status
}

proc mariadb_start {cidict refname} {
    global rdbms
    set install [dict get $cidict $rdbms install]

    # Discover basedir
    set parent [dict get $install install_dir]
    set candidates [glob -nocomplain -types d -directory $parent mariadb-*]
    if {[llength $candidates] == 0} {
        putscli "DB start failed: no mariadb-* directories under $parent"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'START FAILED' WHERE refname = '$refname';"}
        return "START FAILED"
    }
    set basedir ""; set newest -1
    foreach d $candidates {
        set m [file mtime $d]
        if {$m > $newest} { set newest $m ; set basedir $d }
    }

    # Validate start command
    if {![dict exists $install start_cmd]} {
        putscli "DB start failed: <start_cmd> missing in XML"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'START FAILED' WHERE refname = '$refname';"}
        return "START FAILED"
    }
    set start_cmd [dict get $install start_cmd]

    # Defaults file path
    set defaults_name "maria.cnf"
    if {[dict exists $install defaults_file]} {
        set defaults_name [file tail [dict get $install defaults_file]]
    }
    set defaults_dst [file join $basedir $defaults_name]

    # Resolve datadir / redo
    set datadir_val ""
    if {[dict exists $install datadir]} { set datadir_val [dict get $install datadir] }
    if {$datadir_val ne "" && [file pathtype $datadir_val] ne "absolute"} {
        set datadir_val [file join $basedir $datadir_val]
    }
    set redo_val ""
    if {[dict exists $install innodb_log_group_home_dir]} {
        set redo_val [dict get $install innodb_log_group_home_dir]
    }
    if {$redo_val ne "" && [file pathtype $redo_val] ne "absolute"} {
        set redo_val [file join $basedir $redo_val]
    }

    # Build argument list
    set argnames [expr {[dict exists $install start_args] ? [dict get $install start_args] : {defaults_file basedir datadir innodb_log_group_home_dir}}]
    set arglist {}
    set want_basedir 1
    set socket_requested 0
    set port_requested   0
    set socket_val ""
    set port_val   ""

    foreach argname $argnames {
        set lname [string tolower $argname]

        if {$lname eq "socket"} {
            set socket_requested 1
            if {[dict exists $install socket]} { set socket_val [dict get $install socket] }
            continue
        }
        if {$lname eq "port"} {
            set port_requested 1
            if {[dict exists $install port]} { set port_val [dict get $install port] }
            continue
        }

        set val ""
        if {$lname eq "defaults_file"} {
            set val $defaults_dst
        } elseif {$lname eq "basedir"} {
            set val $basedir
            set want_basedir 0
        } elseif {$lname eq "datadir"} {
            if {$datadir_val ne ""} { set val $datadir_val }
        } elseif {$lname eq "innodb_log_group_home_dir"} {
            if {$redo_val ne ""} { set val $redo_val }
        } elseif {[dict exists $install $argname]} {
            set raw [dict get $install $argname]
            if {[string is integer -strict $raw]} {
                set val $raw
            } elseif {[file pathtype $raw] ne "absolute"} {
                set val [file join $basedir $raw]
            } else {
                set val $raw
            }
        }

        if {$val ne ""} {
            set flag "--[string map {_ -} $argname]=\"[string map {\" \\\"} $val]\""
            lappend arglist $flag
        } else {
            putscli "Warning: start_args '$argname' has no value in XML"
        }
    }

    if {$want_basedir} {
        lappend arglist "--basedir=\"$basedir\""
    }

    # Endpoint preference: socket over port
    if {$socket_requested && $socket_val ne ""} {
        lappend arglist "--socket=\"[string map {\" \\\"} $socket_val]\""
    } elseif {$port_requested && $port_val ne ""} {
        if {![string is integer -strict $port_val]} {
            putscli "Warning: <port> must be integer; ignoring"
        } else {
            lappend arglist "--port=$port_val"
        }
    }

    # Spawn server like the working prototype
    set args_str [join $arglist " "]
    set full_cmd "cd \"$basedir\" && $start_cmd $args_str"
    regsub -all {"} $full_cmd {\\"} full_cmd

    putscli "Starting MariaDB:"
    putscli $full_cmd

    set ::pipe_done 0
    if {[catch {
        set pipe [open "|bash -c \"$full_cmd\"" "r"]
        fconfigure $pipe -blocking 0 -buffering line
        fileevent $pipe readable [list handle_output $pipe]
        after 10000 {set ::pipe_done 1}
        vwait ::pipe_done
    } err]} {
        putscli "DB start failed to spawn: $err"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = 'START FAILED' WHERE refname = '$refname';"}
        return "START FAILED"
    }

    return "START SUCCEEDED"
}

proc mariadb_run_sql {cidict refname key} {
    global rdbms
    set install [dict get $cidict $rdbms install]
    set KEY [string toupper $key]

    if {![dict exists $install $key]} {
        putscli "RUN_SQL $key: missing <$key> in XML"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = '$KEY FAILED' WHERE refname = '$refname';"}
        return "$KEY FAILED"
    }

    # Discover basedir
    set parent [dict get $install install_dir]
    set dirs   [glob -nocomplain -types d -directory $parent mariadb-*]
    if {[llength $dirs] == 0} {
        putscli "RUN_SQL $key: no mariadb-* under $parent"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = '$KEY FAILED' WHERE refname = '$refname';"}
        return "$KEY FAILED"
    }
    set basedir ""; set newest -1
    foreach d $dirs { set m [file mtime $d]; if {$m>$newest} { set newest $m; set basedir $d } }

    # Socket path
    set socket "/tmp/mariadb.sock"
    if {[dict exists $install socket]} { set socket [dict get $install socket] }

    # Build client command (exact quoting)
    set sql     [dict get $install $key]
    set sql_cmd "./bin/mariadb -S $socket --skip-ssl -vvv -e \\\"$sql\\\""

    putscli "RUN_SQL $key:"
    putscli $sql_cmd

    set ::pipe_done 0
    set close_status OK
    if {[catch {
        set pipe [open "|bash -c \"cd $basedir && $sql_cmd\"" "r"]
        fconfigure $pipe -blocking 0 -buffering line
        fileevent $pipe readable [list handle_output $pipe]
        after 15000 { if {$::pipe_done == 0} { set ::pipe_done 1 } }
        vwait ::pipe_done
        if {[catch {close $pipe} errMsg]} { set close_status $errMsg }
    } errMsg]} {
        putscli "RUN_SQL $key failed to spawn: $errMsg"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = '$KEY FAILED' WHERE refname = '$refname';"}
        return "$KEY FAILED"
    }

    if {$close_status ne "OK"} {
        putscli "RUN_SQL $key error: $close_status"
        catch {hdbjobs eval "UPDATE JOBTEST SET status = '$KEY FAILED' WHERE refname = '$refname';"}
        return "$KEY FAILED"
    }

    return "$KEY SUCCEEDED"
}

# Run OLTP/OLAP test script; raw streaming; per-invocation done flag
proc mariadb_start_tests {cidict refname workload} {
    global rdbms

    hdbjobs eval "UPDATE JOBTEST SET status = 'running' WHERE refname = '$refname';"
    putscli "MariaDB is up and running for $refname"
    putscli "Pausing for 10 seconds before running tests for $refname"
    after 10000

    # Resolve script path
    set key [string tolower $workload]
    if {$key ni {"oltp" "olap"}} {
        putscli "Test failed: workload must be 'oltp' or 'olap' (got '$workload')"
        hdbjobs eval "UPDATE JOBTEST SET status = 'TEST FAILED' WHERE refname = '$refname';"
        return "TEST FAILED"
    }
    if {![dict exists $cidict $rdbms test $key]} {
        putscli "Test failed: <$key> missing under <$rdbms>/<test> in XML"
        hdbjobs eval "UPDATE JOBTEST SET status = 'TEST FAILED' WHERE refname = '$refname';"
        return "TEST FAILED"
    }
    set script_raw [string map {\" {}} [dict get $cidict $rdbms test $key]]
    if {[file pathtype $script_raw] eq "relative"} {
        set script_abs [file join [pwd] $script_raw]
    } else {
        set script_abs $script_raw
    }
    if {![file exists $script_abs]} {
        putscli "Test failed: script not found: $script_abs"
        hdbjobs eval "UPDATE JOBTEST SET status = 'TEST FAILED' WHERE refname = '$refname';"
        return "TEST FAILED"
    }
    catch {exec chmod +x -- $script_abs}

    putscli "Running Tests ($key)"
    putscli "sudo bash -c \"$script_abs\""

    set doneVar "::pipe_done_tests_[clock milliseconds]"
    set $doneVar 0

    if {[catch {
        set pipe [open "|sudo bash -c \"$script_abs 2>&1\"" "r"]
        fconfigure $pipe -translation binary -buffering none -blocking 0
        fileevent $pipe readable [list handle_test_output $pipe $doneVar]
        vwait $doneVar
        close $pipe
    } err]} {
        putscli "Test failed: $err"
        hdbjobs eval "UPDATE JOBTEST SET status = 'TEST FAILED' WHERE refname = '$refname';"
        return "TEST FAILED"
    }

    putscli "Test sequence complete ($key)"
    return "TEST STARTED"
}

proc mariadb_compare {cidict refname} {
    global rdbms
    if {(![info exists ::env(TMP)] || $::env(TMP) eq "") &&
        [info exists ::env(TMPDIR)] && $::env(TMPDIR) ne ""} {
        set ::env(TMP) $::env(TMPDIR)
    }
    ci_check_tmp

    # Resolve build root and current tag
    if {![dict exists $cidict $rdbms build local_dir_root]} {
        putscli "COMPARE FAILED: <$rdbms>/<build>/<local_dir_root> missing"
        return "COMPARE FAILED"
    }
    set build_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set bad_tag   [expr {[string match "refs/tags/*" $refname] ? [file tail $refname] : $refname}]
    set repo      [file join $build_root $bad_tag]
    set is_commit 0
    if {![string match "refs/tags/*" $refname] && ![string match "refs/heads/*" $refname]} {
        if {[regexp {^[0-9a-fA-F]{7,40}$} $bad_tag]} {
            set is_commit 1
        }
    }
    if {[file isdirectory $repo]} {
        putscli "COMPARE FAILED: repo already exists: $repo"
        return "COMPARE FAILED"
    }

    # Runner script path from XML (<$rdbms>/<test>/<compare>)
    if {![dict exists $cidict $rdbms test compare]} {
        putscli "COMPARE FAILED: <$rdbms>/<test>/<compare> missing in XML"
        return "COMPARE FAILED"
    }
    set runner_raw [string map {\" {}} [dict get $cidict $rdbms test compare]]
    set ham_root [pwd]  ;# runner expects ./hammerdbcli in cwd
    if {[file pathtype $runner_raw] eq "relative"} {
        set runner_abs [file join $ham_root $runner_raw]
    } else {
        set runner_abs $runner_raw
    }
    if {![file exists $runner_abs]} {
        putscli "COMPARE FAILED: runner not found: $runner_abs"
        return "COMPARE FAILED"
    }
    catch {exec chmod +x -- $runner_abs}

    # Profile ids: default base from XML
    set pid_base 999
    if {[dict exists $cidict $rdbms pipeline compare_profileid]} {
        set pid_base [dict get $cidict $rdbms pipeline compare_profileid]
    }
    set bad_pid  $pid_base
    set good_pid [expr {$pid_base + 1}]

    # Try to bump based on existing jobs in JOBMAIN
    if {![catch { hdbjobs eval "SELECT max(profile_id) FROM JOBMAIN" } maxpid]} {
        set maxpid [string trim $maxpid]
        if {$maxpid ne "" && $maxpid ne "null" && [string is integer -strict $maxpid]} {
            set bad_pid  [expr {$maxpid + 1}]
            set good_pid [expr {$maxpid + 2}]
        }
    }

    putscli "COMPARE PROFILEIDS  $bad_pid $good_pid"

    # Find previous tag (good)
    set cmd "cd $repo && git fetch --all --tags"
    putscli $cmd
    set ::pipe_done 0
    if {[catch {
        set p [open "|bash -c \"$cmd\"" "r"]
        fconfigure $p -blocking 0 -buffering line
        fileevent  $p readable [list handle_output $p]
        vwait ::pipe_done
        close $p
    } err]} {
        putscli "COMPARE FAILED: $err"
        return "COMPARE FAILED"
    }

    # Helper to run the runner once (no 2>&1, wait for completion, no extra blank lines)
    proc __compare_run_once {ham_root runner_abs tag pid} {
        set run "cd $ham_root && env REFNAME=$tag PROFILEID=$pid $runner_abs"
        putscli "RUNNER: $run"
        set doneVar "::compare_run_done_[clock milliseconds]"
        set $doneVar 0
        if {[catch {
            set pipe [open "|bash -c \"$run\"" "r"]
            fconfigure $pipe -translation binary -buffering none -blocking 0
            fileevent  $pipe readable [list handle_test_output $pipe $doneVar]
            vwait $doneVar
            close $pipe
        } rerr]} {
            putscli "RUNNER FAILED: $rerr"
            return 0
        }
        return 1
    }

    set co_bad "cd $repo && git checkout -f $bad_tag"
    putscli $co_bad
    set ::pipe_done 0
    if {[catch {
        set p [open "|bash -c \"$co_bad\"" "r"]
        fconfigure $p -blocking 0 -buffering line
        fileevent  $p readable [list handle_output $p]
        vwait ::pipe_done
        close $p
    } err]} {
        putscli "CHECKOUT FAILED: $err"
        return "COMPARE FAILED"
    }

    # 1) Run profile on BAD tag (current)
    set cst [mariadb_clone $cidict $bad_tag]
    if {$cst eq "CLONE FAILED"}   { return "COMPARE FAILED" }
    set bst [mariadb_build $cidict $bad_tag]
    if {$bst eq "BUILD FAILED"}   { return "COMPARE FAILED" }
    set pst [mariadb_package $cidict $bad_tag]
    if {$pst eq "PACKAGE FAILED"} { return "COMPARE FAILED" }
    set ist [mariadb_install $cidict $bad_tag]
    if {$ist eq "INSTALL FAILED"} { return "COMPARE FAILED" }
    set int [mariadb_init $cidict $bad_tag]
    if {$int eq "INIT FAILED"} { return "COMPARE FAILED" }
    set stop_st [mariadb_run_sql $cidict $bad_tag shutdown]
    if {$stop_st ne "SHUTDOWN SUCCEEDED"} { return "COMPARE FAILED" }
    set sst [mariadb_start $cidict $bad_tag]
    if {$sst eq "START FAILED"} { return "COMPARE FAILED" }
    putscli "Pausing for 10 seconds before running tests for $refname"
    after 10000
    set rsy [mariadb_run_sql $cidict $bad_tag change_password]
    if {$rsy eq "CHANGE_PASSWORD FAILED"} { return "COMPARE FAILED" }
    if {![__compare_run_once $ham_root $runner_abs $bad_tag $bad_pid]} {
        return "COMPARE FAILED"
    }

    # 2) Stop DB, checkout GOOD tag, rebuild, install, start
    set stop_st [mariadb_run_sql $cidict $bad_tag shutdown]
    if {$stop_st ne "SHUTDOWN SUCCEEDED"} {
        putscli "COMPARE FAILED: shutdown failed before switching binaries"
        return "COMPARE FAILED"
    }
    catch {cd $ham_root}
    if {$is_commit} {
        set desc_cmd "cd $repo && git rev-list --max-count=1 $bad_tag^"
    } else {
        set desc_cmd "cd $repo && git describe --tags --abbrev=0 $bad_tag^"
    }
    putscli "COMPARE PRECHECK: $desc_cmd"

    if {[catch { set good_tag [exec bash -c "$desc_cmd"] } derr]} {
        if ($is_commit) {
            putscli "COMPARE FAILED: could not find previous commit of $bad_tag: $derr"
        } else {
            putscli "COMPARE FAILED: could not find previous tag of $bad_tag: $derr"
        }
        return "COMPARE FAILED"
    }
    set good_tag [string trim $good_tag]
    putscli "COMPARE PRECHECK -> bad=$bad_tag  good=$good_tag"
    set co_good "cd $repo && git checkout -f $good_tag"
    putscli $co_good
    set ::pipe_done 0
    if {[catch {
        set p [open "|bash -c \"$co_good\"" "r"]
        fconfigure $p -blocking 0 -buffering line
        fileevent  $p readable [list handle_output $p]
        vwait ::pipe_done
        close $p
    } err]} {
        putscli "CHECKOUT FAILED: $err"
        return "COMPARE FAILED"
    }

    set abs_repo [file normalize $repo]
    set good_dir [file normalize [file join $build_root $good_tag]]
    if {![file isdirectory $good_dir]} {
        putscli "Creating worktree for $good_tag"

        # --- Create worktree ---
        set cmd "git -C $abs_repo worktree add -f --detach $good_dir $good_tag"
        putscli $cmd
        set doneVar ::wt_add_[clock microseconds]
        set $doneVar 0
        if {[catch {
            set p [open "|bash -c \"$cmd\"" "r"]
            fconfigure $p -blocking 0 -buffering line
            fileevent $p readable [list handle_test_output $p $doneVar]
            vwait $doneVar
            close $p
        } err]} {
            putscli "WORKTREE FAILED (non-fatal): $err"
        }

        # --- Reset to tag ---
        set cmd "git -C $good_dir reset --hard $good_tag"
        putscli $cmd
        set doneVar ::wt_reset_[clock microseconds]
        set $doneVar 0
        if {[catch {
            set p [open "|bash -c \"$cmd\"" "r"]
            fconfigure $p -blocking 0 -buffering line
            fileevent $p readable [list handle_test_output $p $doneVar]
            vwait $doneVar
            close $p
        } err]} {
            putscli "RESET FAILED: $err"
            return "COMPARE FAILED"
        }

        # --- Submodule update ---
        set cmd "git -C $good_dir submodule update --init --recursive"
        putscli $cmd
        set doneVar ::wt_submod_[clock microseconds]
        set $doneVar 0
        if {[catch {
            set p [open "|bash -c \"$cmd\"" "r"]
            fconfigure $p -blocking 0 -buffering line
            fileevent $p readable [list handle_test_output $p $doneVar]
            vwait $doneVar
            close $p
        } err]} {
            putscli "SUBMODULE UPDATE FAILED: $err"
            return "COMPARE FAILED"
        }
    } else {
        putscli "Using existing worktree for $good_tag"
    }

    set bst [mariadb_build $cidict $good_tag]
    if {$bst eq "BUILD FAILED"}   { return "COMPARE FAILED" }
    after 30000
    putscli "DONE BUILD"
    set pst [mariadb_package $cidict $good_tag]
    if {$pst eq "PACKAGE FAILED"} { return "COMPARE FAILED" }
    after 30000
    putscli "DONE PACKAGE"
    set ist [mariadb_install $cidict $good_tag]
    if {$ist eq "INSTALL FAILED"} { return "COMPARE FAILED" }
    after 30000
    putscli "DONE INSTALL"
    set int [mariadb_init $cidict $good_tag]
    if {$int eq "INIT FAILED"} { return "COMPARE FAILED" }
    after 30000
    putscli "DONE INIT"
    set stop_st [mariadb_run_sql $cidict $good_tag shutdown]
    if {$stop_st ne "SHUTDOWN SUCCEEDED"} { return "COMPARE FAILED" }
    after 30000
    putscli "DONE SHUTDOWN"
    set sst [mariadb_start $cidict $good_tag]
    if {$sst eq "START FAILED"} { return "COMPARE FAILED" }
    putscli "Pausing for 10 seconds before running tests for $refname"
    after 10000
    putscli "DONE START"
    set rsy [mariadb_run_sql $cidict $good_tag change_password]
    if {$rsy eq "CHANGE_PASSWORD FAILED"} { return "COMPARE FAILED" }
    after 30000

    # 3) Run profile on GOOD tag
    if {![__compare_run_once $ham_root $runner_abs $good_tag $good_pid]} {
        return "COMPARE FAILED"
    }
    set stop_st [mariadb_run_sql $cidict $good_tag shutdown]
    putscli $stop_st
    if {$stop_st ne "SHUTDOWN SUCCEEDED"} {
        putscli "COMPARE FAILED: shutdown failed after diff"
        return "COMPARE FAILED"
    }

    # 4) Compare using job diff (singular)
    putscli "COMPARE PROFILEIDS  $bad_pid $good_pid"
    if {[catch { set du [job diff $bad_pid $good_pid false] } dErr]} {
        putscli $dErr
        putscli "COMPARE PRECHECK DONE"
        return "COMPARE PRECHECK DONE"
    }
    putscli "Precheck summary (compare run):"
    putscli "  unweighted = $du"
    return "COMPARE PRECHECK DONE"
}

# Periodic watcher
proc job_watcher {} {
    if {$::watcher_running} {
        run_next_pending_job
        catch { after 10000 job_watcher }
    } else {
        set ::watcher_running 0
    }
}
proc stopwatcher {} { putscli "Job watcher stop.";  set ::watcher_running 0 }
proc startwatcher {} { putscli "Job watcher start."; set ::watcher_running 1; job_watcher }
proc initwatcher {listen_socket} { set ::listen_socket $listen_socket; startwatcher }

# Execute next pending job
proc run_next_pending_job {} {
    global rdbms cidict
    set refname ""

    if {[catch {
        set result [hdbjobs eval { SELECT refname FROM JOBTEST WHERE status = 'pending' ORDER BY timestamp ASC LIMIT 1; }]
        if {[llength $result] > 0} { set refname [lindex $result 0] }
    } err]} {
        putscli "Error querying JOBTEST: $err"
        return
    }

    if {$refname eq ""} { return }

    putscli "Found pending job: $refname"
    putscli "Pausing watcher for build"
    stopwatcher

    if {[catch {
        hdbjobs eval { UPDATE JOBTEST SET status = 'building' WHERE refname = $refname; }
    } err]} {
        putscli "Error updating status to 'building': $err"
        return
    }

    # clone
    set clone_cmd "[string tolower $rdbms]_clone"
    set clone_status [$clone_cmd $cidict $refname]
    putscli $clone_status
    if {$clone_status eq "CLONE FAILED"} { startwatcher; return }

    # build
    set build_cmd "[string tolower $rdbms]_build"
    set build_status [$build_cmd $cidict $refname]
    putscli $build_status
    if {$build_status eq "BUILD FAILED"} { startwatcher; return }

    # package
    set package_cmd "[string tolower $rdbms]_package"
    set package_status [$package_cmd $cidict $refname]
    putscli $package_status
    if {$package_status eq "PACKAGE FAILED"} { startwatcher; return }

    # commit message
    set commit_cmd "[string tolower $rdbms]_commit_msg"
    set commit_message [$commit_cmd $cidict $refname]
    putscli $commit_message

    # install
    set install_cmd "[string tolower $rdbms]_install"
    set install_status [$install_cmd $cidict $refname]
    putscli $install_status
    if {$install_status eq "INSTALL FAILED"} { startwatcher; return }

    # init
    set init_cmd "[string tolower $rdbms]_init"
    set init_status [$init_cmd $cidict $refname]
    putscli $init_status
    if {$init_status eq "INIT FAILED"} { startwatcher; return }

    # start
    set start_cmd "[string tolower $rdbms]_start"
    set start_status [$start_cmd $cidict $refname]
    putscli $start_status
    if {$start_status eq "START FAILED"} { startwatcher; return }

    # change password
    set run_cmd "[string tolower $rdbms]_run_sql"
    set run_status [$run_cmd $cidict $refname change_password]
    putscli $run_status
    if {$run_status eq "CHANGE_PASSWORD FAILED"} { startwatcher; return }

    # shutdown
    set run_cmd "[string tolower $rdbms]_run_sql"
    set run_status [$run_cmd $cidict $refname shutdown]
    putscli $run_status
    if {$run_status eq "SHUTDOWN FAILED"} { startwatcher; return }

    # restart
    set restart_status [$start_cmd $cidict $refname]
    putscli $restart_status
    if {$restart_status eq "START FAILED"} { startwatcher; return }

    # tests
    set test_cmd "[string tolower $rdbms]_start_tests"
    set test_status [$test_cmd $cidict $refname oltp]
    putscli $test_status
    if {$test_status eq "TEST FAILED"} { startwatcher; return }

    startwatcher
}

# cistep <refname> <pipeline>
proc cistep {refname pipeline} {
    global rdbms cidict
    if {$refname eq "" || $pipeline eq ""} {
        putscli "CI: usage: cistep <refname> <pipeline>"
        return
    }

    # Normalize the refname for all downstream steps so they use the same
    # directory naming as cipush (no "refs_tags_" prefix).
    set step_ref $refname
    if {[string match "refs/tags/*"  $refname] || [string match "refs/heads/*" $refname]} {
        set step_ref [file tail $refname]
    }

    if {![info exists ::listen_socket]} {
        putscli "CI listener not running; starting listener"
        cilisten
    }

    # Resolve RDBMS key by case-insensitive match
    set rkey ""
    foreach k [dict keys $cidict] {
        if {[string equal -nocase $k $rdbms]} { set rkey $k ; break }
    }
    if {$rkey eq ""} {
        putscli "CI: <$rdbms> block not found; roots: [join [dict keys $cidict] ", "]"
        return
    }

    if {![dict exists $cidict $rkey pipeline $pipeline]} {
        set avail ""
        if {[dict exists $cidict $rkey pipeline]} {
            set avail [join [dict keys [dict get $cidict $rkey pipeline]] ", "]
        }
        putscli "CI: unknown pipeline '$pipeline' under <$rkey>/<pipeline>."
        if {$avail ne ""} { putscli "CI: available pipelines: $avail" }
        return
    }

    putscli "CI: running pipeline '$pipeline' for $refname"
    putscli "Pausing watcher for CI run"
    stopwatcher
    # This UPDATE is best-effort; it’s fine if there’s no JOBTEST row for step_ref
    catch { hdbjobs eval "UPDATE JOBTEST SET status = 'building' WHERE refname = '$step_ref';" }

    if {[catch { cisteps $cidict $step_ref $pipeline } err]} {
        putscli "CI: pipeline error: $err"
    }

    startwatcher
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
