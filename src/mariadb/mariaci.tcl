proc mariadb_ci_id {cidict refname} {
    global rdbms
    # Ensure a JOBCI row exists for this run and return its ci_id.
    # Reuses existing row when called from WAPP/cilisten; creates one when called directly.
    set ci_id [ci_latest_id $refname]
    if {$ci_id eq ""} {
        hdbjobs eval {INSERT INTO JOBCI (refname,cidict) VALUES ($refname,$cidict)}
        set ci_id [ci_latest_id $refname]
    }
    return $ci_id
}

proc mariadb_ci_safe_ref {refname} {
    # Safe directory component: replace slashes with underscores.
    return [string map {/ _} $refname]
}

proc mariadb_normpath {p} {
    # Collapse duplicate slashes and normalize path joins without changing semantics.
    if {$p eq ""} {
        return ""
    }
    return [file join {*}[file split $p]]
}


proc mariadb_clone {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set repo_url       [string map {\" {}} [dict get $cidict $rdbms build repo_url]]
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]
    set local_dir "$local_dir_root/ci_${ci_id}_${safe_ref}"
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
       set ci_id [ci_latest_id $refname]
       if {$ci_id ne ""} {
           hdbjobs eval { UPDATE JOBCI SET clone_cmd = $shell_cmd WHERE ci_id = $ci_id }
       } else {
           putscli "Error saving clone_cmd: no JOBCI row found for refname $refname"
       }
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

        if {[catch {close $pipe} close_err]} {
            append pipe_output "\rError closing pipe: $close_err\n"
        }

    } clone_err]} {
        set clone_status "CLONE FAILED"
        append pipe_output "\rFailed to start clone: $clone_err\n"
    }

   if {$clone_status eq "CLONE FAILED"} {
      putscli "Clone failed."
      putscli "Full clone output:"
      putscli $pipe_output
      catch {
         set ci_id [ci_latest_id $refname]
         if {$ci_id ne ""} {
            hdbjobs eval { UPDATE JOBCI SET status = 'CLONE FAILED', clone_output = $pipe_output WHERE ci_id = $ci_id }
         }
      }
   } else {
      putscli "Clone succeeded."
      catch {
         set ci_id [ci_latest_id $refname]
         if {$ci_id ne ""} {
            hdbjobs eval { UPDATE JOBCI SET clone_output = $pipe_output WHERE ci_id = $ci_id }
         }
      }
   }
    return $clone_status
}

proc mariadb_build {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]
    set local_dir "$local_dir_root/ci_${ci_id}_${safe_ref}"

    # Prepare build command
    set raw_cmd  [dict get $cidict $rdbms build build_cmd]
    set raw_args [dict get $cidict $rdbms build build_cmd_args]
    set cmd_full "$raw_cmd $raw_args"
    set shell_cmd "cd \"$local_dir\" && $cmd_full 2>&1"

    # Persist command
    if {[catch {
       set ci_id [ci_latest_id $refname]
       if {$ci_id ne ""} {
          hdbjobs eval { UPDATE JOBCI SET build_cmd = $shell_cmd WHERE ci_id = $ci_id }
       } else {
          putscli "Error saving build_cmd: no JOBCI row found for refname $refname"
       }
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
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval { UPDATE JOBCI SET status = 'BUILD FAILED', build_output = $pipe_output WHERE ci_id = $ci_id }
            }
        }
    } else {
        putscli "Build succeeded."
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval { UPDATE JOBCI SET build_output = $pipe_output WHERE ci_id = $ci_id }
            }
        }
    }
    return $build_status
}

proc mariadb_package {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]
    set local_dir "$local_dir_root/ci_${ci_id}_${safe_ref}"

    # Prepare package command
    set raw_cmd   [dict get $cidict $rdbms build package_cmd]
    set shell_cmd "cd \"$local_dir\" && $raw_cmd 2>&1"

    # Persist command  
    if {[catch {
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            hdbjobs eval { UPDATE JOBCI SET package_cmd = $shell_cmd WHERE ci_id = $ci_id }
        } else {
            putscli "Error saving package_cmd: no JOBCI row found for refname $refname"
        }
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
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval { UPDATE JOBCI SET status = 'PACKAGE FAILED', package_output = $pipe_output WHERE ci_id = $ci_id }
            }
        }
    } else {
        putscli "Packaging succeeded."
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval { UPDATE JOBCI SET package_output = $pipe_output WHERE ci_id = $ci_id }
            }
        }
    }
    return $package_status
}

