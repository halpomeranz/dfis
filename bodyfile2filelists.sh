#!/bin/bash
# bodyfile2filelists.sh -- Hal Pomeranz (hrpomeranz@gmail.com)
# Usage: bodyfile2filelists.sh [-U uacdir] | [-d outputdir] [bodyfile]

usage() {
    cat <<EOM
Extract lists of different file and directory types from mactime bodyfile

Usage: $0 [-U uacdir] [-d outputdir] [bodyfile]

    -U uacdir     Path to UAC directory containing "bodyfile" directory.
                  Files will be output to the "system" directory here.
    -d outputdir  Directory where file output goes (default is cwd).
                  Overrides normal UAC path if "-U" specified.

bodyfile must be specified if no "-U" option. Ignored if "-U".
EOM
    exit 1;
}


OutputDir='.'
UserOutputDir=
UACDir=
CheckUIDs=0
CheckGIDs=0
while getopts "d:U:" opts; do
    case $opts in
        d) UserOutputDir=$OPTARG
           ;;
        U) UACDir=$OPTARG
           ;;
        *) usage
           ;;
    esac
done
shift $(($OPTIND-1))

if [[ -n "$UACDir" ]]; then
    BodyFile="$UACDir/bodyfile/bodyfile.txt"
    if [[ ! -r "$BodyFile" ]]; then
	echo $BodyFile not found
	usage
    fi

    # Put output into appropriate UAC directory
    OutputDir="$UACDir/system"

    # if UAC, we need to parse /etc/{passwd,group} and get UIDs/GIDs
    if [[ -r "$UACDir/[root]/etc/passwd" ]]; then
	declare -A Username
	IFS=:
	while read username pwd uid rest; do
	    Username[$uid]=$username
	done < "$UACDir/[root]/etc/passwd"
	unset IFS
	CheckUIDs=1
    fi
    if [[ -r "$UACDir/[root]/etc/group" ]]; then
	declare -A Groupname
	IFS=:
	while read groupname pwd gid rest; do
	    Groupname[$gid]=$groupname
	done < "$UACDir/[root]/etc/group"
	unset IFS
	CheckGIDs=1
    fi
else                               # Not from UAC, give me a bodyfile name
    BodyFile=$1
    [[ -r "$BodyFile" ]] || usage
fi

# If user specified output directory with -d then this overrides all
[[ -n "$UserOutputDir" ]] && OutputDir="$UserOutputDir"
[[ -d "$OutputDir" ]] || mkdir -p "$OutputDir"

# MD5|name|inode|mode_as_string|UID|GID|size|atime|mtime|ctime|crtime
IFS=\|
cat $BodyFile | while read md5 fpath inode fmode uid gid size atime mtime ctime btime; do

    ftype=${fmode:0:1}
    [[ $ftype == '-' ]] && ftype='f'

    perms=${fmode:1}

    fpath=${fpath/ ->*/}               # remove symlink dests
    fname=${fpath/*\//}                # like basename

    # file type "s", socket_files.txt
    [[ $ftype == 's' ]] && echo $fpath >>"$OutputDir/socket_files.txt"
    
    # name starts with "." && file type "d", hidden_directories.txt
    # name starts with "." && file type "f", hidden_files.txt
    if [[ $fname =~ ^\. ]]; then
	[[ $ftype == 'd' ]] && echo $fpath >>"$OutputDir/hidden_directories.txt"
	[[ $ftype == 'f' ]] && echo $fpath >>"$OutputDir/hidden_files.txt"
    fi

    # type "f" && matches "^..[sS]", suid.txt
    [[ $ftype == 'f' && $perms =~ ^..[sS] ]] && echo $fpath >>"$OutputDir/suid.txt"
    # type "f" && matches "^.....[sS]", sgid.txt
    [[ $ftype == 'f' && $perms =~ ^.....[sS] ]] && echo $fpath >>"$OutputDir/sgid.txt"

    # UAC does one pass for mode 777 files/dirs-- this is wrong
    # type "f" && matches "^.......w", world_writable_files.txt
    [[ $ftype == 'f' && $perms =~ ^.......w ]] && echo $fpath >>"$OutputDir/world_writable_files.txt"
    # type "d" && matches "^.......w", world_writable_directories.txt
    [[ $ftype == 'd' && $perms =~ ^.......w ]] && echo $fpath >>"$OutputDir/world_writable_directories.txt"
    # world writable dirs that are not sticky
    [[ $ftype == 'd' && $perms =~ ^.......w && ! $perms =~ t$ ]] && echo $fpath >>"$OutputDir/world_writable_not_sticky_directories.txt"
    # type "f" && matches "^....w", group_writable_files.txt
    [[ $ftype == 'f' && $perms =~ ^....w ]] && echo $fpath >>"$OutputDir/group_writable_files.txt"
    # type "d" && matches "^....w", group_writable_directories.txt
    [[ $ftype == 'd' && $perms =~ ^....w ]] && echo $fpath >>"$OutputDir/group_writable_directories.txt"

    # for the next two, we need to have parsed /etc/{passwd,group} above
    if [[ $CheckUIDs -gt 0 ]]; then
	# user_name_unknown_files.txt
	[[ $ftype == 'f' && -z "${Username[$uid]}" ]] && echo $fpath >>"$OutputDir/user_name_unknown_files.txt"
	# user_name_unknown_directories.txt
	[[ $ftype == 'd' && -z "${Username[$uid]}" ]] && echo $fpath >>"$OutputDir/user_name_unknown_directories.txt"
    fi
    
    if [[ $CheckGIDs -gt 0 ]]; then
	# group_name_unknown_files.txt
	[[ $ftype == 'f' && -z "${Groupname[$gid]}" ]] && echo $fpath >>"$OutputDir/group_name_unknown_files.txt"
	# group_name_unknown_directories.txt
	[[ $ftype == 'd' && -z "${Groupname[$gid]}" ]] && echo $fpath >>"$OutputDir/group_name_unknown_directories.txt"
    fi
done
unset IFS

