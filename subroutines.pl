#!/usr/bin/env perl

package subs;

use strict;
use warnings; 

use Mojolicious::Lite;
use List::Util qw(shuffle);
use Mojo::Util qw/md5_sum html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use MIME::Base64;
use Time::Duration;
use Date::Parse;
use Time::Piece;
use Crypt::Simple;
use File::Slurp;
use File::Find;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::SQLite;
use Data::Dumper;
use Time::HiRes qw(gettimeofday time);
use Mojo::IOLoop;
use Clone qw(clone);

require "./gb.pl";
require "./Websocket.pl";
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my $universal_splitter = $gb::universal_splitter;

our $device = &device_setter();
sub format_name() {
	my $name = shift || "";
	my $fname = lc $name;
	$fname =~ s/_/ /gi;
	my @fname = split ' ',$fname;
	foreach my $f (@fname) {
		my @f = split '',$f;
		$f[0] = uc $f[0];
		$f = join '', @f;
	}
	$fname = join ' ', @fname;
	return $fname;
}

sub unformat_name() {
	my $name = shift || "";
	my $fname = lc $name;
	$fname =~ s/\'//gi;
	$fname =~ s/ /_/gi;
	my @fname = split '_',$fname;
	if ($fname[0] eq '') {
		unshift @fname;
	}
	if ($fname[-1] eq '') {
		pop @fname;
	}
	$fname = join '_', @fname;
	return lc $fname;
}

sub apostrophe_escape() {
	my $string = shift || "";
	$string =~ s/\'/\\\'/gi;
	$string =~ s/\?/\\\?/gi;
	return $string;
}

sub shorthand_name() {
	my $name = shift || "";
	my $shorten = shift || 5;
	my $name1 = substr($name, 0, $shorten);
	return $name1;
}

sub initialize_name() {
	my $name = shift || "";
	my $returner;
	my $count = 0;
	foreach my $n ( split ' ', $name ) {
		if ($count <= 2) {
			$returner .= &shorthand_name($n, 1);
		}
		$count++;
	}
	return $returner;
}

sub teaser_name() {
	my $name = shift || "";
	my $name1 = substr($name, 0, 50);
	return $name1;
}

sub abbreviate_name() {
	my $name = shift || "";
	$name =~ s/[^a-zA-Z 0-9]//g;
	my @words = split ' ', $name;

	my $abbrev = '';

	foreach my $word (@words) {
		my @letters = split '', $word;
		$abbrev = $abbrev . $letters[0] if scalar @letters > 0;
	}
	return $abbrev;
}

sub terminal_name() {
	my $name = shift || "";

	foreach my $split ( (' ', '(', ')', '{', '}', '&', '\'', '"', '+' )) {
		#my @words = split $split, $name;
		#$name = join '\\' . $split, @words;

		$name =~ s/\Q$split/\\$split/gi;
	}


	return $name;
}

sub html_name() {
	my $name = shift || "";
	$name =~ s/[^a-zA-Z0-9\?]+//g;
	#$name = html_unescape $name;

	return $name;
}

sub http_name() {
	my $name = shift || "";
	$name =~ s/ /_/gi;
	$name =~ s/[^a-zA-_Z0-9]+//g;
	$name = html_unescape $name;

	return $name;
}

sub wiki_name() {
	my $name = shift;
	my @name = split '_', $name;

	$name[0] = ucfirst $name[0];
	$name = join '_', @name;
	return $name;
}

sub formatted_time() {
	my $time = shift;
	return localtime($time / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P');
}

sub price_formatter() {
	my $price = shift;
	$price =~ s/^([\-])//gi;
	$price = $1 . sprintf( "\$%.2f", $price);
	return $price;
}

sub percent_formatter() {
	my $percent = shift;
	$percent = $percent * 100;
	$percent = sprintf("%.3f", $percent) . '%';
	return $percent;
}

sub duration_sayer() {
	my $durational = shift;
	my $timestamp = &subs::rightNow();

	my $leap_year =  &subs::time_abbrev_translator('4y') / 1000;
	if ($durational > $leap_year) {
		my $leaps = (( $durational) / ($leap_year));
		$durational = $durational - (&subs::time_abbrev_translator($leaps . 'd' ) / 1000);
	}

	my $duration = duration($durational);

	$duration =~ s/ hours?/h/gi;
	$duration =~ s/ minutes?/m/gi;
	$duration =~ s/ days?/d/gi;
	$duration =~ s/ months?/M/gi;
	$duration =~ s/ weeks?/w/gi;
	$duration =~ s/ seconds?/s/gi;
	$duration =~ s/ years?/y/gi;
	$duration =~ s/ and / /gi;
	$duration =~ s/just now/0s/gi;
	return $duration;
}

sub time_abbrev_translator() {
	my $timing = shift;
	my $timestamp = shift;
	my $total_duration = 0;
	my $negative = '+';
	my @times;
	my $fulltime = $timing;
	return '1' if $timing =~ /Infinity|NaN/gi;
	return unless $timing;
	if ($timing =~ / /) {
		@times = split ' ', $timing;
	}
	else {
		push @times, $timing;
	}

	foreach my $time ( @times ) {
		next unless $time =~ /[0-9a-zA-Z]/gi;
		my $measure;
		$fulltime =~ s/[\-.,0-9]//gi;
		if ($fulltime eq 'year') {
			$measure = 'y';
		}
		elsif ($fulltime eq 'second') {
			$measure = 's';
		}
		elsif ($fulltime eq 'decade') {
			$measure = 'D';
		}
		elsif ($fulltime eq 'minute') {
			$measure = 'm';
		}
		elsif ($fulltime eq 'hour') {
			$measure = 'h';
		}
		elsif ($fulltime eq 'day') {
			$measure = 'd';
		}
		elsif ($fulltime eq 'week') {
			$measure = 'w';
		}
		elsif ($fulltime eq 'month') {
			$measure = 'M';
		}
		$time =~ s/([smhdwmycDM]$)//gi;
		if ($time eq 'in') {
			$negative = '-';
			next;
		}
		$measure = $measure || $1 || 'm';
		$time =~ s/[a-zA-Z]//gi;
		next if $times[0] =~ /\s/;
		if ($times[0] < 0 || $negative eq '-') { $time = $time * -1 unless $time < 0; }
		my $duration = 1000 * $time;
		
		$total_duration = $total_duration + $duration if $measure eq 's' || $measure =~ /second/gi;
		$total_duration = $total_duration + ($duration * 60) if $measure eq 'm' || $measure =~ /minute/gi;
		$total_duration = $total_duration + ($duration * 60 * 60) if $measure eq 'h' || $measure =~ /hour/gi;
		$total_duration = $total_duration + ($duration * 60 * 60 * 24) if $measure eq 'd' || $measure =~ /day/gi;
		$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 7) if $measure eq 'w' || $measure =~ /week/gi;

		if ($measure eq 'M' || $measure eq 'mos' || $measure =~ /month/gi) {
			my $total_days = 0;
			my $month = localtime( $timestamp / 1000 )->strftime( "%m");
			if ($time < 0 || $negative eq '-') {
				if ($time < -12) {
					my $years = $time / 12;
					push @times, $years . 'y';
					until ($time > -12) {
						$time = $time + 12;
					}
				}
				for (my $n = -1; $n >= $time; $n-- ) {
					my $month = localtime( $timestamp / 1000 )->strftime( "%m");
					$month = $month - $n - 1;

					if ($month > 12) { $month = $month - 12; }
					$total_days -= $gb::months->[$month - 1]->{'days'};
				}
			} else {
				if ($time > 12) {
					my $years = $time / 12;
					push @times, $years . 'y';
					until ($time < 12) {
						$time = $time - 12;
					}
				}
				for (my $n = 1; $n <= $time; $n++ ) {
					my $month = localtime( $timestamp / 1000 )->strftime( "%m");
					my $year = localtime( $timestamp / 1000 )->strftime( "%m");
					$month = $month - $n;

					if ($month <= 0) { $month = 12 + $month; }
					$total_days += $gb::months->[$month - 1]->{'days'};
				}
			}
			$duration = 1000;
			$total_duration = $total_duration + ($duration * 60 * 60 * 24 * $total_days);
		}
	 	if ($measure eq 'y' || $measure =~ /year/gi) {
			$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 365);
		}
		$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 365 * 10) if $measure eq 'D' || $measure =~ /decade/gi;
		$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 365 * 100) if $measure eq 'c' || $measure =~ /century/gi;
	}
	return $total_duration;
}

sub is_leap_year() {
	my $timestamp = shift;	
	my $month = localtime( $timestamp / 1000 )->strftime( "%m");
	my $year = localtime( $timestamp / 1000 )->strftime( "%Y");
	if ($timestamp < 10000) {
		$year = $timestamp;
	}
	return 0 if $year % 4;
	return 1 if $year % 100;
	return 0 if $year % 400;
	return 1;

}

sub timespan_widener() {
	my $fulltime = shift;
	$fulltime =~ s/[0-9,.]//gi;
	my $measure = $fulltime;
	if ($fulltime eq 'y') {
		$measure = 'year';
	}
	elsif ($fulltime eq 's') {
		$measure = 'second';
	}
	elsif ($fulltime eq 'D') {
		$measure = 'decade';
	}
	elsif ($fulltime eq 'm') {
		$measure = 'minute';
	}
	elsif ($fulltime eq 'h') {
		$measure = 'hour';
	}
	elsif ($fulltime eq 'd') {
		$measure = 'day';
	}
	elsif ($fulltime eq 'w') {
		$measure = 'week';
	}
	elsif ($fulltime eq 'M') {
		$measure = 'month';
	}
	return $measure;
	
}

sub appt_header_printer() {
	my $data = shift;
	my $app = $data->{'app'};

	my $appts = $data->{'appts'} || &Manager::log_reader({ app => $app, view => 'centre_view'  });

	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $c = app->build_controller;
	my $header = $c->render_to_string(template => 'apps/appointment_header', timestamp => $server_time, appts => $appts, appointments => [ $app ], a => $app );

	eval { &subs::cache_set({ app => $app, context => 'header', timestamp => $server_time }, { timestamp => $timestamp, header => $header }) };

	&Websocket::send('tab', { type => 'header', app => $app, timestamp => $server_time, header => $header });
	return $header;
}



sub random_string_creator() {

  my ($string,$count);
	$count = shift || 8;
	my $chars = shift;
  my @chars;
	if ($chars) {
		if ($chars =~ /[A-Z]/) {
			push @chars, ("A".."Z");
		}
		if ($chars =~ /[a-z]/) {
			push @chars, ("a" .. "z");
		}
		if ($chars =~ /[0-9]/) {
			push @chars, ("0".."9");
		}
	}
	else {
		@chars = ("A".."Z", "a".."z", "0".."9");
	}

  $string .= $chars[rand @chars] for 1..$count;
  return $string;
}

sub inventory_grabber() {
	my $inventory = `cat ./inventory.jawn`;
	my $tree;
	my @description = split "\n", $inventory;
	my $file;
	foreach my $d (@description) {
		if ($d =~ /^\//g) {
			$file = lc $d;
			$file =~ s/^\///g;
		}
		else { $tree->{lc $file}  .= $d . "\n"; }
	}
	foreach my $t ( keys %{$tree}) {
		my $temp;
		foreach my $l ( split "\n", $tree->{$t} ) {
			$temp = $l;
		}
	#	$tree->{$t} = $temp;
	}
	return $tree;
}

sub statement_grabber() {
	my $appts = shift;

	my $articles;

	foreach my $a (keys %{$appts}) {
		unless ($a =~ /^__/ ) {
			$articles .= &format_name($a) . "---";
		}
	}
	return $articles;
}


our $time_subs = {
	'second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * ($multiplier || 1));
		return $re;
	},
	'15second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 15 * ($multiplier || 1));
		return $re;
	},
	'30second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 30 * ($multiplier || 1));
		return $re;
	},
	'45second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 45 * ($multiplier || 1));
		return $re;
	},
	'minute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * ($multiplier || 1));
		return $re;
	},
	'twominute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 2 * ($multiplier || 1));
		return $re;
	},
	'threeminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwominute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 30 * ($multiplier || 1));
		return $re;
	},	
	'fortyfiveminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 45 * ($multiplier || 1));
		return $re;
	},
	'hour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = abs $timestamp - (1000 * 60 * 60 * ($multiplier || 1));
		return $re;
	},
	'twohour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = abs $timestamp - (1000 * 60 * 120 * ($multiplier || 1));
		return $re;
	},
	'threehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 4 * ($multiplier || 1));
		return $re;
	},
	'fivehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 7 * ($multiplier || 1));
		return $re;
	},
	'eighthour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 8 * ($multiplier || 1));
		return $re;
	},
	'ninehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelvehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyonehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwohour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfivehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeighthour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentyninehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 30 * ($multiplier || 1));
		return $re;
	},
	'day' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * ($multiplier || 1));
		return $re;
	},
	'twoday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 48 * ($multiplier || 1));
		return $re;
	},
	'threeday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 72 * ($multiplier || 1));
		return $re;
	},
	'fourday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwoday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * ($multiplier || 1));
		return $re;
	},
	'week' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * ($multiplier || 1));
		return $re;
	},
	'twoweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 2 * ($multiplier || 1));
		return $re;
	},
	'threeweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwoweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 30 * ($multiplier || 1));
		return $re;
	},
	'moon' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 28 * ($multiplier || 1));
		return $re;
	},
	'month' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * ($multiplier || 1));
		return $re;
	},
	'twomonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 2 * ($multiplier || 1));
		return $re;
	},
	'threemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 4 * ($multiplier || 1));
		return $re;
	},
	'fivemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 8 * ($multiplier || 1));
		return $re;
	},
	'ninemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelvemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentymonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyonemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwomonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentythreemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfivemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentyninemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtymonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 30 * ($multiplier || 1));
		return $re;
	},
	'season' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 90 * ($multiplier || 1));
		return $re;
	},
	'quarter' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * (30.5 * 3) * ($multiplier || 1));
		return $re;
	},
	'year' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * ($multiplier || 1));
		return $re;
	},
	'twoyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 2 * ($multiplier || 1));
		return $re;
	},
	'threeyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 3 * ($multiplier || 1));
		return $re;
	},
	'fouryear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwoyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfouryear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 30 * ($multiplier || 1));
		return $re;
	},
	'decade' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * ($multiplier || 1));
		return $re;
	},
	'century' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * 10 * ($multiplier || 1));
		return $re;
	},
	'millenium' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * 10 * 10 * ($multiplier || 1));
		return $re;
	},
	'era' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * 10 * 10 * 10 * ($multiplier || 1));
		return $re;
	},
};

