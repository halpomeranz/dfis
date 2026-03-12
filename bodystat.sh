#!/bin/bash
# bodystat.sh -- Hal Pomeranz (hrpomeranz@gmail.com), 2026-03-12
# Converts mactime style bodyfile lines into output like the stat command
#
# Example: grep /etc/passwd bodyfile | bodystat.sh

IFS='|'
while read -r junk path inode perms uid gid size atime mtime ctime btime; do
    echo "  File: $path"
    echo -e "  Size: $size\\tUID: $uid\\tGID: $gid\\tInode: $inode"
    echo "Access: $(date -d @$atime '+%F %T')"
    echo "Modify: $(date -d @$mtime '+%F %T')"
    echo "Change: $(date -d @$ctime '+%F %T')"
    echo " Birth: $(date -d @$btime '+%F %T')"
    echo
done
