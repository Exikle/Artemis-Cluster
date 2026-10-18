#!/usr/bin/perl
# Strip terminal escapes and drop lines repeated within 10 minutes.
use strict;
use warnings;

$| = 1;
my %last_printed;
while (my $line = <STDIN>) {
    $line =~ s/\e\[[0-9;?]*[A-Za-z]//g;
    $line =~ s/\e\]8;;[^\a]*\a//g;
    next if $line =~ /^\s*$/;
    my $now = time;
    next if exists $last_printed{$line} && $now - $last_printed{$line} < 600;
    $last_printed{$line} = $now;
    print $line;
}
