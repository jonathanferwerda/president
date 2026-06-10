#!/usr/bin/perl

use strict;
use warnings;
package President;
print $0 ."\n";
print `pwd` . "\n";
my $self = $$;
print "I am $self\n";
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::Server::Daemon;
use Mojo::Server::Morbo;
use Mojo::Server::Prefork;
use Mojo::Server::Hypnotoad;
use Data::Dumper;
use File::Slurp;
use Mojo::Util qw/md5_sum /;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Reactor::Poll;

use threads 'exit' => 'threads_only';


my $working_dir = $0;
my $present_dir = `pwd`;

my $dump_dir = &home('~/.president');
`rm -R $dump_dir/*`;
my $duty_file = &home('~/.president/on_duty');
`touch $duty_file`;
write_file($duty_file, 0);
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
if ($working_dir ne $present_dir) {
	my @folder = split '/', $working_dir;
	pop @folder;
	my $new_dir = join '/', @folder;
	print 'chdir to ' . $new_dir . "\n";
	chdir $new_dir;
	print `pwd` . "\n";

}
#`espeak "president has begun"`;


my $environment = shift;

my $cache_dir = &home('~/') . '.president';
`mkdir -p $cache_dir` unless -e $cache_dir;

require './gb.pl';
app->secrets($gb::secret_maker);
$gb::duty_time = &subs::rightNow();

my $random_number;
if (!$config->{'working_port'}) {
	$random_number = 0;
	until ($random_number > 1024 && $random_number < 65532) {
		$random_number = int(rand(65532));
	}
} else {
	$random_number = $config->{'working_port'};
}
my $on_duty = 0;
my $hour = localtime( &subs::rightNow() / 1000 )->strftime( "%H");

my $domain = $config->{'domain'} || '127.0.0.1';
#my $domain = '127.0.0.1';

my $device = &device_setter();
if ($device eq 'mobile') {
	`termux-wake-lock`;
	`sshd`;
}

if ($config->{'open_browser'} eq 'yes') {
	if ($device eq 'mobile') {
		threads->create(sub() { 
			`termux-open https://127.0.0.1:$random_number/manager & `
		});
	}
	elsif ($device eq 'computer') {
		threads->create(sub() { 
			`export DISPLAY=:0`;
			my $chrome = `chromium https://$domain:$random_number/manager &`;
		});
	}
}
if ($environment) {
	if ($environment =~ /^dev/) {
		$config->{'environment'} = 'development';
	}
	elsif ($environment =~ /^pro/) {
		$config->{'environment'} = 'production';
	}
}
my $port = $random_number || $config->{'port'};
my $watch_port = $port + 2;
my $ws_port = $port + 1;
my $dock_port = 3000;
my $tty_port = $port + 3;
if ($config->{'environment'} eq 'development') {
	$ws_port = $port;
}


