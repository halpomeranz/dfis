#!/bin/bash
# uac-prepper.sh -- Hal Pomeranz (hpomeranz@crai.com)
# Version: 1.0.0 - 2025-12-15
#
# Extracts UAC collection(s) from an S3 URL, Velociraptor ZIP collection,
# or standard UAC *.tar.gz file.
#
# Performs additional prep work on extracted data.

usage() {
    cat <<EOM 
Download, extract, and prep UAC images for analysis

Usage: $0 [-d outputdir] [-t tmpdir] target ...

Targets may be a S3 URL, a Velociraptor collection ZIP, a UAC tarball,
or an already unpacked UAC directory.

Multiple targets may be specified, and S3 URLs may be directories or just
individual files.
EOM
    exit 1;
}

argument_postprocessing() {
    [[ -d "$OutputDir" ]] || mkdir -p "$OutputDir"
    OutputDir=$(cd "$OutputDir"; /bin/pwd)

    if [[ -n "$TempDir" ]]; then
	[[ -d "$TempDir" ]] || mkdir -p "$TempDir"
	TempDir=$(cd "$TempDir"; /bin/pwd)
    else
	TempDir="$OutputDir"
    fi
    TempDir="$TempDir/.uacpreptmp$$"
    mkdir -p "$TempDir"
}

do_uac_prep() {
    uacdir=$1

    echo Done!
}

do_uactgz() {
    tgztarg=$1

    # Greedy matching will mess up file names like uac-testuac-linux-...
    hostname=$(echo $tgztarg | sed 's,.*uac-\(.*\)-linux-[0-9]*.tar.gz,\1,')
    
    [[ "$tgztarg" =~ ^/ ]] || ziptarg=$(/bin/pwd)"/$tgztarg"

    echo -n "Unpack UAC data for $hostname... "
    mkdir -p "$TempDir/$hostname"
    cd "$TempDir/$hostname"
    tar zxf "$tgztarg"

    if [[ ! -f uac.log ]]; then
	echo This does not look like a UAC collection
	return
    fi

    if [[ -d "$OutputDir/$hostname" ]]; then
	echo "$OutputDir/$hostname already exists, skipping"
	return
    fi
    mv "$TempDir/$hostname" "$OutputDir/$hostname"

    do_uac_prep "$OutputDir/$hostname"
}

do_vrzip() {
    ziptarg=$1

    [[ "$ziptarg" =~ ^/ ]] || ziptarg=$(/bin/pwd)"/$ziptarg"

    filename=$(basename "$ziptarg")
    newdir=$(echo $filename | sed 's/\.[Zz][Ii][Pp]//')
    if [[ -d "$TempDir/$newdir" ]]; then
        echo "$TempDir/$newdir already exists, skipping"
        return
    fi
    
    echo -n "Unzip $filename..."
    mkdir -p "$TempDir/$newdir"
    cd "$TempDir/$newdir"
    unzip -qq "$ziptarg"

    tarfile=$(ls uploads/file/*.tar.gz 2>/dev/null)
    if [[ -z "$tarfile" ]]; then
	echo This does not look like a Velociraptor collection
	return
    fi

    do_uactgz "$TempDir/$newdir/$tarfile"
}

do_s3url() {
    s3targ=$1

    # $s3targ could be a specific file or a directory.
    if [[ "$s3targ" =~ /$ ]]; then                        # directory
	echo +++ Syncing $s3targ
	s3files=$(aws s3 ls "$s3targ" | cut -c32-)
	aws s3 sync "$s3targ" "$TempDir" --quiet
    else                                                  # single file
	echo -n Download $s3targ...
	s3files=$(echo $s3targ | sed 's,.*/,,')
	aws s3 cp "$s3targ" "$TempDir/$s3files" --quiet
    fi

    for filename in $s3files; do
	shopt -s nocasematch
	if [[ "$filename" =~ \.zip$ ]]; then
	    do_vrzip "$TempDir/$filename"
	elif [[ "$filename" =~ \.(tar\.gz|tgz)$ ]]; then
	    do_uactgz "$TempDir/$filename"
	else
	    echo $filename: unrecognized file type
	    continue
	fi
	shopt -u nocasematch
    done
}

OutputDir=$(/bin/pwd)
TempDir=
while getopts "d:t:" opts; do
    case $opts in
	d) OutputDir=$OPTARG
	   ;;
	t) TempDir=$OPTARG
	   ;;
	*) usage
	   ;;
    esac
done
shift $(($OPTIND-1))

argument_postprocessing

while [[ $# -gt 0 ]]; do
    thisarg=$1
    echo ===== $thisarg
    shift

    # Process each argument in a subshell so that cd in subfunctions
    # doesn't mess up later processing
    shopt -s nocasematch
    if [[ "$thisarg" =~ ^s3:// ]]; then
	(do_s3url "$thisarg")
    elif [[ "$thisarg" =~ \.zip$ ]]; then
	(do_vrzip "$thisarg")
    elif [[ "$thisarg" =~ \.(tar\.gz|tgz)$ ]]; then
	(do_uactgz "$thisarg")
    elif [[ -f "$thisarg/uac.log" ]]; then
	echo -n "UAC directory $thisarg will be prepped in place..."
	(do_uac_prep "$thisarg")
    else
	echo $thisarg: unrecognized argument type
    fi
    shopt -u nocasematch

    echo
done

rm -rf "$TempDir"