proc mariadb_commit_msg {cidict refname} {
    global rdbms
    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]
    set local_dir "$local_dir_root/ci_${ci_id}_${safe_ref}"

    # Prepare commit message command
    set raw_commit_cmd [dict get $cidict common commit_msg_cmd]
    set shell_cmd      "cd \"$local_dir\" && $raw_commit_cmd 2>&1"

    # Persist command (best-effort; ignore if column not present)
    catch {
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            # If you don't have commit_msg_cmd column, this will just be caught.
            hdbjobs eval { UPDATE JOBCI SET commit_msg_cmd = $shell_cmd WHERE ci_id = $ci_id }
        } else {
            putscli "Error saving commit_msg_cmd: no JOBCI row found for refname $refname"
        }
    }

    putscli "Fetching commit message..."
    putscli $shell_cmd

    set safe_cmd [string map {\" \\\"} $shell_cmd]

    set pipe_output ""
    set commit_msg ""
    set status "COMMIT_MSG SUCCEEDED"

    if {[catch {
        set pipe [open "|bash -c \"$safe_cmd\"" "r"]
        fconfigure $pipe -blocking 1 -buffering line
        while {[gets $pipe line] >= 0} {
            append pipe_output "$line\n"
            # Don't spam putscli with multi-line bodies unless you want it:
            putscli $line
        }
        if {[catch {close $pipe} close_err]} {
            append pipe_output "Commit msg command exited with error: $close_err\n"
            set status "COMMIT_MSG FAILED"
        }
    } commit_err]} {
        append pipe_output "Failed to start commit msg command: $commit_err\n"
        set status "COMMIT_MSG FAILED"
    }

    # If succeeded, the output is the commit message (possibly multi-line)
    if {$status eq "COMMIT_MSG SUCCEEDED"} {
        set commit_msg [string trim $pipe_output]
        if {$commit_msg eq ""} {
            # Treat empty as failure because it's what you're seeing
            set status "COMMIT_MSG FAILED"
        }
    }

    # Persist results
    if {$status eq "COMMIT_MSG FAILED"} {
        putscli "Commit message fetch failed."
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                # If commit_msg_output doesn't exist, this will be caught and ignored.
                hdbjobs eval { UPDATE JOBCI SET status = 'COMMIT_MSG FAILED', commit_msg_output = $pipe_output WHERE ci_id = $ci_id }
            }
        }
        return "Could not fetch commit message: [string trim $pipe_output]"
    } else {
        putscli "Commit message fetched."
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval { UPDATE JOBCI SET commit_msg = $commit_msg WHERE ci_id = $ci_id }
                catch { hdbjobs eval { UPDATE JOBCI SET commit_msg_output = $pipe_output WHERE ci_id = $ci_id } }
            }
        }
        return "Commit message: $commit_msg"
    }
}

proc mariadb_install {cidict refname} {
    global rdbms

    set local_dir_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]
    set local_dir "$local_dir_root/ci_${ci_id}_${safe_ref}"
    set install_root [mariadb_normpath [dict get $cidict $rdbms install install_dir]]
    set install_dir  [file join $install_root "ci_${ci_id}_${safe_ref}"]
    # Validate target directory
    if {![file exists $install_root] || ![file isdirectory $install_root] || ![file writable $install_root]} {
        putscli "Error: $install_root missing, not a directory, or not writable"
        return "INSTALL FAILED"
    }

    file mkdir $install_dir

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

    # Save install command
    catch {
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            hdbjobs eval { UPDATE JOBCI SET install_cmd = $shell_cmd WHERE ci_id = $ci_id }
        } else {
            putscli "Error saving install_cmd: no JOBCI row found for refname $refname"
        }
    } err
    if {[info exists err] && $err ne ""} {
        putscli "Error saving install_cmd: $err"
    }

    putscli "Running install command..."
    putscli $shell_cmd

    # Capture output (per-call done var; avoids races with global ::pipe_done)
    set doneVar "::pipe_done_install_[clock milliseconds]"
    set $doneVar 0
    set ::pipe_output ""

    if {[catch {
        set pipe [open "|bash -c \"$safe_cmd\"" "r"]
        fconfigure $pipe -translation binary -buffering none -blocking 0
        fileevent $pipe readable [list handle_test_output $pipe $doneVar]
        vwait $doneVar
        close $pipe
    } install_err]} {

        putscli "Install failed: $install_err"

        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                set out $::pipe_output
                if {$out ne ""} { append out "\n" }
                append out "ERROR: $install_err"
                hdbjobs eval { UPDATE JOBCI SET status = 'INSTALL FAILED', install_output = $out WHERE ci_id = $ci_id }
            }
        }
        return "INSTALL FAILED"
    } else {
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                set out $::pipe_output
                if {$out ne ""} { append out "\n" }
                hdbjobs eval { UPDATE JOBCI SET status = 'INSTALLED', install_output = $out WHERE ci_id = $ci_id }
            }
        }
        return "INSTALL SUCCEEDED"
    }
}

