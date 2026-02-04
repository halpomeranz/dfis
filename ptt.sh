#!/bin/bash
# ptt.sh ("Process That Thing!") -- Hal Pomeranz (hrpomeranz@gmail.com)
# Version: 4.1.0 - 2026-02-04
#
# Usage: ptt.sh [options] mountpoint outputdir
#
# Created to post-process mounted Linux images and UAC collections.
# Currently performs the following tasks:
#
#    -- Runs bulk_extractor against each mounted partition or UAC collection
#    -- Uses strings from bulk_extractor to extract audit.logs,
#          both classic and new-style Syslog logs, and Apache style web logs
#          (will include carved logs and gzip-ed logs thanks to bulk_extractor)
#    -- Creates mactime bodyfiles from login logs and wtmp records
#    -- Builds file system (mactime) timeline (with and without log entries)
#    -- Builds log2timeline timeline with JSON output (incl merged bodyfiles)
#    -- Makes a list of archive files found in the image
#    -- Makes a list of hidden directories (name starts with ".") in the image
#    -- Collects cron jobs, systemd timers, etc into output directory
#    -- Optionally runs Volatility and bulk_extractor against
#          supplied memory image (UAC "memory_dump/avml.lime or use -M)
#    -- Optionally will grep for supplied IOCs with "-i iocfile"
#          (fixed string search, NOT regex)
#
# shellcheck disable=SC2002,SC2004,SC2076,SC2164,SC2190

usage() {
    cat <<EOM
Post-processing for mounted images

Usage: $0 [options] sourcedir outputdir

    -i iocs      Path to file containing IOC strings (optional)
    -H hostname  Hostname used in output files (default: mounted /etc/hostname)
    -L           Do not run log2timline
    -M memdump   Location of memory dump file to process
    -W workdir   Local dir in case output dir is non-Linux file system
    -C           Just check that dependencies are met and then exit
EOM
    exit 1;
}

declare -A TextColor
TextColor=('WARNING' '\e[0;41m\e[1;37m'      # White text on RED background
           'primary' '\e[0;40m\e[1;37m'      # White text on BLACK background
	   'memory ' '\e[0;42m\e[1;37m'      # White text on GREEN background
	   'mactime' '\e[0;45m\e[1;37m'      # White text on PURPLE background
	   'lg2time' '\e[0;45m\e[1;37m'      # White text on PURPLE background
	   'bulk_ex' '\e[0;44m\e[1;37m'      # White text on BLUE background
	   'miscjob' '\e[1;43m\e[1;37m'      # White text on YELLOW background
	   'logxtra' '\e[1;43m\e[1;37m'      # White text on YELLOW background
	   'ziplogs' '\e[1;43m\e[1;37m'      # White text on YELLOW background
)
DefaultColor='\e[0;46m\e[1;37m'              # White text on CYAN background

status_output() {
    tag=$1
    msg=$2

    tclr=${TextColor[$tag]}
    [[ -z "$tclr" ]] && tclr=$DefaultColor

    echo -e $(date '+%F %T') "$tclr" "$tag" '\e[0m' "$msg"
}

check_directories() {
    # Target directory must exist and output directory must be specified
    if [[ ! -d "$MountedDir" ]]; then  
	echo \'"$MountedDir"\' does not exist\!
	usage
    fi
    if [[ -z "$OutputDir" ]]; then  
	echo You must specify an output directory
	usage
    fi

    if [[ ! (-d "$MountedDir/etc" && -d "$MountedDir/var/log") ]]; then
	if [[ -d "$MountedDir/files/etc" && -d "$MountedDir/files/var/log" ]]; then
	    MountedDir="$MountedDir/files"
	    status_output "INFO:::" "Changed target directory to \"$MountedDir\""
	elif [[ -f "$MountedDir/uac.log" ]]; then
	    status_output "INFO:::" "Looks like a UAC collection"
	    UACDir="$MountedDir"
	    MountedDir="$UACDir/[root]"
	else
	    # TODO: we should distinguish between a mountpoint vs. random
	    # directory in the filesystem. Random directory should do
	    # "bulk_extractor -R" like a UAC collection. Mountpoints should
	    # be treated more like a full file system image where BE runs
	    # against the underlying device.
	    status_output "INFO:::" "\"$MountedDir\" does not look like a mounted file system or UAC collection"
	    status_output "INFO:::" "Proceeding anyway-- here's hoping this is what was intended"
	fi
    fi
}    

declare -A ProgSugg
ProgSugg=(
    'bulk_extractor'   'install from https://github.com/simsong/bulk_extractor'
    'mactime'          'try "apt install sleuthkit"'
    'parallel'         'try "apt install parallel"'
    'jq'               'try "apt install jq"'
    'bzcat'            'try "apt install bzip2"'
    'xzcat'            'try "apt install xz-utils"'
    'statx'            'install from https://github.com/tclahr/statx/'
    'ausorter.pl'      'install from https://github.com/halpomeranz/dfis'
    'wtmpreader.pl'    'install from https://github.com/halpomeranz/dfis'
    'wtmpreader2mactime.pl' 'install from https://github.com/halpomeranz/dfis'
)

