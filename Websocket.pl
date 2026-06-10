#!/usr/bin/perl

use strict;
use warnings;

package Websocket;

use List::Util qw(shuffle);
use Mojo::Util qw/html_unescape term_escape/;
use Time::Duration;
use Date::Parse;
use Time::Piece;
use Crypt::Simple;
use File::Slurp;
use Mojo::JSON qw(decode_json encode_json);
use Data::Dumper;

require "./gb.pl";
require "./subroutines.pl";
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);

my $device = &subs::device_setter();
my $home_file = &subs::home('~/') . '.president/ws_watcher';
`touch $home_file` unless -e $home_file;
sub send() {
	my ($app,$msg) = @_;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $returner;
	if ($msg->{'console'}) {
		if (!$msg->{'whoami'}) {
			$msg->{'whoami'} = `whoami`;
			chomp $msg->{'whoami'};
		}
		if (!$msg->{'hostname'}) {
			$msg->{'hostname'} = `hostname`;
			chomp $msg->{'hostname'};
		}
	}
	my $original_msg = $msg;
	if ( eval { encode_json $msg } ) {
		my $uuid = &subs::random_string_creator(10);




	#	$msg->{'uuid'} = $uuid;
		$msg->{'formatted_name'} = &subs::format_name($msg->{'app'});
		my $m = encode_json $msg;
		
		my $server_time = &subs::rightNow();

		if (eval { $sql->db } && $sql->dsn !~ /:$/) {

			my $lid = undef;
			until ($lid) {
				my $success = eval { return &subs::db_insert('websocket_messages', {
					origin => $original_msg->{'origin'},
					server_time => $server_time,
					timestamp => $original_msg->{'timestamp'} || $server_time,
					message => $m,
					destination => $original_msg->{'destination'} || $original_msg->{'browser_tab_id'},
					app => $app,
					environment => 'manager',
					uuid => $uuid,
					patience => $original_msg->{'patience'}
				}) };
				$lid = $success->last_insert_id;
			}
		#	my $home = &subs::home('~/');
		#	`echo "$server_time" > $home_file`;
		}
	}
	return $returner;
}
1;