proc mariadb_init {cidict refname} {
    global rdbms
    set install_section [dict get $cidict $rdbms install]
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]

    # Discover basedir
    if {![dict exists $install_section install_dir]} {
        putscli "DB init failed: <install_dir> missing in XML"
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'INIT FAILED' WHERE ci_id = $ci_id}
            }
        }
        return "INIT FAILED"
    }
    set install_root [dict get $install_section install_dir]
    set parent "$install_root/ci_${ci_id}_${safe_ref}"
    set candidates [glob -nocomplain -types d -directory $parent mariadb-*]
    if {[llength $candidates] == 0} {
        putscli "DB init failed: no mariadb-* directories under $parent"
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'INIT FAILED' WHERE ci_id = $ci_id}
            }
        }
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
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'INIT FAILED' WHERE ci_id = $ci_id}
            }
        }
        return "INIT FAILED"
    }
    set installer      [dict get $install_section installer]
    set installer_path [file join $basedir $installer]
    if {![file exists $installer_path]} {
        putscli "DB init failed: installer not found at $installer_path"
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'INIT FAILED' WHERE ci_id = $ci_id}
            }
        }
        return "INIT FAILED"
    }

    # Copy base config
    if {![dict exists $install_section base_config_file]} {
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'INIT FAILED' WHERE ci_id = $ci_id}
            }
        }
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
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'INIT FAILED' WHERE ci_id = $ci_id}
            }
        }
    } else {
        set init_status "INIT SUCCEEDED"
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval { UPDATE JOBCI SET status = 'INITIALIZED' WHERE ci_id = $ci_id }
            }
        }
    }
    return $init_status 
}

proc mariadb_start {cidict refname} {
    global rdbms
    set install [dict get $cidict $rdbms install]
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]

    # Discover basedir
    set install_root [dict get $install install_dir]
    set parent "$install_root/ci_${ci_id}_${safe_ref}"
    set candidates [glob -nocomplain -types d -directory $parent mariadb-*]
    if {[llength $candidates] == 0} {
        putscli "DB start failed: no mariadb-* directories under $parent"
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'START FAILED' WHERE ci_id = $ci_id}
            }
        }
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
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'START FAILED' WHERE ci_id = $ci_id}
            }
        }
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

    # Buffer pool sizing
    set bp_cfg ""
    if {[dict exists $install innodb_buffer_pool_size]} {
    set bp_cfg [string trim [dict get $install innodb_buffer_pool_size]]
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

   # innodb_buffer_pool_size override (start-time only)
   set bp_mb 1000
   if {$bp_cfg eq "" || [string equal -nocase $bp_cfg "auto"]} {
       set bp_mb [calc_buffer_pool_mb]
       if {$bp_mb > 0} {
       putscli "Auto-tune: innodb_buffer_pool_size=${bp_mb}M"
     }
   } elseif {[string is integer -strict $bp_cfg]} {
       set bp_mb $bp_cfg
       putscli "User override: innodb_buffer_pool_size=${bp_mb}M"
   } else {
       putscli "WARNING: invalid innodb_buffer_pool_size='$bp_cfg' (expected auto or MB integer)"
   }
   if {$bp_mb > 0} {
       lappend arglist "--innodb-buffer-pool-size=${bp_mb}M"
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
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = 'START FAILED' WHERE ci_id = $ci_id}
            }
        }
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
        catch {hdbjobs eval {UPDATE JOBCI SET status = '$KEY FAILED' WHERE refname = $refname}}
        return "$KEY FAILED"
    }

    # Discover basedir (per-CI install dir)
    set ci_id [mariadb_ci_id $cidict $refname]
    set safe_ref [mariadb_ci_safe_ref $refname]
    set install_root [mariadb_normpath [dict get $install install_dir]]
    set parent [file join $install_root "ci_${ci_id}_${safe_ref}"]
    set dirs   [glob -nocomplain -types d -directory $parent mariadb-*]
    if {[llength $dirs] == 0} {
        putscli "RUN_SQL $key: no mariadb-* under $parent"
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = '$KEY FAILED' WHERE ci_id = $ci_id}
            }
        }
        return "$KEY FAILED"
    }
    set basedir ""; set newest -1
    foreach d $dirs { set m [file mtime $d]; if {$m>$newest} { set newest $m; set basedir $d } }

    # Socket path
    set socket "/tmp/mariadb.sock"
    if {[dict exists $install socket]} { set socket [mariadb_normpath [dict get $install socket]] }

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
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = '$KEY FAILED' WHERE ci_id = $ci_id}
            }
        }
        return "$KEY FAILED"
    }

    if {$close_status ne "OK"} {
        putscli "RUN_SQL $key error: $close_status"
        catch {
            set ci_id [ci_latest_id $refname]
            if {$ci_id ne ""} {
                hdbjobs eval {UPDATE JOBCI SET status = '$KEY FAILED' WHERE ci_id = $ci_id}
            }
        }
        return "$KEY FAILED"
    }

    return "$KEY SUCCEEDED"
}

