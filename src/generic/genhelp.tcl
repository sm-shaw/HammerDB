# genhelp.tcl
# CLI + Web Service help, including CI commands

# ------------------------------------------------------------
# WEB-SERVICE HELP (hammerdbws prompt)
# ------------------------------------------------------------

proc helpws {} {
    # Plain text help for the Web Service; no HTTP calls, no http::data.
    putscli ""
    putscli "HammerDB Web Service"
    putscli ""
    putscli "The HammerDB Web Service provides a read-only HTTP API to inspect"
    putscli "benchmark jobs created by the HammerDB CLI (for example with"
    putscli "buildschema and vurun)."
    putscli ""
    putscli "The web service does not start tests, change configuration, or run"
    putscli "CI pipelines. All job creation and control happens in the CLI; the web"
    putscli "interface is for viewing results and metadata only."
    putscli ""
    putscli "Jobs endpoint"
    putscli "GET /jobs is the main endpoint. It returns information about"
    putscli "one or more jobs."
    putscli ""
    putscli "GET /jobs"
    putscli "  List all jobs known to the system."
    putscli ""
    putscli "GET /jobs?jobid=ID"
    putscli "  Show full details for a single job."
    putscli ""
    putscli "GET /jobs?jobid=ID&bm"
    putscli "  Show the benchmark type for the job."
    putscli ""
    putscli "GET /jobs?jobid=ID&db"
    putscli "  Show the database type for the job."
    putscli ""
    putscli "GET /jobs?jobid=ID&dict"
    putscli "  Show the configuration dictionary used for the job."
    putscli ""
    putscli "GET /jobs?jobid=ID&status"
    putscli "  Show the current status of the job."
    putscli ""
    putscli "GET /jobs?jobid=ID&result"
    putscli "  Show the benchmark result summary (for example NOPM/TPM for TPROC-C)."
    putscli ""
    putscli "GET /jobs?jobid=ID&resultdata"
    putscli "  Show the raw result data for the job."
    putscli ""
    putscli "GET /jobs?jobid=ID&timestamp"
    putscli "  Show the start time of the job."
    putscli ""
    putscli "GET /jobs?jobid=ID&tcount"
    putscli "  Show transaction count information."
    putscli ""
    putscli "GET /jobs?jobid=ID&tcountdata"
    putscli "  Show raw transaction count data."
    putscli ""
    putscli "GET /jobs?jobid=ID&timing"
    putscli "  Show timing summary information."
    putscli ""
    putscli "GET /jobs?jobid=ID&timingdata"
    putscli "  Show raw timing data."
    putscli ""
    putscli "GET /jobs?jobid=ID&timing&vuid=N"
    putscli "  Show timing information for a specific virtual user."
    putscli ""
    putscli "GET /jobs?jobid=ID&vu=N"
    putscli "  Show job output for a specific virtual user."
    putscli ""
    putscli "GET /jobs?jobid=ID&delete"
    putscli "  Delete a job and its stored output."
    putscli ""
    putscli "Typical usage"
    putscli ""
    putscli "# List all jobs"
    putscli "  GET http://localhost:8080/jobs"
    putscli ""
    putscli "# Get result summary for a job"
    putscli "  GET http://localhost:8080/jobs?jobid=YOUR_JOB_ID&result"
    putscli ""
    putscli "# Get full timing data for a job"
    putscli "  GET http://localhost:8080/jobs?jobid=YOUR_JOB_ID&timingdata"
    putscli ""
}

# ------------------------------------------------------------
# MAIN HELP COMMAND (CLI + hammerdbws)
# ------------------------------------------------------------

