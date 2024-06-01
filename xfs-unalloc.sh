#!/bin/bash
# Hal Pomeranz (hrpomeranz@gmail.com) -- June 2024
# Distributed under the Creative Commons Attribution-ShareAlike 4.0 license (CC BY-SA 4.0)

usage() {
    cat <<EOM
Dump unallocated blocks from XFS file system to stdout

Usage: $0 [-D] device inode

    -D       Output debugging details
EOM
    exit 1;
}


Debug=0
while getopts "D" opts; do
    case ${opts} in
        D) Debug=1
           ;;
        *) usage
           ;;
    esac
done
shift $((OPTIND-1))

# Supplied device or file must be readable
Device=$1
[[ -r "$Device" ]] || usage

# We need the file system block size and the number of blocks per AG in order to create "dd" commands
agblocks=$(xfs_db -r -c 'sb 0' -c 'print agblocks' $Device | sed 's/.*= //')
[[ $Debug -gt 0 ]] && echo "Blocks per AG: $agblocks"
blocksize=$(xfs_db -r -c 'sb 0' -c 'print blocksize' $Device | sed 's/.*= //')
[[ $Debug -gt 0 ]] && echo "Block size: $blocksize"

# "freesp -d" outputs a one line header, followed by agno/agblock/numblocks data for all free blocks.
# After the free block list, there's a histogram with it's own header (don't care about this).
#
xfs_db -r -c 'freesp -d' $Device | tail -n +2 |
    while read agno agblock len; do
	[[ $agno == "from" ]] && break; 

	[[ $Debug -gt 0 ]] && echo agno: $agno / agblock: $agblock / numblocks: $len
	dd if=$Device  bs=$blocksize skip=$(($agno * $agblocks + $agblock)) count=$len 2>/dev/null
    done
