#!/bin/bash
# ptt.sh ("Process That Thing!") -- Hal Pomeranz (hrpomeranz@gmail.com)
# Version: 3.0.0 - 2025-09-08
#
# Usage: ptt.sh [options] mountpoint outputdir
#
# Created to post-process mounted Linux images and UAC collections.
# Currently performs the following tasks:
#
#    -- Builds file system (mactime) timeline
#    -- Builds log2timeline timeline with JSON output
#    -- Runs bulk_extractor against each mounted partition
#    -- Uses strings from bulk_extractor to extract audit.logs,
#          both classic and new-style Syslog logs, and Apache style web logs
#          (will include carved logs and gzip-ed logs thanks to bulk_extractor)
#    -- Creates bodyfile output from wtmp records carved by bulk_extractor
#    -- Makes a list of archive files found in the image
#    -- Makes a list of hidden directories (name starts with ".") in the image
#    -- Optionally will grep for supplied IOCs with "-i iocfile"
#          (fixed string search, NOT regex)
#

usage() {
    cat <<EOM
Post-processing for mounted images

Usage: $0 [-H hostname] [-W workdir] [-i iocs] [-L] mountpoint outputdir

    -i iocs      Path to file containing IOC strings (optional)
    -H hostname  Hostname used in output files (default: mounted /etc/hostname)
    -L           Do not run log2timline
    -W workdir   Local dir in case output dir is non-Linux file system
EOM
    exit 1;
}

declare -A TextColor
TextColor=('WARNING' '\e[0;41m\e[1;37m'      # White text on RED background
           'primary' '\e[0;40m\e[1;37m'      # White text on BLACK background
	   'mactime' '\e[0;42m\e[1;37m'      # White text on GREEN background
	   'lg2time' '\e[0;45m\e[1;37m'      # White text on PURPLE background
	   'bulk_ex' '\e[0;44m\e[1;37m'      # White text on BLUE background
	   'uacstrs' '\e[0;44m\e[1;37m'      # White text on BLUE background
	   'miscjob' '\e[1;43m\e[1;37m'      # White text on YELLOW background
	   'ziplogs' '\e[1;43m\e[1;37m'      # White text on YELLOW background
	   'xz-logs' '\e[1;43m\e[1;37m')     # White text on YELLOW background
DefaultColor='\e[0;46m\e[1;37m'              # White text on CYAN background

status_output() {
    tag=$1
    msg=$2

    tclr=${TextColor[$tag]}
    [[ -z "$tclr" ]] && tclr=$DefaultColor

    echo -e $(date '+%F %T') ${tclr} $tag '\e[0m' $msg
}

