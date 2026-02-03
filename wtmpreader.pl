#!/usr/bin/perl
# Hal Pomeranz (hrpomeranz@gmail.com) - 2026-02-02

use POSIX;
use Sys::Utmp;

# Weirdly Sys::Utmp returns the content from the local /var/log/wtmp file
# if the file specified on the command line is empty.
exit(0) if (-z $ARGV[0]);

my $utmp = Sys::Utmp->new('Filename' => $ARGV[0]);

my @entries = ();

while (@entries = $utmp->getutent()) {
    $output = join(' , ', @entries);
    if ($output =~ /[^[:print:]]/ ||
	$output =~ /[|;]/ ||
	$entries[3] !~ /^\d+$/ ||
	$entries[4] !~ /^\d$/ ||
	$entries[6] !~ /^\d{10,}$/) {
	print STDERR "invalid entry\n";
	next;
    }
    
    print strftime("%F %T", localtime($entries[6])) . " , $output\n";
}

$utmp->endutent;

