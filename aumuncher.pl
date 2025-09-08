#!/usr/bin/perl
# Hal Pomeranz (hrpomeranz@gmail.com) - 2025-09-05
#
# Extracts login/logout information from Linux audit logs

use POSIX;

while (<>) {
    ($type, $epoch, $msec, $pid, $user, $host, $status) =
	/^type=(USER_(?:AUTH|END)) msg=audit\((\d+)\.(\d+):.* pid=(\d+).* acct="([^"]+)".* addr=(\S+).* res=(failed|success)/;
    next unless length($status);

    if ($type =~ /USER_AUTH/) { $type = 'LOGIN'; }
    else                      { $type = 'LOGOUT'; }
    $stamp = strftime("%F %T", gmtime($epoch)) . ".$msec";

    print join(", ", $stamp, $type, $user, $host, $status, $pid), "\n";
}
