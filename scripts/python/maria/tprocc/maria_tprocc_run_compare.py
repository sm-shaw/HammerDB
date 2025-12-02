#!/usr/bin/env python3
# maintainer: Pooja Jain (Python compare variant)

import os
import sys

# Maintain compatibility if compare.sh didn't set TMP
tmpdir = os.getenv("TMP")
if not tmpdir:
    tmpdir = os.path.join(os.getcwd(), "TMP")
    os.makedirs(tmpdir, exist_ok=True)
    print(f"TMP not set — defaulting to {tmpdir}")
    os.environ["TMP"] = tmpdir
else:
    # Normalise TMP to absolute path (nice but not required)
    tmpdir = os.path.abspath(tmpdir)
    os.environ["TMP"] = tmpdir

print("SETTING CONFIGURATION")

# PROFILEID must be provided by the CI/bisect driver
profileid = os.getenv("PROFILEID")
if not profileid:
    print("ERROR: PROFILEID not set in environment")
    sys.exit(1)

try:
    int(profileid)
except ValueError:
    print(f"ERROR: PROFILEID must be an integer, got: '{profileid}'")
    sys.exit(1)

print(f"Using PROFILEID = {profileid}")

try:
    # Set the profileid inside HammerDB jobs module
    jobs("profileid", profileid)
except Exception as e:
    print(f"ERROR: jobs profileid failed: {e}")
    sys.exit(1)

# Generic options
giset("commandline", "keepalive_margin", 1200)
giset("timeprofile", "xt_gather_timeout", 1200)

# Database & benchmark selection
dbset("db", "maria")
dbset("bm", "TPC-C")

# Connection details
diset("connection", "maria_host", "localhost")
diset("connection", "maria_port", "3306")
diset("connection", "maria_socket", "/tmp/mariadb.sock")

# TPROC-C workload options
diset("tpcc", "maria_user", "root")
diset("tpcc", "maria_pass", "maria")
diset("tpcc", "maria_dbase", "tpcc")
diset("tpcc", "maria_driver", "timed")
diset("tpcc", "maria_rampup", "2")
diset("tpcc", "maria_duration", "5")
diset("tpcc", "maria_allwarehouse", "false")
diset("tpcc", "maria_timeprofile", "false")
diset("tpcc", "maria_purge", "true")

print("TEST STARTED")

import tclpy

vcpu_list = [1, 8, 16, 24, 32, 40, 48, 56, 64]

for z in vcpu_list:
    loadscript()
    vuset("vu", z)
    vuset("logtotemp", 1)
    vucreate()
    tcstart()
    tcstatus()

    # Run test and capture job id
    jobid = tclpy.eval("vurun")

    tcstop()
    vudestroy()

    file_path = os.path.join(tmpdir, f"maria_tprocc_profile.{profileid}")
    print(f"Writing to {file_path}")
    with open(file_path, "a", encoding="utf-8") as fd:
        fd.write(str(jobid) + "\n")

print("TEST COMPLETE")
sys.exit(0)
