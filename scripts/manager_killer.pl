#!/usr/bin/perl

my $self = shift;
print "Protecting " . $self . "\n\n\n";


my $allowed = 1;
$allowed = 0 unless $self =~ /[0-9]/gi;
$self = 000000000000 unless $self;
my @killers = ('President.pl', 'teletype.pl', 'watch.pl', 'Manager.pl', 'termux-tts-spea', 'cat', 'perl');
foreach my $k (@killers) {
	my @ps = grep { $_ !~ /^ $self/ } split "\n", `ps -e | grep $k`;
	until (scalar @ps <= $allowed) {
		foreach my $ps (@ps) {
			next if $ps == $self;
			my $p = $ps[$n];  
			my @n = split " ", $p;
			my $n = $n[0] . "\n" ;
			next if $ps =~ /defunct/;
			print $p . ' ' . $n ."\n";
			# `kill -9 $n`; 
			`kill -9 $n` unless $n == $self;
			print $n;
		}
		sleep .5;
		@ps = grep { $_ !~ /^ $self/ } split "\n", `ps -e | grep $k`;
		print scalar @ps . "\n";
	}
}

