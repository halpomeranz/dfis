#!/usr/bin/perl

use POSIX qw(strftime);

while (<>) {
    ($epoch_with_milli) = /"\@timestamp":(\d+),/;
    $epoch = $epoch_with_milli / 1000;
    $milli = substr($epoch_with_milli, -3);
    $datestr = strftime("%Y-%m-%d %H:%M:%S.$milli", gmtime($epoch));
    s/"\@timestamp":\d+,/"\@timestamp":"$datestr",/;
    print;
}
