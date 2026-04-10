#!/usr/bin/jq -f

."@timestamp" = ((."@timestamp" / 1000) | strftime("%F %T.")) +
                  (."@timestamp" | tostring | .[-3:])

