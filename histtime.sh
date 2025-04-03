#!/bin/bash

while read line; do
    if [[ "$line" =~ ^# ]]; then
	echo -ne $(date -d @$(echo $line | sed 's/#//') '+%F %T')\\t
	continue
    fi
    echo $line
done
