#!/bin/bash
# Hal Pomeranz (hrpomeranz@gmail.com) -- May 2024
# Distributed under the Creative Commons Attribution-ShareAlike 4.0 license (CC BY-SA 4.0)

usage() {
    cat <<EOM
Dump extent details from XFS inodes

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

# Some inode value must be supplied
Inode=$2
[[ -z "$Inode" ]] && usage

# We need the file system block size and the number of blocks per AG in order to create "dd" commands
eval $(xfs_db -r -c 'sb 0' -c 'print agblocks' $Device | tr -d ' ')
[[ $Debug -gt 0 ]] && echo "Blocks per AG: $agblocks"
eval $(xfs_db -r -c 'sb 0' -c 'print blocksize' $Device | tr -d ' ')
[[ $Debug -gt 0 ]] && echo "Block size: $blocksize"

# Create a hex dump of the requested inode using xfs_db
# "tail -n +12" skips the inode core
# Then pull out just the hex from each extent line, without spaces
#
xfs_db -r -c "inode $Inode" -c 'type text' -c print $Device | tail -n +12 | cut -c 7-55 | tr -d ' ' |
    while read line; do
	[[ $line == "00000000000000000000000000000000" ]] && break      # no more extents

	# Dump each extent as binary, then use cut to extract each field of the extent
	bits=$(echo $line | xxd -r -p | xxd -b -c 16 | cut -c 10-154 | tr -d ' ')
	logicaloffset=$(echo $((2#$(echo $bits | cut -c2-55))))
	startblk=$(echo $((2#$(echo $bits | cut -c56-107))))
	numblks=$(echo $((2#$(echo $bits | cut -c108-128))))

	# Convert fsblock addresses to agno and agblock for "dd" command
	agno=$(xfs_db -r -c "convert fsblock $startblk agno" $Device | cut -f2 -d' ' | tr -dc 0-9)
	agblock=$(xfs_db -r -c "convert fsblock $startblk agblock" $Device | cut -f2 -d' ' | tr -dc 0-9)
	
	[[ $Debug -gt 0 ]] && echo "logical offset: $logicaloffset / start block: $startblk (agno=$agno, agblock=$agblock) / num blocks: $numblks"

	# Output working "dd" command to extract the raw blocks for each extent
	echo "(offset $logicaloffset) -- dd if=$Device bs=$blocksize skip=\$(($agno * $agblocks + $agblock)) count=$numblks"
    done
