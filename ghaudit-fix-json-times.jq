#!/usr/bin/jq -cf

."@timestamp" = ((."@timestamp" / 1000) | strftime("%F %T.")) +
                  (."@timestamp" | tostring | .[-3:])

