#!/bin/bash

while read line; do
    if [[ "$line" =~ ^#\+*[0-9][0-9]*$ ]]; then
	echo -ne $(date -d @$(echo $line | sed 's/#//') '+%F %T')\\t
	continue
    fi
    echo "$line"
done
