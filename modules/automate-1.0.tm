# automate-1.0.tm
# HammerDB Enterprise Automation / BaaS MVP page
# - Dropdown tags from GitHub API (cached)
# - Custom ref supports refs/tags/..., refs/heads/..., and commit SHA
# - Builds webhook payload and POSTs to cilisten endpoint
# - PRG (POST/Redirect/GET style) behavior for GET: action=run redirects back to /automate
# - Shows last run status banner (green/red) near the top (and stores last payload/response in memory)
# - ASCII only

package provide automate 1.0

namespace eval automate {
    namespace export wapp-page-automate

    # ----------------------------
    # Small utilities (ASCII only)
    # ----------------------------
    proc __is_true {v} {
        set v [string tolower [string trim $v]]
        expr {$v eq "1" || $v eq "true" || $v eq "yes" || $v eq "on"}
    }

    proc __dict_get_default {d k def} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $def
    }

    proc __norm_pre {s} {
        regsub -all {\r\n} $s "\n" s
        regsub -all {\r}   $s "\n" s
        return $s
    }

    # Safe HTML escape (avoid Wapp %html() macro for JSON blobs)
    proc __html_escape {s} {
        return [string map {& &amp; < &lt; > &gt; \" &quot; ' &#39;} $s]
    }

    proc __pre {s} {
        set s [__norm_pre $s]
        set esc [__html_escape $s]
        wapp-subst {<pre style="white-space:pre-wrap; overflow-wrap:anywhere; margin:0;">}
        wapp-unsafe $esc
        wapp-subst {</pre>}
        wapp-subst "\n"
    }

    proc __page_head {B title} {
        wapp-content-security-policy { default-src 'self'; style-src 'self' 'unsafe-inline' *; img-src * data:; script-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; }
        wapp-subst {<link href="%url(/style.css)" rel="stylesheet">}
        wapp-subst {<p><img src='%html($B)/logo.png' width='55' height='60'></p>}
        wapp-subst "<h3 class='title'>%html($title)</h3>\n"

        # Small, self-contained styles for this page (keeps form consistent)
        wapp-subst {
<style>
.aut-wrap{max-width:980px;}
.aut-form{max-width:720px;}
.aut-ctl{width:100%; box-sizing:border-box; min-width:0;}
.aut-row{margin-top:8px;}
.aut-actions{margin-top:14px;}
.aut-btn{padding:6px 14px;}
.aut-banner{border:1px solid #ddd; padding:10px 12px; border-radius:6px; margin:10px 0 14px 0;}
.aut-ok{background:#e7f6ea; border-color:#7ac189; color:#155724;}
.aut-fail{background:#fdeaea; border-color:#e18b8b; color:#721c24;}
.aut-mini{opacity:0.75; font-size:0.95em;}
.aut-details{margin-top:8px;}
.aut-details summary{cursor:pointer; font-weight:600;}
.aut-kv{margin:0; padding:0;}
.aut-kv b{display:inline-block; min-width:90px;}
</style>
}
        wapp-subst "\n"
    }

    proc __is_sha1 {s} {
        set s [string trim $s]
        expr {[regexp {^[0-9a-fA-F]{7,40}$} $s]}
    }

    # ----------------------------
    # ci.xml access (via cidict)
    # ----------------------------
    proc __get_ci_build_config {} {
        upvar #0 cidict cidict
        if {![info exists cidict]} {
            set cidict [SQLite2Dict "ci"]
        }

        set repo_url    ""
        set ref_regexp  ""
        set listen_port ""

        if {[dict exists $cidict MariaDB build repo_url]} {
            set repo_url [dict get $cidict MariaDB build repo_url]
        }
        if {[dict exists $cidict MariaDB build ref_regexp]} {
            set ref_regexp [dict get $cidict MariaDB build ref_regexp]
        }
        if {[dict exists $cidict common listen_port]} {
            set listen_port [dict get $cidict common listen_port]
        }

        set cilisten_url ""
        if {$listen_port ne "" && [string is integer -strict $listen_port]} {
            set cilisten_url "http://127.0.0.1:$listen_port"
        } else {
            set cilisten_url "http://127.0.0.1:5000"
        }

        return [dict create repo_url $repo_url ref_regexp $ref_regexp cilisten_url $cilisten_url listen_port $listen_port]
    }

    # ----------------------------
    # GitHub tags dropdown (cached)
    # ----------------------------
    variable __tag_cache_ts 0
    variable __tag_cache_list {}

    proc __repo_to_owner_repo {repo_url} {
        set u [string trim $repo_url]
        regsub {\.git$} $u "" u
        if {[regexp {github\.com/([^/]+)/([^/]+)$} $u -> owner repo]} {
            return "$owner/$repo"
        }
        return ""
    }

    proc __github_tags {repo_url} {
        variable __tag_cache_ts
        variable __tag_cache_list

        set now [clock seconds]
        if {$__tag_cache_ts > 0 && ($now - $__tag_cache_ts) < 300 && [llength $__tag_cache_list] > 0} {
            return $__tag_cache_list
        }

        set owner_repo [__repo_to_owner_repo $repo_url]
        if {$owner_repo eq ""} {
            set __tag_cache_ts $now
            set __tag_cache_list {}
            return $__tag_cache_list
        }

        set api "https://api.github.com/repos/$owner_repo/tags?per_page=50"
        set tags {}

        if {[catch {
            set tok [http::geturl $api -timeout 8000]
            set code [http::ncode $tok]
            set body [http::data $tok]
            http::cleanup $tok

            if {$code != 200} {
                set __tag_cache_ts $now
                set __tag_cache_list {}
                return $__tag_cache_list
            }

            # simple extraction: {"name":"..."}
            set names [regexp -all -inline {"name"\s*:\s*"([^"]+)"} $body]
            for {set i 1} {$i < [llength $names]} {incr i 2} {
                lappend tags [lindex $names $i]
            }

            # dedupe, preserve order
            set seen [dict create]
            set out {}
            foreach t $tags {
                if {![dict exists $seen $t]} {
                    dict set seen $t 1
                    lappend out $t
                }
            }
            set tags $out
        } err]} {
            set tags {}
        }

        set __tag_cache_ts $now
        set __tag_cache_list $tags
        return $tags
    }

    # ----------------------------
    # JSON helpers + payload builder
    # ----------------------------
    proc __json_escape {s} {
        set s [__norm_pre $s]
        set s [string map {\\ \\\\ \" \\\" \n \\n \t \\t} $s]
        return $s
    }

    proc __make_payload {ref pipeline} {
        set ref_in [string trim $ref]

        # Normalize shorthand, but allow commits
        if {[string match "refs/*" $ref_in]} {
            # leave as-is
        } elseif {[__is_sha1 $ref_in]} {
            # commit SHA: leave as-is
        } else {
            # shorthand tag name -> refs/tags/<name>
            set ref_in "refs/tags/$ref_in"
        }

        set j_ref [__json_escape $ref_in]
        set j_pl  [__json_escape [string tolower [string trim $pipeline]]]
        return "{\"ref\":\"$j_ref\",\"hammerdb\":{\"pipeline\":\"$j_pl\"}}"
    }

    proc __post_json {url json} {
        set headers [list Content-Type application/json User-Agent HammerDB-Automation]
        set tok ""
        set code 0
        set body ""
        set err ""

        if {[catch {
            set tok [http::geturl $url -method POST -headers $headers -query $json -timeout 15000]
            set code [http::ncode $tok]
            set body [http::data $tok]
            http::cleanup $tok
        } e]} {
            set err $e
        }

        return [dict create code $code body $body err $err]
    }

    # ----------------------------
    # "Flash" last-run store (in-memory)
    # Keeps refresh safe: after action=run we redirect back to /automate (no action=run)
    # ----------------------------
    variable __last_ts 0
    variable __last_client ""
    variable __last_ok 0
    variable __last_http 0
    variable __last_msg ""
    variable __last_payload ""
    variable __last_resp_body ""
    variable __last_resp_err ""

    proc __client_id {} {
        # Remote address is usually available; fall back to empty
        set ra ""
        if {![catch {set ra [wapp-param REMOTE_ADDR]}]} {
            return $ra
        }
        return ""
    }

    proc __store_last {ok http msg payload body err} {
        variable __last_ts
        variable __last_client
        variable __last_ok
        variable __last_http
        variable __last_msg
        variable __last_payload
        variable __last_resp_body
        variable __last_resp_err

        set __last_ts [clock seconds]
        set __last_client [__client_id]
        set __last_ok $ok
        set __last_http $http
        set __last_msg $msg
        set __last_payload $payload
        set __last_resp_body $body
        set __last_resp_err $err
    }

proc __render_last_if_any {} {
    variable __last_ts
    variable __last_client
    variable __last_ok
    variable __last_http
    variable __last_msg
    variable __last_payload
    variable __last_resp_body
    variable __last_resp_err

    set now [clock seconds]
    if {$__last_ts == 0} { return }

    # Only show for same client, and only for 10 minutes
    if {[__client_id] ne $__last_client} { return }
    if {($now - $__last_ts) > 600} { return }

    wapp-subst {<a id="runresult"></a>}
    if {$__last_ok} {
        wapp-subst {<div class="aut-banner aut-ok">}
        wapp-subst "<p class='aut-kv'><b>Result:</b> SUCCESS</p>\n"
    } else {
        wapp-subst {<div class="aut-banner aut-fail">}
        wapp-subst "<p class='aut-kv'><b>Result:</b> FAIL</p>\n"
    }

    if {$__last_http ne "" && $__last_http != 0} {
        wapp-subst "<p class='aut-kv'><b>HTTP:</b> %html($__last_http)</p>\n"
    }
    if {$__last_msg ne ""} {
        wapp-subst "<p class='aut-kv'><b>Info:</b> %html($__last_msg)</p>\n"
    }

    wapp-subst {<details class="aut-details">}
    wapp-subst {<summary>Details</summary>}
    wapp-subst {<div style="margin-top:8px;">}
    wapp-subst {<p class="aut-mini"><b>Webhook payload</b></p>}
    __pre $__last_payload

    wapp-subst {<p class="aut-mini"><b>cilisten response</b></p>}
    if {$__last_resp_err ne ""} {
        __pre $__last_resp_err
    } else {
        __pre $__last_resp_body
    }
    wapp-subst {</div></details>}
    wapp-subst {</div>}
    wapp-subst "\n"
}
    # ----------------------------
    # Main page
    # ----------------------------
    proc wapp-page-automate {} {
        set B [wapp-param BASE_URL]
        set query [wapp-param QUERY_STRING]

        # Parse query string into dict (simple; fine for our params)
        set paramdict [dict create]
        if {$query ne ""} {
            foreach a [split $query &] {
                if {$a eq ""} continue
                lassign [split $a =] k v
                dict set paramdict $k $v
            }
        }

        set cfg [__get_ci_build_config]
        set repo_url     [__dict_get_default $cfg repo_url ""]
        set ref_regexp   [__dict_get_default $cfg ref_regexp ""]
        set cilisten_url [__dict_get_default $cfg cilisten_url "http://127.0.0.1:5000"]

        # Inputs (defaults)
        set action   [__dict_get_default $paramdict action ""]
        set pipeline [string tolower [__dict_get_default $paramdict pipeline "profile"]]

        # tag dropdown selection
        set tag_sel    [__dict_get_default $paramdict tag_sel "mariadb-12.2.1"]
        set ref_custom [__dict_get_default $paramdict ref_custom ""]
        if {$ref_custom eq ""} {
            # tolerate older param name if present
            set ref_custom [__dict_get_default $paramdict ref_cust ""]
        }

        # If user typed something, force Custom selected
        if {[string trim $ref_custom] ne ""} {
            set tag_sel "__custom__"
        }

        set ref $tag_sel
        if {$tag_sel eq "__custom__"} {
            set ref $ref_custom
        }

        # ----------------------------------------
        # If action=run, DO THE WORK then REDIRECT
        # This avoids refresh resubmitting.
        # ----------------------------------------
        if {$action eq "run"} {
            set ref_trim [string trim $ref]
            set pl_trim  [string tolower [string trim $pipeline]]

            if {$ref_trim eq ""} {
                __store_last 0 0 "Ref is required." "" "" "Ref is required."
                wapp-redirect "$B/automate#runresult"
                return
            }
            if {$pl_trim ni {"profile" "compare"}} {
                __store_last 0 0 "Pipeline must be profile or compare." "" "" "Bad pipeline."
                wapp-redirect "$B/automate#runresult"
                return
            }

            set payload [__make_payload $ref_trim $pl_trim]
            set resp [__post_json $cilisten_url $payload]
            set code [dict get $resp code]
            set body [dict get $resp body]
            set err  [dict get $resp err]

            if {$err ne ""} {
                __store_last 0 0 "POST failed (listener unreachable?)" $payload $body $err
            } else {
                # Success if HTTP 2xx
                set ok 0
                if {$code >= 200 && $code < 300} { set ok 1 }
                __store_last $ok $code "Posted to cilisten endpoint" $payload $body ""
            }

            # Redirect back to clean page (no action=run). Refresh is safe.
            wapp-redirect "$B/automate#runresult"
            return
        }

        # Normal GET render
        __page_head $B "AUTOMATION"
        wapp-subst {<div class="aut-wrap">}
        wapp-subst "\n"

        # Show last run banner (if any) near the top
        __render_last_if_any

        # ----------------------------
        # Automation table (JOBCI) at top
        # ----------------------------
        wapp-subst {<table>}
        wapp-subst {<tr><th>CI ID</th><th>Ref</th><th>Pipeline</th><th>Date</th><th>Status</th></tr>}
        wapp-subst "\n"

        set cicount [join [hdbjobs eval {SELECT COUNT(*) FROM JOBCI}]]
        if {$cicount eq 0} {
            wapp-subst {<tr><td colspan="5">No Automated CI runs found.</td></tr>}
            wapp-subst "\n"
        } else {
            # Pipeline column may not exist in older DBs; probe safely
            set has_pipeline 0
            if {![catch {hdbjobs eval {SELECT pipeline FROM JOBCI LIMIT 1}}]} { set has_pipeline 1 }

            if {$has_pipeline} {
                hdbjobs eval {SELECT ci_id, refname, pipeline, timestamp, status FROM JOBCI ORDER BY ci_id DESC LIMIT 25} {
                    set url "$B/ci?ci_id=$ci_id"
                    wapp-subst {<tr><td><a href='%html($url)'>%html($ci_id)</a></td><td>%html($refname)</td><td>%html($pipeline)</td><td>%html($timestamp)</td><td>%html($status)</td></tr>}
                    wapp-subst "\n"
                }
            } else {
                hdbjobs eval {SELECT ci_id, refname, timestamp, status FROM JOBCI ORDER BY ci_id DESC LIMIT 25} {
                    set url "$B/ci?ci_id=$ci_id"
                    wapp-subst {<tr><td><a href='%html($url)'>%html($ci_id)</a></td><td>%html($refname)</td><td>-</td><td>%html($timestamp)</td><td>%html($status)</td></tr>}
                    wapp-subst "\n"
                }
            }
        }
        wapp-subst {</table>}
        wapp-subst "\n"

        # ----------------------------
        # Info
        # ----------------------------
        wapp-subst "<h4>MariaDB Automation (TPROC-C)</h4>\n"
        if {$repo_url ne ""} {
            wapp-subst "<p><b>Repo:</b> %html($repo_url)</p>\n"
        }
        if {$ref_regexp ne ""} {
            wapp-subst "<p><b>Accepted refs:</b> %html($ref_regexp)</p>\n"
        }
        wapp-subst "<p><b>cilisten endpoint:</b> %html($cilisten_url)</p>\n"

        # Fetch GitHub tags (best-effort)
        set tags [__github_tags $repo_url]
        if {[llength $tags] == 0} {
            set tags [list mariadb-12.2.1 mariadb-12.1.2 mariadb-11.8.3 mariadb-11.4.9 mariadb-10.6.20]
        }

        # ----------------------------
        # Form (submits back to /automate with action=run, then redirects)
        # ----------------------------
        wapp-subst {<div class="aut-form">}
        wapp-subst "\n"
        wapp-subst "<form method='GET' action='%html($B)/automate'>\n"
        wapp-subst {<input type='hidden' name='action' value='run'>}
        wapp-subst "\n"

        wapp-subst "<p><b>MariaDB ref</b></p>\n"
        wapp-subst {<select class="aut-ctl" name="tag_sel">}
        wapp-subst "\n"
        foreach t $tags {
            set sel ""
            if {$tag_sel eq $t} { set sel " selected" }
            wapp-subst "<option value='%html($t)'$sel>%html($t)</option>\n"
        }
        set sel ""
        if {$tag_sel eq "__custom__"} { set sel " selected" }
        wapp-subst "<option value='__custom__'$sel>Custom (type below)</option>\n"
        wapp-subst {</select>}
        wapp-subst "\n"

        wapp-subst {<div class="aut-row">}
        wapp-subst {<label>Custom ref (refs/tags/..., refs/heads/..., or commit SHA):</label><br>}
        wapp-subst {<input class="aut-ctl" type="text" name="ref_custom" value="%html($ref_custom)" placeholder="refs/heads/12.2 or 144dead8826f...">}
        wapp-subst {</div>}
        wapp-subst "\n"

        wapp-subst "<p style='margin-top:12px;'><b>Pipeline</b></p>\n"
        set chk_profile ""
        set chk_compare ""
        if {$pipeline eq "compare"} {
            set chk_compare " checked"
        } else {
            set chk_profile " checked"
        }
        wapp-subst "<label><input type='radio' name='pipeline' value='profile'$chk_profile> Profile</label>\n"
        wapp-subst "&nbsp;&nbsp;"
        wapp-subst "<label><input type='radio' name='pipeline' value='compare'$chk_compare> Compare (previous tag)</label>\n"

        wapp-subst {<div class="aut-actions">}
        wapp-subst {<button class="aut-btn" type="submit">GO</button>}
        wapp-subst {</div>}
        wapp-subst "\n"

        wapp-subst {</form>}
        wapp-subst "\n"
        wapp-subst {<p class="aut-mini">MVP: build webhook payload and POST it to cilisten. Monitor listener for progress.</p>}
        wapp-subst "<p><a href='%html($B)/jobs'>Job Index</a></p>\n"
        wapp-subst {</div>}
        wapp-subst "\n"

        wapp-subst {</div>}
        wapp-subst "\n"
    }
}

# allow "namespace import automate::*"
namespace import automate::*