# Run OLTP/OLAP test script; raw streaming; per-invocation done flag
proc mariadb_start_tests {cidict refname workload} {
    global rdbms

    hdbjobs eval {UPDATE JOBCI SET status = 'RUNNING' WHERE refname = $refname}
    putscli "MariaDB is up and running for $refname"
    putscli "Pausing for 10 seconds before running tests for $refname"
    after 10000

    # Resolve script path
    set key [string tolower $workload]
    if {$key ni {"oltp" "olap"}} {
        putscli "Test failed: workload must be 'oltp' or 'olap' (got '$workload')"
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status = 'TEST FAILED' WHERE ci_id = $ci_id}
        }
        return "TEST FAILED"
    }
    if {![dict exists $cidict $rdbms test $key]} {
        putscli "Test failed: <$key> missing under <$rdbms>/<test> in XML"
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status = 'TEST FAILED' WHERE ci_id = $ci_id}
        }
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
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status = 'TEST FAILED' WHERE ci_id = $ci_id}
        }
        return "TEST FAILED"
    }
    catch {exec chmod +x -- $script_abs}

    putscli "Running Tests ($key)"
    #If user is root sudo is needed otherwise access is denied
    set sudo ""
    if {[info exists cidict] && [dict exists $cidict common use_sudo]} {
        if {[string is true [dict get $cidict common use_sudo]]} {
            set sudo "sudo -n "
        }
    }
    putscli "${sudo}bash -c \"$script_abs\""
    set doneVar "::pipe_done_tests_[clock milliseconds]"
    set $doneVar 0
    if {[catch {
        set pipe [open "|${sudo}bash -c \"$script_abs 2>&1\"" "r"]
        fconfigure $pipe -translation binary -buffering none -blocking 0
        fileevent $pipe readable [list handle_test_output $pipe $doneVar]
        vwait $doneVar
        close $pipe
    } err]} {
        putscli "Test failed: $err"
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status = 'TEST FAILED' WHERE ci_id = $ci_id}
        }
        return "TEST FAILED"
    }
        set ci_id [ci_latest_id $refname]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status='COMPLETE', end_timestamp=datetime(CURRENT_TIMESTAMP,'localtime') WHERE ci_id = $ci_id}
        }
putscli "refname is $refname"
putscli "ci_id is $ci_id"
    putscli "Test sequence complete ($key)"
    return "TEST COMPLETE"
}

