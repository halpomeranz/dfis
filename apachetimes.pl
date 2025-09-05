#!/usr/bin/perl

%Months = ('Jan' => '01', 'Feb' => '02', 'Mar' => '03', 'Apr' => '04',
	   'May' => '05', 'Jun' => '06', 'Jul' => '07', 'Aug' => '08',
	   'Sep' => '09', 'Oct' => '10', 'Nov' => '11', 'Dec' => '12');

while (<>) {
    ($day, $monbrev, $year, $time) = /\[(\d+)\/([A-Z][a-z]{2})\/(\d+):(\d+:\d+:\d+) /;
    $mon = $Months{$monbrev};
    print "$year-$mon-${day}_$time $_";
}
