#!/usr/bin/perl
# Hal Pomeranz (hrpomeranz@gmail.com) - 2025-09-05

use POSIX;

while (<>) {
    ($epoch, $msec) = /^type=\S+ msg=audit\((\d+)\.(\d+):/;
    next unless ($epoch > 1000000000 && $epoch < 3000000000);

    $stamp = strftime("%F %T", gmtime($epoch)) . ".$msec";
    $fname = join('-', (split('-', $stamp))[0,1]);

    unless (defined($handles{$fname})) {
	open $handles{$fname}, ">", "$fname" || die "Failed to open $fname!\n";
    }

    print {$handles{$fname}} "$stamp $_";
}