sub ago_calc() {
	my ($ago,$timestamp) = @_;
	$timestamp = &rightNow() unless $timestamp;
	my $server_time = &subs::rightNow();
	my $server_dow = localtime($timestamp / 1000)->[6];
	my $time_dow = localtime($timestamp / 1000)->[6];
	my @days = qw/sun mon tue wed thu fri sat/;
	my @ago = split ' ', $ago;
	my $announced_time;
	my $difference = 0;
	if ($ago =~ /(yo)/) {
		my $birthday = &subs::duration_sayer( ($timestamp / 1000 ) - &ago_calc( $config->{'birthday'},$timestamp) / 1000) || (($timestamp / 1000 ) - (&original_timestamp() / 1000 ) );
		my $birthday_timestamp = &ago_calc( $config->{'birthday'},$timestamp);
		my @years_ago = grep { $_ =~ 'yo' } @ago;
		my $years_ago = $years_ago[0];
		my @birthday = split ' ', $birthday;
		my $bday = $birthday[0];
		if ($bday != $years_ago) {
			my $tims = $years_ago - $bday;
			my $diff = &subs::time_abbrev_translator('1y',$timestamp);
			$timestamp = ($diff * $tims) + $timestamp;
		}
		@ago = grep { $_ !~ 'yo' } @ago;
		$ago = join ' ', @ago;
	}
	if ($ago) {
		if ($ago =~ /(tom)/) {
			$difference = &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
		}
		if ($ago =~ /(yes)/) {
			$difference = -1 * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
		}

		my $is_dow = 0;
		if ($ago =~ /(mon)/) {
			$difference = (1 - $time_dow) * &{$subs::time_subs->{'day'}}(0);			
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(tue)/) {
			$difference = (2 - $time_dow) * &{$subs::time_subs->{'day'}}(0);			
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(wed)/) {
			$difference = (3 - $time_dow) * &{$subs::time_subs->{'day'}}(0);			
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(thu)/) {
			$difference = (4 - $time_dow) * &{$subs::time_subs->{'day'}}(0);			
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(fri)/) {
			$difference = (5 - $time_dow) * &{$subs::time_subs->{'day'}}(0);			
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sat)/) {
			$difference = (6 - $time_dow) * &{$subs::time_subs->{'day'}}(0);			
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sun)/) {
			$difference = (7 - $time_dow) * &{$subs::time_subs->{'day'}}(0);			
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		if ($ago =~ /[:\/APap]/) {
			$timestamp = str2time($ago) * 1000;
			$announced_time = ago(($server_time - $timestamp ) / 1000) if $server_time != $timestamp;
		}
		else {
			my $subtractable = &subs::time_abbrev_translator($ago,$timestamp);
			$timestamp = $timestamp - $subtractable;
			my $time = localtime($timestamp / 1000 )->strftime('%I:%M%P');
			my $date = localtime($timestamp / 1000 )->strftime('%A %B %d %Y');
			my $todays_date = localtime()->strftime('%A %B %d %Y');
			my $todays_time = localtime()->strftime('%I:%M%P');
			$announced_time = $time if $server_time != $timestamp;
			$announced_time = $date . ' at ' . $time if $todays_date ne $date;
		}
		$timestamp = $timestamp - $difference;

	}
	return $timestamp;
}

sub say_it() {
	my $text = shift;
 # Mojo::IOLoop->subprocess->run_p(sub {
		if ($device eq 'mobile') {
			my $filename = &home("~/.president/espeaker.wav");

			`espeak -w $filename "$text"`;
			`termux-media-player play $filename`;
			sleep 1;
			`shred -u $filename`;
		}
		elsif ($device eq 'computer') {
			`espeak -a70 -v gmw/en-US-nyc "$text"`;
		}
#	});
}

sub main_icon_maker() {
	my $data = shift;
	my $unformatted_name = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $settings = $data->{'settings'};
	my $size = $data->{'size'} || 'tiny';
	my $onclick;
	if (!$data->{'onclick'}) {
		$onclick = 'onclick="windowRestorer(' . $timestamp . ',\'' . $unformatted_name . '\')"';
	}
	$settings = &subs::settings_grabber({ app => $unformatted_name }) unless $settings;
	my $main_image = '<span id="window_icon_' . $timestamp . '" style="display:none;" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" ' . $onclick . '>' . &subs::initialize_name(&subs::format_name($unformatted_name)) . '</span>';
	my ($destination,$asset);
	if ($settings->{'main_image'}) {
		($destination,$asset) = &subs::file_device_renamer({ file => $settings->{'main_image'}, app => $unformatted_name, type => 'image' });
		if (-e ($destination . $asset)) {
			$main_image = '<img id="window_icon_' . $timestamp . '" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" src="/file_open?file=' . $destination . $asset . '" class="little_thumb" ' . $onclick . '>';
		}
	}
	unless (-e $destination . $asset) {
		if ($gb::known_appts->{$unformatted_name}) {
			$main_image = '<img id="window_icon_' . $timestamp . '" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" src="' . $gb::known_appts->{$unformatted_name}->{'icon'} . '" class="little_thumb" ' . $onclick . '>';
		}
		elsif (-e 'public/icons/pos/' . $settings->{'pos'} . '.png') {
			$main_image = '<img id="window_icon_' . $timestamp . '" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" src="' . '/icons/pos/' . $settings->{'pos'} . '.png' . '" class="little_thumb" ' . $onclick . '>';
		}
	}
	return $main_image
}

sub device_setter() {
	my $device = 'computer';
	if ($config->{'device'}) {
		$device = $config->{'device'};
	}
	else {
		my $uname = `uname -a`;
		if ($uname =~ /Android/gi) {
			$device = 'mobile';
		}
		elsif ($uname =~ /Debian/gi) {
			$device = 'server';
		}
	}
	return $device;
}

sub restore_list() {
	my $directory = shift;
	my $returner = [];
	my @backups;
	$directory =~ s|[^/]+$||;
	if ($directory && $directory =~ /\/$/) {
		my $backup_ls = `ls -t $directory`;
		@backups = split "\n", $backup_ls;
		foreach my $b (@backups) {
			$b = $directory . $b;
		}
	}
	
	foreach my $b (@backups) {
		my $status = 'closed';
		my @stat = stat $b ;

		my $bees = $b;
		$bees =~ s/\.[^.]*$//;
		$bees = &home($bees);
		if (-e $bees . '.db') { $status = 'open'; }
		my $archive = $bees =~ /\d{10}$/ ? 'archive' : 'current';

		my $size = sprintf('%.2f', ( $stat[7] / 1024 )) . 'kb';
		my $created = localtime($stat[9] )->strftime('%A %B %d %Y - %I:%M:%S%P %Z');
		push @{$returner}, { archive => $archive, status => $status, directory => $directory, filename => $b, size => $size, created => $created, blocks => $stat[12] };
	}

	return $returner;
}


sub edt_button_presser() {
	my $data = shift;
	my $remote_address = $data->{'remote_address'};
	my $timestamp = $data->{'timestamp'};
	my $room = $data->{'room'};
	my $watch_settings = $data->{'watch_settings'};
	my $button = $data->{'button'};
	my $edt = $data->{'edt'};
	my $toggler = $data->{'toggle'};
	my $state = $data->{'state'};
	my $chip_id => $data->{'chip_id'};
	my $room_count = $watch_settings->{'__specs'}->{'room_count'};
	my $room_max = $watch_settings->{'__specs'}->{'room_max'};
	my $component = $data->{'component'} || 'button';
	$button = (($room -1 ) * $room_max) + $button unless $edt eq 'microcontroller';
	my $server_time = &subs::rightNow();
	my $measure = $data->{'measure'};
	my $uuid = &subs::random_string_creator(21);
	my ($db,$database) = &subs::database_grabber();
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $b = $watch_settings->{&subs::shorthand_name($component, $syl_count) . $button} || {};
	my $app = $b->{'app'};
	my $movement = $b->{'movement'};
	my $uuid;
	my $settings = &subs::settings_grabber({ app => $app });
	my $saved_toggle = $settings->{'toggle'};
	my $toggle;
	my $duration = &subs::time_abbrev_translator($settings->{'duration'});

	if (($movement eq 'start' || $movement eq 'record') && ($saved_toggle eq 'on' || $toggler eq 'on' || $saved_toggle == 1)) {
		$movement = 'stop';
		$toggle = 'off';
	}
	my $db_data = {
		app => $app,
		server_time => $server_time,
		timestamp => $timestamp,
		type => $movement,
		toggle => $b->{'toggle'},
		uuid => $uuid,
		duration => $duration,
		warranty => &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time),
		project => $settings->{'t_project'},
		pos => $settings->{'pos'},
		remote_address => $remote_address
	};
	if ($saved_toggle eq 'on') {
		$b->{'toggle'} = 0;
		$toggle = 'off';
	}
	else {
		$b->{'toggle'} = 1;
		$toggle = 'on';
	}



	if ($movement eq 'command' || $movement eq 'kill') {
		if ($settings->{'command'} && $settings->{'kill'}) {

		}
		elsif ($settings->{'command'} && !$settings->{'kill'}) {
			$toggle = $saved_toggle;
			$b->{'toggle'} = $saved_toggle eq 'on' ? 1 : 0;
		}
		my $resulter = &subs::run_command($app,$settings->{$movement});

	}
	&subs::setting_setter({ app => $app, setting => 'toggle', value => $toggle });
	$db_data->{'seen'} = 'yes';
	my $c = app->build_controller;
	my $returner;
	if ($measure) {

		$c->param('measure', $b->{'measure'});
		$c->param('value', $measure);

		&Manager::appt_measure_writer($c,{ app => $app, measure => $b->{'measure'}, value => $measure, timestamp => $timestamp, remote_address => $remote_address });
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure[measure="' . $b->{'measure'} . '"]\').val(\'' . $measure . '\');' });
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure_display[measure="' . $b->{'measure'} . '"]\').text(\'' . $measure . '\');' });
	}
	else {
		$returner = { 
			app => $app, 
			numero => $b->{'numero'}, 
			shorthand_name => &subs::shorthand_name($b->{'shorthand_name'}), 
			movement => $b->{'movement'}, 
			toggle => $b->{'toggle'}, 
			button => $button, 
			colour => $b->{'colour'}, 
			rgb => $b->{'rgb'},
		};

		my $insert = &Manager::appointment_writer($c,$db_data);
	}
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid . '\');' });
	my $od = encode_json $watch_settings;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $od, subsetting => $chip_id });
	return $returner;
}