proc help { args } {
    #Modified help procedure for both CLI and Web Service.
    global hdb_version
    if [ llength [ info commands wapp-default ]] { set wsmode 1 } else { set wsmode 0 }

    # If we are running under the web service, just show Web Service help
    if {$wsmode} {
        helpws
        return
    }

    set helpbanner "HammerDB $hdb_version CLI Help Index\n
Type \"help command\" for more details on specific commands below\n"

    # Original command list + CI commands
    set helpcmds [ list \
        buildschema checkschema deleteschema clearscript savescript customscript custommonitor datagenrun dbset dgset \
        diset distributescript giset jobs librarycheck loadscript metset metstart metstatus metstop print quit steprun switchmode tcset tcstart \
        tcstatus tcstop vucomplete vucreate vudestroy vurun vuset vustatus wsport wsstart wsstatus wsstop \
        citmp cilisten cistop cistatus cipush cistep ciset \
    ]

    if {[ llength $args ] != 1} {
        puts $helpbanner
        # Alphabetical index
        foreach helpcmd [lsort $helpcmds] { puts "\t$helpcmd" }
    } else {
        set option [ lindex [ split  $args ]  0 ]
        set ind [ lsearch $helpcmds $option ]
        if { $ind eq -1 } {
            putscli "Error: invalid option"
            set helpusage "Usage: help \[[ join $helpcmds "|" ]\]"
            putscli $helpusage
            return
        } else {
            switch  $option {
                jobs {
                    putscli "jobs - Usage: jobs"
                    putscli "list all jobs.\n"
                    putscli {jobs - Usage: jobs [jobid|joblist|result|timestamp]}
                    putscli "jobid: list VU output for jobid."
                    putscli "joblist: returns text list of jobs wthout newlines."
                    putscli "result: list result for all jobs."
                    putscli "timestamp: list starting timestamp for all jobs.\n"
                    putscli {jobs format - Usage: jobs format [ text | JSON ]}
                    putscli "text: Format job output as text."
                    putscli "JSON: Format job output as JSON.\n"
                    putscli {jobs disable - Usage: jobs disable [ 0 | 1 ]}
                    putscli "0: Enable storage of job output, restart required."
                    putscli "1: Disable storage of job output, restart required.\n"
                    putscli {jobs profileid - Usage: jobs profileid [ id ]}
                    putscli "profileid: returns current performance profile id."
                    putscli "profileid id: sets current performance profile id or shows all previously used ids with id of all\n"
                    putscli {jobs profile - Usage: jobs profile [ id ]}
                    putscli "profile id: returns the results for the performance profile id.\n"
                    putscli {jobs jobid - Usage: jobs jobid [bm|db|delete|dict|metrics|result|status|system|tcount|timestamp|timing|vuid]}
                    putscli "bm: list benchmark for jobid."
                    putscli "db: list database for jobid."
                    putscli "delete: delete jobid."
                    putscli "dict: list dict for jobid."
                    putscli "metrics: show system metrics for jobid."
                    putscli "result: list result for jobid."
                    putscli "status: list status for jobid."
                    putscli "system: show system data for jobid."
                    putscli "tcount: list count for jobid."
                    putscli "timestamp: list starting timestamp for jobid."
                    putscli "timing: list xtprof summary timings for jobid."
                    putscli "vuid: list VU output for VU with vuid for jobid.\n"
                    putscli {jobs jobid timing - Usage: jobs jobid timing vuid}
                    putscli "timing vuid: list xtprof timings for vuid for jobid.\n"
                    putscli {jobs jobid getchart - Usage: jobs jobid getchart [result | timing | tcount | metrics | profile ]}
                    putscli "result: generate html chart for TPROC-C/TPROC-H result."
                    putscli "timing: generate html chart for TPROC-C/TPROC-H timings."
                    putscli "metrics: generate html chart for TPROC-C/TPROC-H metrics."
                    putscli "profile: generate html chart for TPROC-C performance profile using profileid for jobid argument."
                    putscli "tcount: generate html chart for TPROC-C transaction count.\n"
                }
                print {
                    putscli {print - Usage: print [db|bm|dict|generic|script|vuconf|vucreated|vustatus|datagen|tcconf]}
                    putscli "prints the current configuration:
db: database
bm: benchmark
dict: the dictionary for the current database, i.e. all active variables
generic: the dictionary for generic settings
script: the loaded script
vuconf: the virtual user configuration
vucreated: the number of virtual users created
vustatus: the status of the virtual users
datagen: the datagen configuration
tcconf: the transaction counter configuration"
                }
                quit {
                    putscli "quit - Usage: quit"
                    if $wsmode {
                        putscli "Shuts down the HammerDB Web Service."
                    } else {
                        putscli "Shuts down the HammerDB CLI."
                    }
                }
                librarycheck {
                    putscli "librarycheck - Usage: librarycheck"
                    putscli "Attempts to load the vendor provided 3rd party library for all databases and reports whether the attempt was successful."
                }
                dbset {
                    putscli "dbset - Usage: dbset \[db|bm\] value"
                    putscli "Sets the database (db) or benchmark (bm). Equivalent to the Benchmark Menu in the graphical interface. Database value is set by the database prefix in the XML configuration."
                }
                diset {
                    putscli "diset - Usage: diset dict key value"
                    putscli "Set the dictionary variables for the current database. Equivalent to the Schema Build and Driver Options windows in the graphical interface. Use \"print dict\" to see what these variables are and diset to change:
Example:
hammerdb>diset tpcc count_ware 10
Changed tpcc:count_ware from 1 to 10 for Oracle"
                }
                giset {
                    putscli "giset - Usage: giset dict key value"
                    putscli "Set the dictionary variables for the generic settings. Use \"print generic\" to see what these variables are and giset to change
Example:
hammerdb>giset commandline keepalive_margin 60
Changed commandline:keepalive_margin from 10 to 60 for generic"
                }
                distributescript {
                    putscli "distributescript - Usage: distributescript"
                    putscli "In Primary mode distributes the script loaded by Primary to the connected Replicas."
                }
                steprun {
                    putscli "steprun - Usage: steprun"
                    putscli "Automatically switches into Primary mode, creates and connects the multiple Replicas defined in config/steps.xml and starts the Primary and Replica Virtual Users at the defined intervals creating a step workload. Both Primary and Replicas will exit on completion."
                }
                switchmode {
                    putscli "switchmode - Usage: switchmode \[mode\] ?PrimaryID? ?PrimaryHostname?"
                    putscli "Equivalent to the Mode option in the graphical interface. Mode to switch to must be one of Local, Primary or Replica. If Mode is Replica then the ID and Hostname of the Primary to connect to must be given."
                }
                buildschema {
                    putscli "buildschema - Usage: buildschema"
                    putscli "Runs the schema build for the database and benchmark selected with dbset and variables selected with diset. Equivalent to the Build command in the graphical interface."
                }
                checkschema {
                    putscli "checkschema - Usage: checkschema"
                    putscli "Runs the schema consistency check for the database and benchmark selected with dbset and variables selected with diset. Equivalent to the Check command in the graphical interface."
                }
                deleteschema {
                    putscli "deleteschema - Usage: deleteschema"
                    putscli "Runs the schema delete for the database and benchmark selected with dbset and variables selected with diset. Equivalent to the Delete command in the graphical interface."
                }
                vuset {
                    putscli "vuset - Usage: vuset \[vu|delay|repeat|iterations|showoutput|logtotemp|unique|nobuff|timestamps\]"
                    putscli "Configure the virtual user options. Equivalent to the Virtual User Options window in the graphical interface."
                }
                vucreate {
                    putscli "vucreate - Usage: vucreate"
                    putscli "Create the virtual users. Equivalent to the Virtual User Create option in the graphical interface. Use \"print vucreated\" to see the number created, vustatus to see the status and vucomplete to see whether all active virtual users have finished the workload. A script must be loaded before virtual users can be created."
                }
                vurun {
                    putscli "vurun - Usage: vurun"
                    putscli "Send the loaded script to the created virtual users for execution. Equivalent to the Run command in the graphical interface."
                }
                vudestroy {
                    putscli "vudestroy - Usage: vudestroy"
                    putscli "Destroy the virtual users. Equivalent to the Destroy Virtual Users button in the graphical interface that replaces the Create Virtual Users button after virtual user creation."
                }
                vustatus {
                    putscli "vustatus - Usage: vustatus"
                    putscli "Show the status of virtual users. Status will be \"WAIT IDLE\" for virtual users that are created but not running a workload,\"RUNNING\" for virtual users that are running a workload, \"FINISH SUCCESS\" for virtual users that completed successfully or \"FINISH FAILED\" for virtual users that encountered an error."
                }
                vucomplete {
                    putscli "vucomplete - Usage: vucomplete"
                    putscli "Returns \"true\" or \"false\" depending on whether all virtual users that started a workload have completed regardless of whether the status was \"FINISH SUCCESS\" or \"FINISH FAILED\"."
                }
                loadscript {
                    putscli "loadscript - Usage: loadscript"
                    putscli "Load the script for the database and benchmark set with dbset and the dictionary variables set with diset. Use \"print script\" to see the script that is loaded. Equivalent to loading a Driver Script in the Script Editor window in the graphical interface."
                }
                clearscript {
                    putscli "clearscript - Usage: clearscript"
                    putscli "Clears the script. Equivalent to the \"Clear the Screen\" button in the graphical interface."
                }
                savescript {
                    putscli "savescript - Usage: savescript"
                    putscli "Save the script to a file. Equivalent to the \"Save\" button in the graphical interface."
                }
                customscript {
                    putscli "customscript - Usage: customscript scriptname.tcl"
                    putscli "Load an external script. Equivalent to the \"Open Existing File\" button in the graphical interface."
                }
                custommonitor {
                    putscli "custommonitor - Usage: custommonitor test|timed"
                    putscli "Causes an additional Virtual User to be created when running vucreate. Used when loading a custom script."
                }
                dgset {
                    putscli "dgset - Usage: dgset \[vu|ware|directory\]"
                    putscli "Set the Datagen options. Equivalent to the Datagen Options dialog in the graphical interface."
                }
                datagenrun {
                    putscli "datagenrun - Usage: datagenrun"
                    putscli "Run Data Generation. Equivalent to the Generate option in the graphical interface."
                }
                metset {
                    putscli "metset - Usage: metset \[agent_hostname|agent_id\]"
                    putscli "Configure the CPU Metrics options. Equivalent to the Metrics Options window in the graphical interface."
                }
                metstart {
                    putscli "metstart - Usage: metstart"
                    putscli "Starts the CPU Metrics and agent if configured to the localhost."
                }
                metstatus {
                    putscli "metstatus - Usage: metstatus"
                    putscli "Checks the status of the CPU Metrics."
                }
                metstop {
                    putscli "metstop - Usage: metstop"
                    putscli "Stops the CPU Metrics."
                }
                tcset {
                    if $wsmode {
                        putscli "tcset - Usage: tcset refreshrate seconds"
                    } else {
                        putscli "tcset - Usage: tcset \[refreshrate|logtotemp|unique|timestamps\]"
                    }
                    putscli "Configure the transaction counter options. Equivalent to the Transaction Counter Options window in the graphical interface."
                }
                tcstart {
                    putscli "tcstart - Usage: tcstart"
                    putscli "Starts the Transaction Counter."
                }
                tcstatus {
                    putscli "status - Usage: tcstatus"
                    putscli "Checks the status of the Transaction Counter."
                }
                tcstop {
                    putscli "tcstop - Usage: tcstop"
                    putscli "Stops the Transaction Counter."
                }
                wsport {
                    putscli "wsport - Usage: wsport \[ port number \]"
                    putscli "Set or report the Web Service Port."
                }
                wsstart {
                    putscli "wsstart - Usage: wsstart"
                    putscli "Start the Web Service."
                }
                wsstatus {
                    putscli "wsstatus - Usage: wsstatus"
                    putscli "Checks the status of the Web Service."
                }
                wsstop {
                    putscli "wsstop - Usage: wsstop"
                    putscli "Stops the Web Service."
                }

                citmp {
                    putscli "citmp - Usage: citmp"
                    putscli "Shows the TMP directory and jobs DB path used by CI."
                }
                cilisten {
                    putscli "cilisten - Usage: cilisten"
                    putscli "Starts the CI GitHub webhook listener and job watcher (Linux/Unix only)."
                }
                cistop {
                    putscli "cistop - Usage: cistop"
                    putscli "Stops the CI webhook listener and job watcher."
                }
                cistatus {
                    putscli "cistatus - Usage: cistatus"
                    putscli "Shows whether the CI listener and watcher are running."
                }
                cipush {
                    putscli "cipush - Usage: cipush refname"
                    putscli "Simulates a GitHub webhook push for a ref, e.g.:"
                    putscli "  cipush refs/tags/mariadb-12.2.1"
                }
                cistep {
                    putscli "cistep - Usage: cistep refname pipeline"
                    putscli "Runs a CI pipeline (from ci.xml) for a specific refname, e.g.:"
                    putscli "  cistep refs/tags/mariadb-12.2.1 default"
                    putscli "  cistep refs/tags/mariadb-12.2.1 compare"
                }
                ciset {
                    putscli "ciset - Usage: ciset top section key value"
                    putscli "Updates a CI configuration entry and persists it in ci.db, e.g.:"
                    putscli "  ciset MariaDB build repo_url https://github.com/MariaDB/server.git"
                    putscli "  ciset common listen_port 5001"
                }
            }
        }
    }
}

# ------------------------------------------------------------
# WEB HELP PAGE (HTML returned by /help in browser)
# ------------------------------------------------------------

proc wapp-page-help {} {
    set B [wapp-param BASE_URL]
    wapp-subst {<link href="%url([wapp-param BASE_URL]/style.css)" rel="stylesheet">}
    wapp-trim {
        <html>
        <head>
        <meta content="text/html;charset=ISO-8859-1" http-equiv="Content-Type">
        <title>HammerDB Web Service</title>
        </head>
        <body>
        <h3>HammerDB Web Service</h3>
        <br>
        <b>GET jobs</b>: Show the job ids, configuration, output, status, results and timings of jobs created by buildschema and vurun. Job output is equivalent to the output viewed in the graphical interface or command line.
        <br><br>
        get http://localhost:8080/jobs<br>
        get http://localhost:8080/jobs?jobid=TEXT<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;bm<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;db<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;delete<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;dict<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;index<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;result<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;resultdata<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;status<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;tcount<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;tcountdata<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;timestamp<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;timing<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;timingdata<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;timing&amp;vuid=INTEGER<br>
        get http://localhost:8080/jobs?jobid=TEXT&amp;vu=INTEGER<br>
        <br>
        </body>
        </html>
    }
}