check_dependencies() {
    dep_missing=0

    if [[ ! (-d "$MountedDir/etc" && -d "$MountedDir/var/log") ]]; then
	if [[ -d "$MountedDir/files/etc" && -d "$MountedDir/files/var/log" ]]; then
	    MountedDir="$MountedDir/files"
	    status_output "INFO:::" "Changed target directory to \"$MountedDir\""
	elif [[ -f "$MountedDir/uac.log" ]]; then
	    status_output "INFO:::" "Looks like a UAC collection"
	    UACDir="$MountedDir"
	    MountedDir="$UACDir/[root]"
	else
	    status_output "INFO:::" "\"$MountedDir\" does not look like a mounted file system or UAC collection"
	    status_output "INFO:::" "Proceeding anyway-- here's hoping this is what was intended"
	fi
    fi
    
    if [[ -n "$IocsFile" && ! -r "$IocsFile" ]]; then
	dep_missing=1
	status_output WARNING "IOC file \"$IocsFile\" not found"
    fi

    for prog in ausorter.pl bulk_extractor mactime statx parallel wtmpreader.pl wtmpreader2mactime.pl zip; do
	result=$(type $prog 2>/dev/null)
	[[ -n "$result" ]] && continue
	dep_missing=1
	status_output WARNING "$prog program not found"
    done

    if [[ $NoL2tRun -eq 0 ]]; then
	docker_out=$(docker manifest inspect log2timeline/plaso 2>/dev/null)
	if [[ -z "$docker_out" ]]; then
	    dep_missing=1
	    status_output WARNING "Cannot find \"log2timeline/plaso\" docker container"
	fi
    fi

    [[ $dep_missing -gt 0 ]] && exit 1
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
    
    mactime -d -y -b "$mydir/bodyfile$hostext" 2012-01-01 >"$mydir/timeline$hostext.csv"
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

do_l2t_merge() {
    mydir="$OutputDir/timeline-l2t"
    status_output lg2time "Starting second phase of log2timeline processing..."

    # To make things easier, link the two bodyfiles we want to merge
    # into a subdir of this directory
    mkdir "$mydir/bodies"
    ln "$OutputDir"/timeline-mactime/bodyfile* "$mydir/bodies"
    ln "$OutputDir/wtmp/bodyfile-wtmp" "$mydir/bodies"

    # Then merge the body files into the log2timeline data
    status_output lg2time "Merge file system and wtmp data"
    cp /dev/null "$mydir/l2t.log.2"
    docker run -v "$mydir:$mydir" log2timeline/plaso log2timeline.py \
	   --parsers bodyfile --hashers none -z UTC --storage_file "$mydir/image.plaso" \
	   --status_view linear --status_view_interval 60 "$mydir/bodies" >"$mydir/l2t.log.2" 2>&1

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
    rm -f "$mydir/$bfname-l2t.jsonl" "$mydir"/bodies/*
    rmdir "$mydir/bodies"
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
	sort -u $file
    done | tee "$strdir/audit.log-$ext-timestamps" | sed 's/[^t]*//' >"$strdir/audit.log-$ext"
    rm -f *
    rmdir "$workdir" 2>/dev/null
    status_output '+extra+' "($ext) Finished additional audit.log processing"
}

# audit.log entries
str_auditlog() {
    strdir=$1
    ext=$2

    status_output auditlg "Starting audit.log processing thread"
    grep -P '^\S+\s+type=\S+ msg=audit\(\d+\.\d+:\d+\): ' | sed 's/^[^[:space:]]*[[:space:]]*//' >"$strdir/audit.log-$ext-raw"
    status_output auditlg "Finished audit.log processing"
    [[ -s "$strdir/audit.log-$ext-raw" ]] || return
    extra_auditlog "$strdir" $ext &
    echo $! >>"$PIDFile"
}

# Traditional Syslog logs
str_tradsyslog() {
    strdir=$1
    ext=$2

    status_output oldslog "Started Syslog (traditional format) processing thread"
    grep -P '^\S+\s+[A-Z][a-z]{2}\s+\d+\s+\d+:\d+:\d+\s' | sed 's/^[^[:space:]]*[[:space:]]*//' >"$strdir/syslogs-traditional-$ext-raw"
    status_output oldslog "Finished Syslog (traditional format) processing"
}

# New Syslog timestamp format
str_newsyslog() {
    strdir=$1
    ext=$2

    status_output newslog "Started Syslog (new format) processing thread"
    grep -P '^\S+\s+\d+-\d+-\d+T\d+:\d+:\d+\.\d+[+-]\d+:\d+ ' | sed 's/^[^[:space:]]*[[:space:]]*//' >"$strdir/syslogs-newstyle-$ext-raw"
    outputsize=$(stat --printf '%s' "$strdir/syslogs-newstyle-$ext-raw")
    [[ $outputize -lt 10000000000 ]] && sort -u "$strdir/syslogs-newstyle-$ext-raw" >"$strdir/syslogs-newstyle-$ext"
    status_output newslog "Finished Syslog (new format) processing"
}

# Apache style web logs
str_weblog() {
    strdir=$1
    ext=$2

    status_output weblogs "Started web log processing thread"
    grep -P '^\S+\s+[-.\w]+ - \S+ \[\d+/[A-Z][a-z][a-z]/\d+:\d+:\d+:\d+ [-+]\d+\] "' | sed 's/^[^[:space:]]*[[:space:]]*//' >"$strdir/weblogs-$ext-raw"
    outputsize=$(stat --printf '%s' "$strdir/weblogs-$ext-raw")
    [[ $outputize -lt 10000000000 ]] && sort -u "$strdir/weblogs-$ext-raw" >"$strdir/weblogs-$ext"
    status_output weblogs "Finished web log processing thread"
}

# Looks for IOCs if specified, otherwise just drains the last FIFO
str_iocs() {
    strdir=$1
    ext=$2

    if [[ -r "$IocsFile" ]]; then
	status_output iocsrch "Starting IOC search thread"
	grep -Ff "$IocsFile" >"$strdir/ioc_matches-$ext"
    else
	status_output iocsrch "IOC pattern file not specified. Skipping."
	cat >/dev/null
    fi
    status_output iocsrch "Finished IOC processing thread"
}

# After bulk_extractor runs, gather carved wtmp information along with
# any existing wtmp files and convert it to mactime format
#
extra_wtmp_processing() {
    wtmpdir="$OutputDir/wtmp"
    [[ -d "$wtmpdir" ]] || return
    cd "$wtmpdir"
    found=$(wc -l from-* 2>/dev/null | tail -1 | awk '{print $1}')
    [[ -n $found && $found -gt 0 ]] || return

    sort -t\| -k8,8 from-* | uniq >merged-sort-uniq
    wtmpreader2mactime.pl merged-sort-uniq >bodyfile-wtmp
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
    (cd "$FIFODir"; mkfifo -m 600 befifo; for ((i=1; i <= $((${#string_funcs[@]}+1)); i++)); do mkfifo -m 600 "fifo$i"; done)

    # If UAC dir, we're reading from collected strings files.
    # If mounted directory, we're reading devices files with bulk_extractor.
    sources=(); paths=()
    if [[ -n "$UACDir" ]]; then
	for file in "$UACDir"/strings/*.gz; do
	    sources+=("$file")
	    ext=$(basename $file | sed 's/^(iocs|strings)-//; s/\.gz$//')
	    paths+=("$ext")
	done
    else
        # Be careful here because BTRFS subvols can appear as the same device
	declare -A seen_device
	while read device thispath; do
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
	    statstr='uacstrs'
	    status_output $statstr "Starting string processing for $thissource"
	else
	    # /mnt/foo/files/usr/local turns into "usr_local", and
	    # /mnt/foo/files becomes "root"
	    ext=$(echo $thispath | sed "s,$MountedDir,,; s,^/,,; s,/,_,g")
	    [[ -z "$ext" ]] && ext='root'
	    bedir="$OutputDir/bulk_extractor-$ext"
	    statstr='bulk_ex'

	    # In case something went wrong with the device detection,
	    # don't reuse a bulk_extractor output dir
	    status_output $statstr "Starting bulk_extractor for $thissource ($thispath)"
	    if [[ -f "$bedir/report.xml" ]]; then
		status_output WARNING "Found \"$bedir/report.xml\"-- will not run against this directory again"
		continue
	    fi

	    # Replace "wordlist.txt" in BE output dir w/ symlink to a FIFO.
	    # This allows us to gzip "on the fly" the strings being collected.
	    mkdir -p "$bedir"
	    cp /dev/null "$bedir/be.log"
	    ln -s "$FIFODir/befifo" "$bedir/wordlist.txt"
	fi
	
	# Map chain of FIFOs to string functions
	for f in ${!string_funcs[@]}; do
	    cat "$FIFODir/fifo$(($f+1))" | tee "$FIFODir/fifo$(($f+2))" | ${string_funcs[$f]} "$strdir" $ext &
	    pids[$f]=$!
	done

	# Last link in the chain calls function to look for IOCs
	# (which does nothing if no IOCs specified)
	last_fifo="$FIFODir/fifo$((${#string_funcs[@]} + 1))"
	cat $last_fifo | str_iocs "$strdir" $ext &
	iocpid=$!

	gzpid=                   # only used in bulk_extractor processing
	if [[ -n "$UACDir" ]]; then
	    zcat "$thissource" >"$FIFODir/fifo1"
	    status_output $statstr "Finished uncompressing $thissource"
	else
	    # Grab data from "wordlist.txt" FIFO and feed it into gzip.
	    # Output to "strings" directory.
	    cat "$FIFODir/befifo" | tee "$FIFODir/fifo1" | gzip > "$strdir/strings-$ext.ascii.gz" &
	    gzpid=$!

	    # Here goes bulk_extractor!
	    bulk_extractor -o "$bedir" -e wordlist -S strings=1 -S word_max=4096 -S notify_rate=60 $thissource >>"$bedir/be.log" 2>&1

	    # Process any carved wtmp data
	    wtmpdir="$OutputDir/wtmp"
	    mkdir -p "$wtmpdir"
	    if [[ -d "$bedir/utmp_carved" ]]; then
		cd "$bedir/utmp_carved"
		for file in */*; do
		    wtmpreader.pl $file
		done >"$wtmpdir/from-carved-$ext" 2>/dev/null
	    fi
	    status_output $statstr "Finished bulk_extractor for $thissource ($thispath)"
	fi
	    
	status_output $statstr "Waiting on processing threads for $thissource"
	# Wait for gzip finish and clean up FIFO, move output if necessary
	wait $gzpid $iocpid ${pids[@]}
	rm -f "$bedir/wordlist.txt"
	status_output $statstr "Finished all processing for $thissource"
    done
}

# bulk_extractor doesn't handle XZ compression. So we collect XZ logs here
# and run an IOC scan against them if IOCs are provided.
#
do_xz_logs_for_be() {
    xzfound=$(find "$MountedDir/var/log/" -name \*.xz 2>/dev/null | head -1)
    [[ -z "$xzfound" ]] && return

    xzdir="$OutputDir/XZ-logs"
    status_output xz-logs "XZ compressed log files detected. Copying to '$xzdir'."
    mkdir -p "$xzdir"
    find "$MountedDir/var/log/" -name \*.xz -print0 2>/dev/null | xargs -0 cp -p -t "$xzdir"
    if [[ -n "$IocsFile" ]]; then
	# Run grep before strings to get the file name at the front of each
	# matching line. Sadly xzgrep doesn't understand "-F" but there is
	# an xzfgrep option-- go figure.
	status_output xz-logs "Starting IOC search against XZ compressed logs"
	(cd "$xzdir"; xzgrep -af "$IocsFile" *.xz | strings -a >IOC-MATCHES)
    fi
    status_output xz-logs "Finished processing XZ logs"
}

# Look for *.gz, *.xz, *.bz2? logs in UAC collection and run IOCs if provided
do_compressed_logs_for_uac() {
    [[ -z "$IocsFile" ]] && return
    found=$(find "$MountedDir/var/log/" -name \*.\[bgx\]z -o -name \*.bz2 | head -1)
    [[ -z "$found" ]] && return

    status_output ziplogs "Searching for IOCs in compressed log files"
    complogdir="$OutputDir/Compressed-Log-Searches"
    mkdir -p "$complogdir"
    find "$MountedDir/var/log/" -name \*.\[bgx\]z -o -name \*.bz2 |
	while read file; do
	    basefile=$(echo $file | sed "s,$UACDir/\[root\]/,,; s,/,_,g")
	    thisext=$(echo $file | sed 's,.*\.\([^.]*\),\1,')
	    case $thisext in
		gz) thisext='z'
		    ;;
		bz2) thisext='bz'
		     ;;
	    esac
	    ${thisext}cat "$file" | grep -aFf "$IocsFile" >"$complogdir/ioc_matches-$basefile"
	done
    status_output ziplogs "Finished compressed log file processing"
}

do_misc_tasks() {
    status_output miscjob "Starting miscellaneous tasks"

    thispid=
    if [[ -n "$UACDir" ]]; then
	do_compressed_logs_for_uac &
	thispid=$!
    else
	# Look for XZ compressed logs since bulk_extractor doesn't get them
	do_xz_logs_for_be &
	thispid=$!
    fi
    echo $thispid >>"$PIDFile"

    # Pull data from existing wtmp files
    wtmpdir="$OutputDir/wtmp"
    mkdir -p "$wtmpdir"
    if [[ -d "$MountedDir/var/log" ]]; then
	cd "$MountedDir/var/log"
	for file in wtmp*; do
	    if [[ "$file" =~ \.([bgx]z|bz2)$ ]]; then
		pref=$(echo $file | sed 's/.*\.//')
		base=$(basename "$file" .$pref)
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

    # Make directory to hold output
    miscdir="$OutputDir/Misc"
    mkdir -p "$miscdir"

    # Look for archive files using the file command, not file extensions
    status_output miscjob "Searching for archive files in mounted image"
    find "$MountedDir" -type f | tee "$miscdir/.allfiles" |
	parallel -j 8 --xargs -m file {} | grep -F 'archive data' |
	sed "s,$MountedDir,," | sort >"$miscdir/archive-files"
    status_output miscjob "List of archive files written to $miscdir/archive-files"

    # Look for hidden directories, even in homedirs because we want to find
    # .git dirs to locate build environments
    status_output miscjob "Making a list of hidden directories (name starts with '.')"
    if [[ -n "$UACDir" ]]; then
	awk -F\| '$4 ~ /^d/ && $2 ~ /\/\.[^/]*$/ {print $2}' "$UACDir/bodyfile/bodyfile.txt" >"$miscdir/dot-directories"
    else
	find "$MountedDir" -type d -name .\* | sed "s,$MountedDir,," >"$miscdir/dot-directories"
    fi
    status_output miscjob "Hidden directory names written to $miscdir/dot-directories"

    # clean this up-- $OutputDir/timeline-mactime/bodyfile-$HostName is
    # a better source for this info
    rm -f "$miscdir/.allfiles"
    
    status_output miscjob "Finished miscellaneous tasks"
}

##### MAIN PROGRAM STARTS HERE #################################################

IocsFile=
HostName=
NoL2tRun=0
WorkingDir=
while getopts "H:i:LW:" opts; do
    case $opts in
	H) HostName=$OPTARG
	   ;;
        i) IocsFile=$OPTARG
           ;;
	L) NoL2tRun=1
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
UACDir=               # will be set in check_dependencies() if appropriate

if [[ ! -d "$MountedDir" ]]; then      # Can't proceed without target directory
    echo \'$MountedDir\' does not exist\!
    usage
fi

# Do we have everything we need to run? Exits program if not.
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

# Need full paths for docker invocations
MountedDir=$(cd "$MountedDir"; /bin/pwd)
OutputDir=$(cd "$OutputDir"; /bin/pwd)

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

do_strings &
StringsPID=$!

do_misc_tasks &
MiscPID=$!

# When the bulk_extractor runs are done, we can turn the wtmp data
# into a mactime bodyfile
wait -f $StringsPID
extra_wtmp_processing

# When the wtmp bodyfile is made above and the mactime and initial l2t
# jobs have run, merge the bodyfiles into the l2t data store and make JSON
wait -f $FSTimePID $L2TTimePID

if [[ $NoL2tRun -eq 0 ]]; then
    do_l2t_merge
fi

# Anything still running?
status_output primary "Waiting for all remaining tasks to finish."
wait -f $MiscPID

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
(cd "$FIFODir"; rm -f *fifo*)
rmdir "$FIFODir" 2>/dev/null

status_output primary "All processing finished!"