sub device_lister() {
	my ($timestamp,$load_type,$ip_range,$chip_id) = @_;
	my ($db,$database,$sql) = &subs::database_grabber();
	my ($dev,$devices,@domains);
	my $user_agent = $gb::user_agent;
	my $server_time = &subs::rightNow();
	my $remote_machinery = &subs::db_query('select * from remote_machines');
	my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my $signatorial = &subs::signatorial_designer();
	my $remote_machines = $remote_machinery->hashes;
	my $chip_ids = [];
	if ($load_type eq 'scan') {
		$dev = &subs::db_select('devices');
		$devices = $dev->hashes;
		my $ug    = Data::UUID->new;
		my $uuid = $ug->create_str();
		foreach my $d (@{$devices}) {
			if (scalar @{$devices} > 0) {
				$d->{'address'} = eval { return decode_json $d->{'address'} };
				if ($d->{'domain'} ne '') {
					push @domains, { 'domain' => $d->{'domain'} . ' lladdr ' . 'mac_ave', hostname => $d->{'hostname'} };
				}
			}
		}
		my $hostname = `hostname`;
		my @me_device = grep { $_->{'hostname'} eq $hostname } @{$devices};
		chomp $hostname;
		my $uname = `uname -a`;
		chomp $uname;
		my $username = 'jawn';#`whoami`;
		chomp $username;
		
		my $name = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || $hostname;
		my $cpuinfo = `cat /proc/cpuinfo`;
		chomp $cpuinfo;
		my @ifconfig = split "\n\n", `ifconfig`;
		my @ifconfig_link;
		my @ifconfig_inet;
		my $address = {};
		my $count = {};
		my $home_ip;
		foreach my $if (@ifconfig) {
			my @ifconfig_list = split "\n", $if;

			@ifconfig_inet = grep { $_ =~ /inet/ } @ifconfig_list;

			my $nic = (split ' ', $ifconfig_list[0])[0];
			$nic =~ s/://;
			$address->{$nic}->{'nic'} = $nic;
			my $gw = '$(ip route show 0.0.0.0/0 dev ' . $address->{$nic}->{'nic'} . ' | cut -d\  -f3)';
			$address->{$nic}->{'gw'} = `echo $gw`;
			chomp $address->{$nic}->{'gw'};
			if ($device eq 'computer') {
				my $gw_mac = 'arp -a ' . $gw . '  | grep ' . $address->{$nic}->{'nic'};
				$gw_mac = `$gw_mac`;
				$address->{$nic}->{'gw_mac'} = (split ' ', $gw_mac)[3] if $gw && $device eq 'computer';
			}
			foreach my $i (@ifconfig_inet) {
				my @inet = split " ", $i;
				if ($i =~ /inet /) {
					$address->{$nic}->{'ip'} = $inet[1];
					$address->{$nic}->{'port'} = $ENV{PORT_AHOY};
					$address->{$nic}->{'ws_port'} = $ENV{PORT_MSG};
					$address->{$nic}->{'alarm_port'} = $ENV{PORT_BELL};
					$address->{$nic}->{'manager'} = 'https://' . $inet[1] . ':' . $ENV{PORT_DOCK} .  '/manager';
					$address->{$nic}->{'netmask'} = $inet[3];
					$address->{$nic}->{'broadcast'} = $inet[5];

					my @neighbours;
					my $neighbour_check = `ip neigh show dev $nic`;
					my @neighbourinos = (split "\n", $neighbour_check);
					if ($neighbour_check eq '' && $ip_range && $nic ne 'lo') {
						my $sip = $ip_range;
						$sip =~ s/[0-9]//gi;
						$home_ip = $address->{$nic}->{'ip'};
						my @home_ip = split '\.', $home_ip;
						my @csv = split ',', $ip_range;
						my @ip = split '\.', $ip_range;
						if (scalar @ip == 4) {
							push @neighbourinos, $ip_range . ' ' . &subs::random_string_creator(5);
						}
						else {
							if (scalar @csv > 1) {
								foreach my $csv (@csv) {
									pop @home_ip;
									push @home_ip, $csv;
									push @neighbourinos, (join '.', @home_ip) . ' ' . &subs::random_string_creator(5);
								}
							}
							elsif ($sip eq '..' ) {
								my @sips = split '\.\.', $ip_range;
							
								foreach my $csv ( $sips[0] .. $sips[1] ) {
									pop @home_ip;
									push @home_ip, $csv;
									push @neighbourinos, (join '.', @home_ip ). ' ' . &subs::random_string_creator(5);
								}
							}
						}
					}
					foreach my $do ( @domains ) {
						push @neighbourinos, $do->{'domain'} if $do->{'hostname'} eq $hostname;
					}
					foreach my $m ( @neighbourinos ) {
						next if $m =~ /FAILED/;
						my @l = (split " ", $m);
						my $n = {
							ip => $l[0],
							mac => $l[2] || &subs::random_string_creator(10)
						};
						my $ping_ip = $n->{'ip'};
						my $alive = `timeout .4 ping -c 1 $ping_ip`;
						if ( $n->{'ip'} && $alive =~ /ttl/gi && $n->{'ip'} ne $address->{$nic}->{'ip'}) {

							my $ua = Mojo::UserAgent->new();
							$ua->inactivity_timeout(3);
							my $manager = 'https://' . $n->{'ip'} . ':' . $ENV{PORT_DOCK} .  '/manager';
							my $res = eval { $ua->insecure(1)->get($manager . '/gate?restore_list=' . $config->{'start_dir'} . '&neighbour=' . $hostname . '&my_name=' . $my_name . '&signatorial=' . $signatorial => {user_agent => $user_agent})->result };

							if (eval { $res->is_success }){

								if (eval { decode_json $res->body }) {
									my $rb = decode_json $res->body;
									$n->{'purpose'} = $rb->{'purpose'};
									$n->{'restore_list'} = encode_json $rb->{'restore_list'};
								}
								$n->{'manager'} = $manager;
							}
							else {
								my $manager = 'http://' . $n->{'ip'} . ':' . $ENV{PORT_DOCK} .  '/device_query';
								my $res = eval { $ua->insecure(1)->get($manager) };
								if (eval { $res->result->body }) {
									if (eval { decode_json $res->result->body }) {
										my $rb = decode_json $res->result->body;
										$n->{'purpose'} = $rb->{'purpose'};
										$n->{'model'} = $rb->{'model'};
										$n->{'pins'} = $rb->{'pins'} if $rb->{'pins'};
										$n->{'name'} = $rb->{'name'} if $rb->{'name'};
										$n->{'chip_id'} = $rb->{'chip_id'};
										push @{$chip_ids}, { id => $n->{'chip_id'}, name => $n->{'name'}, purpose => $n->{'purpose'}, server_time => &subs::rightNow() };
									}
								}
								else {
									$n->{'purpose'} = 'hmmm';
								}
							}

							foreach my $d (@{$devices}) {
								foreach my $a (keys %{$d->{'address'}} ) {
									foreach my $g (grep { $_->{'ip'} eq $n->{'ip'} || $_->{'ip_address'} eq $n->{'ip'} } @{$d->{'address'}->{$a}->{'neigh'}} ) {
										$g->{'ip'} =~ /([0-9]+)$/gi;
										my $last_d = $1;
										$n->{'ip'} =~ /([0-9]+)$/gi;
										my $last_n = $1;
										$n->{'fqdn'} = $g->{'fqdn'};
										$n->{'ip_address'} = $g->{'ip_address'};
										if ($g->{'purpose'} && !$n->{'purpose'}){# && $last_d == $last_n) {
											$n->{'purpose'} = $g->{'purpose'};
										}
										if ($g->{'locked'} eq 'yes') {
											$n = $g;
										}
									}
								}
							}
						push @neighbours, $n;
						}


					}
					@{$address->{$nic}->{'neigh'}} = @neighbours;
				}
				if ($i =~ /inet6 /) {
					$address->{$nic}->{'ip6'} = $inet[1];
				}
			}
			@ifconfig_link = grep { $_ =~ /ether/ } @ifconfig_list;
			foreach my $m (@ifconfig_link) {
				my @mac = split " ", $m;
				if ($m =~ /ether/) {
					$address->{$nic}->{'mac'} = $mac[1];
				}
			}
			#here

			foreach my $d (@{$devices}) {
				foreach my $a (keys %{$d->{'address'}} ) {
					if ($d->{'address'}->{$nic}->{'neigh'} && $a eq $nic) {
						foreach my $rd ( @{$d->{'address'}->{$nic}->{'neigh'}} ) {
							if ($rd->{'locked'} eq 'yes') {
								@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $rd->{'ip'} } @{$address->{$nic}->{'neigh'}};
								push @{$address->{$nic}->{'neigh'}}, $rd;
							}
						}
					}
				}
			}
		}

		my $json_address = encode_json $address;

		my @my_device = grep { ($_->{'hostname'} && $_->{'hostname'} eq $hostname) && ($_->{'uname'} && $_->{'uname'} eq $uname) } @{$devices};
		my $president = $database;


		my $oldjchips = $my_device[0]->{'chip_ids'};
		my $oldchips = eval { return decode_json $oldjchips } || [];
		if (scalar @{$oldchips} > 0) {
			foreach my $ci ( @{$oldchips} ) {
				push @{$chip_ids}, $ci unless grep { $_->{'id'} eq $ci->{'id'} } @{$chip_ids};
			}
		}
		my $jchips = encode_json $chip_ids;

		my $me = { 
			timestamp => $timestamp,
			hostname => $hostname, 
			uname => $uname,
			address => $json_address,
			protocol => 'https', 
			port => $ENV{PORT_AHOY},
			server_time => $server_time,
			president => $president,
			uuid => $uuid,
			chip_ids => $jchips
		};
		if (scalar @my_device == 0 || scalar @{$devices} == 0) {
			$log->info('never seen');
			&subs::db_insert('devices', $me);
		}
		else {
			$log->info('been seen');
			&subs::db_update('devices', { chip_ids => $jchips, address => $json_address, timestamp => $timestamp }, { hostname => $hostname, uname => $uname });
		}
	}
	$dev = &subs::db_select('devices');
	$devices = $dev->hashes;
	my $all_chips = [];
	foreach my $d (@{$devices}) {
		$d->{'address'} = decode_json $d->{'address'} if $d->{'address'};
		$d->{'formatted_time'} = &subs::formatted_time($d->{'timestamp'});
		foreach my $a ( keys %{$d->{'address'}} ) {
			foreach my $n ( @{$d->{'address'}->{$a}->{'neigh'}} ) {
				if (my @pool = grep { $d->{'address'}->{$_}->{'ip'} eq $n->{'ip'} } keys %{$d->{'address'}} ) {
					$n->{'me'} = 'me';
				}
				if ($load_type eq 'watch' && $n->{'purpose'} eq 'watch') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'microcontroller' && $n->{'purpose'} eq 'microcontroller') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'printer' && $n->{'purpose'} eq 'printer') {
					return $n;
				}
				if ($load_type eq 'teletype' && $n->{'purpose'} eq 'teletype') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'computer' && $n->{'purpose'} eq 'computer') {
					$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
					return $n;
				}
				if ($load_type eq 'mobile' && $n->{'purpose'} eq 'mobile') {
					$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
					return $n;
				}
				if ($gb::remote->{$n->{'ip'}} ) {
					my @rem = grep { $_->{'ip'} eq $n->{'ip'} } @{$remote_machines};
					$n->{'button'} = $rem[0]->{'buttons'};
				}
			}
		}
	}
	if (scalar @{$all_chips} > 0) {
		return $all_chips;
	}
	return $devices;
}


sub backup_now() {
	my $c = shift;
	my $start_time = &subs::rightNow();
	my $uuid = &subs::random_string_creator(25);
	my $reason = $c->param('reason') || 'unknown';
	return unless $reason ne 'unknown';
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();

	my $t = localtime;
	my $databaser = $database;
	$databaser =~ s/.db$//gi;
	my $server_time = &subs::rightNow();
	my $filename = &subs::unformat_name( $databaser );
	$databaser =~ s/_\d+$//;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my $appendage = $gb::universal_splitter . &subs::encrypter($c->session('suds'),$encryption_standard);
	my $path = $databaser;
	my $temporary_path = $path . &subs::random_string_creator() . '.sql';
	my $enc_file = $path . '.enc';
	my $signatorial = &subs::signatorial_designer();
	my $initializer = 1;

	my $size = -s $database;
	&subs::db_delete('cache', { context => 'template' });
	&subs::db_delete('cache', { context => 'header' });
	
	&subs::db_query('VACUUM');
	my $duration = &subs::rightNow() - $start_time;
#	&appointment_writer($c,{
#		app => 'customs',
#		type => 'backup',
#		timestamp => $timestamp,
#		duration => $duration,
#		file => $path
#	});
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);

	my $secret = &subs::decrypter($c->session('suds'),&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});

	my $ld_server_time = &subs::rightNow();

	if ($reason eq 'remote_update') {
		my $last_updated = &subs::db_query('select * from backups where reason=? and recipient = ? and signatorial = ? order by server_time DESC', 'remote_update',$c->param('signatorial'), $signatorial)->hashes->[0];
		my $last_update = 10;
		if ($c->param('gimme') =~ /[0-9]/gi) {
			$last_update = $c->param('gimme');
			$ld_server_time = $last_update;
		}
		elsif ($last_updated->{'server_time'}) {
			$last_update = $last_updated->{'server_time'};
			$ld_server_time = $last_update;
		}
		my $tables = `sqlite3 $database .tables`;
		my @tables = sort split ' ', $tables;
		my $schema_file = $temporary_path . '.schema.sql';
		`sqlite3 $database .schema > $schema_file`;
		my $command = `sqlite3 $temporary_path < $schema_file`;
		`shred -u $schema_file`;
#		my $backup = `sqlite3 $database .schema $temporary_path`;
		my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_path);
		my $tdb = $tsql->db;

		foreach my $t ( @{$gb::forbidden->{'tables'}} ) {
			@tables = grep { $_ ne $t } @tables;
			$tdb->query('DROP TABLE ' . $t);
		}

		foreach my $d ( @tables ) {
			next if grep { $_ eq $d } @{$gb::forbidden->{'tables'}};
			my $new_data = &subs::db_query('select * from ' . $d . ' where server_time >= ?', $ld_server_time)->hashes;
#			$tdb->query('delete from ' . $d . ' where server_time < ?', $ld_server_time);
			foreach my $nd ( @{$new_data} ) {
				$tdb->insert($d, $nd);
			}
		}
		$tdb->query('VACUUM');

	}
	else {
		my $backup = `sqlite3 $database ".backup '$temporary_path'"`;

	}
	my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_path);
	my $tdb = $tsql->db;
	my $indexes = $tdb->query('select * from sqlite_master where name not like ? and type=?', '%autoindex%', 'index')->hashes;
	foreach my $index ( @{$indexes} ) {
		$tdb->query('DROP INDEX ' .  $index->{'name'});
	}
	$tdb->query('VACUUM');
	my $archive_path = $path . '_' . $timestamp;
	my $encrypt =	`openssl enc -e -k "$secret" -$encryption_standard -pbkdf2 -in $temporary_path -out $archive_path.enc`;
	my $stat_path = `stat $temporary_path`;
	`echo "$appendage" >> $archive_path.enc`;
	if ($reason eq 'remote_update') {
		my $defunct_backups = &subs::db_query('select * from backups where recipient = ? and signatorial = ? and ost <= ?', $c->param('signatorial'), $signatorial, $ld_server_time)->hashes; 
		foreach my $defb ( @{$defunct_backups} ) {
			if ($defb->{'enc_file'} && -e $defb->{'enc_file'}) {
				my $delb = $defb->{'enc_file'};
				`shred -u $delb`;
			}
		}
		my $last_updated = &subs::db_query('delete from backups where recipient = ? and signatorial = ? and ost <= ?', $c->param('signatorial'), $signatorial, $ld_server_time); 
	}
	else {
		my $archive_encrypt = `cp -v $archive_path.enc $enc_file`;
	}
	`shred -u $temporary_path*`;

	my $max_backups = &Manager::misc_setting_list()->{$device}->{'max_backups'} || 3;
	my $backup_list_command = 'ls -t ' . $path . '_*.enc';
	my $backups = `$backup_list_command`;

	my @backups = split "\n", $backups;
	@backups = grep { $_ ne $enc_file } @backups;
	if (scalar @backups > $max_backups) {
		for (my $n = $max_backups; $n < scalar @backups; $n++) {
			my $shredder = 'shred -u ' . $backups[$n];
			my $backs = &subs::db_select('backups', undef, { enc_file => $backups[$n] })->hashes;
			foreach my $ba ( @{$backs} ) { 
				&Manager::deletion_registration({ table => 'backups', uuid => $ba->{'uuid'}, scope => 'single', server_time => $ba->{'server_time'} });
			}
			&subs::db_delete('backups', { enc_file => $backups[$n] });
			`$shredder`;
		}
	}

	&Websocket::send('tab', { type => 'event', timestamp => $timestamp });
	my @folder = split '/', $archive_path;
	my $archive_name = pop @folder;
	my $folder = join '/', @folder;
	@folder = split '/', $path;
	my $current_name = pop @folder;
	my $backup_data = { 
		timestamp => $timestamp, 
		server_time => $server_time, 
		size => $size, 
		signatorial => $signatorial, 
		destination => $database,
		reason => $reason,
		enc_file => $archive_path . ".enc",
		recipient => $c->param('signatorial'),
		warranty => $warranty,
		uuid => $uuid
	};
	&subs::db_insert('backups',$backup_data);
	my $returner = { 
		database => $database,
		signatorial => $signatorial,
		folder => $folder,
		current => $current_name . ".enc",
		archive => $archive_name . ".enc",
		archive_path => $archive_path . ".enc",
		path => $enc_file,
		backup_data => $backup_data,
		misc_settings => &Manager::misc_setting_list(),
		home => &subs::home('~/'),
		device => $device,
		server_time => $server_time,
		uuid => $uuid,
		size => -s $archive_path . '.enc'
	};
	if ($reason ne 'remote_update') {
#		&subs::db_insert('appointments',{ 
#			warranty => $warranty, 
#			uuid => &subs::random_string_creator(40), 
#			app => "customs", 
#			type => "backup", 
#			timestamp => $timestamp, 
#			server_time => $server_time, 
#			duration => $duration, 
#			file => $archive_path . '.enc'
#		});
	}
	return $returner;
}


