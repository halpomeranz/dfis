#!/usr/bin/perl

while (<>) {
    chomp;
    @fields = split(' , ');

    if ($fields[5] =~ /[12]/) {
	mactime_output("Action=$fields[1] kernel=$fields[6]", $fields[7]);
    }
    elsif ($fields[5] =~ /[6]/) {
	($user, $pty, $pid, $host, $epoch) = @fields[1,3,4,6,7];
	next if ($user eq 'LOGIN');
	mactime_output("FAILED LOGIN User=$user Host=$host PTY=$pty PID=$pid", $epoch);
    }
    elsif ($fields[5] =~ /[7]/) {
	($user, $pty, $pid, $host, $epoch) = @fields[1,3,4,6,7];
	next if ($user eq 'LOGIN');
	mactime_output("LOGIN User=$user Host=$host PTY=$pty PID=$pid", $epoch);
	$cache{"$pid-$pty"} = [$user, $host];
    }
    elsif ($fields[5] == 8) {
	($pty, $pid, $epoch) = @fields[3,4,7];
	($user, $host) = @{$cache{"$pid-$pty"}};
	delete($cache{"$pid-$pty"});
	mactime_output("LOGOUT User=$user Host=$host PTY=$pty PID=$pid", $epoch);
    }
}

# 0|/home|1074766016|drwxr-xr-x|0|0|6|1727701622|1456155395|1456155395|0
sub mactime_output {
    my($msg, $epoch) = @_;

    print join('|', 0, $msg, 0, '----------', 0, 0, 0, $epoch, $epoch, $epoch, $epoch) . "\n";
}




