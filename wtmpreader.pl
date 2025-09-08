#!/usr/bin/perl
# Hal Pomeranz (hrpomeranz@gmail.com) - 2025-09-05

use POSIX;
use Sys::Utmp;

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