sub sms_list_check() {
my $returner = '';
	if ($device eq 'mobile') {
		my $timestamp = &subs::rightNow();
		my $c = app->build_controller;
		$gb::suds = &suds_grabber();
		$c->session('suds' => $gb::suds);
		my $json_list = `termux-sms-list -l 100 --message-sort-order="date DESC"` || '[]';
		my $list = decode_json $json_list;
		foreach my $l (grep { $_->{'type'} eq 'draft' || $_->{'type'} eq 'sent' || $_->{'type'} eq 'inbox' } @{$list}) {
			my $time = &subs::ago_calc($l->{'received'},$timestamp);
			my $phone = $l->{'number'};
			$phone =~ s/\D+//gi;
			$phone =~ s/^1//;
			$returner .= "Phone is " . $phone . "\n";
		#	$log->info(Dumper $l);
			my $res = &subs::db_query('select app from settings where setting = ? and value like ? and device = ?', 'phone', '%' . $phone, &subs::device_setter())->hashes;
			foreach my $r ( @{$res} ) {
				my $chats = &subs::db_select('mailbox', undef, { phone => $phone, timestamp => $time })->hashes;
				if ( scalar @{$chats} == 0) {
					$l->{'body'} =~ s/[^\x00-\x7F]+//gi;
					my $message = &subs::note_encrypter($gb::suds,$l->{'body'});
					my $sender = &subs::format_name($r->{'app'});
					&subs::db_insert('mailbox', {
						uuid => &subs::random_string_creator(44),
						timestamp => $time,
						server_time => &subs::rightNow(),
						body => $message,
						manager_file => $sender,
						status => $l->{'type'},
						phone => $phone,
					});
				}

				my $q = &subs::db_query('select * from appointments where app = ? and type = ? and timestamp = ?', $r->{'app'},'sms',$time);
				my $qu = $q->hashes;
				if ( scalar @{$qu} == 0 ) {
					$l->{'body'} =~ s/[^\x00-\x7F]+//gi;
					$returner .= "Phone: " . $phone . " - " . $r->{'app'} . "\n";
					&Manager::appointment_writer($c,{
						app => &subs::unformat_name($r->{'app'}),
						timestamp => $time || $timestamp,
						type => 'sms',
						notes => &subs::note_encrypter($c->session('suds'),&subs::format_name($l->{'type'}) . ": " . $l->{'body'}),
						duration => 5000
					});
				}
				else {
					$returner .= "Seen " . $phone . " at " . $l->{'received'} . " from " . $r->{'app'} . " already\n";
				}
			}
		}
	}
	return $returner;
}

sub encrypter() {
	my ($numerics,$content) = @_;
	use Crypt::Simple passphrase => $numerics;
	my $notes = encrypt($content) if eval { encrypt($content) };
	return $notes;
}
sub decrypter() {
	my ($secret,$content) = @_;
	use Crypt::Simple passphrase => $secret;
	my $notes = decrypt($content) if eval { decrypt($content) };
	return $notes;
}

sub note_encrypter() {
	my ($secret,$content) = @_;
	if ($content) {
		$content =~ s/\"/\\\"/gi;
		my $md5 = md5_sum $content;
		$md5 = &shorthand_name($md5, 5);
		my $encryption_standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
		my $encrypted = `(echo "$content") | openssl enc -e -k "$secret" -$encryption_standard -pbkdf2 | base64 -w 0`;
		my $almost_ready = $encrypted . ':::---:::' . $encryption_standard . ':::---:::' . $md5;
		my $returner = &subs::encrypter($secret, $almost_ready);
		return $returner;
	}
}

sub note_decrypter() {
	my ($secret,$contented, $timestamp,$tries) = @_;
	my $sc = [];
	if ($timestamp) {
		my $q = &db_query('select * from security where level != ? and ost <= ? order by ost desc', 'padlock', $timestamp);
		$sc = $q->hashes;
	}
	if ($contented) {
		if (scalar @{$sc} > 0) {
			foreach my $s ( @{$sc} ) {
				my $tsecret = &decrypter($secret, $s->{'credential'} );
				my $content = &subs::decrypter($tsecret, $contented);
				my @returns = split ':::---:::', $content;
				my $encryption_standard = $returns[1];
				$content = $returns[0];
				my $returner = `(echo $content) | base64 --decode | openssl enc -d -k "$tsecret" -$encryption_standard -pbkdf2`;
				chomp $returner;
				if ($returner =~ /[A-Za-z0-9]/gi) {
					my $md5 = md5_sum $returner;
					if ($returns[2] && &shorthand_name($md5, 5) eq &shorthand_name($returns[2],5)) {
						return $returner;
					}
					elsif ($returns[2]) {
						next;
					}
					elsif ($returner !~ /[^\x00-\x7F]+/) {
						return $returner;
					}
				}
			}
		}
		else {
			my $content = &subs::decrypter($secret, $contented);
			my @returns = split ':::---:::', $content;
			my $encryption_standard = $returns[1];
			$content = $returns[0];
			my $returner = `(echo $content) | base64 --decode | openssl enc -d -k "$secret" -$encryption_standard -pbkdf2`;
			if ($returns[2] && md5_sum $returner eq $returns[2]) {
				chomp $returner;
				return $returner;
			}
			elsif ($returns[2]) {
				next;
			}
			elsif ($returner !~ /[^\x00-\x7F]+/) {
				chomp $returner;
				return $returner;
			}
			else {
				if ($tries <= 2) {
					return &note_decrypter($secret,$contented,&subs::rightNow() * 10000, $tries + 1);
				}
			}
		}
	}
	return '';
}

sub manufacturer_grabber() {
	my $manufacturers = &subs::db_select('settings', undef, { setting => 'pos', value => 'manufacturer', device => $device })->hashes;
	my $mans = [];
	foreach my $m ( @{$manufacturers} ) {
		push @{$mans}, $m->{'app'};
	}
	$gb::abilities->{'manufacturer'}->{'options'} = $mans;
}

sub embedded_internal_jobs() {
	my $op_d = shift;
	foreach my $k ( keys %{$op_d} ) {
		if ($gb::embedded_components->{$op_d->{$k}->{'component'}}->{'direction'} eq 'input') {
			foreach my $ko ( keys %{$op_d} ) {
				if ($op_d->{$ko}->{'app'} eq $op_d->{$k}->{'app'} && $gb::embedded_components->{$op_d->{$ko}->{'component'}}->{'direction'} eq 'output') {
					$op_d->{'__specs'}->{'internal_jobs'}->{$k} = [] if !$op_d->{'__specs'}->{'internal_jobs'}->{$k};
					push @{$op_d->{'__specs'}->{'internal_jobs'}->{$k}}, $op_d->{$ko};
				}
			}
		}
	}
	return $op_d;
}