check_dependencies() {
    dep_missing=0

    if [[ -n "$IocsFile" && ! -r "$IocsFile" ]]; then
	dep_missing=1
	status_output WARNING "IOC file \"$IocsFile\" not found"
    fi

    # Validate supplied memory dump path, or check in UAC directory
    if [[ -z "$MemoryDumpFile" && -n "$UACDir" ]]; then
	[[ -r "$UACDir/memory_dump/avml.lime" ]] && MemoryDumpFile="$UACDir/memory_dump/avml.lime"
    fi

    if [[ -n "$MemoryDumpFile" ]]; then
	# Check size of memory dump file, which will also catch invalid paths
	memsize=$(stat -c '%s' "$MemoryDumpFile" 2>/dev/null)
	if [[ $memsize -le 4096 ]]; then
	    status_output WARNING "$MemoryDumpFile does not appear to be a valid memory image"
	    MemoryDumpFile=
	fi
    fi
   
    # Do we have a valid memory dump file? Check for Volatility
    if [[ -n "$MemoryDumpFile" ]]; then
	volvers=$(vol -v 2>/dev/null)
	if [[ "$volvers" =~ ^(Volatility 3) ]]; then
	    RunVolatility=1
	else
	    status_output WARNING "Volatility 3 not found. Will still use bulk_extractor on memory dump."
	    RunVolatility=0
	fi
    fi

    for prog in "${!ProgSugg[@]}"; do
	result=$(type "$prog" 2>/dev/null)
	[[ -n "$result" ]] && continue
	dep_missing=1
	status_output WARNING "$prog program not found (${ProgSugg[$prog]})"
    done

if ! perl -e 'use Sys::Utmp' >/dev/null 2>&1; then
	dep_missing=1
	status_output WARNING 'Perl Sys::Utmp not found (try "apt install libsys-utmp-perl")'
    fi

    if [[ $NoL2tRun -eq 0 ]]; then
	docker_out=$(docker run log2timeline/plaso log2timeline.py --version 2>/dev/null)
	if [[ -z "$docker_out" ]]; then
	    status_output WARNING "Cannot find \"log2timeline/plaso\" docker container"
	    status_output WARNING "See https://plaso.readthedocs.io/en/latest/sources/user/Installing-with-docker.html"
	    status_output WARNING "log2timeline will not run"
	    NoL2tRun=1
	fi
    fi

    if [[ $dep_missing -gt 0 ]]; then
	status_output WARNING "Program cannot run until depenencies are met"
	exit 1
    fi
    if [[ $CheckDepsOnly -gt 0 ]]; then
	status_output primary "Dependencies met. Program can run."
	exit 0
    fi
}

# Using statx here-- not fls-- to be compatible across a wide range
# of file systems
do_fs_timeline() {
    mydir="$OutputDir/timeline-mactime"
    mkdir -p "$mydir"

    status_output mactime "Creating file system timeline..."
    hostext=
    [[ -n "$HostName" ]] && hostext="-$HostName"

    if [[ -n "$UACDir" ]]; then
	cp "$UACDir/bodyfile/bodyfile.txt" "$mydir/bodyfile$hostext"
    else
	find "$MountedDir" -print0 | xargs -0 statx | sed "s,$MountedDir/*,/," >"$mydir/bodyfile$hostext"
    fi
    
    mactime -d -y -b "$mydir/bodyfile$hostext" 2001-01-01 >"$mydir/timeline$hostext.csv" 2>"$mydir/timeline$hostext.csv-errors" 
    status_output mactime "File system timeline done!"
}

# Assumes access to a dockerized version of Plaso called "log2timeline/plaso"
do_l2t_firstpass() {
    mydir="$OutputDir/timeline-l2t"
    mkdir -p "$mydir"
    cp /dev/null "$mydir/l2t.log.1"

    status_output lg2time "Starting log2timeline initial processing..."
    
    # Control l2t runtime by only grabbing limited artifacts in first pass.
    # Will add file system info from mactime bodyfile plus adding wtmp data.
    cat <<EOF >>"$mydir/l2t-filter.yaml"
description: only grab limited artifacts
type: include
paths:
  - /var/log/.*
  - /root/..*history
  - /home/[^/]*/..*history 
EOF
    docker run -v "$MountedDir:$MountedDir" -v "$mydir:$mydir" log2timeline/plaso \
           log2timeline.py --parsers systemd_journal,text -f "$mydir/l2t-filter.yaml" \
	   --hashers none -z UTC --storage_file "$mydir/image.plaso" \
	   --status_view linear --status_view_interval 60 "$MountedDir" >"$mydir/l2t.log.1" 2>&1

    status_output lg2time "Finished log2timeline initial processing"
}