proc mariadb_profile {cidict refname} {
    global rdbms
    if {(![info exists ::env(TMP)] || $::env(TMP) eq "") &&
        [info exists ::env(TMPDIR)] && $::env(TMPDIR) ne ""} {
        set ::env(TMP) $::env(TMPDIR)
    }
    ci_check_tmp

    # Resolve build root and current tag
    if {![dict exists $cidict $rdbms build local_dir_root]} {
        putscli "PROFILE FAILED: <$rdbms>/<build>/<local_dir_root> missing"
        return "PROFILE FAILED"
    }
    set build_root [string map {\" {}} [dict get $cidict $rdbms build local_dir_root]]
    set bad_tag [expr {[string match "refs/tags/*" $refname] ? [file tail $refname] : $refname}]

    # Ensure exactly ONE JOBCI row exists for this run:
    # - If caller already created it (queued / WAPP), reuse it.
    # - If not (direct cistep/cisteps), create it once.
    set ci_id [ci_latest_id $bad_tag]
    if {$ci_id eq ""} {
        hdbjobs eval {INSERT INTO JOBCI (refname,cidict) VALUES ($bad_tag,$cidict)}
        set ci_id [ci_latest_id $bad_tag]
    }
    if {$ci_id ne ""} {
        hdbjobs eval {UPDATE JOBCI SET status = 'BUILDING' WHERE ci_id = $ci_id}
    } else {
        putscli "PROFILE FAILED: could not create/find JOBCI row for $bad_tag"
        return "PROFILE FAILED"
    }
    set repo [file join $build_root "ci_${ci_id}_${bad_tag}"]
    set is_commit 0
    if {![string match "refs/tags/*" $refname] && ![string match "refs/heads/*" $refname]} {
        if {[regexp {^[0-9a-fA-F]{7,40}$} $bad_tag]} {
            set is_commit 1
        }
    }
    if {[file isdirectory $repo]} {
        putscli "PROFILE FAILED: repo already exists: $repo"
        return "PROFILE FAILED"
    }

    # Runner script path from XML (<$rdbms>/<test>/<profile>)
    if {![dict exists $cidict $rdbms test profile]} {
        putscli "PROFILE FAILED: <$rdbms>/<test>/<profile> missing in XML"
        return "PROFILE FAILED"
    }
    set runner_raw [string map {\" {}} [dict get $cidict $rdbms test profile]]
    set ham_root [pwd]  ;# runner expects ./hammerdbcli in cwd
    if {[file pathtype $runner_raw] eq "relative"} {
        set runner_abs [file join $ham_root $runner_raw]
    } else {
        set runner_abs $runner_raw
    }
    if {![file exists $runner_abs]} {
        putscli "PROFILE FAILED: runner not found: $runner_abs"
        return "PROFILE FAILED"
    }
    catch {exec chmod +x -- $runner_abs}

    # Profile ids: default base from XML
    set pid_base 1000
    if {[dict exists $cidict $rdbms pipeline profileid]} {
        set pid_base [dict get $cidict $rdbms pipeline profileid]
    }
    set bad_pid  $pid_base

    # Try to bump based on existing jobs in JOBMAIN
    if {![catch { hdbjobs eval {SELECT max(profile_id) FROM JOBMAIN} } maxpid]} {
        set maxpid [string trim $maxpid]
        if {$maxpid ne "" && $maxpid ne "null" && [string is integer -strict $maxpid]} {
            set bad_pid  [expr {$maxpid + 1}]
        }
    }

    set ci_id [ci_latest_id $bad_tag]
    if {$ci_id ne ""} {
        hdbjobs eval {UPDATE JOBCI SET profile_id = $bad_pid WHERE ci_id = $ci_id}
    }

    putscli "PROFILE PROFILEIDS $bad_pid"

    # Helper to run the runner once (no 2>&1, wait for completion, no extra blank lines)
    proc _profile_run_once {ham_root runner_abs tag pid} {
        set run "cd $ham_root && env REFNAME=$tag PROFILEID=$pid $runner_abs"
        putscli "RUNNER: $run"
        set ci_id [ci_latest_id $tag]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status = 'RUNNING' WHERE ci_id = $ci_id}
        }

        set doneVar "::profile_run_done_[clock milliseconds]"
        set $doneVar 0
        if {[catch {
            set pipe [open "|bash -c \"$run\"" "r"]
            fconfigure $pipe -translation binary -buffering none -blocking 0
            fileevent  $pipe readable [list handle_test_output $pipe $doneVar]
            vwait $doneVar
            close $pipe
        } rerr]} {
            putscli "PROFILE FAILED: $rerr"
            return 0
        }
        set ci_id [ci_latest_id $tag]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status='COMPLETE', end_timestamp=datetime(CURRENT_TIMESTAMP,'localtime') WHERE ci_id = $ci_id}
        }
        putscli "TEST COMPLETE"
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
        return "PROFILE FAILED"
    }

    # 1) Run profile 
puts $ci_id
    catch { hdbjobs eval { UPDATE JOBCI SET status='CLONING' WHERE ci_id=$ci_id } }
    set cst [mariadb_clone $cidict $bad_tag]
    if {$cst eq "CLONE FAILED"}   { return "PROFILE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='COMMIT MSG' WHERE ci_id=$ci_id } }
    set cmst [mariadb_commit_msg $cidict $bad_tag]
    if {$cmst eq "COMMIT_MSG FAILED"} { return "PROFILE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='BUILDING' WHERE ci_id=$ci_id } }
    set bst [mariadb_build $cidict $bad_tag]
    if {$bst eq "BUILD FAILED"}   { return "PROFILE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='PACKAGING' WHERE ci_id=$ci_id } }
    set pst [mariadb_package $cidict $bad_tag]
    if {$pst eq "PACKAGE FAILED"} { return "PROFILE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='INSTALLING' WHERE ci_id=$ci_id } }
    set ist [mariadb_install $cidict $bad_tag]
    if {$ist eq "INSTALL FAILED"} { return "PROFILE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='INIT' WHERE ci_id=$ci_id } }
    set int [mariadb_init $cidict $bad_tag]
    if {$int eq "INIT FAILED"} { return "PROFILE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='STOPPING' WHERE ci_id=$ci_id } }
    set stop_st [mariadb_run_sql $cidict $bad_tag shutdown]
    if {$stop_st ne "SHUTDOWN SUCCEEDED"} { return "PROFILE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='STARTING' WHERE ci_id=$ci_id } }
    set sst [mariadb_start $cidict $bad_tag]
    if {$sst eq "START FAILED"} { return "PROFILE FAILED" }
    putscli "Pausing for 10 seconds before running tests for $refname"
    after 10000
    catch { hdbjobs eval { UPDATE JOBCI SET status='RUNNING' WHERE ci_id=$ci_id } }
    set rsy [mariadb_run_sql $cidict $bad_tag change_password]
    if {$rsy eq "CHANGE_PASSWORD FAILED"} { return "PROFILE FAILED" }
    if {![_profile_run_once $ham_root $runner_abs $bad_tag $bad_pid]} {
        return "PROFILE FAILED"
    }
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
    set bad_tag [expr {[string match "refs/tags/*" $refname] ? [file tail $refname] : $refname}]

    # Ensure exactly ONE JOBCI row exists for this run:
    # - If caller already created it (queued / WAPP), reuse it.
    # - If not (direct cistep/cisteps), create it once.
    set ci_id [ci_latest_id $bad_tag]
    if {$ci_id eq ""} {
        hdbjobs eval {INSERT INTO JOBCI (refname,cidict) VALUES ($bad_tag,$cidict)}
        set ci_id [ci_latest_id $bad_tag]
    }
    if {$ci_id ne ""} {
        hdbjobs eval {UPDATE JOBCI SET status = 'BUILDING' WHERE ci_id = $ci_id}
        hdbjobs eval {UPDATE JOBCI SET pipeline = 'COMPARE' WHERE ci_id = $ci_id}
    } else {
        putscli "COMPARE FAILED: could not create/find JOBCI row for $bad_tag"
        return "COMPARE FAILED"
    }
    set repo [file join $build_root "ci_${ci_id}_${bad_tag}"]
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
    set pid_base 1000
    if {[dict exists $cidict $rdbms pipeline compare_profileid]} {
        set pid_base [dict get $cidict $rdbms pipeline compare_profileid]
    }
    set bad_pid  $pid_base
    set good_pid [expr {$pid_base + 1}]

    # Try to bump based on existing jobs in JOBMAIN
    if {![catch { hdbjobs eval {SELECT max(profile_id) FROM JOBMAIN} } maxpid]} {
        set maxpid [string trim $maxpid]
        if {$maxpid ne "" && $maxpid ne "null" && [string is integer -strict $maxpid]} {
            set bad_pid  [expr {$maxpid + 1}]
            set good_pid [expr {$maxpid + 2}]
        }
    }

    set ci_id [ci_latest_id $bad_tag]
    if {$ci_id ne ""} {
        hdbjobs eval {UPDATE JOBCI SET profile_id = $bad_pid WHERE ci_id = $ci_id}
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
    proc _compare_run_once {ham_root runner_abs tag pid} {
        set run "cd $ham_root && env REFNAME=$tag PROFILEID=$pid $runner_abs"
        putscli "RUNNER: $run"
        set ci_id [ci_latest_id $tag]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status = 'RUNNING' WHERE ci_id = $ci_id}
        }

        set doneVar "::compare_run_done_[clock milliseconds]"
        set $doneVar 0
        if {[catch {
            set pipe [open "|bash -c \"$run\"" "r"]
            fconfigure $pipe -translation binary -buffering none -blocking 0
            fileevent  $pipe readable [list handle_test_output $pipe $doneVar]
            vwait $doneVar
            close $pipe
        } rerr]} {
            putscli "COMPARE FAILED: $rerr"
            return 0
        }
        set ci_id [ci_latest_id $tag]
        if {$ci_id ne ""} {
            hdbjobs eval {UPDATE JOBCI SET status='COMPLETE', end_timestamp=datetime(CURRENT_TIMESTAMP,'localtime') WHERE ci_id = $ci_id}
        }
        putscli "TEST COMPLETE"
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
puts $ci_id
    catch { hdbjobs eval { UPDATE JOBCI SET status='CLONING' WHERE ci_id=$ci_id } }
    set cst [mariadb_clone $cidict $bad_tag]
    if {$cst eq "CLONE FAILED"}   { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='COMMIT MSG' WHERE ci_id=$ci_id } }
    set cmst [mariadb_commit_msg $cidict $bad_tag]
    if {$cmst eq "COMMIT_MSG FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='BUILDING' WHERE ci_id=$ci_id } }
    set bst [mariadb_build $cidict $bad_tag]
    if {$bst eq "BUILD FAILED"}   { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='PACKAGING' WHERE ci_id=$ci_id } }
    set pst [mariadb_package $cidict $bad_tag]
    if {$pst eq "PACKAGE FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='INSTALLING' WHERE ci_id=$ci_id } }
    set ist [mariadb_install $cidict $bad_tag]
    if {$ist eq "INSTALL FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='INIT' WHERE ci_id=$ci_id } }
    set int [mariadb_init $cidict $bad_tag]
    if {$int eq "INIT FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='STOPPING' WHERE ci_id=$ci_id } }
    set stop_st [mariadb_run_sql $cidict $bad_tag shutdown]
    if {$stop_st ne "SHUTDOWN SUCCEEDED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='STARTING' WHERE ci_id=$ci_id } }
    set sst [mariadb_start $cidict $bad_tag]
    if {$sst eq "START FAILED"} { return "COMPARE FAILED" }
    putscli "Pausing for 10 seconds before running tests for $refname"
    after 10000
    catch { hdbjobs eval { UPDATE JOBCI SET status='RUNNING' WHERE ci_id=$ci_id } }
    set rsy [mariadb_run_sql $cidict $bad_tag change_password]
    if {$rsy eq "CHANGE_PASSWORD FAILED"} { return "COMPARE FAILED" }
    if {![_compare_run_once $ham_root $runner_abs $bad_tag $bad_pid]} {
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
    hdbjobs eval {INSERT INTO JOBCI (refname,cidict) VALUES ($good_tag,$cidict)}
    set ci_id [ci_latest_id $good_tag]
    if {$ci_id ne ""} {
        hdbjobs eval {UPDATE JOBCI SET status = 'BUILDING' WHERE ci_id = $ci_id}
        hdbjobs eval {UPDATE JOBCI SET profile_id = $good_pid WHERE ci_id = $ci_id}
        hdbjobs eval {UPDATE JOBCI SET pipeline = 'COMPARE' WHERE ci_id = $ci_id}
    }
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
    set good_dir [file normalize [file join $build_root "ci_${ci_id}_${good_tag}"]]
    if {![file isdirectory $good_dir]} {
        putscli "Creating worktree for $good_tag"

        # --- Worktree add (clone-equivalent) ---
        catch { hdbjobs eval { UPDATE JOBCI SET status='CLONING' WHERE ci_id=$ci_id } }
        set cmd "git -C \"$abs_repo\" worktree add -f --detach \"$good_dir\" \"$good_tag\" 2>&1"
        putscli "Running clone command..."
        putscli $cmd
        catch { hdbjobs eval { UPDATE JOBCI SET clone_cmd = $cmd WHERE ci_id = $ci_id } }

        # Escape quotes for bash
        set safe_cmd [string map {\" \\\"} $cmd]

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
                    set clone_status "CLONE FAILED"
                }
            }

            if {[catch {close $pipe} close_err]} {
                putscli "Warning: close pipe reported: $close_err"
            }
        } wt_err]} {
            set clone_status "CLONE FAILED"
            append pipe_output "Failed to start worktree add: $wt_err\n"
        }

        if {$clone_status eq "CLONE FAILED"} {
            putscli "Clone failed."
            putscli "Full clone output:"
            putscli $pipe_output
            catch {
                hdbjobs eval { UPDATE JOBCI SET status='CLONE FAILED', clone_output=$pipe_output WHERE ci_id = $ci_id }
            }
            return "COMPARE FAILED"
        } else {
            putscli "Clone succeeded."
            catch {
                hdbjobs eval { UPDATE JOBCI SET clone_output = $pipe_output WHERE ci_id = $ci_id }
            }
        }

        # --- Reset to tag ---
        set cmd "git -C \"$good_dir\" reset --hard \"$good_tag\" 2>&1"
        putscli $cmd
        catch { hdbjobs eval { UPDATE JOBCI SET clone_cmd = $cmd WHERE ci_id = $ci_id } }
        set safe_cmd [string map {\" \\\"} $cmd]
        set pipe_output ""
        set clone_status "CLONE SUCCEEDED"
        if {[catch {
            set pipe [open "|bash -c \"$safe_cmd\"" "r"]
            fconfigure $pipe -blocking 1 -buffering line
            while {[gets $pipe line] >= 0} {
                append pipe_output "$line\n"
                putscli $line
                if {[regexp -nocase {fatal:|error:} $line]} {
                    set clone_status "CLONE FAILED"
                }
            }
            if {[catch {close $pipe} close_err]} {
                putscli "Warning: close pipe reported: $close_err"
            }
        } rst_err]} {
            set clone_status "CLONE FAILED"
            append pipe_output "Failed to start reset: $rst_err\n"
        }
        if {$clone_status eq "CLONE FAILED"} {
            catch { hdbjobs eval { UPDATE JOBCI SET status='CLONE FAILED', clone_output=$pipe_output WHERE ci_id=$ci_id } }
            return "COMPARE FAILED"
        } else {
            catch { hdbjobs eval { UPDATE JOBCI SET clone_output=$pipe_output WHERE ci_id=$ci_id } }
        }

        # --- Submodule update ---
        set cmd "git -C \"$good_dir\" submodule update --init --recursive 2>&1"
        putscli $cmd
        catch { hdbjobs eval { UPDATE JOBCI SET clone_cmd = $cmd WHERE ci_id = $ci_id } }
        set safe_cmd [string map {\" \\\"} $cmd]
        set pipe_output ""
        set clone_status "CLONE SUCCEEDED"
        if {[catch {
            set pipe [open "|bash -c \"$safe_cmd\"" "r"]
            fconfigure $pipe -blocking 1 -buffering line
            while {[gets $pipe line] >= 0} {
                append pipe_output "$line\n"
                putscli $line
                if {[regexp -nocase {fatal:|error:} $line]} {
                    set clone_status "CLONE FAILED"
                }
            }
            if {[catch {close $pipe} close_err]} {
                putscli "Warning: close pipe reported: $close_err"
            }
        } sub_err]} {
            set clone_status "CLONE FAILED"
            append pipe_output "Failed to start submodule update: $sub_err\n"
        }
        if {$clone_status eq "CLONE FAILED"} {
            catch { hdbjobs eval { UPDATE JOBCI SET status='CLONE FAILED', clone_output=$pipe_output WHERE ci_id=$ci_id } }
            return "COMPARE FAILED"
        } else {
            catch { hdbjobs eval { UPDATE JOBCI SET clone_output=$pipe_output WHERE ci_id=$ci_id } }
        }
    } else {
        putscli "Using existing worktree for $good_tag"
        catch { hdbjobs eval { UPDATE JOBCI SET clone_output='Using existing worktree' WHERE ci_id=$ci_id } }
    }
puts $ci_id
    catch { hdbjobs eval { UPDATE JOBCI SET status='COMMIT MSG' WHERE ci_id=$ci_id } }
    set cmst [mariadb_commit_msg $cidict $good_tag]
    if {$cmst eq "COMMIT_MSG FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='BUILDING' WHERE ci_id=$ci_id } }
    set bst [mariadb_build $cidict $good_tag]
    if {$bst eq "BUILD FAILED"}   { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='PACKAGING' WHERE ci_id=$ci_id } }
    set pst [mariadb_package $cidict $good_tag]
    if {$pst eq "PACKAGE FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='INSTALLING' WHERE ci_id=$ci_id } }
    set ist [mariadb_install $cidict $good_tag]
    if {$ist eq "INSTALL FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='INIT' WHERE ci_id=$ci_id } }
    set int [mariadb_init $cidict $good_tag]
    if {$int eq "INIT FAILED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='STOPPING' WHERE ci_id=$ci_id } }
    set stop_st [mariadb_run_sql $cidict $good_tag shutdown]
    if {$stop_st ne "SHUTDOWN SUCCEEDED"} { return "COMPARE FAILED" }
    catch { hdbjobs eval { UPDATE JOBCI SET status='STARTING' WHERE ci_id=$ci_id } }
    set sst [mariadb_start $cidict $good_tag]
    if {$sst eq "START FAILED"} { return "COMPARE FAILED" }
    putscli "Pausing for 10 seconds before running tests for $refname"
    after 10000
    catch { hdbjobs eval { UPDATE JOBCI SET status='RUNNING' WHERE ci_id=$ci_id } }
    set rsy [mariadb_run_sql $cidict $good_tag change_password]
    if {$rsy eq "CHANGE_PASSWORD FAILED"} { return "COMPARE FAILED" }

    # 3) Run profile on GOOD tag
    if {![_compare_run_once $ham_root $runner_abs $good_tag $good_pid]} {
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