sub intelligent_automation_toggle() {
	my $data = shift;
	my $app = $data->{'app'};
	my $state = $data->{'state'};
	my $appt_uuid = $data->{'appt_uuid'};
	my $uuid = $data->{'uuid'};
	my $value = $data->{'value'};
	my $type = $data->{'type'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $remote_address = $data->{'remote_address'};
	my $now = &subs::rightNow();
	my $measure = $data->{'measure'};
	my $asets = &subs::settings_grabber({ app => $app, settings => ['ia','toggle'] });
	my $jia = $asets->{'ia'};
	my $ia = eval { return decode_json $jia } || {};
	my $counted = 0;
	foreach my $chip ( keys %{$ia} ) {
		foreach my $i ( keys %{$ia->{$chip}} ) {
			next if $remote_address && $ia->{$chip}->{$i}->{'ip'} eq $remote_address;
			if ($ia->{$chip}->{$i}->{'direction'} eq 'output') {
				my $when = 'later';
				if ($timestamp <= $now + 1000) {
					$when = 'now';
				}

				if ($data->{'measure'} && $measure ne $ia->{$chip}->{$i}->{'measure'}) {
				#	return;
				}
				if ($ia->{$chip}->{$i}->{'movement'} eq 'start') {
					my $returner = &Manager::embedded_toggle({
						app => $app,
						pin => $ia->{$chip}->{$i}->{'pin'},
						ip => $ia->{$chip}->{$i}->{'ip'},
						edt => $ia->{$chip}->{$i}->{'edt'},
						component => $ia->{$chip}->{$i}->{'component'},
						timestamp => $timestamp,
						'state' => $state,
						measure => $measure,
						chip_id => $chip,
						'when' => $when,
						uuid => $uuid,
						appt_uuid => $appt_uuid,
						value => $data->{'value'},
						counted => $counted
					});
				}
				elsif ($ia->{$chip}->{$i}->{'movement'} eq 'measure') {
					my $edt_data = {
						app => $app,
						pin => $ia->{$chip}->{$i}->{'pin'},
						ip => $ia->{$chip}->{$i}->{'ip'},
						edt => $ia->{$chip}->{$i}->{'edt'},
						component => $ia->{$chip}->{$i}->{'component'},
						timestamp => $timestamp,
						'state' => $state,
						measure => $measure,
						chip_id => $chip,
						'when' => $when,
						uuid => $uuid,
						appt_uuid => $appt_uuid,
						value => $data->{'value'},
						counted => $counted
					};
					if ($type eq 'text') {
						if ($data->{'measurement'} && $ia->{$chip}->{$i}->{'named_measure'}) {
							if ($data->{'measurement'} eq $ia->{$chip}->{$i}->{'named_measure'}) {
								$edt_data->{'state'} = 'on';
							}
							else {
								$edt_data->{'state'} = 'off';
							}
						}
					}
					else {
						if ($data->{'measurement'} && $ia->{$chip}->{$i}->{'threshold'}) {
							if ($ia->{$chip}->{$i}->{'comparison'} eq '>') {
								if ($data->{'measurement'} > $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '>=') {
								if ($data->{'measurement'} >= $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '<=') {
								if ($data->{'measurement'} <= $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '<') {
								if ($data->{'measurement'} < $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							}
							else {
								if ($data->{'measurement'} == $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							}
							&Manager::embedded_toggle($edt_data);
							$counted++;
						}
					}
				}
			}

		}
	}

}

sub setting_setter() {
	my $settings = shift;
	my $app = $settings->{'app'};
	my $original_app = $app;
	my $setting = $settings->{'setting'};
	my $subsetting = $settings->{'subsetting'};
	my $value = $settings->{'value'};
	my $timestamp = $settings->{'timestamp'} || &rightNow();
	my $browser_tab_id = $settings->{'browser_tab_id'};
	my $dev = $settings->{'device'} || &device_setter();
	my ($db,$database) = &database_grabber();
	my $server_time = $settings->{'server_time'} || &rightNow();
	if ($setting eq 'name_change') {
		$value = &subs::unformat_name($value);
		&db_update('appointments', { account => $value, server_time => $server_time }, { account => $app });
		&db_update('appointments', { project => $value, server_time => $server_time }, { project => $app });
		&db_update('appointments', { manufacturer => $value, server_time => $server_time }, { manufacturer => $app });
		&db_update('appointments', { app => $value, server_time => $server_time }, { app => $app });
		&db_update('settings', { app => $value, server_time => $server_time }, { app => $app });

		foreach my $ex ( qw/model option subcategory option_category/ ) {
			&db_update($ex, { name => $value }, { name => $app });
		}


		my ($db,$database,$sql) = &database_grabber();
		my $tables = `sqlite3 $database .tables`;
		my @u = sort split ' ', $tables;
		foreach my $t ( @u ) {
			if (eval { $db->query('select app from ' . $t . ' limit 1') } ) {
				&db_update($t, { app => $value, server_time => $server_time }, { app => $app });
			}
			else {

			}
		}
		&Websocket::send('server', { console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });
		&Websocket::send('server', { console => 'appointmentGrabber(\'' . $value . '\',\'' . $timestamp .'\',\'ws\');'});
		$app = $value;
	}
	if ($setting eq 'pos') {
		&subs::manufacturer_grabber();
		my $old_settings = &subs::settings_grabber({ app => $app });
		my $old_sc = &subs::db_query('select * from settings where app=? and setting like ? escape ?', $app, 'sc\_%', '\\')->hashes;
		my $buc = &subs::cache_get({ app => 'relational', context => 'buckets' });
		my $bub = &subs::cache_get({ app => 'relational', context => 'bubbles' });

		foreach my $os ( @{$old_sc} ) {

			my $osc = eval { return decode_json $os->{'value'} } || [];
			foreach my $sc ( @{$osc} ) {
				my $set = &subs::settings_grabber({ uuid => $sc });
				delete $buc->{$set->{'app'}};
				delete $bub->{$set->{'app'}};
				my $otsc = eval { return decode_json $set->{'sc_' . $old_settings->{'pos'}} } || [];
				if (scalar @{$otsc} > 0) {
					@{$otsc} = grep { $_ ne $old_settings->{'uuid'} } @{$otsc};
					my $jotsc = encode_json $otsc;

					&subs::setting_setter({ app => $set->{'app'}, setting => 'sc_' . $old_settings->{'pos'}, value => $jotsc });
				}
				my $ntsc = eval { return decode_json $set->{'sc_' . $value} } || [];
				push @{$ntsc}, $old_settings->{'uuid'};
				my $jntsc = encode_json $ntsc;
				&subs::setting_setter({ app => $set->{'app'}, setting => 'sc_' . $value, value => $jntsc });

			}
			delete $buc->{$original_app};
			delete $bub->{$original_app};
			&subs::cache_set({ app => 'relational', context => 'buckets', warranty => '-5y'}, $buc);
			&subs::cache_set({ app => 'relational', context => 'bubbles', warranty => '-5y'}, $bub);
		}
	}
	if ($setting eq 'phone') {
		$value =~ s/\D+//gi;
	}
	if ($setting eq 'web') {
		if ($value =~ /[0-9A-Za-z]/) {
			&Websocket::send('server', { console => '$(\'.app_act[app="' . $app . '"][type="web"]\').attr(\'web\', \'' . $value . '\').show();' });
		}
		else {
			&Websocket::send('server', { console => '$(\'.app_act[app="' . $app . '"][type="web"]\').attr(\'web\', \'\').hide();' });
		}
	}
	if ($setting eq 'colour' || $setting eq 'name_change' || $setting eq 'mab') {
		my $buc = &subs::cache_get({ app => 'relational', context => 'buckets' });
		my $bub = &subs::cache_get({ app => 'relational', context => 'bubbles' });
		delete $buc->{$original_app};
		delete $bub->{$original_app};
		&subs::cache_set({ app => 'relational', context => 'buckets', warranty => '-5y'}, $buc);
		&subs::cache_set({ app => 'relational', context => 'bubbles', warranty => '-5y'}, $bub);
	}
	if ($setting eq 'toggle' && $settings->{'source'} eq 'panel') {
		&intelligent_automation_toggle({ app => $app });
	}

	if ($setting eq 'uuid') {
		my $s_old = &db_select('settings', undef, { app => $app, setting => $setting, device => $dev })->hashes->[0];
		if ($s_old->{'value'}) {
			return { app => $app, timestamp => $timestamp, setting => $setting, value => $s_old->{'value'}, device => $dev, browser_tab_id => $browser_tab_id };
		}
	}

	my $old_set = &db_delete('settings', { app => $app, setting => $setting, device => $dev, subsetting => $subsetting });
	&db_insert('settings', {
		app => $app,
		timestamp => $timestamp,
		setting => $setting,
		value => $value,
		server_time => $server_time,
		device => $dev,
		browser_tab_id => $browser_tab_id,
		uuid => $settings->{'uuid'} || &random_string_creator(25),
		subsetting => $subsetting
	});
	if ($setting eq 'colour') {
		&Websocket::send('server', { console => '$(\'.top_navbar[app="' . $app . '"]\').css({\'background-color\':\'' . $value . '\'});' });
	}
	return { app => $app, timestamp => $timestamp, setting => $setting, value => $value, device => $dev, browser_tab_id => $browser_tab_id };
}

sub setting_grabber() {
	my $settings = shift;
	if ($settings->{'uuid'}) {
		my $s = &subs::db_select('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}

	my $app = $settings->{'app'};
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	$settings->{'device'} = $settings->{'device'} || &device_setter();
	my $returner;

	if (my $q = eval { return &db_select('settings', ['value'], $settings) }) {
		my $list = $q->hashes;

		if (scalar @{$list} > 1) {
			$returner = $list->[-1]->{'value'};
		}
		else {
			$returner = $list->[0]->{'value'};
		}
	}
	return $returner;
}

sub settings_grabber() {
	my $settings = shift;
#	return {};

	if ($settings->{'uuid'}) {
		my $s = &subs::db_select('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}


	my $app = $settings->{'app'};
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	$settings->{'device'} = $settings->{'device'} || &device_setter();
#	$settings->{'device'} = $device unless $settings->{'device'} ne '';
	my $returner = { app => $app };

	my $query = 'select * from settings where app=? and device=?';
	my $q;
	if ($settings->{'settings'}) {
		if (scalar @{$settings->{'settings'}}) {
			
			my $query = 'select * from settings where app=? and device=? and ( ';
			for (my $n = 0; $n <= scalar @{$settings->{'settings'}}; $n++) {
				if ($n == scalar @{$settings->{'settings'}}) {
					$query .= ' setting = ? ';
				} else {
					$query .= ' setting = ? or ';
				}

			}
			$query .= ')';
			$q = &db_query($query, $app,$settings->{'device'}, @{$settings->{'settings'}});
		}
	}
	else {
		$q = &db_query($query, $app,$settings->{'device'});
	}
	my $list = $q->hashes;
	if ($settings->{'subsetting'}) {
		@{$list} = grep { $_->{'subsetting'} eq $settings->{'subsetting'} } @{$list};
	}
	foreach my $s ( @{$list } ) {
		$returner->{$s->{'setting'}} = $s->{'value'};
	}
	unless ($device_defined == 1 && $returner->{$settings->{'setting'}}) {
		my $qe = &db_query('select * from settings where app=?', $app);
		my $liste = $q->hashes;
		foreach my $s (@{$liste}) {
			unless ($returner->{$s->{'setting'}}) {
				$returner->{$s->{'setting'}} = $s->{'value'};
			}
		}
	}
	unless ($returner->{'uuid'}) {
		if ($settings->{'benign'} != 1) {
			my $uuid = &random_string_creator(25);
			$returner->{'uuid'} = $uuid;
			&setting_setter({ app => $app, setting => 'uuid', subsetting => $settings->{'subsetting'}, value => $uuid });
		}
	}
	return $returner;
}

sub setting_deleter() {
	my $setting = shift;
	$setting->{'device'} = $setting->{'device'} || &device_setter();
	&db_delete('settings',{ app => $setting->{'app'}, setting => $setting->{'setting'}, subsetting => $setting->{'subsetting'}, device => $setting->{'device'} });
	return $setting;
}


sub file_encrypter() {
	my $data = shift;

	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $suds = $data->{'suds'} || &subs::suds_grabber();
	my $pre_server_time = &subs::ago_calc('1h', &subs::rightNow());
	my $file_db = &subs::db_query('select * from appointments where app=? and file != ? and (encryption_standard is null or server_time >= ?)', $app,'',$pre_server_time);
	my $filings = $file_db->hashes;
	my $server_time = &subs::rightNow();
	return unless &subs::setting_grabber({ app => $app, setting => 'enc' } ) eq 'on';
	my $success = 0;
	my $file_join;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";

	foreach my $filing ( @{$filings} ) {
		my $files = eval { return decode_json $filing->{'file'} } || [];
		if (eval { $files->{'f'} }) {
			$files = [ $files ];
		}
		foreach my $fi ( @{$files} ) {
			foreach my $file_type ( qw/f thumb/ ) { 
				my $f = $fi->{$file_type};

				if (-e $f && $f !~ /\.enc/gi) {

					my $path = &subs::terminal_name($f);
					my $enc_path = $path;
					my @enc_path = split '/', $enc_path;
					my @ext = split /\./, $enc_path[-1];
					my $ext = $ext[-1];
					my $original_filename = pop @enc_path;
					$enc_path = ( join '/', @enc_path ) . '/' . &subs::random_string_creator(20) . '.' . $ext . '.enc';
					my $secret = $suds;
					# first, store the encryption standard.

					my $encrypt =	`openssl enc -e -k "$secret" -$encryption_standard -pbkdf2 -in $path -out $enc_path`;
					`shred -u $path`;
					$f = $enc_path;
					$fi->{$file_type} = $f;
					$fi->{'server_time'} = &subs::rightNow();
					$fi->{'uuid'} = &subs::random_string_creator(17) unless $fi->{'uuid'};
					if ($file_type eq 'f') {
						$fi->{'of'} = $original_filename;
						
						if ($fi->{'att'}) {
							my $att_file = &subs::db_select($fi->{'att'}, undef, { uuid => $fi->{'att_uuid'}, app => $app })->hashes->[0];

							my $atf = eval { return decode_json $att_file->{'file'} } || [];
							foreach my $af ( @{$atf} ) {
								if ($af->{'uuid'} eq $fi->{'uuid'}) {
									$af->{'f'} = $f;
									$af->{'server_time'} = &subs::rightNow();
									$af->{'of'} = $original_filename;
								}
							}
							my $jaf = encode_json $atf;
							&subs::db_update($fi->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
						}
					}
					$success = 1;
				}
			}
		}
		$file_join = encode_json $files;
		if ($success == 1) {
			&subs::db_query('update appointments set server_time = ?, file = ?, encryption_standard = ? where app= ? and uuid = ?',
				&subs::rightNow(), $file_join, $encryption_standard, $app, $filing->{'uuid'});
			&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $filing->{'uuid'} .'\');'});
		}

	}
}


sub file_decrypter() {
	my $data = shift;
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $suds = $data->{'suds'};
	my $file_db = &subs::db_query('select * from appointments where app=? and file is not null', $app);
	my $filings = $file_db->hashes;
	my $success = 0;
	my $file_join;
	my $server_time = &subs::rightNow();
	foreach my $filing ( @{$filings} ) {
		my $files = eval { return decode_json $filing->{'file'} } || [];
		foreach my $fi ( @{$files} ) {
			foreach my $file_type ( qw/f thumb/ ) {
				my $f = $fi->{$file_type};
				if (-e $f && $f =~ /\.enc/gi) {
					my $encryption_standard = $filing->{'encryption_standard'};
					my $enc_path = &subs::terminal_name($f);


					my $path = $enc_path;
					if ($fi->{'of'}) {
						my @f = split '/', $path;
						pop @f;
						push @f, $fi->{'of'};
						$path = join '/', @f;
					}
					$path =~ s/\.enc$//gi;
					my $passwords = &subs::db_query('select * from security where level != ? order by server_time DESC','padlock');
					my $pwords = $passwords->hashes;

					foreach my $p ( @{$pwords} ) {
						my $secret = &subs::decrypter($suds, $p->{'credential'});

						my $data = `openssl enc -d -k "$secret" -$encryption_standard -pbkdf2 -in $enc_path`;
						my $ft = File::Type->new();
						my $type_from_data = $ft->mime_type($data);
						my $head = `echo "$data" | head`;

						if ($type_from_data ne 'application/octet-stream' || ($data =~ /webm/)) {

							my $o = `openssl enc -d -k "$secret" -$encryption_standard -pbkdf2 -in $enc_path -out $path`;
							$f = $path;
							`shred -u $enc_path`;
							$success = 1;
							last;
						}
					}



					$fi->{$file_type} = $f;
					$fi->{'server_time'} = &subs::rightNow();
					$fi->{'uuid'} = &subs::random_string_creator(7) unless $fi->{'uuid'};

					if ($fi->{'att'} && $file_type eq 'f') {
						my $att_file = &subs::db_select($fi->{'att'}, undef, { uuid => $fi->{'att_uuid'}, app => $app })->hashes->[0];
						my $atf = eval { return decode_json $att_file->{'file'} } || [];
						foreach my $af ( @{$atf} ) {
							if ($af->{'uuid'} eq $fi->{'uuid'}) {
								$af->{'f'} = $f;
								$af->{'server_time'} = &subs::rightNow();
							}
						}
						my $jaf = encode_json $atf;
						&subs::db_update($fi->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
					}

				}
			}

		}
		$file_join = encode_json $files;
		&subs::db_query('update appointments set server_time = ?, file = ?, encryption_standard = ? where app= ? and uuid = ?',
			&subs::rightNow(), $file_join, undef, $app, $filing->{'uuid'}) if $success == 1;
		&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $filing->{'uuid'} .'\');'});
	}
}





sub window_closer() {
	my $app = shift;
	my $browser_tab_id = shift;
	my $timestamp = &subs::rightNow();

	&Websocket::send('server', { browser_tab_id => $browser_tab_id, not_me => 1, console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });
	undef $gb::ws->{$app}->{$browser_tab_id};
}

sub config_reader() {
	foreach my $dt ( @gb::device_types ) {
		foreach my $k ( @gb::misc_settings ) {
			my $s = $k . "_background_colour";
			my $req = &db_query('select value from settings where setting = ? and app = ? and device = ?',$s,'misc',$dt);
			my $qu = $req->hashes;

			foreach my $q ( @{$qu } ) {
				$config->{$dt}->{$k}->{'background_colour'} = $q->{'value'} || $config->{$k}->{'background_colour'}
			}
		}
	}
	$config->{'device'} = &device_setter();
	return $config;
}


sub cache_set() {
	my ($params,$data) = @_;
	my $app = &subs::unformat_name($params->{'app'});
	my $context = $params->{'context'};
	my $subcontext = $params->{'subcontext'} || undef;
	my $timestamp = $params->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $json_data = encode_json $data;
	my ($db,$database,$sql) = &subs::database_grabber();
	&cache_delete({ app => $app, context => $context, subcontext => $subcontext });
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }), &subs::rightNow()) || &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', &subs::rightNow());
	if ($params->{'warranty'}) {
		$warranty = &subs::ago_calc($params->{'warranty'}, &subs::rightNow());
	}
	my $lid = undef;
	until ($lid) {
		my $success = eval { return &db_insert('cache', {
			app => $app,
			context => $context,
			subcontext => $subcontext,
			data => $json_data,
			timestamp => $timestamp,
			server_time => $server_time,
			warranty => $warranty,
			device => $device,
			uuid => &random_string_creator(25)
		}) };
		$lid = $success->last_insert_id;
	}
#	my $result = &db_select('cache', undef, $params);
#	return $result->hashes;
}

sub cache_delete() {
	my ($params) = @_;
	$params->{'device'} = $device;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $result = &db_delete('cache', $params);
}

sub cache_get() {
	my ($params) = @_;
	$params->{'device'} = $device;
	my $returner;
	my ($db,$database,$sql) = &subs::database_grabber();

	my $results = &db_select('cache', ['data'], $params);
	my $result = $results->hash;
	my $json_data = $result->{'data'};

	if ($result->{'data'}) { 
		$returner = decode_json $json_data;
		return $returner;
	}
}

sub file_device_renamer() {
	my $data = shift;
	my $file = $data->{'file'};
	my $app = $data->{'app'};
	my $is_thumb = $data->{'is_thumb'} || 0;
	undef $data->{'is_thumb'};
	my $misc_settings = $data->{'misc_settings'};
	my $type = $data->{'type'};

	my @f = split '/', $file;
	my $destination;
	my $asset = $f[-1];

	if ($f[-2] eq 'thumbs') {
		$is_thumb = 1;
	}
	my @asset = split /\./, $asset;
	my $assetual = $asset;
	$assetual =~ s/\.enc$//gi;
	my $ext = $asset[-1];
	if ($asset[-1] eq 'enc') {
		$ext = $asset[-2];
	}

	if ($type) {
		if ($type eq 'recording') {
			$type = 'rec';
		}
		elsif ($type eq 'image') {
			$type = 'photo';
		}
		elsif ($type eq 'audio') {
			$type = 'music';
		}
		if (my $location = &subs::setting_grabber({ app => 'misc', setting => $type . '_location', device => $device})) {
			$destination = &subs::home($location . '/' . $app . '/');
		}
	}


	unless ($destination) {
		$misc_settings = &Manager::misc_setting_list() unless $misc_settings;
		if ($assetual =~ /\.mp3$|\.m4a$|\.flac$|\.aiff$|\.weba$|\.wav$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'music_location'} . '/' . $app . '/');
			$type = 'audio';
		}
		elsif ($assetual =~ /\.jpg$|\.xcf$|\.png$|\.bmp$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'photo_location'} . '/' . $app . '/');
			$type = 'image';
		}
		elsif ($assetual =~ /\.mov$|\.avi|\.webm$|\.mp4$|\.mkv$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'video_location'} . '/' . $app . '/');
			$type = 'video';
		}
		elsif ($assetual =~ /\.pdf$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'document_location'} . '/' . $app . '/');
			$type = 'document';
		}
		else {
			$destination = &subs::home($misc_settings->{$device}->{'download_location'} . '/' . $app . '/');
			$type = 'software';
		}
	}
	if ($is_thumb == 1) {
		$destination = $destination . 'thumbs/';
	}
	return ($destination,$asset,$type);
}