# Link all generated bodyfiles into "$OutputDir/bodyfiles" for
# use by analysts (do_l2t_merge() only uses a subset of these
# because the first l2t pass pulled in logfile data already).
#
# Produce a merged CSV timeline with "mactime" and drop it into
# "$OutputDir/timeline-mactime". Also extract a text file with just
# the login logs into "$LogExtraDir/logins"
#
collect_bodyfiles() {
    mkdir -p "$OutputDir/bodyfiles"
    [[ -n $(ls "$OutputDir"/timeline-mactime/bodyfile* 2>/dev/null) ]] &&
	ln "$OutputDir"/timeline-mactime/bodyfile* "$OutputDir/bodyfiles"
    [[ -r "$LogExtraDir/wtmp/bodyfile-wtmp" ]] &&
	ln "$LogExtraDir/wtmp/bodyfile-wtmp" "$OutputDir/bodyfiles"
    [[ -r "$LogExtraDir/journal/bodyfile-securelogs-journal" ]] &&
	ln "$LogExtraDir/journal/bodyfile-securelogs-journal" "$OutputDir/bodyfiles"
    [[ -n $(ls "$OutputDir"/strings/audit.log-*-bodyfile 2>/dev/null) ]] &&
	ln "$OutputDir"/strings/audit.log-*-bodyfile "$OutputDir/bodyfiles"
    [[ -n $(ls "$OutputDir"/strings/syslogs-newstyle-*-bodyfile 2>/dev/null) ]] &&
	ln "$OutputDir"/strings/syslogs-newstyle-*-bodyfile "$OutputDir/bodyfiles"
    [[ -r "$LogExtraDir/compressed/bodyfile-compressed-securelogs" ]] &&
	ln "$LogExtraDir/compressed/bodyfile-compressed-securelogs" "$OutputDir/bodyfiles"

    hostext=
    [[ -n "$HostName" ]] && hostext="-$HostName"
    mkdir -p "$LogExtraDir/logins"
    cat "$OutputDir/bodyfiles"/* | 
        mactime -d -y 2001-01-01 2>/dev/null |
	tee "$OutputDir/timeline-mactime/timeline-withlogins$hostext.csv" |
	grep -F ',0,macb,----------,0,0,0,' |
	sed 's/,0,macb,----------,0,0,0,/\t/; s/"//g; s/T/ /; s/Z//' >"$LogExtraDir/logins/merged-securelog-data.txt"
}

do_l2t_merge() {
    mydir="$OutputDir/timeline-l2t"
    status_output lg2time "Starting second phase of log2timeline processing..."

    # We need to merge in the filesystem timeline and wtmp info
    # (the first l2t pass pulled in the systemd journal and other log files).
    mkdir -p "$mydir/bodyfiles"
    [[ -n $(ls "$OutputDir"/timeline-mactime/bodyfile* 2>/dev/null) ]] &&
	ln "$OutputDir"/timeline-mactime/bodyfile* "$mydir/bodyfiles"
    [[ -r "$LogExtraDir/wtmp/bodyfile-wtmp" ]] &&
	ln "$LogExtraDir/wtmp/bodyfile-wtmp" "$mydir/bodyfiles"

    # Merge the collected body files into the log2timeline data
    status_output lg2time "Merge file system and wtmp data"
    cp /dev/null "$mydir/l2t.log.2"
    docker run -v "$mydir:$mydir" log2timeline/plaso log2timeline.py \
	   --parsers bodyfile --hashers none -z UTC --storage_file "$mydir/image.plaso" \
	   --status_view linear --status_view_interval 60 "$mydir/bodyfiles" >"$mydir/l2t.log.2" 2>&1

    # Output json_line
    status_output lg2time "Output JSON"
    [[ -n "$HostName" ]] && bfname=$HostName || bfname='timeline'
    cp /dev/null "$mydir/l2t.log.3"
    docker run -v "$mydir:$mydir" log2timeline/plaso \
	   psort.py -q --status-view none -o json_line \
	   -w "$mydir/$bfname-l2t.jsonl" "$mydir/image.plaso" >>"$mydir/l2t.log.3" 2>&1

    # Remove mountpoint from file paths and gzip
    status_output lg2time "Compress JSON"
    cat "$mydir/$bfname-l2t.jsonl" | sed "s,$MountedDir/*,/,g" | gzip >"$mydir/$bfname-l2t.jsonl.gz"
    rm -f "$mydir/$bfname-l2t.jsonl"
    cd "$mydir/bodyfiles" && rm -f ./*
    rmdir "$mydir/bodyfiles"

    status_output lg2time "Finished log2timeline processing"
}

# Pulling extra de-duplication processing into this routine so that it
# doesn't block other processing
extra_auditlog() {
    strdir=$1
    ext=$2

    status_output '+extra+' "($ext) Starting additional audit.log processing begins"
    workdir="$strdir/audit.log-$ext-working"
    mkdir -p "$workdir"
    cd "$workdir"
    cat "$strdir/audit.log-$ext-raw" | ausorter.pl
    for file in *; do
	sort -u "$file"
    done | tee "$strdir/audit.log-$ext-timestamps" | sed 's/[^t]*//' >"$strdir/audit.log-$ext"
    rm -f ./*
    rmdir "$workdir" 2>/dev/null
    status_output '+extra+' "($ext) Finished additional audit.log processing"
}

# audit.log entries
str_auditlog() {
    strdir=$1
    ext=$2

    status_output auditlg "Starting audit.log processing thread"
    grep -aoP 'type=\S+ msg=audit\(\d+\.\d+:\d+\): .*' >"$strdir/audit.log-$ext-raw"
    status_output auditlg "Finished audit.log processing"
    [[ -s "$strdir/audit.log-$ext-raw" ]] || return
    extra_auditlog "$strdir" "$ext" &
    echo $! >>"$PIDFile"
}

# Traditional Syslog logs
str_tradsyslog() {
    strdir=$1
    ext=$2

    status_output oldslog "Started Syslog (traditional format) processing thread"
    # Mon dd hh:mm:ss host proc: whatever
    grep -aoP '[A-Z][a-z]{2} ( |\d)\d \d{2}:\d{2}:\d{2} [-.\w]+ \S+:\s+.*' >"$strdir/syslogs-traditional-$ext-raw"
    status_output oldslog "Finished Syslog (traditional format) processing"
}

# New Syslog timestamp format
str_newsyslog() {
    strdir=$1
    ext=$2

    status_output newslog "Started Syslog (new format) processing thread"
    # yyyy-mm-ddThh:mm:ss.usec+hh:mm fac.pri host proc: whatever
    grep -aoP '\d+-\d+-\d+T\d+:\d+:\d+\.\d+[+-]\d+:\d+ \w+\.\w+ [-.\w]+ \S+:\s+.*' >"$strdir/syslogs-newstyle-$ext-raw"
    outputsize=$(stat --printf '%s' "$strdir/syslogs-newstyle-$ext-raw")
    [[ "$outputsize" -lt 10000000000 ]] && sort -u "$strdir/syslogs-newstyle-$ext-raw" >"$strdir/syslogs-newstyle-$ext"
    status_output newslog "Finished Syslog (new format) processing"
}

# Apache style web logs
str_weblog() {
    strdir=$1
    ext=$2

    status_output weblogs "Started web log processing thread"
    # ip - user [yyyy/Mon/dd:hh:mm:ss+zzzz] "whatever
    grep -aoP '[-.\w]+ - \S+ \[\d+/[A-Z][a-z][a-z]/\d+:\d+:\d+:\d+ [-+]\d+\] ".*' >"$strdir/weblogs-$ext-raw"
    outputsize=$(stat --printf '%s' "$strdir/weblogs-$ext-raw")
    [[ "$outputsize" -lt 10000000000 ]] && sort -u "$strdir/weblogs-$ext-raw" >"$strdir/weblogs-$ext"
    status_output weblogs "Finished web log processing thread"
}

# Looks for IOCs if specified, otherwise just drains the last FIFO
str_iocs() {
    strdir=$1
    ext=$2

    if [[ -r "$IocsFile" ]]; then
	status_output iocsrch "Starting IOC search thread"
	grep -aFf "$IocsFile" >"$strdir/ioc_matches-$ext"
    else
	status_output iocsrch "IOC pattern file not specified. Skipping."
	cat >/dev/null
    fi
    status_output iocsrch "Finished IOC processing thread"
}

# Run bulk_extractor with the "-e wordlist -S strings=1" to collect strings.
# Play evil games with FIFOs to (a) compress the strings on the fly, and
# (b) run post-processing jobs to gather logs and check for IOCs
#
do_strings() {
    strdir="$OutputDir/strings"
    mkdir -p "$strdir"

    # Add new string processing function names here, and all is automatic
    string_funcs=('str_auditlog' 'str_tradsyslog' 'str_newsyslog' 'str_weblog')
    
    # Make enough FIFOs for all string searches. We need one more FIFO than
    # we have "string_funcs" so that the last function can chain to the
    # (optional) IOC search.
    (cd "$FIFODir"
     mkfifo -m 600 befifo
     for ((i=1; i <= $((${#string_funcs[@]}+1)); i++)); do
	 mkfifo -m 600 "fifo$i"
     done)

    # If UAC dir, we're going to run BE on the "[root]" directory
    # If mounted directory, we're running BE on the underlying device files
    sources=(); paths=()
    uac_extra=
    if [[ -n "$UACDir" ]]; then
	sources+=("$MountedDir")
	paths+=("uacroot")
	uac_extra='-R'
    else
        # Be careful here because BTRFS subvols can appear as the same device
	declare -A seen_device
	while read -r device thispath; do
	    [[ -n "${seen_device[$device]}" ]] && continue
	    seen_device["$device"]=1
	    sources+=("$device")
	    paths+=("$thispath")
	done< <(df --output=source,target | grep -F "$MountedDir" | sort -b -k2,2)
    fi

    # Now loop over each input source
    for ((i=0; i < ${#sources[@]}; i++)); do
	thissource=${sources[$i]}
	thispath=${paths[$i]}

	if [[ -n "$UACDir" ]]; then
	    ext="$thispath"
	else
	    # /mnt/foo/files/usr/local turns into "usr_local", and
	    # /mnt/foo/files becomes "root"
	    ext=$(echo "$thispath" | sed "s,$MountedDir,,; s,^/,,; s,/,_,g")
	    [[ -z "$ext" ]] && ext='root'
	fi

	# In case something went wrong with the device detection,
	# don't reuse a bulk_extractor output dir
	status_output "bulk_ex" "Starting bulk_extractor for $thissource ($thispath)"
	bedir="$OutputDir/bulk_extractor-$ext"
	if [[ -f "$bedir/report.xml" ]]; then
	    status_output WARNING "Found \"$bedir/report.xml\"-- will not run against this directory again"
	    continue
	fi

	# Replace "wordlist.txt" in BE output dir w/ symlink to a FIFO.
	# This allows us to gzip "on the fly" the strings being collected.
	mkdir -p "$bedir"
	cp /dev/null "$bedir/be.log"
	ln -s "$FIFODir/befifo" "$bedir/wordlist.txt"
	
	# Map chain of FIFOs to string functions
	for f in "${!string_funcs[@]}"; do
	    cat "$FIFODir/fifo$(($f+1))" | tee "$FIFODir/fifo$(($f+2))" | ${string_funcs[$f]} "$strdir" "$ext" &
	    pids[$f]=$!
	done

	# Last link in the chain calls function to look for IOCs
	# (which does nothing if no IOCs specified)
	last_fifo="$FIFODir/fifo$((${#string_funcs[@]} + 1))"
	cat "$last_fifo" | str_iocs "$strdir" "$ext" &
	iocpid=$!

	# Grab data from "wordlist.txt" FIFO and feed it into gzip.
	# Output to "strings" directory.
	#
	# If bulk_extractor is running against a UAC directory,
	# each line of output starts with the full pathname of $UACDir/[root],
	# which is unhelpful. Also BE weirdly adds "\xf4\x80\x80\x9c" after
	# the file path. Remove all this faff.
	safepat=$(echo "$MountedDir" | sed 's/\([^[:alnum:]]\)/\\\1/g')
	cat "$FIFODir/befifo" | sed "s,^$safepat,,; s,\xf4\x80\x80\x9c,," | tee "$FIFODir/fifo1" | gzip > "$strdir/strings-$ext.ascii.gz" &
	gzpid=$!

	# Here goes bulk_extractor!
	bulk_extractor -o "$bedir" $uac_extra -e wordlist -S strings=1 -S word_max=4096 -S notify_rate=60 "$thissource" >>"$bedir/be.log" 2>&1

	# Process any carved wtmp data
	wtmpdir="$LogExtraDir/wtmp"
	mkdir -p "$wtmpdir"
	if [[ -d "$bedir/utmp_carved" ]]; then
	    cd "$bedir/utmp_carved"
	    for file in */*; do
		wtmpreader.pl "$file"
	    done >"$wtmpdir/from-carved-$ext" 2>/dev/null
	fi
	status_output "bulk_ex" "Finished bulk_extractor for $thissource ($thispath)"
	status_output "bulk_ex" "Waiting on processing threads for $thissource"
	# Wait for gzip finish and clean up FIFO, move output if necessary
	wait $gzpid $iocpid ${pids[@]}
	rm -f "$bedir/wordlist.txt"
	status_output "bulk_ex" "Finished all processing for $thissource"
    done
}