my @threads;
sub manager_starter() {
my $ws_tty_port = $tty_port + 1;
	$ENV{PORT_AHOY} = $random_number;
	$ENV{PORT_MSG} = $ws_port;
	$ENV{PORT_BELL} = $watch_port;
	$ENV{PORT_BESTOW} = $tty_port;
	$ENV{PORT_DOCK} = $dock_port;
	$ENV{PORT_COMS} = $ws_tty_port;
	$ENV{PORT_ENV} = $config->{'environment'};
	$ENV{cookie_name} = 'president';

	my $certs = "";

	if (-e './server/fullchain.pem' && -e './server/privkey.pem') {
		$certs = "?cert=./server/fullchain.pem&key=./server/privkey.pem";
	}
	my $time_count = 0;
	write_file($duty_file, &subs::rightNow());

	$ENV{'MOJO_MAX_LINE_SIZE'} = "64000";


	if ($config->{'environment'} eq 'development') {
		threads->create(sub() { 
			print "Starting Locker Server on port " . $dock_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $dock_port . $certs;
			$ENV{PURPOSE} = 'locker';
			my $morbo = Mojo::Server::Morbo->new;
			$morbo->backend->watch(['./', './templates']);
			$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
			$morbo->run('./Manager.pl');
		});
		if ($ENV{PORT_AHOY} != $ENV{PORT_MSG}) {
			threads->create(sub() { 
				print "Starting WS Server on port " . $ws_port . "\n";
				$ENV{MOJO_LISTEN} = 'https://*:' . $ws_port . $certs;
				$ENV{PURPOSE} = 'websocket';
				my $morbo = Mojo::Server::Morbo->new;
				$morbo->backend->watch(['./', './templates']);
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./Manager.pl');
			});
		}
		threads->create(sub() { 
			print "Starting Main Server on port " . $port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $port . $certs;
			$ENV{PURPOSE} = 'main';
			my $morbo = Mojo::Server::Morbo->new;
			$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
			$morbo->backend->watch(['./', './templates']);
			$morbo->run('./Manager.pl');
		});
	}
	elsif ($config->{'environment'} eq 'production') {

		push @threads, threads->create(sub() { 
			print "Starting Pro Locker Server on port " . $dock_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $dock_port . $certs;
			$ENV{PURPOSE} = 'locker';
			my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after locker server');
		});

		push @threads, threads->create(sub() { 
			print "Starting Pro WS Server on port " . $ws_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $ws_port . $certs;
			$ENV{PURPOSE} = 'websocket';
			my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after ws server');
		});

		push @threads, threads->create(sub() { 
			print "Starting Pro Prefork Main Server on port " . $port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $port . $certs;
			$ENV{PURPOSE} = 'main';
			my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(7);
			$prefork->run;
			$log->info('after main server');
		});


	}
	else {
		print "I have no environment!\n";
	}

	if ($device ne 'server') {
		threads->create(sub() { 
			$ENV{PURPOSE} = "watch";
			$ENV{MOJO_LISTEN} = 'https://*:' . $watch_port . $certs;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development Watch Server on $watch_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./watch.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro Watch Server on port " . $watch_port . "\n";
				my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
				$prefork->load_app('./watch.pl');
				$prefork->workers(4);
				$prefork->run;
			}
		});

		threads->create(sub() { 
			$ENV{PURPOSE} = "teletype";
			$ENV{MOJO_LISTEN} = 'https://*:' . $tty_port . $certs;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTY Server on $tty_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./teletype.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTY Server on port " . $tty_port . "\n";
				my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
				$prefork->load_app('./teletype.pl');
				$prefork->workers(3);
				$prefork->run;
			}
		});
		threads->create(sub() { 
			$ENV{MOJO_LISTEN} = 'http://*:' . $ws_tty_port ;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTYws Server on $ws_tty_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./teletype.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTYws Server on port " . $ws_tty_port . "\n";
				my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
				$prefork->load_app('./teletype.pl');
				$prefork->workers(1);
				$prefork->run;
			}
		});
	}


	print "Starting Alarm Clock\n";
	$ENV{PURPOSE} = "alarm";
	require './Alarm.pl';
	$gb::alarm_running = 0;
	$gb::budget_running = 0;
	$gb::housekeeping_running = 0;
	$gb::clothesline_running = 0;

	threads->create(sub() {
		if ($gb::alarm_running != 1) {
			$gb::alarm_running = 1;
			$gb::alarm_running = 0;
		}
		&Alarm::alarm_clock();# if $config->{'environment'} eq 'production';
	});
	my $aid = Mojo::IOLoop->recurring($gb::timeouts->{'alarm_haircut'} => sub () {
		if ($gb::alarm_haircut_running != 1) {
			$gb::alarm_haircut_running = 1;
			$gb::alarm_haircut_running = 0;
		}
		&Alarm::alarm_haircut() if $config->{'environment'} eq 'production';
	});
	threads->create(sub() {
		while (1) {
			if ($gb::budget_running == 0) {
				$gb::budget_running = 1;
				$gb::budget_running = &Alarm::budget_watcher();
			}
			sleep ($gb::timeouts->{'budget'});
		}
	});
	if ($device eq 'mobile') {
		my $sms = Mojo::IOLoop->recurring($gb::timeouts->{'sms'} => sub() {
			my $returner = &subs::sms_list_check();
		});
	}
	my $backups = Mojo::IOLoop->recurring($gb::timeouts->{'backups'} => sub() {
		my ($db,$database,$sql) = &subs::database_grabber();
		if ($db) {
			my $c = app->build_controller;
			my $suds = &subs::suds_grabber();
			$c->session('suds' => $suds);
			$c->param('reason' => 'backup');
			if ($suds ne '') {
				&subs::backup_now($c);
			}
		}
	});

	my $clothes = Mojo::IOLoop->recurring($gb::timeouts->{'clothesline'} => sub() {
		if ($gb::clothesline_running == 0) {
			$gb::clothesline_running = 1;
			&subs::hang_to_dry();
			$gb::clothesline_running = 0;
		}
	});
	my $tasks = Mojo::IOLoop->recurring($gb::timeouts->{'tasks'} => sub() {
		if ($gb::tasks_running == 0) {
			$gb::tasks_running = 1;
			$gb::tasks_running = &Alarm::task_checker();
		}
	});
	#threads->create(sub() {
	#	my ($db,$database,$sql) = &subs::database_grabber('new');
	#	$log->info($sql);
		Mojo::IOLoop->recurring($gb::timeouts->{'remote_machine_sync'} => sub() {
			$log->info('doing negotiator');
			#if ($gb::syncing == 0) {
				$gb::syncing = 1;
				my $gimme;


				my $hour = localtime( &subs::rightNow() / 1000 )->strftime( "%H");
				if ($hour eq 4) {
					$gimme = '3d';
				}
				&subs::remote_machine_negotiator({ gimme => $gimme });
				$gb::syncing = 0;
			#}
#			sleep($gb::timeouts->{'remote_machine_sync'});
		});
	#});
	my $websites = Mojo::IOLoop->recurring($gb::timeouts->{'headless_browser'} => sub() {
		&subs::headless_browser();
	});
	if ($device eq 'mobile') {
		my $websites = Mojo::IOLoop->recurring($gb::timeouts->{'telephone_check'} => sub() {
			&subs::telephone_contacts_check();
			&subs::telephone_call_log_check();
		});
		&subs::telephone_call_log_check();
	}

	my $house = Mojo::IOLoop->recurring($gb::timeouts->{'housekeeping'} => sub() {
		if ($gb::housekeeping_running == 0) {
			$gb::housekeeping_running = 1;
			$gb::housekeeping_running = &Alarm::housekeeping();
		}
	});

	Mojo::IOLoop->start;



#	while (1) {
#		sleep 1;
#	}
	END {
		print "quitting now!\n";
		print "They dead\n";
	#	`./scripts/manager_killer.pl`;
	}
}

&manager_starter();

sub home() {
	my ($inhabitant) = @_;
	my $com = 'echo $HOME';
	my $cwd = `$com`;
	chomp $cwd;
	$inhabitant =~ s/~/$cwd/;
	return $inhabitant;
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