sub file_media_information() {
	my $file_data = shift;
	my $file = shift || $file_data->{'f'};



	if ($file_data->{'type'} eq 'image') {
		my $command = 'ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 ' . $file;
		my $res = `$command`;
		chomp $res;
		my @res = split ',', $res;
		$file_data->{'info'} = { width => $res[0], height => $res[1] };
	}
	elsif ($file_data->{'type'} eq 'audio') {

		my $command = 'ffprobe -print_format json -show_entries stream=codec_name:format -select_streams a:0 -v quiet ' . $file;
	
		my $jres = `$command`;
		my $res = eval { return decode_json $jres } || {};
		my $format = $res->{'format'};
		if ($format->{'duration'}) {
			$file_data->{'info'} = $format;
		}
		else {
			my $command = 'ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 ' . $file;
			my $res = `$command`;
			chomp $res;
			my @res = split ',', $res;
			my $duration = $res[0];
			$file_data->{'info'} = { duration => $duration };
		}		
	}
	elsif ($file_data->{'type'} eq 'video') {
		my $command = 'ffprobe -print_format json -show_chapters -show_entries stream=height,width,duration,codec_name:format -select_streams v:0 -v quiet ' . $file;
		my $jres = `$command`;
		my $res = eval { return decode_json $jres } || {};
		my $format = $res->{'format'};
		my $chapters = $res->{'chapters'};

		$file_data->{'info'} = $format;
		$file_data->{'info'}->{'chapters'} = $chapters;
		foreach my $d ( @{$res->{'streams'}} ) {
			foreach my $dr ( keys %{$d} ) {
				$file_data->{'info'}->{$dr} = $d->{$dr};
			}
		}
	}
	return $file_data;
}


sub music_transmitter() {
	my $c = shift;
	my $data = shift;
	Mojo::IOLoop->subprocess->run_p(sub {
		my $file = $data->{'file'};
		my $domain = $data->{'domain'};
		my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
		my $remote_machines = &subs::db_query('select * from remote_machines where connection=?','active')->hashes;
		my $signatorial = &subs::signatorial_designer();
		my $toggle = $data->{'toggle'};
		my $seek = $data->{'seek'} || 0;
		my $volume = $data->{'volume'};
		my $timestamp = $data->{'timestamp'};
		my $music_data = $data->{'music_data'};
		my $queuing = $data->{'queuing'};
		foreach my $rm ( @{$remote_machines} ) {
			if ($domain eq $rm->{'fqdn'} || $domain eq $rm->{'ip'}) {
				my $address = $rm->{'fqdn'};
				my $ping = `timeout .5 ping -c 1 $address`;
				if ($ping =~ /ttl/gi) {
					$rm = &Manager::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $signatorial, rm => $rm });
					my $server_time = &subs::rightNow();
					$seek = $seek + (($server_time - $timestamp) / 1000);
					$music_data = encode_json $music_data;

					$music_data = encode_base64 &subs::encrypter($c->session('suds'), $music_data);
					my $latency = ($server_time - $timestamp) / 1000;
					my $url = $rm->{'manager'} . '/music/receiver?timestamp=' . $timestamp . '&latency=' . $latency . '&queuing=' . $queuing . '&file=' . $file . '&domain=' . $config->{'domain'} . '&volume=' . $volume . '&toggle=' . $toggle . '&seek=' . $seek . '&music_data=' . $music_data;
					my $res = $rm->{'ua'}->post($url)->result;
					if ($res->is_success) {
						my $bod = eval { return decode_json $res->body } || {};
						$bod->{'browser_tab_id'} = $data->{'browser_tab_id'};
						&Websocket::send('music', $bod);
					}
				}
			}
		}
	});
};

sub vacuum() {
	my $app = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = rightNow();
	my $app_q = &db_query('select * from appointments where app=?',$app);
	my $appts = $app_q->hashes;
	if (scalar @{$appts} == 0 && &setting_grabber({ app => $app, setting => 'permanent' }) ne 'checked') {
		&Websocket::send('server', { console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });

		foreach my $t ( qw/appointments tickets settings continent websites tickets cache subcategory option model option_category mailbox websockets/) {
			&db_query('delete from ' . $t . ' where app=?',$app);	
		}
	}
}
sub vacuum_app() {
	my $app = shift;
	my $timestamp = rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app_q = &db_query('select * from appointments where app=?',$app);
	my $appts = $app_q->hashes;
	foreach my $app ( @{$appts} ) {
		if ($app->{'file'}) {
			my @files = split ',', $app->{'file'};
			foreach my $f ( @files ) {
				if (-e $f) {
					`shred -u $f`;
				}
			}
		}
	}
	&Websocket::send('server', { console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });
	sleep 1;
	foreach my $t ( qw/appointments tickets settings continent websites tickets cache subcategory option model option_category mailbox websockets/) {
		&db_query('delete from ' . $t . ' where app=?',$app);	
	}

}

sub home() {
	my ($inhabitant) = @_;
	my $com = 'echo $HOME';
	my $cwd = `$com`;
	chomp $cwd;
	$inhabitant =~ s/~/$cwd/;
	return $inhabitant;
}

sub newest_folder_checker() {
	my $files = &ide_files('./');
	my $newest = 0;
	foreach my $l ( @{$files} ) {
		if ($l->{'modified'} > $newest) {
			$newest = $l->{'modified'};
		}
	}
	return $newest * 1000;
}


my $ide_files = [];
sub ide_files() {
	my $folder = shift;
	$ide_files = [];
	find(\&ide_process_file,$folder);
	my $tree = [];
	foreach my $f (@{$ide_files}) {
		my $temp = { file => $f, type => 'file' };
		my @stat = stat($f);
		my @folder_split = split '/', $f;
		my @temp_split = @folder_split;
		$temp->{'short_name'} = $temp_split[-1];
		pop @temp_split;
		$temp->{'root_count'} = @temp_split;
		$temp->{'location'} = join '/', @temp_split;
		$temp->{'size'} = $stat[7];
		$temp->{'modified'} = $stat[9];
		$temp->{'created'} = $stat[10];
		$temp->{'accessed'} = $stat[8];
		if ( -d $f) {
			$temp->{'type'} = 'folder';
		}
		push @{$tree}, $temp;
	}
	return $tree;
}

sub ide_process_file() {
	my $name = $File::Find::name;
	$name =~ s/^\.\///g;
	push @{$ide_files}, $name;
}


our $database_holder;
our $database;
sub database_grabber() {
	my $connection = shift || '';
	my $server_time = &rightNow();
	if ($database_holder->{'server_time'} && $server_time <= $database_holder->{'server_time'} + 300 && $connection ne 'new') {
		$database_holder->{'server_time'} = $server_time;
		if (-e $database_holder->{'database'}) {
			$database_holder->{'sql'} = Mojo::SQLite->new('sqlite:' . $database_holder->{'database'});
			$database_holder->{'db'} = $database_holder->{'sql'}->db;
			return ($database_holder->{'db'}, $database_holder->{'database'}, $database_holder->{'sql'});
		}
	}

	my $dir = $config->{'start_dir'};
	my $files = `ls -t $dir | grep .db`;
	my @databases = split "\n", $files;
	@databases = grep { $_ =~ /\.db$/gi } @databases;

	foreach my $d ( @databases ) {
		$d = &subs::home($config->{'start_dir'} . $d);
	}
	@databases = grep { -s $_ > 5000 } @databases;
	my $database = $databases[0];
	
	if ($database) {

		my $sql = Mojo::SQLite->new('sqlite:' . $database, sqlite_use_immediate_transaction => 0);
		$sql->options({AutoCommit => 1 });
		my $db = $sql->db;
		$database_holder = { server_time => &subs::rightNow(), database => $database, db => $db, sql => $sql };

		return ($db,$database,$sql);
	}
	return (undef,undef,undef);
}

sub db_insert() {
	my $table = shift;
	my $data = shift;
	$data->{'ost'} = $data->{'ost'} || &rightNow();
	$data->{'server_time'} = $data->{'ost'} unless $data->{'server_time'};
	$data->{'uuid'} = &random_string_creator(15) unless $data->{'uuid'};
	my ($db,$database,$sql) = &database_grabber();
	my $lid = undef;
	my $success;
	my $count = 0;
	until ($lid || $count >= 25) {
		$success = eval { return $db->insert($table, $data); };
		$lid = eval { return $success->last_insert_id };
		unless ($lid) {  }
		$count++;
	}
	return $success;
}

sub db_query() {
	my $query = shift;
	my @params = @_;
	my ($db,$database,$sql) = &database_grabber();

	return $db->query($query, @params);
}

sub db_update() {
	my $table = shift;
	my $data = shift;
	my $params = shift;
	my ($db,$database,$sql) = &database_grabber();
	return $db->update($table, $data, $params);
}

sub db_delete() {
	my $table = shift;
	my $params = shift;

	my ($db,$database,$sql) = &database_grabber();
	my ($lid,$success);

	if ($table && ref $params eq ref {}) {
		$success = $db->delete($table, $params);
	}
	else {
		$log->info('Bad Delete ' . $table);
		$log->info(Dumper $params);
	}
	return $success;
}

sub db_select() {
	my $table = shift;
	my $columns = shift;
	my $params = shift;
	my $filters = shift;
	my ($db,$database,$sql) = &database_grabber();

	return $db->select($table,$columns,$params,$filters);
}

sub db_close() {
	
}


sub random_colour_grabber() {
	my $col = [ 0, 0, 0 ];
	foreach my $co ( @{$col} ) {
		until ($co > 130) {
			$co = rand(255);
		}
	}


	my @colours = map { 
		join "", map { sprintf "%02x", $col->[$_] } (0..2) 
	} (60..65);
	return $colours[0];
}


sub typesetter() {
	my $app = shift;
	my $save = shift;
	my $type = 'idea';
	my $movement = '';
	my $last_word = (split '_', $app)[-1];
	my $first_word = (split '_', $app)[0];
	my $type_saved = 0;
	$last_word =~ s/[0-9]$//gi;
	$first_word =~ s/[0-9]$//gi;
	if ($last_word !~ /^!/ && grep { lc $last_word eq $_ } keys %{$gb::pos}) {
		my @app = split '_', $app;
		pop @app unless scalar @app == 1;
		$app = join '_', @app;
		$type = $last_word;
		$type_saved = 1;
	}
	elsif ($last_word =~ /^!/) {
		my @app = split '_', $app;
		$last_word = pop @app;
		$last_word =~ s/^!//gi;
		push @app, $last_word;
		$app = join '_', @app;
	}
	elsif ( my $default_pos = &subs::setting_grabber({ app => 'me', setting => 'pos' }) ) {
		$type = $default_pos;
	}
	if ($first_word !~ /^!/ && grep { lc $first_word eq $_ } @gb::movements) {
		my @app = split '_', $app;
		shift @app unless scalar @app == 1;
		$app = join '_', @app;
		$movement = $first_word;
	}
	elsif ($first_word =~ /^!/) {
		my @app = split '_', $app;
		$first_word = shift @app;
		$first_word =~ s/^!//gi;
		unshift @app, $first_word;
		$app = join '_', @app;
	}
	if ($type_saved == 1 && $save ne 'no') {
		&subs::setting_setter({ app => $app, setting => 'pos', value => $type });
	}
	return ($app,$type,$movement);
}

sub setting_initializer() {
	my ($app,$timestamp) = @_;
	my $returner;
	$app = &unformat_name($app);
	my ($db,$database) = &database_grabber();
	my $server_time = &rightNow();
	my $type;
	($app,$type) = &typesetter($app);
	my $counter = &subs::db_query('select count(*) from appointments where app=?', $app);
	my $count = $counter->hash->{'count(*)'};
	my $res = &db_query('select * from settings where app=? and device = ? order by server_time desc',$app,$device);
	my $re = $res->hashes;

	my $aka = &db_query('select * from settings where setting = ? and value like ?', 'aka', '%' . $app . '%')->hashes;

	if ( $count == 0 && scalar @{$aka} > 0 ) {
		foreach my $ak ( @{$aka} ) {
			if (exists $ak->{'value'}) {
				my @a = split ',', $ak->{'value'};
				foreach my $o ( @a ) {
					$o = &subs::unformat_name($o);
					if ($o eq $app) {
						$app = &subs::unformat_name($ak->{'app'});
						$res = &db_query('select * from settings where app=?',$app);
						$re = $res->hashes;
						last;
					}
				}
			}
		}
	}
	my $me_settings = &subs::settings_grabber({ app => 'me' });

	my $colour = &random_colour_grabber();

	$returner->{'app'} = $app;
	my $settings = { 
		'colour' => ('#' . $colour || 'white'),
		'worth' => $me_settings->{'worth'},
		'visible' => 'checked',
		'permanent' => 'checked',
		'pos' => $type,
		'duration' => $me_settings->{'duration'},
		'currency' => $me_settings->{'currency'},
		'unit' => $me_settings->{'unit'},
		'cost' => 0,
		'enc' => 'on',
		'public' => 'off',
		'warranty' => $me_settings->{'warranty'},
		'notification_text' => &subs::format_name($app),
		'schedule' => 'once',
		'uuid' => &random_string_creator(25),
		'navigation' => 'once'
	};

	foreach my $s (keys %{$settings}) {
		my @seen = grep { $_->{'setting'} eq $s } @{$re};

		unless ( scalar @seen > 0 ) {
			my $pen = { 
				app => $app,
				timestamp => &subs::rightNow(),
				setting => $s,
				value => $settings->{$s},
				server_time => &subs::rightNow(),
				device => $device,
				uuid => &random_string_creator(20)
			};
			&db_insert('settings', $pen);
			$returner->{$s} = $settings->{$s};
		}
		else {
			my $set = $seen[0];
			$returner->{$s} = $set->{'value'};
			if (scalar @seen > 1) {
				unshift @seen;
				foreach my $s ( @seen ) {
					&subs::db_delete('settings', { app => $app, uuid => $s->{'uuid'} });
					&Manager::deletion_registration({ table => 'settings', app => $app, uuid => $s->{'uuid'}, scope => 'single', server_time => $s->{'server_time'} });
				}
			}
		}
	}
	return $returner;
};