# After bulk_extractor runs, gather carved wtmp information along with
# any existing wtmp files and convert it to mactime format
#
make_bodyfiles() {
    # Make bodyfile from wtmp data carved by bulk_extractor and data
    # extracted in do_logs_extra()
    wtmpdir="$LogExtraDir/wtmp"
    [[ -d "$wtmpdir" ]] || return
    cd "$wtmpdir"
    found=$(wc -l from-* 2>/dev/null | tail -1 | awk '{print $1}')
    [[ -n $found && $found -gt 0 ]] || return

    sort -t\| -k8,8 from-* | uniq >merged-sort-uniq
    wtmpreader2mactime.pl merged-sort-uniq >bodyfile-wtmp

    # Make bodyfile from carved audit log data. We initially select
    # unique audit.log-*-raw files, but actually operate on the de-duped
    # file (without the -raw extension).
    find "$OutputDir/strings" -name audit.log\*-raw \! -empty |
	while read -r file; do
	    targfile=${file%%-raw}     # want to operate on de-duped file

	    grep -aE 'type=USER_(AUTH|END) msg=audit' "$targfile" |
		grep -aFv terminal=cron |
		sed 's,type=\([^[:space:]]*\) msg=audit(\([0-9]*\).* pid=\([0-9]*\).* acct="\([^"]*\)".* addr=\([^[:space:]]*\).* terminal=\([^[:space:]]*\).* res=\([^[:space:]]*\).,\1 \2 \3 \4 \5 \6 \7,; s/USER_AUTH/LOGIN/; s/USER_END/LOGOUT/' |
		grep -aFv type= |
		while read -r action epoch pid user addr terminal result; do
		    echo "0|$action $result for $user from $addr via $terminal (pid $pid)|0|----------|0|0|0|$epoch|$epoch|$epoch|$epoch"
		done >"$targfile-bodyfile"
	done

    # Make bodyfile from newstyle syslog data. We initially select
    # unique*-raw files, but actually operate on the de-duped
    # file (without the -raw extension). We also operate on any
    # XZ/BZ compressed data that got missed by bulk_extractor.
    find "$OutputDir/strings" -name syslogs-newstyle\*-raw \! -empty |
	while read -r file; do
	    targfile=${file%%-raw}     # want to operate on de-duped file

	    grep -aE ' (sshd[^:]*: ((Accepted|Failed) .* for|Invalid user) |sudo[^:]*: .* COMMAND=|(useradd|usermod|groupadd|groupmod|passwd|chsh|chfn)[^:]*: )' "$targfile" |
		sed 's/^\([^[:space:]]*\) [^:]* \([^:]*: .*\)/\1 \2/' |
		while read -r timestamp message; do
		    epoch=$(date -d "$timestamp" '+%s')
		    message=${message//|/(pipe)}
		    echo "0|$message|0|----------|0|0|0|$epoch|$epoch|$epoch|$epoch"
		done >"$targfile-bodyfile"
	done

    find "$LogExtraDir/compressed" -name \*-newstyle-securelogs \! -empty |
	while read -r file; do
	    sed 's/^\([^[:space:]]*\) [^:]* \([^:]*: .*\)/\1 \2/' "$file" |
		while read -r timestamp message; do
		    epoch=$(date -d "$timestamp" '+%s')
		    message=${message//|/(pipe)}
		    echo "0|$message|0|----------|0|0|0|$epoch|$epoch|$epoch|$epoch"
		done >>"$LogExtraDir/compressed/bodyfile-compressed-securelogs"
	done

    # Use jq to make mactime output from interesting security messages
    [[ -r "$LogExtraDir/journal/journal.json" ]] &&
	cat "$LogExtraDir/journal/journal.json" |
	    jq -r 'select(._COMM != null and
                            ((._COMM == "sshd" and (.MESSAGE | test("^((Accepted|Failed) .* for|Invalid user) "))) or
                             (._COMM == "sudo" and (.MESSAGE | test("COMMAND="))) or
			     (._COMM | test("useradd|usermod|groupadd|groupmod|passwd|chsh|chfn")))) |
"0|\(._COMM)[\(._PID)]: \(.MESSAGE | sub("\\|";"(pipe)";"g"))|0|----------|0|0|0|\(._SOURCE_REALTIME_TIMESTAMP | .[:-6])|\(._SOURCE_REALTIME_TIMESTAMP | .[:-6])|\(._SOURCE_REALTIME_TIMESTAMP | .[:-6])|\(._SOURCE_REALTIME_TIMESTAMP | .[:-6])"' >"$LogExtraDir/journal/bodyfile-securelogs-journal" 2>"$LogExtraDir/journal/bodyfile-securelogs-journal-errors"
}

# Look for *.xz, *.bz2? logs because bulk_extractor doesn't uncompress them.
# Run IOCs if provided.
do_compressed_logs() {
    found=$(find "$MountedDir/var/log/" \( -name \*.\[bx\]z -o -name \*.bz2 \) | head -1)
    [[ -z "$found" ]] && return

    complogdir="$LogExtraDir/compressed"
    status_output ziplogs "Compressed log files detected. Copying to '$complogdir'."
    mkdir -p "$complogdir"
    find "$MountedDir/var/log/" \( -name \*.\[bx\]z -o -name \*.bz2 \) 2>/dev/null |
	while read -r file; do
	    # transform file names to var_log_<logfile>
	    targfile=${file#"$MountedDir/"}
	    targfile=${targfile//\//_}
	    cp "$file" "$complogdir/$targfile"
	done

    [[ -n "$IocsFile" ]] && mkdir -p "$LogExtraDir/iocs"
    for file in "$complogdir"/*; do
	basefile=${file##*/}               # like basename
	thisext=${file##*.}                # only final extension
	thisext=${thisext%2}               # "bz2" becomes "bz"

	${thisext}cat "$file" | grep -aE '^[0-9]*-[0-9]*-[0-9]*T[0-9]*:[0-9]*:[0-9]*\.[0-9]*.* (sshd[^:]*: ((Accepted|Failed) .* for|Invalid user) |sudo[^:]*: .* COMMAND=|(useradd|usermod|groupadd|groupmod|passwd|chsh|chfn)[^:]*: )' >"$file-newstyle-securelogs"
	[[ -n "$IocsFile" ]] && ${thisext}cat "$file" | grep -aFf "$IocsFile" >"$LogExtraDir/iocs/$basefile-iochits"
    done
    find "$complogdir" -name \*-securelogs -empty -delete
    status_output ziplogs "Finished compressed log file processing"
}

do_logs_extra() {
    status_output "logxtra" "Starting extra log processing"
    # Look for BZ/XZ compressed logs since bulk_extractor doesn't get them
    do_compressed_logs &
    thispid=$!
    echo $thispid >>"$PIDFile"

    # Pull data from existing wtmp files
    wtmpdir="$LogExtraDir/wtmp"
    mkdir -p "$wtmpdir"
    if [[ -d "$MountedDir/var/log" ]]; then
	cd "$MountedDir/var/log"
	for file in wtmp*; do
	    if [[ "$file" =~ \.([bgx]z|bz2)$ ]]; then
		pref=${file##*.}           # pulls off file extension
		base=${file%."$thisext"}   # filename without extension
		case $pref in
		    gz) pref='z'
			;;
		    bz2) pref='bz'
			 ;;
		esac
		${pref}cat "$file" > "$wtmpdir/$base"
		srcfile="$wtmpdir/$base"
	    else
		srcfile=$file
	    fi
	    wtmpreader.pl "$srcfile" >"$wtmpdir/from-$file" 2>/dev/null
	done
    fi

    # Dump systemd journal to text file and do IoC search if applicable
    if [[ -d "$MountedDir/var/log/journal" ]]; then
	mkdir -p "$LogExtraDir/journal"
	journalctl -D "$MountedDir/var/log/journal" -q -o short-iso --utc >"$LogExtraDir/journal/journal.txt"
	if [[ -r "$IocsFile" ]]; then
	    grep -aFf "$IocsFile" "$LogExtraDir/journal/journal.txt" >"$LogExtraDir/iocs/journal-iochits"
	fi

	# Also make JSON output from systemd journal, used in make_bodyfiles()
	journalctl -D "$MountedDir/var/log/journal" -q -o json --utc >"$LogExtraDir/journal/journal.json"
    fi
    
    status_output "logxtra" "Finished extra log processing"
}

do_misc_tasks() {
    status_output miscjob "Starting miscellaneous tasks"

    # Make directory to hold output
    miscdir="$OutputDir/misc"
    mkdir -p "$miscdir"

    # Look for archive files using the file command, not file extensions.
    # In the case of UAC, however, also search for file extensions in
    # the bodyfile (if present) since we don't have a full file system
    # to work from.
    status_output miscjob "Searching for archive files in mounted image"
    find "$MountedDir" -type f | tee "$miscdir/.allfiles" |
	parallel -j 8 --xargs -m file {} | grep -aF 'archive data' |
	sed "s,$MountedDir,," | sort >"$miscdir/archive-files"
    [[ -n "$UACDir" && -r "$UACDir/bodyfile/bodyfile.txt" ]] &&
	awk -F\| 'BEGIN {IGNORECASE=1}; $2 ~ /\.(zip|7z|rar|tgz|tar.gz)$/ {print $2}' "$UACDir/bodyfile/bodyfile.txt" >"$miscdir/archive-files-frombodyfile"
    status_output miscjob "List of archive files written to $miscdir/archive-files"

    # Look for hidden directories, even in homedirs because we want to find
    # .git dirs to locate build environments
    status_output miscjob "Making a list of hidden directories (name starts with '.')"
    if [[ -n "$UACDir" ]]; then
	[[ -r "$UACDir/bodyfile/bodyfile.txt" ]] &&
	    awk -F\| '$4 ~ /^d/ && $2 ~ /\/\.[^/]*$/ {print $2}' "$UACDir/bodyfile/bodyfile.txt" >"$miscdir/dot-directories"
    else
	find "$MountedDir" -type d -name .\* | sed "s,$MountedDir,," >"$miscdir/dot-directories"
    fi
    status_output miscjob "Hidden directory names written to $miscdir/dot-directories"

    # Collect all the different task scheduling configs into a directory
    # TO-DO: create an allow list for "known goods"
    status_output miscjob "Collecting scheduled tasks"
    mkdir -p "$OutputDir/scheduled-tasks"
    cd "$MountedDir"
    find etc/cron* var/cron* var/spool/cron* -type f \! -name .placeholder 2>/dev/null | cpio -pd "$OutputDir/scheduled-tasks" 2>/dev/null
    find usr/lib/systemd/system etc/systemd/system home/*/.config/systemd run -name \*.timer -type f 2>/dev/null |
	while read -r file; do
	    svcfile="${file%%.timer}.service"
	    echo "$file"
	    [[ -r "$svcfile" ]] && echo "$svcfile"
	done |
	cpio -pd "$OutputDir/scheduled-tasks" 2>/dev/null

    # clean this up-- $OutputDir/timeline-mactime/bodyfile-$HostName is
    # a better source for this info
    rm -f "$miscdir/.allfiles"
    
    status_output miscjob "Finished miscellaneous tasks"
}

VolSafeModules=(
bash.Bash
boottime.Boottime
capabilities.Capabilities
ebpf.EBPF
elfs.Elfs
envars.Envars
graphics.fbdev.Fbdev
iomem.IOMem
ip.Addr
ip.Link
kallsyms.Kallsyms
kmsg.Kmsg
kthreads.Kthreads
library_list.LibraryList
lsmod.Lsmod
lsof.Lsof
malware.check_afinfo.Check_afinfo
malware.check_creds.Check_creds
malware.check_idt.Check_idt
malware.check_modules.Check_modules
malware.check_syscall.Check_syscall
malware.hidden_modules.Hidden_modules
malware.keyboard_notifiers.Keyboard_notifiers
malware.malfind.Malfind
malware.modxview.Modxview
malware.netfilter.Netfilter
malware.tty_check.Tty_Check
mountinfo.MountInfo
pidhashtable.PIDHashTable
proc.Maps
psaux.PsAux
pslist.PsList
psscan.PsScan
pstree.PsTree
ptrace.Ptrace
tracing.ftrace.CheckFtrace
tracing.perf_events.PerfEvents
tracing.tracepoints.CheckTracepoints
vmcoreinfo.VMCoreInfo
)

VolBewareModules=(
pagecache.Files
pagecache.RecoverFs
pscallstack.PsCallStack
sockstat.Sockstat
)

do_volatility_plugins() {
    status_output "memory " "Using volatility on memory image"
    
    voloutputdir="$OutputDir/memory/volatility"
    mkdir -p "$voloutputdir"

    dvp_counter=0
    dvp_output='/dev/null'

    for module in "${VolSafeModules[@]}"; do
	mod_class=${module%%.*}

        echo "from volatility3.plugins.linux import $mod_class"
        echo "treegrid = gt($module, kernel = self.config['kernel'])"
        echo "treegrid.populate()"
        echo "from volatility3.cli import text_renderer"
        echo "rt(treegrid,text_renderer.JsonLinesRenderer())"
    done |
    volshell -f "$MemoryDumpFile" -o "$voloutputdir" -l -q 2>&1 |
    while read -r line; do
	if [[ "$line" =~ '(layer_name) >>>' ]]; then
	    if [[ "$line" =~ (\(layer_name\) >>> ){3} ]]; then
		dvp_output="$voloutputdir/${VolSafeModules[$((dvp_counter++))]}.json"
		line=$(echo "$line" | sed 's,(layer_name) >>> *,,g')
	    else
		dvp_output='/dev/null'
	    fi
	fi
	echo "$line" >>"$dvp_output"
    done

    status_output "memory " "Running potentially slow volatility modules"
    for module in "${VolBewareModules[@]}"; do
	timeout 20m vol -q -r jsonl -f "$MemoryDumpFile" -o "$voloutputdir" "linux.$module" >"$voloutputdir/$module.json" 2>"$voloutputdir/$module.json-errors"
    done

    if [[ -r "$IocsFile" ]]; then
	status_output "memory " "Checking IOCs against volatility output"
	cd "$voloutputdir"
	grep -raFf "$IocsFile" * >.grep$$ 2>.grep$$-errs
	mv .grep$$ IOC-output.txt
	mv .grep$$-errs IOC-errors.txt
    fi

    status_output "memory " "Finished volatility on memory image"
}

do_be_on_memory() {
    status_output "memory " "Running bulk_extractor on memory image"
    mem_bedir="$OutputDir/memory/bulk_extractor"
    mkdir -p "$mem_bedir"

    bulk_extractor -o "$mem_bedir" -e wordlist -S strings=1 -S word_max=4096 -S notify_rate=60 "$MemoryDumpFile" >>"$mem_bedir/be.log" 2>&1

    
    if [[ -r "$IocsFile" ]]; then
	status_output "memory " "Checking IOCs against bulk_extractor memory data"
	cd "$mem_bedir"
	grep -raFf "$IocsFile" * >.grep$$ 2>.grep$$-errs
	mv .grep$$ IOC-output.txt
	mv .grep$$-errs IOC-errors.txt
    fi

    status_output "memory " "Finished bulk_extractor on memory image"
}

do_memory() {
    status_output "memory " "Starting memory analysis jobs on $MemoryDumpFile"

    if [[ $RunVolatility -gt 0 ]]; then
	do_volatility_plugins &
	dm_vol_pid=$!
    fi

    do_be_on_memory &
    dm_be_pid=$!

    wait -f $dm_vol_pid $dm_be_pid

    status_output "memory " "Finished memory analysis jobs"
}

##### MAIN PROGRAM STARTS HERE ###############################################

IocsFile=
HostName=
NoL2tRun=0
MemoryDumpFile=
WorkingDir=
CheckDepsOnly=0
while getopts "CH:i:LM:W:" opts; do
    case $opts in
	C) CheckDepsOnly=1
	   ;;
	H) HostName=$OPTARG
	   ;;
        i) IocsFile=$OPTARG
           ;;
	L) NoL2tRun=1
	   ;;
	M) MemoryDumpFile=$OPTARG
	   ;;
	W) WorkingDir=$OPTARG
	   ;;
        *) usage
           ;;
    esac
done

shift $(($OPTIND-1))
MountedDir="$1"
OutputDir="$2"

# Sanity check for directory arguments. Sets $UACDir if appropriate.
UACDir=
if [[ $CheckDepsOnly -eq 0 ]]; then
    check_directories
fi

# Do we have everything we need to run? Exits program if not.
RunVolatility=0
check_dependencies

if [[ ! -d "$OutputDir" ]]; then       # Can create this, but warn user
    status_output INFO::: "Making \"$OutputDir\""
    mkdir -p "$OutputDir"
fi

if [[ -n "$WorkingDir" && ! -d "$WorkingDir" ]]; then
    status_output INFO::: "Making \"$WorkingDir\""
    mkdir -p "$WorkingDir"
    WorkingDir=$(cd "$WorkingDir"; /bin/pwd)
fi

# Need full paths for docker invocations, et al
MountedDir=$(cd "$MountedDir"; /bin/pwd)
OutputDir=$(cd "$OutputDir"; /bin/pwd)
if [[ -n "$UACDir" ]]; then
    UACDir=$(cd "$UACDir"; /bin/pwd)
fi

# Collecting log information here
LogExtraDir="$OutputDir/logs-extra"


# If $OutputDir is not a Linux file system, we need to put FIFOs
# in some other location
[[ -n "$WorkingDir" ]] && FIFODir="$WorkingDir/fifos" || FIFODir="$OutputDir/fifos"
mkdir -p "$FIFODir"

# $HostName is used to name files in the output. Make best effort.
[[ -z "$HostName" ]] && HostName=$(cat "$MountedDir/etc/hostname" 2>/dev/null)

# $PIDFile stores PIDs for extra processing jobs
PIDFile="$OutputDir/.pids"

status_output primary "Starting processing-- go relax with a beverage..."

do_fs_timeline &
FSTimePID=$!

if [[ $NoL2tRun -eq 0 ]]; then
    do_l2t_firstpass &
    L2TTimePID=$!
fi

if [[ -n "$MemoryDumpFile" ]]; then
    do_memory &
    MemoryPID=$!
fi

do_strings &
StringsPID=$!

do_logs_extra &
LogsPID=$!

do_misc_tasks &
MiscPID=$!

# When the bulk_extractor runs are done and do_logs_extra() has sorted
# the wtmp and journal data, make_bodyfiles() creates mactime bodyfiles
# from wtmp, audit.log, and journal data.
wait -f $LogsPID $StringsPID
make_bodyfiles

# After make_bodyfiles() and the mactime and initial l2t jobs have run,
# merge the bodyfiles into the l2t data store and make l2t JSON output
wait -f $FSTimePID $L2TTimePID

collect_bodyfiles
if [[ $NoL2tRun -eq 0 ]]; then
    do_l2t_merge
fi

# Anything still running?
status_output primary "Waiting for all remaining tasks to finish."
wait -f $MemoryPID $MiscPID

# Can't use "wait" because these processes were subprocesses of
# backgrounded tasks
pidmatch=$(cat "$PIDFile" | tr \\n \| | sed 's,|$,,')
while true; do
    foundpid=$(ps -ef | awk "\$2 ~ /^$pidmatch\$/ {print \$2}")
    [[ -z "$foundpid" ]] && break
    sleep 30
done
rm -f "$PIDFile"

# Clean up any FIFOs
(cd "$FIFODir" && rm -f ./*fifo*)
rmdir "$FIFODir" 2>/dev/null

status_output primary "All processing finished!"