&signatorial_establisher();

sub signatorial_establisher() {
	my $context = shift;
	if ($config->{'signatorial'} && -e $config->{'signatorial'}) {

		my $j = &subs::terminal_name(&subs::home($config->{'signatorial'}));
		my $checksum = `base64 $j`;
		my $md5 = md5_sum $checksum;
		$gb::secret_maker = [ $md5 ];
		return $md5;
	}
	elsif ($context ne 'designer') {
		return &random_string_creator(12);
	}
}

sub signatorial_designer() {
	my $designation = shift;
	if (!$designation && $gb::signatorial) {
		return $gb::signatorial;
	}
	my $folder = './public/images/jonathans';
	my $jonathans = `ls $folder`;
	my @jonathans = split /\n/, $jonathans;
	my $checksum = $database;
	if ($designation eq 'neighbour_link') {

	}
	foreach my $j ( @jonathans ) {
		$j = &terminal_name($folder . '/' . $j);
		$checksum .= encode_base64 `cat $j`;
	}
	my $md5 = md5_sum &signatorial_establisher('designer') . $checksum;
	$gb::signatorial = $md5;

	return $gb::signatorial;
}

sub run_command() {
	my $app = shift;
	my $command = shift;
	my $timestamp = shift;
	my $exec = 'none';
	my $whoami = `whoami`;
	chomp $whoami;
	my $hostname = `hostname`;
	chomp $hostname;
  Mojo::IOLoop->subprocess->run_p(sub {
		if ($command =~ /^&/) {
			$exec = eval { $command };
			my $json = { type => 'command', whoami => 'President', hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => $exec, timestamp => $timestamp };

			&Websocket::send('server', $json);
		}
		else {
			$exec = eval { return `$command` };
			my $json = { type => 'command', whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => $exec, timestamp => $timestamp };

			&Websocket::send('server', $json);
			sleep(.3);
			my $msg = { app => $app, whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(25), console => $command };
			&Websocket::send('server', $msg);
		}
		return 'done';
	});
}

sub rightNow() {
	my $precision = shift;
	my $time = time() * 1000;

	unless ($precision) {
		$time = sprintf("%.0f",$time); 
	}

	return $time;
}


sub hang_to_dry() {
	my $server_time = &rightNow();
	my $returner = [];

	my $time_plinkos = clone $gb::time_plinkos;
	my $cls = &db_query('select * from settings where setting = ? and device = ? and app!= ? and value is not null', 'clothesline', $device,'__president')->hashes;

	foreach my $clr ( @{$cls} ) {

		my $cl = eval { return decode_json $clr->{'value'} } || {};
		my $time = localtime($server_time / 1000);
		my $app = &unformat_name($clr->{'app'});
		my $settings = &settings_grabber({ app => $app });
		my $app_data = { name => $app, app => $app, formatted_name => &shorthand_name(&format_name($app),10), colour => $settings->{'colour'} };
		my $time_plinko = $cl->{'time_plinko'} || {};
		my @schedule = split ',', $cl->{'schedule'};
		foreach my $schedule ( @schedule ) {
			
		}
		my $count = scalar keys %{$cl->{'time_plinko'}};
		my $cl_count = 0;

		for (my $n = 0; $n <= 8; $n++) {
			my $ft = $time->[$n];
			if ($n == 2) {
				if ($ft == 0) { 
					$ft = '12am';
				}
				elsif ($ft >= 12) {
					if ($ft == 12) { $ft = 24; }
					$ft = ($ft - 12) . 'pm';
				}
				elsif ($time->[$n] > 0 && $time->[$n] < 13) {
					$ft .= 'am';
				}
			}
			if ($n == 4) { $ft = $time->monname; }
			if ($n == 5) { $ft += 1900; }
			if ($n == 6) { $ft = $time->wdayname; }

			if ($time_plinko->{$time_plinkos->[$n]->{'name'}}) {

				if (grep { $_ eq $ft || $_ eq 'all' } @{$time_plinko->{$time_plinkos->[$n]->{'name'}}}) {
					$cl_count++;
					if ($cl_count == $count) {
						if ($settings->{'visible'} eq 'checked') {
							push @{$returner}, $app_data;
						}
						
					}
				}
			}
		}
		unless (grep { $_->{'app'} eq $app } @{$returner}) { 
			my $running_appts = &db_query('select * from appointments where app = ? and (type = ? or type = ?)',$app, 'start','record')->hashes;
			if (scalar @{$running_appts} > 0) {
				push @{$returner}, $app_data;
			}
			foreach my $circumstance( keys %{$gb::budget_modes} ) { 
				if ($cl->{$circumstance . '_budget'}) {
					my $budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
					if (grep { $budget->{'status'} eq $_ } @{$cl->{$circumstance . '_budget'}}) {
						push @{$returner}, $app_data unless grep { $_->{'app'} eq $app } @{$returner};
					}
				}
			}
		}



	}
	@{$returner} = sort { $a->{'app'} cmp $b->{'app'} } @{$returner};
	my $jreturner = encode_json $returner;
	&setting_setter({ app => '__president', setting => 'clothesline', value => $jreturner }); 
	return 0;

}

sub headless_browser() {
	my $changes = 0;
	my $headless_timeout = $gb::headless_browser * 1000;
	my $recurring_websites = &subs::db_query('select * from settings where setting=? and device=? and value is not null and value != ?', 'web_recurring', $device, '')->hashes;
	foreach my $rw ( @{$recurring_websites} ) {
		my $app = $rw->{'app'};
		my $able_devices = &subs::db_query('select * from settings where app=? and setting=? and (value=? or value = ?) and device=?', $app, 'web_headless_device', $device, 'all', $device)->hashes;
		if (scalar @{$able_devices} > 0) {
			my $websites = &subs::db_query('select * from settings where app=? and setting=? and device = ?', $app, 'web', $device)->hashes;

			foreach my $w ( @{$websites} ) {
				my $history = &subs::db_query('select * from websites where app=? and url=? order by timestamp desc',$app, $w->{'value'})->hashes;
				my $last_run = 0;
				if ($history->[0]) {
					$last_run = $history->[0]->{'timestamp'};
				}
				my $recurrence = &time_abbrev_translator($rw->{'value'}) || '1M';

				if (&subs::rightNow() - $last_run + $headless_timeout > $recurrence) {

					my ($window,$internal_url,$uuid,$timestamp) = &Manager::website_grabber({ 
						app => $app, 
						website => $w->{'value'}, 
						timestamp => &subs::rightNow(), 
						user_agent => $gb::user_agent,
					});
					$changes = 1;
				}
			}
		}

	}
	if ($changes == 1) {
		my $c = app->build_controller;
		my $update = $c->render_to_string(
			template => 'web',
			app => ''
		);
		&Websocket::send('tab', { type => 'replaceWith', selector => '#web', content => $update });


	}
}

sub telephone_contacts_check() {

	return unless $device eq 'mobile';

	my $jcontacts = `termux-contact-list`;
	my $contacts = eval { return decode_json $jcontacts } || [];
	foreach my $contact ( @{$contacts} ) {
		my $name = &subs::unformat_name($contact->{'name'});
		my $number = $contact->{'number'};
		$number =~ s/\D+//gi;

		my $phones = &subs::settings_grabber({ app => $name, settings => ['phone', 'uuid' ] });

		if ($phones->{'uuid'} && $phones->{'phone'} ne $number) {
			my $settings = &subs::setting_initializer($name,&subs::rightNow());
			my $data = { app => $settings->{'app'}, setting => 'phone', value => $number };

			&subs::setting_setter($data);
		}
	}
}

sub telephone_call_log_check() {

	return unless $device eq 'mobile';

	my $call_logs = `termux-call-log -l 30`;
	my $calls = eval { return decode_json $call_logs } || [];

	foreach my $call ( grep { $_->{'phone_number'} =~ /\d/ } @{$calls} ) {
		my $name = &subs::unformat_name($call->{'name'});
		my $number = $call->{'phone_number'};
		$number =~ s/\D+//gi;
		my $timestamp = &subs::ago_calc($call->{'date'},&subs::rightNow());

		my @duration = split /:/, $call->{'duration'};


		my $duration = '';
		if (scalar @duration == 3) {
			$duration .= $duration[0] . 'h ';
			$duration .= $duration[1] . 'm ';
			$duration .= $duration[2] . 's';
		}
		else {
			$duration .= $duration[0] . 'm ';
			$duration .= $duration[1] . 's';
		}
		$duration = &subs::time_abbrev_translator($duration);


		my $phone = &subs::db_query('select * from settings where setting=? and value like ?', 'phone', '%' . $number)->hashes->[0];
		$log->info('new call from ' . $number . ' ' . $phone->{'app'} . ' ' . $call->{'phone_number'});

		if ($phone->{'app'}) {
			my $appts = &subs::db_query('select * from appointments where app=? and timestamp = ?', $phone->{'app'}, $timestamp)->hashes;
			unless (scalar @{$appts} > 0) {
				my $data = {
					app => $phone->{'app'},
					type => 'start',
					duration => '-' . $duration,
					timestamp => $timestamp,
					stop_timestamp => ($timestamp + $duration),
					seen => 'yes',
					subtype => 'phone'
				};

				my $c = app->build_controller;
				&Manager::appointment_writer($c,$data);
			}
		}


	}
	


}

sub task_grabber() {
	my $app = shift;
	my $parent = shift || 0;
	my $settings = &subs::settings_grabber({ app => $app });
	my $tasks_json = &subs::setting_grabber({ app => $app, setting => 'tasks' }) || '[]';
	my $tasks = decode_json $tasks_json;
	@{$tasks} = grep { $_->{'uuid'} } @{$tasks};
	@{$tasks} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$tasks};
	my $totals = {};
	foreach my $t ( @{$tasks} ) {
		my $tsettings = &subs::settings_grabber({ app => &unformat_name($t->{'task'}) });
		$t->{'colour'} = $tsettings->{'colour'} if $tsettings->{'colour'};
		foreach my $bm ( keys %{$gb::budget_modes} ) {
			if ($bm eq 'duration') {
				$totals->{$bm} += $t->{$bm};
				$t->{$bm} = &subs::duration_sayer($t->{$bm} / 1000);
			}
			elsif ($bm eq 'occurences') {
				$totals->{$bm} += $t->{$bm};
			}
		}
		if ($t->{'renew_freq'} + $t->{'last_completed'} < &subs::rightNow() && $t->{'renew_freq'} > 0) {
			$t->{'completed'} = 'off';
		#	$t->{'duration'} = abs $settings->{'duration'};
		}
		$t->{'renew_freq'} = &subs::duration_sayer($t->{'renew_freq'} / 1000);


		if (my $jt = eval { return decode_json $tsettings->{'tasks'} }) {
			if (scalar @{$jt} > 0) {

				$t->{'subsidiaries'} = &task_grabber(&unformat_name($t->{'task'}), $parent + 1);
				if (scalar @{$t->{'subsidiaries'}->{'tasks'}} == 0) {
					&subs::setting_deleter({ app => &subs::unformat_name($t->{'task'}), setting => 'tasks' });
					$t->{'subsidiaries'} = undef;
				}
			}

		}
	}
	$totals->{'duration'} = &subs::duration_sayer($totals->{'duration'} / 1000);

	if ($settings->{'tasks_sort'} eq 'new') {
		@{$tasks} = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'high') {
		@{$tasks} = sort { $b->{'priority'} <=> $a->{'priority'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'low') {
		@{$tasks} = sort { $a->{'priority'} <=> $b->{'priority'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'az') {
		@{$tasks} = sort { $a->{'task'} cmp $b->{'task'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'za') {
		@{$tasks} = sort { $b->{'task'} cmp $a->{'task'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'chk') {
		@{$tasks} = sort { $a->{'last_completed'} <=> $b->{'last_completed'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'rchk') {
		@{$tasks} = sort { $b->{'last_completed'} <=> $a->{'last_completed'} } @{$tasks};
	}
	else {
		@{$tasks} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$tasks};
	}

	if ($settings->{'tasks_filter'} eq 'done') { 
		@{$tasks} = grep { $_->{'completed'} eq 'on' } @{$tasks};
	}
	elsif ($settings->{'tasks_filter'} eq 'open') {
		@{$tasks} = grep { $_->{'completed'} eq 'off' } @{$tasks};
	}

	push @{$tasks}, { uuid => 'new', lock => 'locked', colour => '#' . &subs::random_colour_grabber() } unless $parent > 0;
	my $c = app->build_controller;
	my $html = $c->render_to_string(
		template => 'apps/tasks',
		tasks => $tasks,
		app => $app,
		totals => $totals,
		settings => $settings,
		parent => $parent
	);
	return { html => $html, tasks => $tasks, totals => $totals };
}

sub task_writer() {
	my $c = shift;
	my $data = shift;
	my $papp = &subs::unformat_name($data->{'papp'});
	my $app = &subs::unformat_name($data->{'app'});

	my $timestamp = $data->{'timestamp'};
	my $uuid = $data->{'uuid'};
	my $name = $data->{'name'};
	my $value = $data->{'value'};
	my $colour = $data->{'colour'};
	my $tasks = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'tasks' }) } || [];

	if ($name eq 'duration') {
		$value = &subs::time_abbrev_translator($value);
	}
	elsif ($name eq 'occurences') {
		$value =~ s/[^0-9.]//gi;
		$value = abs $value;
	}
	elsif ($name eq 'renew_freq') {
		$value = &subs::time_abbrev_translator($value);
	}
	elsif ($name eq 'task') {
		$value = &subs::unformat_name($value);
	}
	if ($uuid eq 'new') {
		my $settings = &subs::settings_grabber({ app => $value });
		$settings->{'worth'} =~ s/[^0-9.]//gi;
		push @{$tasks}, { 
			uuid => &subs::random_string_creator(),
			$name => $value,
			timestamp => $timestamp,
			colour => $settings->{'colour'} || $colour,
			duration => &subs::duration_sayer(abs &subs::time_abbrev_translator($settings->{'duration'}) / 1000),
			occurences => 1,
			priority => 0,
			completed => 'off',
		};
	}
	else {
		my @task = grep { $_->{'uuid'} eq $uuid } @{$tasks};


		my $task = $task[0];
		$task->{$name} = $value;
		my @tasks = grep { $_->{'uuid'} ne $uuid } @{$tasks};
		push @tasks, $task;
		@{$tasks} = @tasks;
		my $parent_task = eval { return decode_json &subs::setting_grabber({ app => $task->{'task'}, setting => 'tasks' }) } || [];
		foreach my $pt ( @{$parent_task} ) {
			my $tasks = &subs::task_writer($c,{
				papp => $papp,
				app => $pt->{'task'},
				timestamp => $timestamp,
				uuid => $pt->{'uuid'},
				name => $name,
				value => $value,
				colour => $pt->{'colour'}
			});
		}
		if ($name eq 'completed' && $value eq 'on') {

			my $running_appt = &subs::db_query('select * from appointments where app = ? and (type = ? or type = ?) and timestamp <= ? order by timestamp', $papp, 'start', 'record', $timestamp)->hashes->[0];
			$task->{'last_completed'} = &subs::rightNow();
			if ($task->{'appt'} eq 'on') {
				my $settings = &subs::settings_grabber({ app => $task->{'task'} });
				my $duration;
				if ($task->{'duration'} && $task->{'duration'} =~ /[0-9]/gi) {
					$duration = abs &subs::time_abbrev_translator($settings->{'duration'});
				}
				elsif ($settings->{'duration'} && $settings->{'duration'} =~ /[0-9]/gi) {
					$duration = abs &subs::time_abbrev_translator($settings->{'duration'});
				}
				else {
					$duration = abs &subs::time_abbrev_translator(&subs::setting_grabber({ 'app' => 'me', setting => 'duration'}) || '5m');
				}


				my $data = {
					app => $task->{'task'},
					timestamp => $timestamp,
					type => 'usual',
					quantity => $task->{'occurences'},
					duration => (abs $duration),
					source_uuid => $running_appt->{'uuid'},
					project => $data->{'project'},
					account => $data->{'account'},
					movement => $data->{'movement'}
				};
				my $app = &Manager::appointment_writer($c,$data);
				$task->{'last_appt_uuid'} = $app->{'uuid'};
				$task->{'last_server_time'} = $app->{'server_time'};
				
			}

		}
		elsif ($name eq 'completed' && $task->{'appt'} eq 'on' && $value eq 'off') {
			&Manager::delete_app($task->{'task'},$task->{'last_appt_uuid'},$task->{'server_time'},'task');
		}
	}
	return $tasks;
}

sub note_retriever() {
	my ($app,$uuid) = @_;
	my $noters = &subs::db_select('appointments', ['start_notes','notes','end_notes','server_time'], { app => $app, uuid => $uuid });
	my $noteskis = $noters->hashes;
	my $cred = &subs::db_select('security');
	my $creds = $cred->hashes;
	my $s = &subs::suds_grabber();
	my $notekeeper;
	foreach my $note ( @{$noteskis} ) {
		my $start_notes = &subs::note_decrypter($s, $note->{'start_notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'start_notes'},$note->{'ost'}) };
		my $notes = &subs::note_decrypter($s, $note->{'notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'notes'},$note->{'ost'}) };
		my $end_notes = &subs::note_decrypter($s, $note->{'end_notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'end_notes'},$note->{'ost'}) };
		$notekeeper = "<br>" . $start_notes . "<br>" . $notes . "<br>" . $end_notes;
		$notekeeper =~ s/\n/<br>/gi;
	}
	return $notekeeper;
}

sub log_reader_file_preparer() {
	my $file = shift;
	my $f = $file->{'f'};

	#	my ($destination,$asset) = &subs::file_device_renamer($f,$a->{'app'},$misc_settings);
	#	if ($f ne $destination . $asset) {
	#		$f = $destination . $asset;
	#	}
	my $tf = {
		file => $f,
		uuid => $file->{'uuid'},
		server_time => $file->{'server_time'},
		function => $file->{'function'},
		type => $file->{'type'},
		name => $file->{'name'},
		app => $a->{'app'}
	};
	$tf->{'file_type'} = 'img' if $f =~ /jpg|png|bmp|tiff|xcf/;
	$tf->{'file_type'} = 'snd' if $f =~ /wav|mp3|aiff|weba|m4a|flac/;
	$tf->{'file_type'} = 'vid' if $f =~ /mp4|avi|mov|webm|mkv/;
	$tf->{'file_type'} = 'pdf' if $f =~ /pdf/;
	$tf->{'file_type'} = 'doc' if $f =~ /doc|docx|xls|xlsx|pub|pubx|txt|rtf/;
	return $tf;
}	



sub remote_machine_negotiator() {
	my $data = shift;
	$log->info(Dumper $data);
	$gb::suds = &suds_grabber();
	$log->info('before c');
	my $c = app->build_controller;
	$log->info('after c');
	$c->session('suds' => $gb::suds);
	$c->session('gimme' => $data->{'gimme'});


	my $remote_upgrade = &subs::setting_grabber({ app => '__president', setting => 'remote_upgrade' });
	my $remote_connect_timer =  &subs::setting_grabber({ app => '__president', setting => 'remote_connect_timer' }) || 0;
	$log->info($remote_upgrade . ' ' . $remote_connect_timer);
	if ($remote_connect_timer + (60 * 7 * 1000) < &subs::rightNow()) {
		$log->info('setting remote upgrade to null');
		&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
	}
	if ($remote_upgrade ne 'running' && $remote_connect_timer + 10000 < &subs::rightNow()) {
		$log->info('running remote machine reconnector');
		&Manager::remote_machine_reconnector($c);
	}
	#&system_monitor({
	#	timeout => 'remote_machine_sync',
	#});
}


sub system_monitor() {
	my $data = shift;
	my $device = &device_setter();
	$data->{'device'} = $device;
	$data->{'timestamp'} = &subs::rightNow();

	&subs::cache_set({ app => '__president', context => $data->{'timeout'} }, $data);
	my $remote_machines = &subs::db_query('select * from remote_machines where connection=?', 'active')->hashes;
	Mojo::IOLoop->subprocess->run_p(sub {	
		foreach my $rm ( @{$remote_machines} ) {
			$rm = &Manager::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
			my $params;

			foreach my $p ( keys %{$data} ) {
				$params .= $p . '=' . url_escape $data->{$p} . '&';
			}

			my $url = $rm->{'manager'} . '/manager/configure/system_monitor?' . $params;
			my $res = $rm->{'ua'}->post($url)->result;
		}
	});
}


sub suds_grabber() {
	my $duty_time = &subs::setting_grabber({ app => '__president', setting => 'remote_duty' });
	$log->info('DT ' . $duty_time . ' GBDT: ' . $gb::duty_time);
	if ($duty_time eq '' || !$duty_time || $duty_time != $gb::duty_time || !$gb::duty_time) {
		$log->info('no dt');
		my ($db,$database,$sql) = &subs::database_grabber('new');
		if (!$gb::duty_time) {
			my $duty_file = &subs::home('~/.president/on_duty');
			$gb::duty_time = read_file($duty_file);
			$log->info('writing duty time');
		}
		$log->info('about to set');
		&subs::setting_setter({ app => '__president', setting => 'remote_duty', value => $gb::duty_time });
		$log->info('about to tick');
		my $tick = &subs::db_query('select * from tickets where status=? order by server_time desc', 'active');
		my $ticke = $tick->hashes;
		my $ticket = $ticke->[0];
		$log->info('got ticket');
		$log->info(Dumper $ticket);
		my $v = $ticket->{'verification'};
		my $secret = $ticket->{'secret'};
		my $ver = url_unescape `echo "$secret" | base64 --decode`;
		my $verification = &subs::note_decrypter($ticket->{'password'}, $ver);
		my $vrai = eval { return decode_json $verification } || {};
		$secret = &subs::decrypter($vrai->{'p'},&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});
		my $suds = &subs::note_decrypter($vrai->{'p'}, $ticket->{'suds'});
		$gb::suds = $suds;
		$log->info('new suds: ' . $suds);
	}
	$log->info('suds bypassed ');
	return $gb::suds;
}

sub pen_message() {
	my $data = shift;
	my $msg = $data->{'msg'};
	my ($db,$database,$sql) = &subs::database_grabber();

	my $command = './pen.pl ' . '"' . $msg . '" ' . $database;
	my $response = eval { return decode_json `$command` } || {};

	return $response;

}

sub manager_file_maker() {
	my $session_name = shift;
	my ($my_name,$computer_name,$hostname,$hostnamer,$database_name);
	my ($db,$database) = &subs::database_grabber();
	$hostname = `hostname`;
	chomp $hostname;
	$hostnamer = eval { return &subs::db_select('devices', ['name'], { hostname => $hostname } )->hash->{name} };
	$my_name = $session_name || &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	$computer_name = &subs::setting_grabber({ app => 'me', setting => 'computer_name' });
	$database_name = $database;
	$database_name =~ s/^database\///;
	$database_name =~ s/.db$//gi;
	my @database_name = split '/', $database_name;
	$database_name = $database_name[-1];

	return ($my_name || $hostnamer || $hostname) . '@' . $database_name . '.' . ($computer_name || $hostname);

};

sub data_size() {
	my $data = shift;
	my $data_size = $data;
	if ($data >= 1024000000) {
		$data_size = sprintf("%.2f", $data / 1000000000) . 'GB';
	}
	elsif ($data > 1024000) {
		$data_size = sprintf("%.2f", $data / 1000000) . 'MB';
	}

	elsif ($data > 1024) {
		$data_size = sprintf("%.2f", $data / 1000) . 'KB';
	}
	return $data_size;
}

sub usual_appointment_maker() {
	my $data = shift;
	my $settings = shift;
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $type = $data->{'type'};
	my $duration = $data->{'duration'};
	if ($settings->{'project'}) {
		$data->{'project'} = $settings->{'project'};
	}
	my $m = &subs::db_select('model', undef, { app => $app, def => 'on' })->hashes->[0];
	my ($model,$jmodel,$joptions);
	if ($m->{'uuid'}) {
		$model = { 
			uuid => $m->{'uuid'}, 
			name => $m->{'name'}, 
			timestamp => $timestamp, 
			quantity => ($data->{'quantity'} || $m->{'quantity'}), 
			unit => $data->{'unit'} || $m->{'unit'},
			delay_start => $m->{'delay_start'},
			delay_stop => $m->{'delay_stop'}
		};
		$jmodel = encode_json $model;
	}
	
	if ($m->{'save_app'} eq 'on') {
		$data->{'seen'} = 'yes';
		&source_appt_writer($m,$data,'model');
	}

	my $def_options = &subs::db_select('option', undef, { app => $app, def => 'on' })->hashes;
	my $options = [];
	foreach my $do ( @{$def_options} ) {
		my $quantity = $do->{'quantity'};
		$quantity = ($data->{'quantity'} || $do->{'quantity'});
		push @{$options}, { 
			uuid => $do->{'uuid'}, 
			timestamp => $timestamp, 
			quantity => $quantity, 
			unit => $do->{'unit'}, 
			name => $do->{'name'},
			delay_start => $do->{'delay_start'},
			delay_stop => $do->{'delay_stop'}
		};
		if ($do->{'save_app'} eq 'on') {
			$data->{'seen'} = 'yes';
			&source_appt_writer($do,$data,'option');
		}
	}
	if (scalar @{$options}) {
		$joptions = encode_json $options;
	}
	else { $options = undef; $joptions = undef; }
	
	return ($model,$options,$jmodel,$joptions);
}

sub source_appt_writer() {
	my $m = shift;
	my $data = shift;
	my $table = shift;
	my $returner = {};
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $type = $data->{'type'};
	my $duration = $data->{'duration'};

	my $char = eval { return decode_json $m->{'characteristics'} } || [];
	my $measures = { uuid => &subs::random_string_creator(19) };
	my $unit =  ($app eq $m->{'unit'}) ? $data->{'unit'} : $m->{'unit'};

	my $quantity = $data->{'quantity'} || $m->{'quantity'};

	my $recursion_check = &subs::db_select('appointments', undef, { app => $m->{'name'}, source_uuid => $uuid })->hashes;
	my $datas = {
		app => $m->{'name'},
		timestamp => $timestamp,
		type => $type,
		duration => $duration || 1000,
		source_uuid => $uuid,
		unit => $data->{'unit'} || $m->{'unit'},
		quantity => ($data->{'quantity'} || $m->{'quantity'}),
		project => $data->{'project'} || $m->{'project'},
		manufacturer => $data->{'manufacturer'} || $m->{'manufacturer'}
	};

	if ($type eq 'start' && $m->{'delay_start'}) {
		my $t = &subs::time_abbrev_translator($m->{'delay_start'});
		$timestamp = $timestamp + $t;
		$datas->{'timestamp'} = $timestamp;
	}
	elsif ($type eq 'stop' && $data->{'delay_stop'}) {
		my $t = &subs::time_abbrev_translator($m->{'delay_stop'});
		$timestamp = $timestamp + $t;
		$datas->{'timestamp'} = $timestamp;
	}


	unless (scalar @{$recursion_check} > 0) {


		if ($table = 'model') {

		}
		elsif ($table = 'option') {

		}

		my $c = app->build_controller;
		$returner = &Manager::appointment_writer($c,$datas);
	}

	foreach my $ch ( @{$char} ) {
		if ($ch->{'save_appt'} eq 'on') {
			$datas->{'app'} = &subs::unformat_name($ch->{'name'});
			$datas->{'source_uuid'} = $returner->{'uuid'};
			$datas->{'quantity'} = $ch->{'value'};
			$datas->{'unit'} = $ch->{'unit'};
			$datas->{'uuid'} = &subs::random_string_creator(92);
			my $c = app->build_controller;
			&Manager::appointment_writer($c, $datas);
		}
	}

}

sub log_writer() {
	my $data = shift;
	my $log_data;
	my $timestamp = &subs::rightNow();
	if ( eval { @{$data} } ) {
		$log_data = Dumper $data;
	}
	elsif ( eval { %{$data} } ) {
		$log_data = Dumper $data;
	}
	else {
		$log_data = $data;
	}
	my $settings = &subs::settings_grabber({ app => 'terminal' });

	$settings->{'log'} = eval { return decode_json $settings->{'log'} } || [];
	splice @{$settings->{'log'}}, 30;
	my $uuid = &subs::random_string_creator(10);
	my $logg = { timestamp => $timestamp, 'msg' => $log_data, uuid => $uuid };
	push @{$settings->{'log'}}, $logg;

	my $sl = encode_json $settings->{'log'};
	&subs::setting_setter({ app => 'terminal', setting => 'log', value => $sl });
	&Websocket::send('server', { view => 'log', console => $logg, error => $uuid });
	return $data;
}

1;
