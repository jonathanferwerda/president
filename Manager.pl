#!/usr/bin/env perl
package Manager;
use threads;
use strict;
no warnings 'uninitialized';

use Mojolicious::Lite -signatures;
use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use feature 'signatures';
no warnings 'experimental::signatures';
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
plugin 'RenderFile';

use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;
use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Authen::SASL;
use Net::IMAP::Client;
use MIME::Parser;
use Email::Stuffer;
use Email::Sender::Transport::SMTP;


require "./Websocket.pl";
require "./subroutines.pl";
require "./Music.pl";
require "./hooks.pl";



my $tuuid    = Data::UUID->new;
my $thread_uuid = $tuuid->create_str();
my $universal_splitter = $gb::universal_splitter;
our $database;
our $sql;
our $config_file = read_file('./config.json');
our $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my $environment = $config->{'environment'};
our $random_caching_string = &subs::random_string_creator(10);
my $duty_file = &subs::home('~/.president/on_duty');
write_file($duty_file, &subs::rightNow());
$subs::database_holder->{'last_restart'} = &subs::rightNow();

my $main_process = $$;
my $device = &subs::device_setter();
my $user_agent = $gb::user_agent;

if ($device eq 'mobile' && `ps -e | grep sshd` eq '') {
	`sshd`;
}

sub record_video($data) {
	return if $device eq 'mobile';
	my $app = $data->{'app'};
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } ));

	my $filename = $folder . '/' . $app;
	`mkdir -p $filename` unless -e $filename;
	$filename = $filename . '/' . $app . '_' . $timestamp . '.webm';

	threads->create(sub() {
		`ffmpeg -i /dev/video0 $filename`;
	});

	return [];
}

sub record_audio($data) {
	my $app = $data->{'app'};
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } ));
	my $filename = $folder . '/' . $app;
	`mkdir -p $filename` unless -e $filename;
	if ($device eq 'mobile') {
		$filename = $filename . '/' . $app . '_' . $timestamp . '.mp3';
	}
	else {
		$filename = $filename . '/' . $app . '_' . $timestamp . '.wav';
	}

	if ($device eq 'mobile') {
		threads->create(sub() {	
			`termux-microphone-record -l 0 -e mp3 -f $filename`; 
		});
	}
	elsif ($device eq 'computer') {
		threads->create(sub() {	
			`rec $filename`;
		});
	}
	return [];
};

sub record_video_stop($data) {
	return if $device eq 'mobile';
	my $app = $data->{'app'};
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};


	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } ));

	my $filename = $folder . '/' . $app;
	`mkdir -p $filename` unless -e $filename;

	`pkill ffmpeg`;
	my $stopped = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
	if ($stopped->{'uuid'} && $stopped->{'type'} eq 'record') {

		my $files = eval { return decode_json $stopped->{'file'} } || [];
		$filename = $filename . '/' . $app . '_' . $timestamp . '.webm';
		my $duration = $timestamp - $stopped->{'timestamp'};
		my $data = { server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(16), type => 'video' };
		$data = &thumbnail_creator($data);
		push @{$files}, $data;
		my $jdata = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			duration => $duration,
			encryption_standard => undef,
			file => $jdata,
			type => 'video',
			stop_timestamp => &subs::rightNow(),
			stop_seen => 'yes',
			seen => 'yes'
		},
		{
			app => $app,
			uuid => $uuid
		});
		sleep 2;
		&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
		&subs::file_encrypter({ app => $app });
	}
	return $filename;
}

sub record_audio_stop($data) {
	my $c = $data->{'c'};
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $uuid = $data->{'uuid'};
	my $filename;

	if ($device eq 'mobile') {
		`termux-microphone-record -q`;
	}
	elsif ($device eq 'computer') {
		`pkill rec`;
	}
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } ));
	my ($db) = &subs::database_grabber();
	my $stopped = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
	if ($stopped->{'uuid'} && $stopped->{'type'} eq 'record') {
		$filename = $folder . '/' . $app;
		`mkdir -p $filename` unless -e $filename;
		if ($device eq 'mobile') {
			$filename = $filename . '/' . $app . '_' . $timestamp . '.mp3';
		}
		else {
			$filename = $filename . '/' . $app . '_' . $timestamp . '.wav';
		}
		my $duration = $timestamp - $stopped->{'timestamp'};

		my $files = eval { return decode_json $stopped->{'file'} } || [];

		my $data = { server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(16), type => 'audio' };
		push @{$files}, $data;
		my $jdata = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			duration => $duration,
			encryption_standard => undef,
			file => $jdata,
			type => 'audio',
			stop_timestamp => &subs::rightNow(),
			stop_seen => 'yes',
			seen => 'yes'
		},
		{
			app => $app,
			uuid => $uuid
		});
		&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
		&subs::file_encrypter({ app => $app });
	}
	return $filename;
}

sub timestamp_adjuster($c) {
	my $timestamp = $c->param('timestamp');
	my $time_machine = $c->param('time_machine');
	my $timeshift = $c->param('timeshift');
	my $ago = $c->param('ago');
	if ($time_machine) {
		$timestamp = &subs::ago_calc($time_machine,$timestamp);
	}
	if ($timeshift) {
		if ($timeshift =~ /[0-9]/gi) {
			$timestamp = &subs::ago_calc($timeshift,$timestamp);
		}
	}
	if ($ago) {
		$timestamp = &subs::ago_calc($ago,$timestamp);
	}
	return $timestamp;
}

post '/manager/take_picture' => sub($c) {
	my $timestamp = &timestamp_adjuster($c);
	my $camera = $c->param('camera');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my ($file,$ocr);
	my $data = { 
		app => $app, 
		timestamp => $timestamp, 
		camera => $camera, 
		uuid => $uuid, 
		duty => 'image',
		duuid => &subs::random_string_creator()
	};
	if ($timestamp >= &subs::rightNow() + 1000) {
		my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0];
		my $duties = eval { return decode_json $appt->{'duties'} } || [];
		push @{$duties}, $data;
		@{$duties} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$duties};
		my $next_duty = $duties->[0]->{'timestamp'};
		my $jduties = encode_json $duties;
		&subs::db_update('appointments', { duties => $jduties, next_duty => $next_duty, server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
	}
	else {
		($file,$ocr) = &take_picture($c,$data);
	}
	&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
	$c->render(json => { files => $file, ocr => $ocr });
};

sub take_picture($c,$data) {
	my $uuid = $data->{'uuid'} || undef;
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $app = &subs::unformat_name($data->{'app'} || $c->param('app'));
	unless ($c->session('suds')) {
		$c->session('suds' => &subs::suds_grabber());
		$c->stash('app' => $app);
		$c->stash('uuid' => $uuid);
	}
	if (!grep { $_ eq $data->{'camera'} } @{$gb::capabilities->{&subs::device_setter()}->{'camera'}}) {
		&remote_relay_request($c);
		return ('denial','denial');
	}


	my $camera = $data->{'camera'} || 0;
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'app', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time);
	my ($filename,$ocr);
	my ($db,$database,$sql) = &subs::database_grabber();
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } ));
	$filename = $folder . '/' . $app;
	

	my $resolution = &subs::setting_grabber({ app => 'misc', setting => 'photo_size' } ) || '1920x1080';
	`mkdir -p $filename` unless -e $filename;
	my $thumb = $filename . '/thumbs/';
	`mkdir -p $thumb` unless -e $thumb;
	$thumb = $thumb . $app . '_' . $timestamp . '.jpg';
	$filename = $filename . '/' . $app . '_' . $timestamp;

	my $text_file = $filename;
	$filename = $filename . '.jpg';


	if ($device eq 'mobile' && ($camera eq 0 || $camera == 1)) {
		`termux-camera-photo -c $camera $filename`;
	}
	elsif ($device eq 'computer' && $camera eq 'webcam') {
		eval { `ffmpeg -i /dev/video0 $filename` };
	}
	if (-e $filename) {
		$ocr = &ocr_reader($c,$filename);
		`magick $filename -resize $resolution $filename` unless lc $resolution eq 'raw';
	}
	my $duration = $server_time - &subs::rightNow();
	my $u_data = { thumb => $thumb, server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(9), type => 'image', ocr => $ocr };
	$u_data = &thumbnail_creator($u_data);

	my $files = [$u_data];
	if ($uuid) {
		my $appt = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
		my $pre_files = eval { return decode_json $appt->{'file'} } || [];
		push @{$files}, @{$pre_files};
		my $jfiles = encode_json $files;
		&subs::db_update('appointments', { encryption_standard => undef, duration => $duration, file => $jfiles, server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
	}
	else {
		$uuid = &subs::random_string_creator(20);
		my $jfiles = encode_json $files;
		&appointment_writer($c, {
			app => $app,
			type => 'image',
			file => $jfiles,
			timestamp => $timestamp,
			server_time => $server_time,
			uuid => $uuid,
			warranty => $warranty,
			duration => $duration
		});
	}
	my $jfiles = encode_json $files;
	&subs::file_encrypter({ app => $app });

	return ($jfiles,$ocr);
}

post '/manager/scan_document' => sub($c) {
	my $timestamp = &timestamp_adjuster($c);
	my $feed = $c->param('feed');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $scandata = {
		timestamp => $timestamp,
		feed => $feed,
		uuid => $uuid,
		app => $app,
		source => 'existing',
		duty => 'scan',
		duuid => &subs::random_string_creator()
	};
	my $file;
	if ($timestamp >= &subs::righNow() + 1000) {
		my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0];
		my $duties = eval { return decode_json $appt->{'duties'} } || [];
		push @{$duties}, $scandata;
		@{$duties} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$duties};
		my $next_duty = $duties->[0]->{'timestamp'};
		my $jduties = encode_json $duties;
		&subs::db_update('appointments', { duties => $jduties, next_duty => $next_duty, server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
	}
	else {
		$file = &scan($c, $scandata);
	}


	&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
	$c->render(json => { files => $file });
};


sub scan($c,$scandata) {
	my $timestamp = $scandata->{'timestamp'};
	my $feed = $scandata->{'feed'};
	my $uuid = $scandata->{'uuid'};
	my $suds = $c->session('suds') || &subs::suds_grabber();
	$c->session('suds' => $suds);
	my $source = $scandata->{'source'};
	my $app = $scandata->{'app'} || $c->param('app');
	if (!grep { $_ eq $scandata->{'feed'} } @{$gb::capabilities->{&subs::device_setter()}->{'scan'}}) {
		&remote_relay_request($c);
		return 'denial';
	}
	my ($db,$database,$sql) = &subs::database_grabber();

	my $start_time = &subs::rightNow();
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'scan_location', device => $device } ));
	my $filename = $folder . '/' . $app;
	$filename = &subs::home($filename);
	`mkdir -p $filename` unless -e $filename;
	my $thumb_folder = $filename . '/thumbs';
	`mkdir -p $thumb_folder` unless -e $thumb_folder;
	my $thumb = $thumb_folder . '/' . $app . '_' . $timestamp . '.jpg';
	my $file = $filename . '/' . $app . '_' . $timestamp;
	my $image_file = $file . '.jpg';
	my $printer = &subs::device_lister($timestamp,'printer');
	Mojo::IOLoop->subprocess->run_p(sub {
		my $command;
		($db,$database,$sql) = &subs::database_grabber();
		my $scanner = $config->{'scanners'}->[0];
		my $address = ("hpaio:/net/officejet_3830_series?ip=" . $printer->{'ip'}) || $scanner-{'address'};
		my $resolution = $scanner->{'resolution'};
		if ($feed eq 'flatbed' && grep { lc $_ eq 'flatbed' } @{$scanner->{'feeds'}}) {
			$command = "scanimage --format tiff --source Flatbed --batch=$file.tiff --mode Color -d $address --resolution=$resolution;";
		}
		elsif ($feed eq 'adf' && grep { lc $_ eq 'adf' } @{$scanner->{'feeds'}}) {
			$command = "scanimage --format tiff --source ADF --batch=$file\_\%d.tiff --mode Color -d $address --resolution=$resolution;";
		}
		my $caseworker = `$command`;
		my $scans = `ls -tr $file*.tiff`;
		sleep 1;
		my @scans = split "\n",$scans;
		my @filenames;
		my $count = 1;
		my $photo_size = &subs::setting_grabber({ app => 'misc', setting => 'scan_size', device => $device } ) || '1920x1080';
		foreach my $scan (@scans) {
			$file = $scan;
			$file =~ s/\.[^.]+$//;
			$image_file = $file . '.jpg';

			my @image_file = split /\//, $image_file;
			my $thumb_file = pop @image_file;
			$thumb = $thumb_folder . '/' . $thumb_file;


			my $ocr = &ocr_reader($c,$scan);
			if ($photo_size ne "Raw") {
				my $convert = `magick convert $scan -resize $photo_size $image_file`;

			}
			else {
				my $convert = `magick convert $scan $image_file`;
			}
			`shred -u $scan`;
			push @filenames, { f => $image_file , thumb => $thumb, ocr => $ocr};
			
			$count++;

		}
		my $fnames = [];
		foreach my $f ( @filenames ) {
			my $file_data = { server_time => &subs::rightNow(), ocr => $f->{'ocr'}, f => $f->{'f'}, thumb => $f->{'thumb'}, uuid => &subs::random_string_creator(10), type => 'document', 'of' => $f->{'f'} };
			$file_data = &thumbnail_creator($file_data);
			push @{$fnames}, $file_data;
		}

		if ($uuid) {
			my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0];
			my $pre_files = eval { return decode_json $appt->{'file'} } || [];
			if (scalar @{$pre_files} > 0) {
				push @{$fnames}, @{$pre_files};
			}
		}


		my $filenames = encode_json $fnames;
		my $server_time = &subs::rightNow();
		my $duration = ($start_time - $server_time );
		if (@{$fnames} > 0) {
			&subs::db_query('update appointments set server_time = ?, duration = ?, file = ?, encryption_standard = ? where app = ? and uuid = ?',
				&subs::rightNow(),$duration, $filenames, undef, $app, $uuid );
			&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
		}
		elsif ( scalar @filenames == 0 && $source ne 'existing' ) {
			&subs::db_delete('appointments', { uuid => $uuid });
			&Websocket::send('server', { console => '$(\'appointment_detail[app="' . $app . '"][uuid="' . $uuid . '"]\').remove();'});
		}
		&subs::file_encrypter({ app => $app });
	});
	&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
	return encode_json [{ f => $image_file }];
}

sub ocr_reader($c,$filename) {
	my $text_file = $filename;
	`tesseract $filename $text_file`;
	$text_file = $text_file . '.txt';
	my $ocr = read_file($text_file);
	$ocr =~ s/[^\x00-\x7F]+//gi;
	$ocr = &subs::note_encrypter($c->session('suds'),$ocr);
	`shred -u $text_file`;

	return $ocr;
}

sub play_audio($file) {
	threads->create(sub() {
		$file = &subs::terminal_name($file);
		if ( `ps -e | grep play` ) {
			`pkill play`;
		}
		else {
			Mojo::IOLoop->subprocess->run_p(sub {
				`play "$file"`;
			});
		}
	});
	return $file;
}

sub play_audio_stop($file) {
	`pkill play`;
	return $file;
}



get '/file_open' => sub($c) {
	my $data = &rock_and_roll($c);
#	$c->render(text => 'no') if $data eq 'no';
};


sub rock_and_roll($c) {
	my $man = 'rejected';
	my $file = $c->param('file');
	if ($c->param('remote_uuid') && $c->param('remoted') ne 'yes') {
		$c->param('subprocess' => 'yes');
		my $result = &remote_relay_request($c);

		$c->render(data => $result);
		
		return;
	}
	my ($db,$database,$sql) = &subs::database_grabber();

	my $mag;


	unless ( $c->session('authentication') eq 'approved' ) {


		my $uuid = $c->param('uuid');
		my $fq = &subs::db_query('select * from magazine where uuid = ?',$uuid );
		$mag = $fq->hashes->[0];
		if ($mag->{'status'} eq 'publish') {
			my $public = &subs::setting_grabber({ app => &subs::unformat_name($mag->{'title'}), setting => 'public' });
			
			if ($public eq 'on' && $mag-{'content'} =~ /$file/) {
				$man = 'approved';
			}

		}
	}
	else {
		$man = &authentication_passer($c);
	}
	if ($man eq 'approved') {
		my $tdir = $gb::tmp_dir;

		$file = uri_decode $c->param('track') unless $file;
		my $timestamp = $c->param('timestamp') || &subs::rightNow();
		my $filename = $file;
	#	return 'no' unless -e &subs::terminal_name($file);

		if ($c->param('as_is') && -e $file) {
			my $data = read_file($file);
			$data = encode_base64 $data;
			$c->render(data => $data);
			return;
		}
		elsif ($c->param('as_is')) {
			$c->render(text => 'not found');
			return;
		}
		my $app = &subs::unformat_name($c->param('app'));
		my $writer = {
			timestamp => $timestamp,
			app => &subs::unformat_name($mag->{'title'}) || $app,
			file => $file,
			uuid => $mag->{'uuid'},
			type => 'file'
		};
		my @file_split = split /\//, $file;
		my $file_match = $file_split[-1];
		my $appt_q;
		if ($c->param('app_uuid')) {
			$appt_q = &subs::db_query('select * from appointments where uuid=? and app=? LIMIT 1',$c->param('app_uuid'), $app);
		}
		else {
			$appt_q = &subs::db_query('select * from appointments where file like ? and app=? and (server_time=? or timestamp=?) LIMIT 1','%' . $file_match . '%', $app,$timestamp,$timestamp);
		}
		my $appter = $appt_q->hashes;
		my $appt_server_time = $appter->[0]->{'server_time'};
		my $atf = eval { return decode_json $appter->[0]->{'file'} } || [];
		my $file_data = {};
		my $thumbnail_size = &subs::setting_grabber({ app => 'misc', setting => 'thumbnail_size' }) || 'none';
		foreach my $af ( @{$atf} ) {
			if ($file eq $af->{'f'}) {
				$appt_server_time = $af->{'server_time'};
				$file_data = $af;

				if ($af->{'thumb'} && $c->param('thumb') && $thumbnail_size ne 'none') {
					if (-e $af->{'thumb'}) {
						$file = $af->{'thumb'};
						$c->param('thumb' => undef);
					}
				}
			}
		}
		if ($file =~ /\.enc$/gi) {
			my $encryption_standard = $appter->[0]->{'encryption_standard'} || &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || "aes-256-ctr";
			my @encryption_standards = ( $encryption_standard );
			if (!$appter->[0]->{'uuid'}) {
				my @file_splitter = split /\//, $file;

				$appt_q = &subs::db_query('select * from appointments where app = ? and file is not null and file like ?',$app,'%' . $file_splitter[-1] . '%' );
				my $apptser = $appt_q->hashes;
				my $appt_server_time = $apptser->[0]->{'server_time'};
				foreach my $at ( @{$apptser} ) {
					if ( $at->{'encryption_standard'} ne $encryption_standard ) {
						push @encryption_standards, $at->{'encryption_standard'};
					}
					my $atf = eval { return decode_json $at->{'file'} } || [];
					foreach my $af ( @{$atf} ) {
						if ($file eq $af->{'file'}) {
							$appt_server_time = $af->{'server_time'};
							$file_data = $af;
							if ($af->{'thumb'} && $c->param('thumb') && $thumbnail_size ne 'none') {
								if (-e $af->{'thumb'}) {
									$file = $af->{'thumb'};
									$c->param('thumb' => undef);
								}
							}
						}
					}
				}
			}

			unless ($appt_server_time) {
				if (-e $file) {
					my @stat = stat($file);
					$appt_server_time = $stat[10] * 1000;
				}
			}
			my $suds = $c->session('suds');
			my $passwords = &subs::db_query('select * from security where level != ? and timestamp <= ? order by timestamp DESC','padlock',$appt_server_time);
			my $pwords = $passwords->hashes;
			foreach my $p ( @{$pwords} ) {
				my $secret = &subs::decrypter($suds, $p->{'credential'}, $appt_server_time);
				my $filename = $file;
				$filename =~ s/\.enc$//gi;
				foreach my $es ( @encryption_standards ) {
					my $data =	`openssl enc -d -k "$secret" -$encryption_standard -pbkdf2 -in $file`;
					my $ft = File::Type->new();
					my $fd = $ft->checktype_contents($data);

					if ($fd ne 'application/octet-stream' || ($file =~ /webm/)) {
						my @ext = split /\./, $file;
						my $ext = $ext[-2];
						if ($c->param('duty')) {
							return { 
								data => $data, 
								image => 'data:' . $fd . ';base64,' . encode_base64($data,''), 
								fd => $fd, 
								timestamp => $appt_server_time,
								ext => $ext
							};
						}
						elsif ($fd =~ /pdf/) {
							$c->render(format => 'pdf', data => $data);
							return;
						}
						else {
							if ($c->param('thumb') eq 'ya') {

								my @filename = split /\./, $file;
								my $ext = $filename[-2];
								unless ( -e $file_data->{'thumb'}) {
									my $filename = $tdir . '/' .&subs::random_string_creator(20) . '.' . $ext;
									if ($file =~ /webm/) { $fd = 'video/webm'; }
									my $command = 'openssl enc -d -k "' . $secret . '" -' . $encryption_standard . ' -pbkdf2 -in ' . $file .' -out ' . $filename;
									`$command`;

									if ($file_data->{'type'} eq 'video' || grep { $_ eq $ext } qw/mp4 webm/ ) {
										my $command2 = 'ffmpeg -ss 00:00:00.010 -f ' . $ext . ' -i ' . $filename . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize ' . $thumbnail_size . ' - ';
										$file_data->{'type'} = 'video';
										$data = `$command2`;
									}
									elsif ($file_data->{'type'} eq 'image' || grep { $_ eq $ext } qw/bmp tiff jpg png/) {
										my $command2 = 'magick ' . $filename . ' -resize ' . $thumbnail_size . ' -';
										$file_data->{'type'} = 'image';
										$data = `$command2`;
									}
									if ($file_data->{'uuid'} && $data && $thumbnail_size ne 'none') {
										pop @file_split;
										my $folder = join '/', @file_split;
										$folder = $folder . '/thumbs';
										`mkdir -p $folder`;
										my $worker_id = &subs::random_string_creator(10);
										my $priority = $folder . '/priority.txt';
										my $pr = eval { return decode_json read_file($priority) } || {};
										until ($pr->{$appter->[0]->{'uuid'}}->{'state'} ne 'working' || $pr->{$appter->[0]->{'uuid'}}->{'time'} < &subs::rightNow() - 6000) {
											sleep .5;
											$pr = eval { return decode_json read_file($priority) } || {};
										}
										$pr->{$appter->[0]->{'uuid'}}->{'state'} = 'working';
										$pr->{$appter->[0]->{'uuid'}}->{'time'} = &subs::rightNow();
										$pr->{$appter->[0]->{'uuid'}}->{'worker'} = $worker_id;
										my $jpr = encode_json $pr;
										write_file($priority, $jpr);
										my $path = $folder . '/' . &subs::random_string_creator(23) . '.png.enc';

										$file_data->{'thumb'} = $path;
										$file_data->{'server_time'} = &subs::rightNow();
										$file_data = &subs::file_media_information($file_data,$filename);
										write_file($filename, $data);
										my $encrypt =	`openssl enc -e -k "$secret" -$encryption_standard -pbkdf2 -in $filename -out $path`;
										my $appt = &subs::db_select('appointments', undef, { uuid => $appter->[0]->{'uuid'}, app => $appter->[0]->{'app'} })->hashes->[0];
										$atf = eval { return decode_json $appt->{'file'} } || [];
										my @natf = grep { $_->{'uuid'} eq $file_data->{'uuid'} } @{$atf};
										if (-e $natf[0]->{'thumb'}) { my $natfthumb = $natf[0]->{'thumb'}; `shred -u $natfthumb`; }
										@{$atf} = grep { $_->{'uuid'} ne $file_data->{'uuid'} } @{$atf};

										push @{$atf}, $file_data;
										my $jdata = encode_json $atf;
										&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jdata }, { uuid => $appter->[0]->{'uuid'}, app => $appter->[0]->{'app'} });
										my $pr = eval { return decode_json read_file($priority) } || {};
										delete $pr->{$appter->[0]->{'uuid'}};
										if (scalar keys %{$pr} == 0) {`shred -u $priority`; }
										else {
											$jpr = encode_json $pr;
											write_file($priority, $jpr);
										}
									}
									Mojo::IOLoop->subprocess->run_p(sub {
										`shred -u $filename`;
									});
								}
							}
							$c->render_file(data => $data);
							return;
						}
					}
					last;
				}
			}
		}
		elsif ($c->param('duty')) {
			my $data = read_file($file);
			my $ft = File::Type->new();
			my $fd = $ft->checktype_contents($data);
			my @ext = split /\./, $file;
			my $ext = $ext[-1];
			my $server_time;
			if (-e $file) {
				my @stat = stat($file);
				$server_time = $stat[10] * 1000;
			}
			return { 
				data => $data, 
				image => 'data:' . $fd . ';base64,' . encode_base64($data,''), 
				fd => $fd, 
				timestamp => $server_time,
				ext => $ext
			};
		}
		elsif ($device eq 'mobile') {
			if (-e $file) {
				if ($c->param('subtitle')) {
					my $sub_file = $file . '.vtt';
					if (-e $sub_file) {
						my $data = read_file($sub_file);
						$c->render_file(filepath => $sub_file);
						return;
					}
					else {
						my $command = 'ffmpeg -i ' . &subs::terminal_name($file) . ' -map 0:s:0 ' . &subs::terminal_name($sub_file);
						`$command`;
						if (-e $sub_file) {
							my $data = read_file($sub_file);
							$c->render_file(data => $data, type => 'text/vtt');
							return;
						}
						else {
							return $c->reply->not_found;
						}
					}
				}
				if ($c->param('thumb')) {
					my $data;
					if ($file_data->{'uuid'} && ! -e $file_data->{'thumb'} && $thumbnail_size ne 'none') {
						my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $file, app => $appter->[0]->{'app'}, type => $file_data->{'type'}, is_thumb => 1 });
						$file_data->{'type'} = $type;
						$file_data->{'thumb'} = $destination . $asset;
						
						$file_data = &thumbnail_creator($file_data);
						$data = read_file($file_data->{'thumb'});
						$c->render(data => $data);
						return;
					}
					else {
						my $filename = $tdir . '/' . &subs::random_string_creator(20) . '.png';
						my $command = 'ffmpeg -ss 00:01:30.010 -i ' . &subs::terminal_name($file) . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize 200x200 -';
						my $data = `$command`;
						$c->render_file(data => $data);
						return;
					}
				}
				else {
					my $sdata = read_file($file);
					$c->render_file('data' => $sdata);
					return;
				}
			}
		}
		else {
			if (-e $file) {
				if ($c->param('subtitle')) {
					my $sub_file = $file . '.vtt';
					if (-e $sub_file) {
						my $data = read_file($sub_file);
						$c->render_file(filepath => $sub_file);
						return;
					}
					else {
						my $command = 'ffmpeg -i ' . &subs::terminal_name($file) . ' -map 0:s:0 ' . &subs::terminal_name($sub_file);
						`$command`;
						if (-e $sub_file) {
							my $data = read_file($sub_file);
							$c->render_file(data => $data, type => 'text/vtt');
							return;
						}
						else {
							return $c->reply->not_found;
						}
					}
				}
				if ($c->param('thumb')) {
					my $data;
					if ($file_data->{'uuid'} && ! -e $file_data->{'thumb'} && $thumbnail_size ne 'none') {
						my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $file, app => $appter->[0]->{'app'}, type => $file_data->{'type'}, is_thumb => 1 });
						$file_data->{'type'} = $type;
						$file_data->{'thumb'} = $destination . $asset;
						
						$file_data = &thumbnail_creator($file_data);
						$data = read_file($file_data->{'thumb'});
						$c->render(data => $data);
						return;
					}
					else {
						my $filename = $tdir . '/' . &subs::random_string_creator(20) . '.png';
						my $duration = $c->param('duration');

						my @folder = split /\//, $file;
						my $tfile = pop @folder;
						my $folder = join '/', @folder;
						my $thumb_folder = $folder . '/thumbs';
						my $tfd = &subs::terminal_name($thumb_folder);
						`mkdir -p $tfd` unless -e $thumb_folder;
						my @tfile = split /\./, $tfile;
						pop @tfile;
						if ($c->param('chapter') eq 'ya') {
							$tfile = (join '.', @tfile) . ' ' . $c->param('id') . '.png';
							if ($c->param('end_time')) {
								$duration = (($c->param('end_time') - $c->param('start_time')) / 2 + $c->param('start_time'));
							}
							else {
								$duration = $c->param('start_time') + 5;
							}
						}
						else {					
							$tfile = (join '.', @tfile) . '.png';
						}
						$tfile = $thumb_folder . '/' . $tfile;
						if ( -e $tfile && !$c->param('position')) {
							$data = read_file($tfile);
						}
						else {
							my $save = 1;
							if ($c->param('position')) {
								$duration = $c->param('position');
								$save = 0;
							}
							elsif ($c->param('chapter') ne 'ya') {
								if ($duration < 10) {
									$duration = '00:00:01.000';
								}
								elsif ($duration < 60) {
									$duration = '00:00:12.000';
								}
								elsif ($duration < 120) {
									$duration = '00:01:01.000';
								}
								else {
									$duration = '00:02:00.020';
								}
							}
							my $command = 'ffmpeg -ss ' . $duration . ' -i ' . &subs::terminal_name($file) . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize 200x200 -';
							$data = `$command`;
							
							write_file($tfile, $data) if $save == 1;	
						}
					}
					$c->render_file(data => $data);
					return;
				}
				else {
					$c->render_file('filepath' => $file);
					return;
				}
			}
			else {
				$c->render('text' => '');
				return;
			}
		}
	}
	else {
		$c->render('text' => 'no');
		return;
	}
}


sub appointment_writer($c,$app) {
#	&subs::cache_delete({ app => $app->{'app'}, context => 'template' });
	$app->{'server_time'} = $app->{'server_time'} || &subs::rightNow();
	$app->{'timestamp'} = $app->{'server_time'} unless $app->{'timestamp'};
	$app->{'browser_tab_id'} = $c->param('browser_tab_id') if $c->param('browser_tab_id') && !$app->{'browser_tab_id'};
	my $remote_address = $app->{'remote_address'};
	delete $app->{'remote_address'};
	my $timestamp = $app->{'timestamp'};
	my $server_time = $app->{'server_time'};
	$app->{'device'} = $device;
	$app->{'uuid'} = $app->{'uuid'} || &subs::random_string_creator(90);
	if ($app->{'timestamp'} <= $app->{'server_time'} + 1000) {
		$app->{'seen'} = 'yes';
	}
	my ($db,$database,$sql) = &subs::database_grabber();
	my $init = &subs::setting_initializer($app->{'app'},$app->{'timestamp'});
	$app->{'app'} = $init->{'app'};
	($app->{'app'},undef) = &subs::typesetter($app->{'app'});
	my $settings = &subs::settings_grabber({ app => $app->{'app'} });
	if ($app->{'type'} eq 'usual' || $app->{'type'} eq 'start' || $app->{'type'} eq 'record') {
		my ($model,$options);
		($model,$options,$app->{'model'},$app->{'options'}) = &subs::usual_appointment_maker($app,$settings);
		if ($model->{'unit'} && !$app->{'unit'}) {
			$app->{'unit'} = $model->{'unit'};
		}
		if ($model->{'quantity'} && !$app->{'quantity'}) {
			$app->{'quantity'} = $model->{'quantity'};
		}
	}

	my $warranty_holder = $app->{'timestamp'} > $app->{'server_time'} ? $app->{'timestamp'} : $app->{'server_time'};
	$app->{'warranty'} = $app->{'warranty'} || &subs::ago_calc(($init->{'warranty'} || '-10y'), $warranty_holder);
	$app->{'project'} = $settings->{'t_project'} unless $app->{'project'};
	$app->{'pos'} = $settings->{'pos'} unless $app->{'pos'};


	if ($app->{'type'} eq 'record') {
		my $recording_type = &subs::setting_grabber({ app => $app->{'app'}, setting => 'record' });
		my $dat = { recorder => $recording_type };
		
		if ($recording_type eq 'video') {
			$app->{'seen'} = undef;
		#	$dat->{'camera'} = $camera;

		}
		elsif ($recording_type eq 'audio') {
			$app->{'seen'} = undef;
		}
		elsif ($recording_type eq 'screen') {
			$app->{'seen'} = undef;
		}
		elsif ($recording_type eq 'security') {
			&record_video({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
		}
		else {
			&record_audio({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
		}
		$app->{'data'} = encode_json $dat;
	}



	if ($app->{'uuid'} && 0) {
		my $pa = &subs::db_query('select * from appointments where uuid=?', $app->{'uuid'});
		my $prev = $pa->hashes->[0];
		if ($prev->{'app'}) {
			my $duration = ($prev->{'duration'} + (&subs::rightNow() - $prev->{'timestamp'}));
			&subs::db_query('update appointments set duration=?, timestamp=? where uuid=?', $duration, $app->{'timestamp'}, $app->{'uuid'});
		}
		else {
			&subs::db_insert('appointments', $app);
		}
	}
	if ($app->{'type'} eq 'stop') {

		my $appts = &subs::db_query('select * from appointments where app=? and (type=? or type = ? ) and timestamp < ? order by timestamp asc', $app->{'app'},'start','record',$app->{'timestamp'})->hashes;
		return {} unless scalar @{$appts} > 0;
		foreach my $appt ( @{$appts} ) {
			$app->{'type'} = 'stop';
			$app->{'duration'} = $appt->{'timestamp'} - $app->{'timestamp'};
			$app->{'uuid'} = $appt->{'uuid'};
			my $recording_type = &subs::setting_grabber({ app => $app->{'app'}, setting => 'record' }) || 'system';
			if ($appt->{'type'} eq 'record') {
				my $dat = eval { return decode_json $appt->{'data'} } || {};

				if ($dat->{'recorder'} eq 'security') {
					if ($app->{'seen'} eq 'yes') {
						&record_video_stop({ app => $app->{'app'}, timestamp => $appt->{'timestamp'}, uuid => $appt->{'uuid'} }) if $appt->{'uuid'};
						next;
					}
					else { $app->{'type'} = 'record'; };
				}
				elsif ($dat->{'recorder'} eq 'system') {
					if ($app->{'seen'} eq 'yes') {
						&record_audio_stop({ app => $appt->{'app'}, timestamp => $appt->{'timestamp'}, uuid => $appt->{'uuid'} }) if $appt->{'uuid'};
						next;
					}
					else { $a->{'type'} = 'record'; };
				}
				else {
					&Websocket::send('music', { console => 'jpStop(\'' . $appt->{'app'} . '\',\'' . $dat->{'recorder'} . '\',\'' . $appt->{'uuid'} . '\');' });
				}
			}



			&subs::intelligent_automation_toggle({ appt_uuid => $app->{'uuid'}, app => $app->{'app'}, 'state' => 'off', timestamp => $app->{'timestamp'}, remote_address => $remote_address });
			my $sources = &subs::db_select('appointments', undef, { source_uuid => $app->{'uuid'} })->hashes;
			my $options = eval { return decode_json $appt->{'options'} } || [];
			my $model = eval { return decode_json $appt->{'model'} } || {};
			push @{$options}, $model if $model->{'uuid'};

			foreach my $so ( @{$sources} ) {
				push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
				if ( $so->{'type'} eq 'start' ) {
					my $dur = $so->{'timestamp'} - $timestamp;


					my @current_option = grep { $_->{'name'} eq $so->{'app'} } @{$options};
					my $co = $current_option[0];
					my $so_data = { 
						duration => $dur, 
						server_time => $server_time,
					};
					my $ts = $timestamp;
					if ($co->{'delay_stop'}) {
						my $t = &subs::time_abbrev_translator($co->{'delay_stop'});
						$ts = $ts + $t;
						$dur = $dur + $t;
						$so_data->{'duration'} = $dur;
						$so_data->{'stop_timestamp'} = $ts;
					}
					my $so_data = { stop_timestamp => $ts, duration => $dur, server_time => $server_time };
					if ($ts <= &subs::rightNow()) {
						$so_data->{'type'} = $app->{'type'};
						$so_data->{'stop_seen'} = 'yes';
						$so_data->{'stop_timestamp'} = $app->{'timestamp'}
					}

					&subs::db_update('appointments', $so_data, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'} });
					&budget_runner($so->{'app'});
					&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'off', timestamp => $ts, remote_address => $remote_address });
					&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
				}
			}
			&subs::db_update('appointments', { stop_timestamp => $app->{'timestamp'}, stop_seen => 'yes', duration => $app->{'duration'}, type => $app->{'type'}, server_time => &subs::rightNow() }, { uuid => $appt->{'uuid'}, app => $app->{'app'} });
		}
	}
	else {
		if ($app->{'type'} eq 'start' || $app->{'type'} eq 'record') { 
			&subs::intelligent_automation_toggle({ appt_uuid => $app->{'uuid'}, app => $app->{'app'}, 'state' => 'on', timestamp => $app->{'timestamp'}, remote_address => $remote_address });
			if ($app->{'stop_timestamp'}) {
				&subs::intelligent_automation_toggle({ appt_uuid => $app->{'uuid'}, app => $app->{'app'}, 'state' => 'off', timestamp => $app->{'stop_timestamp'}, remote_address => $remote_address });		
			}

			if ($app->{'type'} eq 'record') {
				my $jdata;

				my $recording_type = &subs::setting_grabber({ app => $app->{'app'}, setting => 'record' }) || 'system';
				my $dat = { recorder => $recording_type };
				if ($recording_type eq 'video') {
					$app->{'seen'} = undef;
					#$dat->{'camera'} = $camera;
				}
				elsif ($recording_type eq 'audio') {
					$app->{'seen'} = undef;
				}
				elsif ($recording_type eq 'screen') {
					$app->{'seen'} = undef;
				}
				elsif ($recording_type eq 'video_front') {
				#	$dat->{'camera'} = $camera;
				}
				elsif ($recording_type eq 'security') {
					&record_video({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
				}
				else {
					&record_audio({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
				}
				$app->{'data'} = encode_json $dat;

			}
		}
		&subs::db_insert('appointments', $app);
	}

	&Websocket::send('tab', { console => 'appointmentDetailGrabber("' . $app->{'app'} . '","' . $app->{'uuid'} .'");' });
	&Websocket::send('tab', { console => 'continent_record({\'uuid\':\'' . $app->{'uuid'} . '\', \'app\':\'' . $app->{'app'} .'\',\'purpose\':\'app\',\'timestamp\':\'' . $app->{'timestamp'} . '\',\'navigation\':"once" });' });
	&subs::appt_header_printer({ app => $app->{'app'} });
	&budget_runner($app->{'app'});

	if (1 == 0 && $app->{'app'}) {
#		unless ( &subs::db_select('appointments', ['uuid'], { uuid => $uuid })->hashes > 0) {

			my $params = Mojo::Parameters->new(%{$app});
			$params = $params->to_string;

			Mojo::IOLoop->subprocess->run_p(sub {
				my $remote_machines = &subs::db_query('select * from remote_machines where connection=?', 'active')->hashes;
				foreach my $rm ( @{$remote_machines} ) {
					$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });

					my $url = $rm->{'manager'} . '/manager/appointment/writer?' . $params;

					my $res = $rm->{'ua'}->post($url);

					my $additions = eval { return decode_json $rm->{'additions'} } || [];

				#	push @{$additions}, { app => $app, uuid => $app->{'uuid'}, scope => 'single', initialization => &subs::rightNow() };
					my $jadditions = encode_json $additions;
					&subs::db_update('remote_machines', { additions => $jadditions }, { uuid => $rm->{'uuid'}, signatorial => $rm->{'signatorial'} });
				}

			});
#		}
	}
	return $app;
}

post '/manager/appointment/writer' => sub ($c) {
	my $parameters = $c->req->body_params->{'string'};
	my $params = Mojo::Parameters->new($parameters);
	&appointment_writer($c,$params);
	$c->render(json => $params);
};




my (@appointments,@results);
get '/' => sub ($c) {
	my $homepage = &homepage_maker($c);
	$c->render('text' => $homepage);
};

get '/manager/home' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $homepage = &homepage_maker($c);
	$homepage = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'home', contents => $homepage }, $timestamp);
	$c->render('text' => $homepage);
};

sub homepage_maker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	unless ($database) {
		$c->render(template => 'guest_layouts/denial');
	}
	my $articulation;
	my $port = $c->req->url->base->port;
	my $server_time = &subs::rightNow();
	my $name = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || 'Home';
	$articulation = &subs::db_query('select * from magazine where status=? and timestamp <= ? and warranty >= ? order by timestamp DESC','publish', $server_time, $server_time);
	my $magazine_categories = [];# = $mag_cat->hashes;
	my $articles = $articulation->hashes;
	foreach my $mc ( @{$articles} ) {
		unless ( grep { $_->{'app'} eq $mc->{'category'} } @{$magazine_categories}) {
			push @{$magazine_categories}, { app => $mc->{'category'} };
		}
	}
	if ($c->param('category')) {
		$articulation = &subs::db_query('select * from magazine where status=? and category=? and timestamp <= ? and warranty >= ? order by timestamp DESC','publish',$c->param('category'), $server_time, $server_time);
	}
	else {
		$articulation = &subs::db_query('select * from magazine where status=? and timestamp <= ? and warranty >= ? order by timestamp DESC','publish', $server_time, $server_time);
	}
	$articles = $articulation->hashes;
	foreach my $mc ( @{$articles} ) {
		$mc->{'public'} = &subs::setting_grabber({ app => &subs::unformat_name($mc->{'title'}), setting => 'public' });

	}
	my $ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/manager/ws';
	my $mail_ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/mail/ws';
	my $paperboy_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/observer/ws';
	my ($website,$header) = &website_preloader($c);
	my $my_name = $c->param('name') || &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my %data = (
		template => 'homepage',
		title => $name,
		articles => $articles,
		mail_ws_url => $mail_ws_url,
		paperboy_url => $paperboy_url,
		website => $website,
		header => $header,
		my_name => $my_name,
		magazine_categories => $magazine_categories,
		config => &subs::config_reader(),
		device => &subs::device_setter(),
		string => &subs::random_string_creator(),
		newsstand => &subs::statement_grabber(),
		pseudonyms => &pseudonym_maker('manager',''),
		ws_url => $ws_url,
		advertise_watching => &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' })
	);
	unless ($c->param('window_maker')) {
		$data{'layout'} = 'homepage';
	}
	my $homepage = $c->render_to_string(
		%data
	);
	return $homepage;
}

get '/manager/register_grabber' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $returner = &register_grabber($app);
	$c->render(json => $returner);
};

sub register_grabber($app) {
	my $timestamp = &subs::rightNow();
	my $returner = { timestamp => $timestamp };
	my $c = app->build_controller;
	foreach my $att ( qw/model option option_category subcategory/ ) { 
		$returner->{'html'} .= $c->render_to_string(
			template => 'pos/attributes',
			att => $att,
			a => $app
		);
	}
	return $returner
}



get '/store' => sub ($c) {
	&store_maker($c);
};

get '/manager/store' => sub($c) {

	my $timestamp = $c->param('timestamp');

	my $contents = &store_maker($c);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'store', contents => $contents }, $timestamp);
	$c->render(text => $website);
};


sub store_maker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $cat = &subs::db_query('select * from settings where setting=? and value=? and device=?','pos','category',$device);
	my $categories = $cat->hashes;
	my $timestamp = &subs::rightNow();
	my $settings = &subs::settings_grabber({ app => 'store' });
	foreach my $s ( @{$categories} ) {
		my $app = $s->{'app'};
		$s->{'settings'} = &subs::settings_grabber({ app => $app });
	}
	my $mail_ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/mail/ws';
	my $paperboy_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/observer/ws';
	my $ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/manager/ws';
	my $advertise_watching = &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' });
	if ($c->param('window_maker') eq 'yes') {
		return $c->render_to_string(
			template => 'store/store',
			string => $random_caching_string,
			categories => $categories,
			newsstand => &subs::statement_grabber(),
			ws_url => $ws_url,
			mail_ws_url => $mail_ws_url,
			paperboy_url => $paperboy_url,
			config => &subs::config_reader(),
			advertise_watching => $advertise_watching,
			my_name => $c->session('name'),
			pseudonyms => &pseudonym_maker('manager',''),
			window_maker => $c->param('window_maker'),
			settings => $settings
		);
	}
	else {
		$c->render(
			template => 'store/store',
			layout => 'store',
			string => $random_caching_string,
			categories => $categories,
			newsstand => &subs::statement_grabber(),
			ws_url => $ws_url,
			mail_ws_url => $mail_ws_url,
			paperboy_url => $paperboy_url,
			config => &subs::config_reader(),
			advertise_watching => $advertise_watching,
			my_name => $c->session('name'),
			pseudonyms => &pseudonym_maker('manager',''),
			window_maker => $c->param('window_maker')
		);
	}

}

get '/store/category_grabber' => sub ($c) {
	my $category = &subs::unformat_name($c->param('category'));
	my $subcategory = &subs::unformat_name($c->param('subcategory'));
	my $types = eval { return decode_json $c->param('types') } || [];
	my $count = $c->param('count') || '';
	my ($db,$database,$sql) = &subs::database_grabber();
	my $itemq = &subs::db_query('select * from settings where setting=? and value=? and device=?','category',$category,$device);

	my $items = $itemq->hashes;
	$items = &store_item_merchandiser($items,$types);
	@{$items} = grep { $_->{'settings'}->{'public'} eq 'on' } @{$items} unless $c->session('privilege') eq 'citizen';
	if ($subcategory) {
		@{$items} = grep { $_->{'settings'}->{'subcategory' . $count} eq $subcategory } @{$items};
	}
	if (scalar @{$types} > 0) {
		my @temp_items;
		foreach my $type ( @{$types} ) {
			push @temp_items, grep { $_->{'settings'}->{'pos'} eq $type } @{$items};
		}
		@{$items} = @temp_items;
	}


	my $subcategories;
	if ($subcategory) {
		$subcategories = &subs::db_query('select * from subcategory where app=?', $subcategory)->hashes;
		$count++;
	}
	else {
		$subcategories = &subs::db_query('select * from subcategory where app=?', $category)->hashes;
	}
	my $subcategories_text;
	foreach my $sub ( @{$subcategories} ) {
		$sub->{'settings'} = &subs::settings_grabber({ app => $sub->{'name'} });
		$subcategories_text  .= '
			<style>
				.store_subcategory[category=' . $category . '][subcategory=' . $sub->{'name'} . '][status=closed] {
					background-color:' .  $sub->{'settings'}->{'colour'} . ';border:solid 2px black;
				}
			</style>
			<div class="store_subcategory hover" count="' . $count . '" status="closed" category="' . $category . '" subcategory="' . $sub->{'name'} . '" style="">' . &subs::format_name($sub->{'name'}) . 
			'</div><div style="display:none;padding-left:'. 20 * (1 + $count) . 'px;" class="store_subcategories" category="' . $category . '" subcategory="' . $sub->{'name'} . '"></div>';
	}
	my $rendered = $c->render_to_string(
		template => 'store/category',
		items => $items,
		category => $category
	);
	my $returner = {
		content => $rendered,
		category => $category,
		subcategories => $subcategories_text
	};
	$c->render(json => $returner);
};

post '/store/search' => sub($c) {
	my $search = &subs::unformat_name($c->param('search'));
	my $timestamp = $c->param('timestamp');
	my $types = eval { return decode_json $c->param('types') } || [];
	my $items = &subs::db_query('select distinct(app) as app,* from settings where setting=? and app like ? and device=?', 'pos', '%' . $search . '%',$device)->hashes;
	my @temp_items;
	foreach my $st ( @gb::store_types ) {
		push @temp_items, grep { $_->{'value'} eq $st } @{$items};
	}
	@{$items} = sort { $a->{'app'} cmp $b->{'app'} } @temp_items;
	$items = &store_item_merchandiser($items,$types);

	my $rendered = $c->render_to_string(
		template => 'store/category',
		items => $items,
	);
	my $returner = {
		content => $rendered
	};
	$c->render(json => $returner);
};

sub markup_adjuster($markup) {
	if ($markup =~ /%$/gi) {
		$markup =~ s/[^0-9.]//gi;
		$markup = abs(($markup / 100)) + 1;
	}
	return $markup;
}

sub store_item_merchandiser($items,$types) {
	my $universal_markup = &subs::setting_grabber({ app => 'me', setting => 'markup' }) || '5%';
	my $markup = $universal_markup;
	if ($markup =~ /%$/gi) {
		$markup =~ s/[^0-9.]//gi;
		$markup = abs(($markup / 100));
	}

	foreach my $i ( @{$items} ) {
		$i->{'settings'} = &subs::settings_grabber({ app => $i->{'app'} });
		$markup = $i->{'settings'}->{'markup'} || $universal_markup;
		if ($markup =~ /%$/gi) {
			$markup =~ s/[^0-9.]//gi;
			$markup = abs(($markup / 100));
		}
		my $models = &subs::db_query('select * from model where app = ?', $i->{'app'})->hashes;
		my $options = &subs::db_query('select * from option where app = ?', $i->{'app'})->hashes;
		my $seen = 0;
		foreach my $mo ( @{$models}, @{$options} ) {
			if ($mo->{'def'} eq 'on') {
				if ($mo->{'price'}) {
					$i->{'price'} += $mo->{'price'} * ($mo->{'quantity'});
					$seen += 1;
				}
				elsif ($mo->{'cost'}) {
					$i->{'price'} += $mo->{'cost'} * ($mo->{'quantity'}) * $markup;
					$seen += 1;
				}
			}
		}

		if ($seen == 0) {
			@{$i->{'models'}} = sort { $a->{'price'} cmp $b->{'price'} } @{$models};
			if (scalar @{$i->{'models'}} > 0) {
				if ($i->{'models'}[0]->{'price'}) {
					$i->{'price'} = $i->{'models'}[0]->{'price'};
				}
				elsif ($i->{'models'}[0]->{'cost'}) {
					$i->{'price'} = $i->{'models'}[0]->{'cost'} * $markup;
				}
			}
		}
	}
	if (scalar @{$types} > 0) {
		my @temp_items;
		foreach my $type ( @{$types} ) {
			push @temp_items, grep { $_->{'settings'}->{'pos'} eq $type } @{$items};
		}
		@{$items} = @temp_items;
	}
	return $items;

}

get '/store/item' => sub ($c) {
	my $item = {};
	my $manufacturer = &subs::unformat_name($c->param('manufacturer'));
	$item->{'app'} = &subs::unformat_name($c->param('item'));
	$item->{'settings'} = &subs::settings_grabber({ app => $item->{'app'} });
	my @manufacturers;
	$item->{'models'} = &subs::db_query('select * from model where app = ? order by price', $item->{'app'})->hashes;
	my $markup = &markup_adjuster($item->{'settings'}->{'markup'} || &subs::setting_grabber({ app => 'me', setting => 'markup' }) || '5%');
	

	if (scalar @{$item->{'models'}} > 0) {
		if ($item->{'models'}[0]->{'markup'}) {
			$markup = &markup_adjuster($item->{'models'}[0]->{'markup'});
		}
		if ($item->{'models'}[0]->{'price'}) {
			$item->{'price'} = $item->{'models'}[0]->{'price'};
		}
		elsif ($item->{'models'}[0]->{'cost'}) {
			$item->{'price'} = $item->{'models'}[0]->{'cost'} * $markup;
			$item->{'cost'} = $item->{'models'}[0]->{'cost'};
		}
		else {
			$item->{'price'} = $item->{'settings'}->{'worth'} * $markup;
		}
		$item->{'models'}[0]->{'select'} = 'on';
	}
	else {
		$item->{'price'} = $item->{'settings'}->{'worth'} * $markup;
	}
	$item->{'options'} = &subs::db_query('select * from option where app = ?', $item->{'app'})->hashes;
	my $option_categories = {};
	foreach my $att ( @{$item->{'models'}}, @{$item->{'options'}} ) {
		if ($att->{'manufacturer'}) {
			push @manufacturers, $att->{'manufacturer'} unless grep { $_ eq $att->{'manufacturer'} } @manufacturers;
		}
		if ($att->{'markup'}) {
			$markup = &markup_adjuster($att->{'markup'});
		}
		if ($att->{'file'}) {
			$att->{'file'} = eval { return decode_json $att->{'file'} } || [];
		}
		if ($att->{'price'}) {

		}
		else {
			$att->{'price'} = $att->{'cost'} * $markup;
		}
		if ($att->{'discount'}) {
			if ($att->{'discount'} =~ /%$/gi) {
				$att->{'discount'} =~ s/[^0-9.]//gi;
				$att->{'discount'} = abs($att->{'price'} * ($att->{'discount'} / 100));
			}
			$att->{'discount'} = abs($att->{'discount'}) * -1;
		}
		$att->{'characteristics'} = eval { return decode_json $att->{'characteristics' } } || [];
		if (my @oc = grep { $_->{'name'} eq 'option_category' } @{$att->{'characteristics'}} ) {
			foreach my $o ( @oc ) {
				my $option_category = &subs::db_select('option_category', undef, { uuid => $o->{'value'} })->hashes;
				if ($option_category->[0]->{'file'}) {
					$option_category->[0]->{'file'} = eval { return decode_json $option_category->[0]->{'file'} } || [];
				}
				$option_category->[0]->{'characteristics'} = eval { return decode_json $option_category->[0]->{'characteristics'} } || [];
				$item->{'option_categories'}->{$option_category->[0]->{'name'}} = $option_category->[0];
				foreach my $occ ( @{$option_category->[0]->{'characteristics'}} ) {
					$item->{'option_categories'}->{$option_category->[0]->{'name'}}->{$occ->{'name'}} = $occ->{'value'};
				}
				push @{$option_categories->{$option_category->[0]->{'name'}}}, $att;
			}
			@{$att->{'characteristics'}} = grep { $_->{'name'} ne 'option_category' } @{$att->{'characteristics'}};
		}
	}
	if ($manufacturer) {
		@{$item->{'options'}} = grep { $_->{'manufacturer'} eq $manufacturer } @{$item->{'options'}};
		@{$item->{'models'}} = grep { $_->{'manufacturer'} eq $manufacturer } @{$item->{'models'}};
	}
	if ($item->{'settings'}->{'public'} eq 'on' || $c->session('privilege') eq 'citizen') {
		my $fapptsq = &subs::db_query('select file from appointments where app = ? and file is not null', $item->{'app'})->hashes;
		$item->{'files'} = [];
		foreach my $t ( qw/ specs description / ) {
			$item->{'settings'}->{$t} =~ s/\n/<br>/gi;
		}
		foreach my $f ( @{$fapptsq} ) {
			$f->{'files'} = eval { return decode_json $f->{'file'} } || [];
			foreach my $fi ( grep { $_->{'function'} ne 'receipt' } @{$f->{'files'}} ) {
				push @{$item->{'files'}}, $fi if -e $fi->{'f'} && $fi->{'visible'} ne 'unchecked';
			}
		}
		if (!$item->{'settings'}->{'main_image'} && scalar @{$item->{'files'}} > 0) {
			$item->{'settings'}->{'main_image'} = $item->{'files'}->[0]->{'f'};
		}
		$item->{'template'} = $c->render_to_string(
			template => 'store/item',
			item => $item,
			markup => $markup,
			option_categories => $option_categories,
			manufacturers => \@manufacturers,
			settings => &subs::settings_grabber({ app => 'store' })
		);
	}
	else {
		$item = { template => $c->render_to_string(template => 'guest_layouts/denial') };
	}
	$c->render(json => $item);
};

get '/manager/store/customer_search' => sub($c) {
	my $search = $c->param('search');
	my $movement = $c->param('movement');
	if ($search) {
		my @search = split ' ', $search;
		my $s = join '%', @search;
		$search = '%' . $s . '%';
	
		my ($db) = &subs::database_grabber();
		my $results;
		if ($movement eq 'expense') {
			$results = &subs::db_query('select DISTINCT(app) from settings where app like ? and setting=? and (value=? or value =? or value=? or value=? or value=?) LIMIT 20', $search,'pos','vendor','person','government','institution','corporation')->hashes;
		}
		elsif ($movement eq 'income') {
			$results = &subs::db_query('select DISTINCT(app) from settings where app like ? and setting=? and (value=? or value =? or value=? or value=? or value=?) LIMIT 20', $search,'pos','customer','person','government','institution','corporation')->hashes;
		}
		foreach my $r ( @{$results} ) { 
			$r->{'uuid'} = &subs::setting_grabber({ app => $r->{'app'}, setting => 'uuid' });
		}
		my $resulted = $c->render_to_string(template => 'search/customer', results => $results);
		$c->render(json => { results => $resulted, count => scalar @{$results} });
	}
	else {
		$c->render(json => { count => 0 });
	}
};


get '/manager/store/customer_load' => sub($c) {
	my ($db) = &subs::database_grabber();
	my $cx = $c->param('cx');
	my $customer = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
	my $settings = &subs::settings_grabber({ app => $customer->{'app'} });
	my $content = $c->render_to_string(
		template => 'store/customer',
		cx => $cx,
		customer => $customer,
		settings => $settings,
	);
	$c->render(json => { content => $content, cx => $cx, formatted_name => &subs::format_name($customer->{'app'}), settings => $settings });
};

post '/store/quote/save' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $item = $c->param('item');
	my $quote_uuid = $c->param('uuid');
	my $cx = $c->param('cx');
	my $movement = $c->param('movement');
	if ($cx) {
		my $quote = eval { return decode_json $c->param('quote') } || { info => {}, options => [], model => {}, numbers => {}};
		
		my $customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
		my $s = &subs::settings_grabber({ app => $customer_s->{'app'} });
		$quote->{'id'} = &quote_id_maker($quote);# unless $quote->{'id'};
		my $jquote = encode_json $quote;
		&appointment_writer($c, { data => $jquote, movement => $movement, app => $customer_s->{'app'}, duration => &subs::time_abbrev_translator('10s'), timestamp => $timestamp, type => 'quote' });

		$c->render(json => { quote => $quote });
	}
	else {
		$c->render(json => { error => 'no customer' });
	}
};

sub quote_id_maker($quote) {
	my $server_time = &subs::rightNow();
	my $time = localtime($server_time / 1000);

	my $id = ($time->[4] + 1) . ($time->[3]) . ($time->[5] + 1900);
	my $today_quotes = &subs::db_query('select type,data,uuid from appointments where ( type=? or type=? or type=? or type=? ) and timestamp > ? and timestamp < ? order by server_time',
		'order','invoice','quote','purchase', &subs::ago_calc('1d',$server_time), &subs::ago_calc('-1d',$server_time))->hashes;
	my $quote_number = 1;

	foreach my $q ( @{$today_quotes} ) {
		my $qd = eval { return decode_json $q->{'data'} } || {};
		my @qid = split '-', $qd->{'id'};
		$quote_number = $qid[1] + 1 unless $quote_number > $qid[1] + 1;
	}

	$id .= '-' . $quote_number . &subs::shorthand_name(&subs::signatorial_designer(),3);
	return $id;
}

post '/store/quote/delete' => sub($c) {
	my $uuid = $c->param('uuid');
	my $cx_uuid = $c->param('cx_uuid');
	my $timestamp = $c->param('timestamp');
	my $type = $c->param('type');
	my $server_time = $c->param('server_time');
	my $customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx_uuid })->hashes->[0];
	my $data = { type => $type, app => $customer_s->{'app'}, uuid => $uuid };
	&delete_app($customer_s->{'app'},$uuid,$server_time,'quote_delete');
	$c->render(text => $data);
};

post '/store/quote/move' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $cx_uuid = $c->param('cx_uuid');
	my $uuid = $c->param('uuid');
	my $action = $c->param('action');
	my $type = $c->param('type');
	my $customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx_uuid })->hashes->[0];



	my $data = { type => $type, app => $customer_s->{'app'}, uuid => $uuid };
	my $appt = &subs::db_select('appointments', undef, $data)->hashes->[0];
	if ($action eq 'invoice' && $appt->{'type'} eq 'quote') {
		my $d = eval { return decode_json $appt->{'data'} };
		$d->{'numbers'}->{'balance'} = $d->{'numbers'}->{'total'};
		$appt->{'data'} = encode_json $d;
	}
	$appt->{'type'} = $action;
	$appt->{'status'} = 'open';
	$appt->{'server_time'} = &subs::rightNow();
	$appt->{'uuid'} = &subs::random_string_creator(25);
	&subs::db_insert('appointments', $appt, $data);

	$c->render(text => 'ok');
};

get '/store/quote/load' => sub($c) {
	my $uuid = $c->param('uuid');
	my ($db) = &subs::database_grabber();
	my $quote = &subs::db_select('appointments', undef, { uuid => $uuid })->hashes->[0];
	if ($quote->{'data'}) {
		my $data = decode_json $quote->{'data'};
		$c->render(json => $data);
	}
	else {
		$c->render(json => {});
	}
};

get '/store/print' => sub($c) {
	my $type = $c->param('type');
	my $cx_uuid = $c->param('cx_uuid');
	my $uuid = $c->param('uuid');

	my $printer = &store_printer({ 
		type => $type,
		cx_uuid => $cx_uuid,
		uuid => $uuid
	});
	my $header = $c->render_to_string(
		%{$printer}
	);
	$c->render(text => $header);
};

get '/public_view/:type/:uuid/:cx_uuid' => sub ($c) {
	my $uuid = $c->stash('uuid');
	my $type = $c->stash('type');
	my $cx_uuid = $c->stash('cx_uuid');

	my $printer = &store_printer({
		uuid => $uuid,
		type => $type,
		cx_uuid => $cx_uuid
	});
	$printer->{'layout'} = 'public_view';
	$c->render(
		%{$printer}
	);
};

sub store_printer($data) {
	my $type = $data->{'type'};
	my $cx_uuid = $data->{'cx_uuid'};
	my $uuid = $data->{'uuid'};
	my $visibility = $data->{'visibility'};
	my $c = app->build_controller;
	my $customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx_uuid })->hashes->[0];
	my $cx_settings = &subs::settings_grabber({ app => $customer_s->{'app'} });
	my $print_date = 0;
	my $due = &subs::setting_grabber({ app => 'me', setting => 'payment_due_date' });
	my $due_date;
	my $cx = $cx_settings;
	$cx->{'app'} = $customer_s->{'app'};

	my $registers;
	if ( $uuid eq 'all' ) { 
		$registers = &subs::db_select('appointments', undef, { type => $type, app => $cx->{'app'} })->hashes;
	}
	else {
		$registers = &subs::db_select('appointments', undef, { type => $type, app => $cx->{'app'}, uuid => $uuid })->hashes;
	}
	my (@i);
	my $totals = { price => 0, tax => 0, discount => 0, total => 0 };
	my $payments = [];
	foreach my $reg ( @{$registers} ) {
		$reg->{'data'} = eval { return decode_json $reg->{'data'} } || {};

		push @i, $reg->{'data'}->{'id'};
		foreach my $t ( qw/subtotal discount tax aux total balance/ ) {
			$totals->{$t} += $reg->{'data'}->{'numbers'}->{$t};
		}
		if ($reg->{'timestamp'} > $print_date) {
			$print_date = $reg->{'timestamp'};
			if ($due) {
				$due_date = &subs::ago_calc($due, $print_date);
			}
			else {
				$due_date = $print_date;
			}
		}
		if ($reg->{'data'}->{'payments'}) {
			push @{$payments}, @{$reg->{'data'}->{'payments'}};
		}
	}
	my $id = join '<br>', @i;

	my $address = $c->tx->local_address;
	if ($config->{'domain'}) {
		my @d = split '\.', $config->{'domain'};
		if (scalar @d > 2) {
			shift @d;
			$address = join '.', @d;
			my $ping = `timeout .5 ping -c 1 $address`;
			unless ($ping =~ /ttl/gi) {
				$address = $config->{'domain'};
			}
		}
		else {
			$address = $config->{'domain'};
		}
	}
	
	my $qr = 'https://' . $address . ':3000/public_view/' . $type . '/' . $uuid . '/' . $cx_uuid ;

	my $qr_img = `qrencode -o - $qr`;
	$qr_img = 'data:image/png;base64,' . encode_base64($qr_img);

	my $returner = {
		template => '/store/printer/header',
		registers => $registers,
		type => $type,
		visibility => $visibility,
		uuid => $uuid,
		cx => $cx_settings,
		qr_code => $qr,
		qr_img => $qr_img,
		id => $id,
		totals => $totals,
		payments => $payments,
		print_date =>	localtime( $print_date / 1000 )->strftime('%b %d %Y'),
		due_date => localtime( &subs::ago_calc($due, $print_date) / 1000 )->strftime('%b %d %Y')
	};


	return $returner;

}
get '/manager/store/customer_list' => sub($c) {
	my $cx = $c->param('cx');
	my $list_type = $c->param('list');
	my $type = $list_type;
	$type =~ s/s$//;
	my ($db) = &subs::database_grabber();
	my $customer = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
	if ($customer->{'app'}) {
		my $totals = {};
		my $settings = &subs::settings_grabber({ app => $customer->{'app'}});
		my $list = &subs::db_select('appointments', undef, { type => $type, app => $customer->{'app'} })->hashes;
		foreach my $l ( @{$list} ) { 
			$l->{$type} = eval { return decode_json $l->{'data'} } || {};
			foreach my $number ( keys %{$l->{$type}->{'numbers'}} ) {
				$totals->{$number} += $l->{$type}->{'numbers'}->{$number};
			}
		}
		my $content = $c->render_to_string(
			template => 'store/list',
			list => $list,
			type => $type,
			settings => $settings,
			customer => $customer,
			totals => $totals
		);
		$c->render(json => { content => $content, cx => $cx, list => $list, settings => $settings });
	}
	else {
		$c->render(json => { content => 'no' });
	}
};

post '/manager/configure/attribute_copy' => sub($c) {
	my $uuid = $c->param('uuid');
	my $att = $c->param('att');
	my $app = &subs::unformat_name($c->param('app'));
	my $pre_app = &subs::unformat_name($c->param('pre_app'));
	my $returner = { app => $app, att => $att, uuid => $uuid, pre_app => $pre_app };

	my $attribute = &subs::db_select($att, undef, { uuid => $uuid, app => $pre_app })->hashes->[0];
	$attribute->{'characteristics'} = eval { return decode_json $attribute->{'characteristics'} } || [];
	if ($att eq 'option') {
		my @category = grep { $_->{'name'} eq 'option_category' } @{$attribute->{'characteristics'}};
		my $cat = $category[0];
		my $oc = &subs::db_select('option_category', undef, { app => $pre_app, uuid => $cat->{'value'} })->hashes->[0];

		my $oc_check = &subs::db_select('option_category', undef, { app => $app, name => $oc->{'name'} })->hashes;

		unless ( scalar @{$oc_check} > 0 ) {
			$oc->{'app'} = $app;
			$oc->{'server_time'} = &subs::rightNow();
			$oc->{'uuid'} = &subs::random_string_creator(100);
			&subs::db_insert('option_category', $oc);

		}
		else {
			$oc = $oc_check->[0];
		}
		$cat->{'value'} = $oc->{'uuid'};

		$returner->{'option_category'} = $oc;
	}
	$attribute->{'characteristics'} = encode_json $attribute->{'characteristics'};
	$attribute->{'server_time'} = &subs::rightNow();
	$attribute->{'uuid'} = &subs::random_string_creator(101);
	$attribute->{'app'} = $app;

	my $att_check = &subs::db_select($att, undef, { name => $attribute->{'name'}, app => $app })->hashes;

	if (scalar @{$att_check} > 0 ) {
		my $ac = $att_check->[0];
		$attribute->{'uuid'} = $ac->{'uuid'};
		&subs::db_update($att, $attribute, { uuid => $ac->{'uuid'}, app => $ac->{'app'}, name => $ac->{'name'} });
	}
	else {
		&subs::db_insert($att, $attribute);
	}
	$returner->{'template'} = $c->render_to_string(template => 'pos/attributes', att => $att, a => $app);

	$returner->{'attribute'} = $attribute;

	$c->render(json => $returner);

};

post '/manager/store/:att/save' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $name = &subs::unformat_name($c->param('name'));
	my $att = $c->stash('att');
	my $cost = $c->param('cost');
	my $price = $c->param('price');
	my $uuid = $c->param('uuid');
	my $timestamp = $c->param('timestamp');
	my $discount = $c->param('discount');
	my $unit = $c->param('unit') || $name;
	my $markup = $c->param('markup');
	my $category = $c->param('category');
	my $description = $c->param('description');
	my $manufacturer = $c->param('manufacturer');
	my $def = $c->param('def');
	my $save_app = $c->param('save_app');
	my $quantity = $c->param('quantity');
	my $delay_start = $c->param('delay_start');
	my $delay_stop = $c->param('delay_stop');

	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[^0-9.]//gi;
	}



	if ($uuid ne 'new') {
		if ($def eq 'on' && $att eq 'model') {
			&subs::db_update($att, { def => 'off' }, { app => $app })->hashes;
		}
	}

	my $server_time = &subs::rightNow();
	my $returner = {
		app => $app,
		name => $name,
		cost => $cost,
		price => $price,
		discount => $discount,
		markup => $markup,
		description => $description,
		uuid => &subs::random_string_creator(50),
		timestamp => $timestamp,
		server_time => $server_time,
		manufacturer => $manufacturer,
		def => $def,
		save_app => $save_app,
		quantity => $quantity,
		unit => $unit,
		delay_start => $delay_start,
		delay_stop => $delay_stop
	};


	$returner->{'category'} = $category if $att eq 'option_category' || $att eq	'subcategory';
	if ($uuid eq 'new') {
		&subs::db_insert($att, $returner);
	}
	else {
		$returner->{'uuid'} = $uuid;
		&subs::db_update($att, $returner, { uuid => $uuid });
	}

	my $attd = $att;
	$attd = s/_//gi;

	$returner->{'template'} = $c->render_to_string(template => 'pos/attributes', att => $att, a => $app);
	$c->render(json => $returner);
};

post '/manager/configure/attribute_upload' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $attribute = $c->param('attribute');
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my @uploads = @{$c->req->uploads};
	my $image;
	my $returner;
	my $att_files = &subs::db_select($attribute, undef, { uuid => $uuid, app => $app })->hashes->[0];
	my $atf = eval { return decode_json $att_files->{'file'} } || [];
	my (@uploaded_files,$linux_file,$upload_type);
	foreach my $u ( @uploads ) {

		my $server_time = &subs::rightNow();
		$timestamp++;
		my $filen = &subs::unformat_name($u->filename);
		my @f = split /\./, $filen;
		my $ext = pop @f;
		$filen = join '.', @f;
		my $fn = $filen . '_' . $timestamp . '.' . $ext;

		my $upload = {
			type => $u->headers->content_type,
			path => $u->asset->path,
			filename => $fn,
			size => $u->size,
		};

		$app = &subs::unformat_name($app);
		my $init = &subs::setting_initializer($app,$timestamp);
		$app = $init->{'app'};
		push @uploaded_files, $upload;
		my ($folder,$location);

		if ($upload->{'type'} =~ /audio/gi) {
			$upload_type = 'audio';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		elsif ($upload->{'type'} =~ /video/gi) {
			$upload_type = 'video';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		elsif ($upload->{'type'} =~ /pdf/gi) {
			$upload_type = 'scan';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'document_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		elsif ($upload->{'type'} =~ /application/gi) {
			$upload_type = 'software';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'download_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		elsif ($upload->{'type'} =~ /image/gi) {
			$upload_type = 'image';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		else {
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'download_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		`mkdir -p $location` unless -e $location;
		my $filename = $location . '/' . $upload->{'filename'};
		$u->move_to($filename);
		$linux_file .= `file $filename`;

		if ($upload->{'filename'} =~ /avi$|mkv$/gi) {
			my $old_filename = $filename;
			$filename =~ s/avi$|mkv$/mp4/;
			my $tn_o = &subs::terminal_name($old_filename);
			my $tn_f = &subs::terminal_name($filename);
			threads->create(sub() { 
				`ffmpeg -i $tn_o $tn_f & exit /b`;
				`shred -u $tn_o`;
				&subs::file_encrypter({ app => $app });
			});
		}
		my $filing = { f => $filename, att => $attribute, att_uuid => $uuid, uuid => &subs::random_string_creator(18), type => $upload_type, server_time => &subs::rightNow() };
		push @{$returner}, $filing;
		push @{$atf}, $filing;


	}

	my $jfile = encode_json $returner;
	my $jafile = encode_json $atf;
	&subs::db_update($attribute, { file => $jafile, server_time => &subs::rightNow() }, { uuid => $uuid, app => $app });
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		notes => &subs::note_encrypter($c->session('suds'),$linux_file),
		type => $upload_type,
		file => $jfile,
		uuid => &subs::random_string_creator(20),
		duration => '1000'
	};
	&appointment_writer($c,$write);
	&subs::file_encrypter({ app => $app });
	$c->render(json => $returner);
};


post '/manager/store/attribute_characteristic_setter' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $att = &subs::unformat_name($c->param('att'));
	my $app = $c->param('app');
	my $att_uuid = $c->param('att_uuid');
	my $uuid = $c->param('uuid');
	my $input = $c->param('input');
	my $value = $c->param('value');
	my $unit;
	if ($value =~ /[a-zA-Z0-9]/) {
		my $gunit = $value;
		$gunit =~ s/[^a-zA-Z]//gi;
		if (grep { $_ eq $gunit } keys %{$gb::measures}) {
			$unit = $gunit;
			$value =~ s/[^0-9.]//gi;
		}
	}



	my $type = $c->param('type');
	my ($db,$database) = &subs::database_grabber();
	my $attributes = &subs::db_select($att, ['uuid','characteristics',], { uuid => $att_uuid })->hashes;
	my $attr = $attributes->[0];
	my $chars = eval { return decode_json $attr->{'characteristics'} } || [];

	my $data = {
		uuid => &subs::random_string_creator(25),
		$input => $value,
		timestamp => $timestamp
	};


	
	if ($type eq 'select') {
		$data = {
			name => $input,
			value => $value,
			timestamp => $timestamp,
			uuid => $uuid
		};
		if ($uuid eq 'new') {
			my $measurement = $value;
			$measurement =~ s/[0-9.,-]//gi;
			$data->{'uuid'} = &subs::random_string_creator(25);

		}
		else {
			@{$chars} = grep { $_->{'uuid'} ne $uuid } @{$chars};

		}
	}
	elsif ($uuid eq 'new') {
	}
	else {
		my @cdata = grep { $_->{'uuid'} eq $uuid } @{$chars};
		@{$chars} = grep { $_->{'uuid'} ne $uuid } @{$chars};
		$cdata[0]->{$input} = $value;
		$cdata[0]->{'timestamp'} = $timestamp;
		$data = $cdata[0];
		$data->{'unit'} = $unit if $unit;
	}
	unshift @{$chars}, $data;
	my $json_chars = encode_json $chars;
	&subs::db_update($att, { characteristics => $json_chars }, { uuid => $att_uuid });
	$c->render(json => { template => $c->render_to_string(template => 'pos/attributes', att => $att, a => $app), attribute => $data });

};

post '/manager/store/characteristic_delete' => sub($c) {
	my $uuid = $c->param('uuid');
	my $att_uuid = $c->param('att_uuid');
	my $att = $c->param('att');

	my ($db) = &subs::database_grabber();
	my $attribute = &subs::db_select($att, undef, { uuid => $att_uuid })->hashes->[0];
	my $chars = eval { return decode_json $attribute->{'characteristics'} } || [];
	@{$chars} = grep { $_->{'uuid'} ne $uuid } @{$chars};
	my $json_chars = encode_json $chars;
	&subs::db_update($att, { characteristics => $json_chars }, { uuid => $att_uuid });
	$c->render(json => { uuid => $uuid });

};

post '/manager/store/attribute_delete' => sub($c) {
	my $uuid = $c->param('uuid');
	my $att = $c->param('att');
	my ($db,$database) = &subs::database_grabber();
	&subs::db_delete($att, { uuid => $uuid });
	$c->render('text' => 'ok');
};

post '/manager/store/appointment_model_migration' => sub($c) {
	my $att = $c->param('att');
	my $matt = $c->param('matt');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');

	my $original = &subs::db_select($att, undef, { app => $app, uuid => $uuid })->hashes->[0];

	&subs::db_delete($att, { app => $app, uuid => $uuid });
	&deletion_registration({ table => $att, uuid => $uuid, server_time => $original->{'server_time'} });

	$original->{'server_time'} = &subs::rightNow();
	&subs::db_insert($matt, $original);
	my $returner = &register_grabber($app);

	$c->render(json => $returner);
};

post '/manager/store/appointment_model_selector' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $appt_uuid = $c->param('appt_uuid');
	my $server_time = &subs::rightNow();
	my $quantity = $c->param('quantity');
	my $manufacturer = $c->param('manufacturer');
	my $unit = $c->param('unit');
	my $source = $c->param('source');
	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[^0-9.]//gi;
	}

	my $app = $c->param('app');

	my $appt = &subs::db_query('select * from appointments where uuid=? and app =?', $appt_uuid, $app)->hashes->[0];

	my $cause = $c->param('cause');
	my $existing_model = eval { return decode_json $appt->{'model'} } || {};

	my $m = &subs::db_select('model', undef, { uuid => $uuid })->hashes->[0];
	if ($cause eq 'model') {
		$quantity = $m->{'quantity'};
		$unit = $m->{'unit'};
	}
	my $model = encode_json { uuid => $m->{'uuid'}, timestamp => $timestamp, quantity => ( $quantity), name => $m->{'name'}, unit => ( $unit) };
	if ($source ne 'transaction') {
		if ($existing_model->{'uuid'}) {
			
			my $del = &subs::db_select('appointments', undef, { source_uuid => $appt->{'uuid'}, app => $existing_model->{'name'} })->hashes;
			foreach my $d ( @{$del} ) {
				&delete_app($d->{'app'},$d->{'uuid'},$d->{'server_time'},'appointment_model_selector');
			}
		}
		if ( $m->{'save_app'} eq 'on') {
			&subs::source_appt_writer($m, {
				app => $appt->{'app'},
				uuid => $appt->{'uuid'},
				type => $appt->{'type'},
				duration => $appt->{'duration'},
				timestamp => $appt->{'timestamp'},
				unit => $unit,
				quantity => $quantity,
				project => $appt->{'project'},
				manufacturer => $manufacturer
			}, 'model');
		}
		$manufacturer = $m->{'manufacturer'} unless $manufacturer;

		&subs::db_query('update appointments set server_time = ?, model=?, manufacturer=?, quantity=?, unit=? where uuid=?',$server_time,$model,$manufacturer,$quantity,$unit,$appt_uuid);
		&Websocket::send($app, { console => 'appointmentDetailGrabber(\'' . $appt->{'app'} . '\',\'' . $appt->{'uuid'} .'\');' });
	}
	$c->render(json => $model);
};

post '/manager/store/appointment_option_selector' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');

	my $appt_uuid = $c->param('appt_uuid');
	my $server_time = &subs::rightNow();
	my $app = $c->param('app');
	my $option = &subs::db_select('option', undef, { uuid => $uuid, app => $app })->hashes->[0];
	my $manufacturer = $c->param('manufacturer');
	my $quantity = $c->param('quantity');
	my $unit = $c->param('unit');
	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[^0-9.]//gi;
	}


	my $select = $c->param('select');
	my $all_options = eval { return decode_json $c->param('all_options') } || [];
	@{$all_options} = grep { $_->{'uuid'} ne $uuid } @{$all_options};
	my $appt = &subs::db_query('select * from appointments where uuid=? and app = ?', $appt_uuid, $app)->hashes->[0];

	my $options = eval { return decode_json $appt->{'options'} } || [];

	if (scalar @{$options} == 0 ) {
		foreach my $o ( @{$all_options} ) {
			push @{$options}, { uuid => $o->{'uuid'}, quantity => $o->{'quantity'}, timestamp => &subs::rightNow(), unit => $o->{'unit'}, name => $o->{'name'} };
		}
	}

	my @deletions = grep { $_->{'uuid'} eq $uuid } @{$options};
	foreach my $deleters ( @deletions ) {
		my $op = &subs::db_select('option', undef, { uuid => $deleters->{'uuid'}, app => $app })->hashes->[0];
		my $del = &subs::db_select('appointments', undef, { source_uuid => $appt->{'uuid'}, app => $op->{'name'} })->hashes->[0];
		&delete_app($del->{'app'},$del->{'uuid'},$del->{'server_time'},'appointment_option_Selector');
	}
	@{$options} = grep { $_->{'uuid'} ne $uuid } @{$options};
	
	if ($select eq 'on') {
		if ($quantity == 1 && $unit eq $app) {
			$quantity = $option->{'quantity'};
			$unit = $option->{'unit'};
			my $settings = &subs::settings_grabber({ app => $option->{'name'} });
			if (!$unit) {
				$unit = $settings->{'unit'};
			}
			if (!$quantity) {
				$quantity = $settings->{'quantity'};
			}
			if (!$unit) {
				$unit = $app;
			}
		}
		my $o = { uuid => $uuid, quantity => $quantity, timestamp => $timestamp, unit => $unit, name => $option->{'name'} };

		push @{$options}, $o;
		if ( $option->{'save_app'} eq 'on') {
			&subs::source_appt_writer($o, {
				app => $appt->{'app'},
				uuid => $appt->{'uuid'},
				type => $appt->{'type'},
				quantity => $quantity,
				unit => $unit,
				duration => $appt->{'duration'},
				timestamp => $appt->{'timestamp'},
				manufacturer => $manufacturer,
				project => $appt->{'project'}
			}, 'option');
		}
	}


	#if ( scalar @{$options} > 0 ) {
		my $joptions = encode_json $options;
		&subs::db_update('appointments', { options => $joptions, server_time => $server_time }, { app => $app, uuid => $appt_uuid });
	#}
	&Websocket::send($app, { console => 'appointmentDetailGrabber(\'' . $appt->{'app'} . '\',\'' . $appt->{'uuid'} .'\');' });
	$c->render(json => $options);

};

get '/manager/configure/store_list' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $store = &store_setting_list();
	$c->render(
		template => 'configure/store_setting_list',
		store => $store,
		pos_list => $gb::pos
	);
};

get '/manager/editor' => sub ($c) {
	my $editor = &editor_maker($c);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'editor', contents => $editor }, $c->param('timestamp'));
	$c->render(text => $website);
};

get '/manager/magazine/neighbour_publish' => sub($c) {
	my $ip = $c->param('ip');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $remote_machine = &subs::db_select('remote_machines', undef, { uuid => $uuid, ip => $ip })->hashes->[0];
	$remote_machine = &remote_useragent_maker({ ip => $ip, signatorial => $remote_machine->{'signatorial'}, rm => $remote_machine });
	if ($remote_machine->{'ua'}) {
		my ($db,$database,$sql) = &subs::database_grabber();
		my $q = &subs::db_query('select * from magazine where status = ?', 'publish');
		my $articles = $q->hashes;
		my $json = encode_json $articles;

		my $npq = &subs::db_query('select title,uuid from magazine where status != ?', 'publish');
		my $nparticles = $npq->hashes;
		my $npjson = encode_json $nparticles;

		my $port_quest = &subs::db_query('select * from remote_machines where ip=?', $ip);
		my $ports = $port_quest->hashes;
		my $remote = $ports->[-1];
		my $port = $remote->{'port'};
		my $string = '/manager/magazine/publishing_receive';
		my $remote_params = { articles => $json, nonpublished => $npjson };
		my $res = eval { return $remote_machine->{'ua'}->insecure(1)->post('https://' . $ip . ':' . $port . $string => form => $remote_params)->result };
		if ($res) {
			$c->render('text' => $res->body);
		}
		else { $c->render('text' => 'no good'); }

	}
	else {
		$c->render('text' => 'no idea');
	}
};

post '/manager/magazine/publishing_receive' => sub($c) {
	my $articles = eval { return decode_json $c->param('articles') } || {};
	my $nonpublished = eval { return decode_json $c->param('nonpublished') };
	my $timestamp = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	foreach my $a ( @{$articles} ) {
		my $q = &subs::db_query('select * from magazine where uuid=?', $a->{'uuid'});
		my $prev = $q->hashes;
		my $category = &subs::setting_grabber({ app => $a->{'category'}, setting => 'pos' });
		unless ($category eq 'category') {
			my $pillow = &subs::unformat_name($a->{'category'} . ' category');
			my $init = &subs::setting_initializer($pillow,$timestamp);
			$a->{'category'} = $init->{'app'};
			my $ass = &appointment_writer($c,{
				app => $a->{'category'},
				type => 'text',
				timestamp => $timestamp,
			});
		}
		if ($prev->[0]->{'uuid'}) {
			&subs::db_update('magazine', $a, { uuid => $a->{'uuid'} });
		}
		else {
			my $insert = &subs::db_insert('magazine', $a);
		}
	}
	foreach my $a (@{$nonpublished}) {
		&subs::db_query('update magazine set status=? where uuid=?', $a->{'status'}, $a->{'uuid'});
	}
	$c->render('text' => 'success');
};


sub editor_maker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $uuid = $c->param('article_uuid') || '';
	my $scope = $c->param('scope');
	my $timestamp = $c->param('timestamp');
	my $t = &{$subs::time_subs->{$scope}}($timestamp); #timestamp at beginning
	my $t1 = ($timestamp - $t);
	my $t2 = ($t1 + $timestamp + $t1);
	my $articulation = &subs::db_query('select * from magazine order by timestamp DESC');# where timestamp >= ? and timestamp <= ?', $t, $t2);
	my $mag_cat = &subs::db_query('select distinct(app) from settings where setting=? and value=?','pos','category');
	my $magazine_categories = $mag_cat->hashes;
	my $articles = $articulation->hashes;

	my $contents = $c->render_to_string(
		template => 'editor',
		articles => $articles,
		uuid => $uuid,
		magazine_categories => $magazine_categories,
		window_maker => $c->param('window_maker')
	);
	return $contents;
}

post '/manager/editor/save' => sub ($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $scope = $c->param('scope');
	my $server_time = &subs::rightNow();
	my $title = $c->param('title');
	my $content = $c->param('content');
	my $teaser = &subs::teaser_name($c->param('teaser')) . '...' || "";
	my $uuid = $c->param('article_uuid');
	my $text_colour = $c->param('text_colour');
	my $background_colour = $c->param('background_colour');
	my $status = $c->param('status');
	my $category = $c->param('category');
	my $image = $c->param('image');
	my $warranty = &subs::ago_calc($c->param('warranty') || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time);
	my $previous_edition;
	if ($uuid ne 'none') {
		my $previous_editionq = &subs::db_query('select * from magazine where uuid=?', $uuid);
		$previous_edition = $previous_editionq->hashes->[0];

	}
	my $timestamp = &subs::ago_calc($c->param('timestamp'), $server_time) || $server_time;


	my $article = {
		uuid => $uuid,
		title => $title,
		content => $content,
		timestamp => $timestamp,
		manager_file => &manager_file_maker($c->session('name')),
		status => $status,
		text_colour => $text_colour,
		background_colour => $background_colour,
		server_time => $server_time,
		category => $category,
		warranty => $warranty,
		image => $image,
		teaser => $teaser
	};
	if (!$previous_edition->{'uuid'} || $uuid eq 'none') {
		$article->{'uuid'} = &subs::random_string_creator(100);
		$uuid = $article->{'uuid'};
		&subs::db_insert('magazine', $article);
	}
	else {
		&subs::db_update('magazine', $article, { uuid => $uuid });
	}
	if (($status ne 'publish') || ( $timestamp >= $server_time || $warranty <= $server_time )) { 
		&paperRoute({ uuid => $article->{'uuid'}, remove => 'yes' });
	}
	elsif ($status eq 'publish') {
		$article->{'art'} = $c->render_to_string(template => 'article', art => $article);
		&paperRoute($article);
	}
	$c->render(json => { uuid => $uuid });
};

post '/manager/editor/delete' => sub ($c) {
	my $uuid = $c->param('article_uuid');
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::db_query('delete from magazine where uuid = ?', $uuid);
	$c->render('text' => 'ok');
};


hook before_dispatch => sub {
	my ($c) = @_;
	$c->session(expiration => 604800);
};




hook before_render => sub {
	$database = '';
};

sub password_maker($c) {
	my $sacred = $c->param('numerics');
	my @uploads = @{$c->req->uploads};
	my @numerics = split '', $sacred;
	my ($secret,$ass);
	my $count = scalar @numerics;
	if (scalar @uploads > 0) {
		foreach my $u ( @uploads ) {
			my $size = $u->size;
			if ($size > 10000000) {
				&subs::say_it('way too big of a file!');
				$c->rendered;
				return 'noway';
			}
		  $ass = $u->asset->slurp;
			$ass = encode_base64($ass, "");
			$ass =~ s/\\\n//gi;
			my @asset = split '', $ass;
			my $mid = scalar @asset / 2;
			my $low_mid = (scalar @asset * .3333);
			my $up_mid = (scalar @asset * .6666);
			my $keys = [];
			for (my $i = 1; $i <= $count; $i++) {
				my $d = ($i / scalar @numerics);
				if ($d =~ /\./) {
					my @s = split /\./, $d;
					$d = $s[0];
				}
				foreach my $nm ( ( $low_mid, $mid, $up_mid ) ) {
					my $n = ($nm / $i);
					if ($n =~ /\./) {
						my @s = split /\./, $n;
						$n = $s[0];
					}
					push @{$keys}, $n + $i;
					$secret = $secret . $asset[$n + $i] . $asset[$n + $i - 5];
				}
				$secret = $secret . $numerics[$i - 1];
			}
		}
	}
	if ($ass eq '') {
		$secret = $sacred;
	}
	return $secret;
}

post '/sesh_check' => sub ($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $secret = &password_maker($c);
	my $reject_count = $c->session('reject_count');
	my $start_time = &subs::rightNow();
	my $backup = $c->param('president') || $c->param('backup') || $c->param('bullshit');
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $remote_timestamp = $c->param('remote_timestamp');
	my $me_warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d');
	my $t = localtime;
	my $db_exists = 0;
	$backup = &subs::home($backup);
	my $computer = $c->param('computer');
	my $local_address = $c->tx->local_address;
	my $remote_address = $c->tx->remote_address;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	if ($backup =~ /enc$/gi) {
		my $backup_file = $backup;
		$backup_file =~ s/.enc$//gi;
		$database = $backup_file . '.db';
		unless (-e $database && -s $database > 5000) {
			my $data = `tail $backup`;
			my @split_data = split $universal_splitter, $data;
			$encryption_standard = &subs::decrypter($secret, $split_data[1]);
			`openssl enc -d -k "$secret" -$encryption_standard -pbkdf2 -in $backup -out $database`;

		}
		if (-e $database && -s $database > 5000) {
			$sql = Mojo::SQLite->new('sqlite:' . $database);
			if (eval { $sql->db }) {
				$db_exists = 1;
			}
			else {
				`shred -u $database`;
				$db_exists = 0;
			}
		}

	}
	elsif ($backup =~ /db$/) {
		$database = $backup;
		$sql = Mojo::SQLite->new('sqlite:' . $database);
		$db_exists = 1;
	}
	if ($db_exists == 1) {
		my ($db,$database) = &subs::database_grabber();

		&update_database($c);

	#	&subs::db_insert('appointments',{ warranty => $me_warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "id", timestamp => $timestamp, server_time => $server_time }) if $db_exists == 1;
		my $credential = eval { return &subs::db_select('security', ['credential'], { level => 1 })->hash->{credential} };
		$credential = &subs::decrypter($secret,$credential);

		if (secure_compare $secret, $credential) {
			app->sessions->samesite(undef);
			$c->session('authentication' => 'approved');
			my $app_warranty = &subs::setting_grabber({ app => $c->param('app'), setting => 'warranty' });
			my $warranty = &subs::ago_calc($app_warranty || &subs::setting_grabber({ 'app' => 'me', 'setting' => 'login_warranty' } ) || '-3h',$server_time);
			$c->session('database' => $database);
			$c->session('suds' => $secret);
			$c->session('warranty' => $warranty);
			$c->session('string' => &subs::random_string_creator());
			$c->session('name') => &subs::setting_grabber({ app => 'me', setting => 'name' });
			$c->session('privilege' => 'citizen');
			$c->session('app' => $c->param('app'));


			my $debbie = eval { return &subs::db_select('settings', ['value'], { app => '__DEBRIEFING__', device => $device })->hash->{value} };
			my $deb = $debbie || encode_json [];
			my $duration = $start_time - &subs::rightNow();
		#	&subs::db_insert('appointments',{ warranty => $me_warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "entry", timestamp => $timestamp, server_time => $server_time });
			my $d = { title => 'Your Majesty', app => 'customs', role => 'citizen', message => $remote_address, image => "/images/make believe/crown.png" };

			unless ($c->param('silence')) {
				&subs::say_it('your majesty');
				&notification_sender($d,$database);
			}
			my $hs = &subs::setting_grabber({ app => 'me', setting => 'computer_name' }) || `hostname`;
			chomp $hs;

			my $who = `whoami`;
			chomp $who;
		#	my $me = &me_setting_list();
			my $colour = '#' . &subs::random_colour_grabber();
			my $device_count = &subs::db_query('select count(*) from devices');
			my $bti = $c->stash('browser_tab_id');
			my $pwd = `pwd`;
			chomp $pwd;

			my $js = { 
				'authentication' => 'approved', 
				hostname => $hs,
				username => $who,
				debriefer => $deb,
				port => $ENV{PORT_AHOY},
				ws_port => $ENV{PORT_AHOY},
				alarm_port => $ENV{PORT_BELL},
	#			me => $me,
				device => $device,
				database => $database,
				browser_tab_id => $bti,
				manager_file => &manager_file_maker($c->session('name')),
				signatorial => &subs::signatorial_designer(),
				pwd => $pwd,
				fqdn => $config->{'domain'},
				ssh_port => $config->{'ssh_port'},
				manager_colour => &subs::setting_grabber({ app => 'misc', setting => 'manager_background_colour' })
				
			};
			$c->render(json => $js);
		}
		elsif ($reject_count > 2) {
			my $denial = $c->render_to_string(template => 'guest_layouts/denial', message => '... and fuck you too!');
			$c->render(json => { 'authentication' => 'denial', denial => $denial });
		}
		else {
			$reject_count = $reject_count + 1;
			$c->session('reject_count' => $reject_count);
			my $visitor = $local_address eq $remote_address ? 'Me' : $computer || 'door';
			&subs::say_it('Who the fuck are you? ' . $visitor . ' ' . $c->session('reject_count'));
			&subs::db_insert('appointments',{ warranty => $me_warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "reject", timestamp => $timestamp, server_time => $server_time }) if $db_exists == 1;
			$c->render(json => { 'authentication' => 'rejected'});
			$c->session('authentication' => 'rejected');
			&subs::say_it('I reject: ' . $remote_address);
			$c->stash('browser_tab_id' => undef);
			$c->session('suds' => 'go fuck yourself');
			&notification_sender({ app => 'customs', role => 'citizen', title => 'WTFAU', message => 'DB open', image => "/images/make believe/explosion.png" },$database);

		}
	}
	else {
			my $reject_count = $c->session('reject_count') + 1;
			$c->session('reject_count' => $reject_count);
			my $visitor = $local_address eq $remote_address ? 'Me' : 'door';
			&subs::say_it($c->session('reject_count') . ' Who the fuck are you? ' . $visitor);
			$c->render(json => { 'authentication' => 'rejected'});
			$c->session('authentication' => 'rejected');
			$c->session('suds' => 'fuck you too!');
			$c->stash('browser_tab_id' => undef);

			&notification_sender({ app => 'customs', role => 'citizen', title => 'WTFAU', message => 'DB Closed', image => "/images/make believe/explosion.png" },$database);
	}
};

get '/manager/debrief_grabber' => sub($c) {
	my $ticket_uuid = $c->session('ticket_uuid');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $q = &subs::db_query('select debriefer from tickets where uuid = ?', $ticket_uuid);
	my $debrief = $q->hashes->[0]->{'debriefer'};
	my $debriefer = decode_json $debrief || {};
	$c->render(json => $debriefer);
};

post '/manager/fuck_you' => sub($c) {
	my $timestamp = $c->param('timestamp');
	&Websocket::send('server',{ not_me => 1, browser_tab_id => $c->param('browser_tab_id'), 'console' => 'fuck_you();', timestamp => $timestamp });
	$c->render('text' => 'fuck yeah!');
};

get '/manager/configure/device_lister' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $load_type = $c->param('load_type');
	my $ip = $c->param('host');
	my $devices = &subs::device_lister($timestamp,$load_type,$ip);
	my $ping = &subs::setting_grabber({ app => 'misc', setting => 'ping' });

	$c->render(
		template => 'configure/device_lister',
		devices => $devices,
		ping => $ping,
	);
};

post '/manager/configure/device_purpose' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $ip = $c->param('ip');
	my $mac = $c->param('mac');
	my $uuid = $c->param('uuid');
	my $purpose = $c->param('purpose');
	my $dev = &subs::db_query('select * from devices where uuid=?',$uuid);
	my $devices = $dev->hashes;
	foreach my $d ( @{$devices} ) {
		my $address = decode_json $d->{'address'};
		foreach my $nic ( keys %{$address} ) {
			foreach my $neigh ( @{$address->{$nic}->{'neigh'}} ) {
				if ($neigh->{'ip'} eq $ip && $neigh->{'mac'} eq $mac) {
					$neigh->{'purpose'} = $purpose;
				}
			}
		}
		my $json_address = encode_json $address;
		&subs::db_update('devices', { address => $json_address }, { uuid => $uuid });
	}
	$c->render('text' => 'done');
};

get '/manager/time_jump' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $filter = $c->param('filter');
	my $type = $c->param('type');
	my $app = $c->param('app');
	my $scope = $c->param('scope');
	my $t = &{$subs::time_subs->{$scope}}($timestamp); #timestamp at beginning
	my $t1 = ($timestamp - $t);
	my $t2 = ($t1 + $timestamp + $t1);
	my $query;
	my $date = localtime( time() )->strftime('%a %B %d %Y %I:%M%P');
	if ($type eq 'prev') {
		if ($filter ne 'all') {
			$query = &subs::db_query('select timestamp from appointments where app=? and type=? and timestamp < ? order by timestamp DESC LIMIT 1',
				$app,$filter,$t);	
		}
		else {
			$query = &subs::db_query('select timestamp from appointments where app=? and timestamp < ? order by timestamp DESC LIMIT 1',
				$app,$t);	
		}
	}
	elsif ($type eq 'next') {
		if ($filter ne 'all') {
			$query = &subs::db_query('select timestamp from appointments where app=? and type=? and timestamp > ? order by timestamp ASC LIMIT 1',
				$app,$filter,$t2);
		}
		else {
			$query = &subs::db_query('select timestamp from appointments where app=? and timestamp > ? order by timestamp ASC LIMIT 1',
				$app,$t2);
		}
	}

	my $res = $query->hashes;

	if ($res->[0]->{'timestamp'} == undef) {
		$query = &subs::db_query('select timestamp from appointments where app=? and timestamp = ? order by timestamp ASC LIMIT 1',
			$app,$timestamp);
		$res = $query->hashes;
	}

	$date = localtime($res->[0]->{'timestamp'} / 1000 )->strftime('%a %B %d %Y %I:%M:%S%P') unless $timestamp == 0 || $timestamp == undef;

	$c->render(json => { date => $date, sent_timestamp => $timestamp, new_timestamp => $res->[0]->{'timestamp'} });

};

get '/manager/configure/me_settings' => sub($c) {
	my $pos = &subs::setting_grabber({ app => 'me', setting => 'pos' });
	my $me = &me_setting_list();
	$c->render(
		template => 'configure/me_setting_list',
		me => $me,
		pos_list => $gb::pos
	);
};

post '/manager/configure/me_setting' => sub($c) {
	my $value = $c->param('value');
	if ($value =~ /\%$/gi) {
		$value =~ s/\%$//gi;
		$value = ($value / 100) + 1;
	}
	my $setting = &subs::setting_setter({ 
		app => 'me', 
		setting => $c->param('setting'), 
		value => $value, 
		device => $c->param('device'), 
		timestamp => $c->param('timestamp') 
	});
	$c->render(json => $setting);
};


sub me_setting_list() {
	my ($db,$database,$sql) = &subs::database_grabber();

	my @settings = qw/mugshot log_me my_name home_plate currency tax information budget_alarm computer_name unit activity_timeout login_warranty warranty room_count duration worth pos advertise_watching gallery_appts/;
	my $settings = {};

	foreach my $dt ( @gb::device_types ) {
		foreach my $s (@settings) {
			my $res = eval {return &subs::db_select('settings', ['value'], { app => 'me', setting => $s, device => $dt })->hash->{value} };
			$settings->{$dt}->{$s} = $res;
		}
	}
	return $settings;
}

sub store_setting_list() {
	my ($db,$database,$sql) = &subs::database_grabber();

	my @settings = qw/store_name slogan logo markup sales_tax address email phone tax_number doc_notes payment_due_date/;
	my $settings = {};

	foreach my $dt ( @gb::device_types ) {
		foreach my $s (@settings) {
			my $res = eval {return &subs::db_select('settings', ['value'], { app => 'me', setting => $s, device => $dt })->hash->{value} };
			$settings->{$dt}->{$s} = $res;
		}
	}
	return $settings;
}

post '/manager/configure/mugshot_upload' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my @uploads = @{$c->req->uploads};
	my $image;
	my $ass;
	if (scalar @uploads > 0) {
		foreach my $u ( @uploads ) {
		  $ass = $u->asset->slurp;
			$image = 'data:image/png;base64,' . encode_base64($ass);
			&subs::setting_setter({ app => 'me', setting => 'mugshot', value => $image });
		}
	}
	$c->render(text =>  $image );
};

post '/manager/configure/logo_upload' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my @uploads = @{$c->req->uploads};
	my $image;
	my $ass;
	if (scalar @uploads > 0) {
		foreach my $u ( @uploads ) {
		  $ass = $u->asset->slurp;
			$image = 'data:image/png;base64,' . encode_base64($ass);
			&subs::setting_setter({ app => 'me', setting => 'logo', value => $image });
		}
	}
	$c->render(text =>  $image );
};

sub misc_setting_list() {
	my ($db,$database,$sql) = &subs::database_grabber();

	my @settings = qw/max_files thumbnail_size photo_size max_backups scan_size download_location music_location document_location photo_location video_location encryption_standard scan_location rec_location/;
	my $settings = {};

	foreach my $dt ( @gb::device_types ) {
		foreach my $s (@settings) {
			my $res = eval {return &subs::db_select('settings', ['value'], { app => 'misc', setting => $s, device => $dt })->hash->{value} };
			$settings->{$dt}->{$s} = $res;
		}
	}

	return $settings;
}

get '/manager/configure/misc_setting_list' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $settings = &misc_setting_list();
	my $encryption_standards = `openssl enc -ciphers`;
	my @encryption_standards = split ' ', $encryption_standards;
	@encryption_standards = map { $_ =~ s/^-//; $_ } @encryption_standards;
	shift @encryption_standards;
	shift @encryption_standards;
	$c->render(
		template => 'configure/misc_setting_list',
		settings => $settings,
		encryption_standards => \@encryption_standards,
		photo_sizes => $gb::photo_sizes,
		thumbnail_sizes => $gb::thumbnail_sizes,
		folders => $config->{'folders'},
		config => &subs::config_reader()
	);
};

post '/manager/configure/misc_setting' => sub($c) {
	&subs::setting_setter({ 
		app => 'misc', 
		setting => $c->param('setting'), 
		value => $c->param('value'), 
		device => $c->param('device'), 
		timestamp => $c->param('timestamp') 
	});
	$c->render(text => 'ok');
};

get '/manager/configure/ping' => sub($c) {
	my $ip = $c->param('host');
	my $timestamp = $c->param('timestamp');

	my ($db,$database) = &subs::database_grabber();
	my $timeout = .2;
	my $returner = {};
	&subs::setting_setter({ app => 'misc', setting => 'ping', value => $ip });
	if ($ip) {

		my @ip = split '\.', $ip;
		if (scalar @ip == 4) {

			$returner->{$ip}->{'ip'} = $ip;
			$returner->{$ip}->{'result'} = `timeout $timeout ping -c 1 $ip`;
		}
		else {
			my @ifconfig = split "\n\n", `ifconfig`;
			foreach my $if (@ifconfig) {
				my @ifconfig_list = split "\n", $if;

				my @routes = grep { $_ =~ /inet/ } @ifconfig_list;
				foreach my $route (@routes) {
					my @inet = split " ", $route;
					if ($route =~ /inet /) {


						my @items = split " ", $route;
						my $sip = $ip;
						$sip =~ s/[0-9]//gi;
						
						my $gw = $items[1];
						my @gw = split /\./, $gw;
				
						my @csv = split ',', $ip;
						if (scalar @csv > 1) {
							foreach my $csv (@csv) {
								pop @gw;
								push @gw, $csv;
								my $ip_address = join '.', @gw;
								$returner->{$ip_address}->{ip} = $ip_address;
								$returner->{$ip_address}->{'result'} = `timeout $timeout ping -c 1 $ip_address`;
							}
						}
						elsif ($sip eq '..' ) {
							my @sips = split '\.\.', $ip;
							
							foreach my $csv ( $sips[0] .. $sips[1] ) {

								pop @gw;
								push @gw, $csv;
								my $ip_address = join '.', @gw;
								$returner->{$ip_address}->{ip} = $ip_address;
								$returner->{$ip_address}->{'result'} = `timeout $timeout ping -c 1 $ip_address`;

							}
						}
						else {
							pop @gw;
							push @gw, $ip;
							my $ip_address = join '.', @gw;
							$returner->{$ip_address}->{ip} = $ip_address;
							$returner->{$ip_address}->{'result'} = `timeout $timeout ping -c 1 $ip_address`;
						}
					}
				}
			}
		}
	}
	$c->render(text => (Dumper $returner) . '<br>');
};

post '/manager/configure/remote_rsync' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $port = $c->param('ssh_port');

	
	my $hostname = `hostname`;
	chomp $hostname;


	my $direction = $c->param('direction');
	my $remote_device = $c->param('device');
	my $signatorial = $c->param('signatorial');
	my $uuid = $c->param('uuid');
	my $home = $c->param('home');
	my $folder = $home || '~/president';
	my $rm = &subs::db_select('remote_machines', undef, { uuid => $uuid, signatorial => $signatorial, ip => $ip })->hashes;
	my $username = $rm->[0]->{'username'};
	my $password = &subs::decrypter($c->{'suds'},$rm->[0]->{'password'});
	my $connector;
	if ($direction eq 'from') {
		$connector = 'sshpass -p "' . $password . '" rsync -avr -e "ssh -p ' . $port . '" ' . $username . '@' . $ip . ':' . $home . ' ~/ --delete --exclude=public/images/jonathans --exclude=config.json';
	}
	elsif ($direction eq 'to') {
		$connector = 'sshpass -p "' . $password . '" rsync -avr -e "ssh -p ' . $port . '" ~/president ' . $username . '@' . $ip . ':~/ --delete --exclude=public/images/jonathans --exclude=config.json';
	}
	&ssh_known_host_adder($ip,$port);
	my $result = `$connector`;
	my @result = split "\r", $result;

	$result = join "<br>", @result;
	my $whoami = `whoami`;
	chomp $whoami;
	$connector =~ s/$password/_________/gi;
	my $json = { type => 'command', whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(), command => $connector, 'return' => $result, timestamp => $timestamp };

	&Websocket::send('server', $json);
	&subs::db_update('remote_machines', { server_time => &subs::rightNow(), connection => 'inactive' }, { ip => $ip, uuid => $uuid, signatorial => $signatorial });
	$c->render('text' => $result);
};

post '/manager/configure/remote_upgrade' => sub($c) {
	if ( &subs::setting_grabber({ app => '__president', setting => 'remote_upgrade' }) eq 'running' ) {
		$c->render('text' => 'already running');
		$c->rendered;
		return;
	}

	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $ssh_port = $c->param('ssh_port');
	my $hostname = $c->param('hostname');
	my $database = $c->param('database');
	my $direction = $c->param('direction');
	my $gimme = $c->param('gimme');
	my $remote_signatorial = $c->param('signatorial');
	my $remote_device = $c->param('device');
	my $params = {
		timestamp => $timestamp,
		ip => $ip,
		ssh_port => $ssh_port,
		hostname => $hostname,
		database => $database,
		gimme => $gimme,
		remote_signatorial => $remote_signatorial,
		remote_device => $remote_device
	};
	Mojo::IOLoop->subprocess->run_p(sub {
		&remote_upgrade($c,$params);
	});
	$c->render('text' => 'ok');
};

sub remote_upgrade($c,$params) {
	if ( &subs::setting_grabber({ app => '__president', setting => 'remote_upgrade' }) eq 'running' ) {
		return;
	}
	&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => 'running' });
	my $timestamp = $params->{'timestamp'};
	my $ip = $params->{'ip'};
	my $port = $params->{'ssh_port'};
	my $hostname = $params->{'hostname'};
	my $database = $params->{'database'};
	my $gimme = $params->{'gimme'};
	my $remote_signatorial = $params->{'remote_signatorial'};
	my $remote_device = $params->{'remote_device'};
	my $remote_machine = $params->{'remote_machine'};
	my @database = split '/', $database;
	my @extender = split /\./, $database[-1];
	$extender[-1] = 'enc';
	$database[-1] = join '.', @extender;
	$database = join '/', @database;

	my $folder = '~/';
	my $connector;
	my $signatorial = &subs::signatorial_designer();
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10));
	unless ($remote_machine) {
		my $remote_machines = &subs::db_query('select * from remote_machines where ip= ? and signatorial = ? order by timestamp DESC', $ip,$remote_signatorial)->hashes;
		$remote_machine = $remote_machines->[0];
		$remote_machine = &remote_useragent_maker({ ip => $ip, signatorial => $signatorial, rm => $remote_machine });
	}

	my $auuid = &subs::random_string_creator(10);
	if ($remote_machine->{'username'} && $remote_machine->{'password'}) {

		my $html = '<h2>Running Remote Backup</h2>';
		&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $remote_machine->{'data'}->{'manager_colour'} });


		my $url = $remote_machine->{'manager'} . '/manager/configure/backup_now?reason=remote_update&timestamp=' . $timestamp . '&signatorial=' . $signatorial;
		if ($gimme =~ /[A-Za-z0-9]/gi) {
			$gimme = &subs::ago_calc($gimme, &subs::rightNow());
			$url .= '&gimme=' . $gimme;
		}
		else {
			$gimme = undef;
		}

		my $ua = $remote_machine->{'ua'};

		my $res = eval { return $ua->insecure(1)->get($url)->result };




		if ($res) {
			my $body = eval { return decode_json $res->body } || {};


			if ($body->{'path'} && $body->{'signatorial'}) {

				if (1) {
					my $html = '<h2>Syncing Remote Backup ' . &subs::data_size($body->{'size'}) . '</h2>';
					&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $remote_machine->{'data'}->{'manager_colour'}  });
					`mkdir -p $temp_folder` unless -e "$temp_folder";
					my $temporary_file = $temp_folder . '/tmpman.enc';
					my $username = $remote_machine->{'username'};
					my $password = &subs::decrypter($c->session('suds'), $remote_machine->{'password'});
					my $connector = 'sshpass -p "' . $password . '" rsync -avr -e "ssh -p ' . $port . '" ' . $username . '@' . $ip . ':' . $body->{'archive_path'} . ' ' . $temporary_file;
					
					&ssh_known_host_adder($ip,$port);
					my $connected = `$connector`;
					my $disposition = &merge_database($c,{ 
						file => $temporary_file, 
						signatorial => $body->{'signatorial'},
						misc_settings => $body->{'misc_settings'},
						remote => $remote_machine,
						gimme => $gimme,
						colour => $remote_machine->{'data'}->{'manager_colour'}
					});
					`shred -u $temporary_file`;
					`rm -R $temp_folder`;
					&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
			#		&subs::db_update('remote_machines', { connection => 'inactive' }, { ip => $ip, signatorial => $remote_machine->{'signatorial'}, uuid => $remote_machine->{'uuid'} });

					my $defunct_backups = &subs::db_query('select * from backups where ost < ? and recipient = ? and signatorial = ? and reason=?', $body->{'server_time'}, $signatorial, $remote_machine->{'signatorial'}, 'remote_upgraded' )->hashes;
					foreach my $defb ( @{$defunct_backups} ) { 
						if ($defb->{'enc_file'} && -e $defb->{'enc_file'}) {
							my $delb = $defb->{'enc_file'};
							`shred -u $delb`;
						}
					}


					&subs::db_query('delete from backups where ost < ? and recipient = ? and signatorial = ? and reason=?', $body->{'server_time'}, $signatorial, $remote_machine->{'signatorial'}, 'remote_upgraded' );
					&subs::db_update('backups', { server_time => $body->{'server_time'}, reason => 'remote_upgraded' }, { 
						recipient => $signatorial,
						signatorial => $remote_machine->{'signatorial'},
					});

				}
			}
		}
		else {
			&Websocket::send('tab', { yellow => 'Complete', 'close' => 'yes', colour => $remote_machine->{'data'}->{'manager_colour'}  });
		}


		&Websocket::send('tab', { yellow => 'Complete', 'close' => 'yes', colour => $remote_machine->{'data'}->{'manager_colour'}  });
	}
}


post '/manager/configure/remote_device_disconnect' => sub ($c) {
	my $ip = $c->param('ip');
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::db_delete('remote_machines', { ip => $ip });
	$c->render('text' => 'ok');
};



get '/manager/configure/remote_device_connect' => sub ($c) {
	my $manager = $c->param('manager');
	my $filename = $c->param('filename');
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $port = $c->param('port');
	my $password = $c->session('suds');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $browser_tab = $c->param('browser_tab');
	my $name = $c->session('name');
	my $signatorial = $c->param('signatorial');
	my $uuid = $c->param('uuid');
	my $nic = $c->param('nic');
	my $returner = &remote_device_connect({
		manager => $manager,
		filename => $filename,
		timestamp => $timestamp,
		ip => $ip,
		password => $password,
		name => $name,
		browser_tab_id => $browser_tab_id,
		browser_tab => $browser_tab,
		signatorial => $signatorial,
		nic => $nic
	});
	my $device = &subs::db_select('devices', undef, { uuid => $uuid })->hash;
	my $address = decode_json $device->{'address'};
	my $neighbour = [];
	@{$neighbour} = grep { $ip eq $_->{'ip'} } @{$address->{$nic}->{'neigh'}};
	$neighbour->[0]->{'signatorial'} = $returner->{'body'}->{'signatorial'};
	$neighbour->[0]->{'purpose'} = $returner->{'body'}->{'device'};
	$address = encode_json $address;
	&subs::db_update('devices', { address => $address }, { uuid => $uuid });
	$c->render(json => $returner);
};

sub ssh_known_host_adder($ip,$port) {
	my $known = &subs::home('~/.ssh/known_hosts');
	my $known_hosts_cmd = 'cat ' . $known;
	my $known_hosts = `$known_hosts_cmd`;
	my @kh = split /\n/, $known_hosts;
	unless (grep { $_ =~ /\Q$ip/gi && $_ =~ /\Q$port/gi } @kh) {
		my $rest = 'ssh-keyscan -p ' . $port . ' ' . $ip . ' >> ' . $known;
		`$rest`;
	}
}

sub remote_device_connect($rdata) {
	my $manager = $rdata->{'manager'};
	my $filename = $rdata->{'filename'};
	my $timestamp = $rdata->{'timestamp'};
	my $server_time = &subs::rightNow();
	my $ip = $rdata->{'ip'};
	my $name = $rdata->{'name'};
	my $browser_tab_id = $rdata->{'browser_tab_id'};
	my $browser_tab = $rdata->{'browser_tab'};
	my $password = $rdata->{'password'};
	my $port = $rdata->{'port'} || $ENV{PORT_DOCK};
	my $nic = $rdata->{'nic'};


	my $returner = {};
	$manager =~ s/\/manager$//gi;

	$manager =~ s/:$port/:3000/gi;
	my $bti;
	my $ua = Mojo::UserAgent->new();
	my $manager_file = &manager_file_maker($name);
	my $url = $manager . '/sesh_check?silence=yes&neighbour=' . $browser_tab_id . '&numerics=' . $password . '&president=' . $filename . '&remote_timestamp=' . $timestamp . '&manager_file=' . $manager_file;
	my $res = eval { return $ua->insecure(1)->post($url)->result };

	$returner->{'body'} = eval { return decode_json $res->body };
	$port = $returner->{'body'}->{'port'};
	$manager =~ s/:3000/:$port/gi;
	$manager =~ s/:6100/:$port/gi;
	if ($returner->{'body'}->{'fqdn'} && $ip !~ /[a-zA-Z]/) {
		$returner->{'body'}->{'ip_address'} = $ip;
		my $fqdn = $returner->{'body'}->{'fqdn'};
		my $ping = `timeout .5 ping -c 1 $fqdn`;
		if ($ping =~ /ttl/gi) {
			my @ping = split /\n/, $ping;
			if ($ping[1] =~ /$ip/) {
				$manager =~ s/$ip/$fqdn/gi;

				my $devices = &subs::db_select('devices')->hashes;
				foreach my $d ( @{$devices} ) {
					my $address = eval { return decode_json $d->{'address'} };

					my @neigh = grep { $_->{'ip'} eq $ip } @{$address->{$nic}->{'neigh'}};
					#$neigh[0]->{'ip'} = $fqdn;
					$neigh[0]->{'fqdn'} = $fqdn;
					$neigh[0]->{'purpose'} = $returner->{'body'}->{'device'};
					$neigh[0]->{'ip_address'} = $ip;
					$neigh[0]->{'signatorial'} = $returner->{'body'}->{'signatorial'};
					my $jaddress = encode_json $address;
					&subs::db_update('devices', { address => $jaddress }, { uuid => $d->{'uuid'}} );			
				}
			
				$ip = $fqdn;
			}
		}
	}

	if ($returner->{'body'}->{'authentication'} eq 'approved') {
		$ua = Mojo::UserAgent->new();
		$url = $manager . '/sesh_check?silence=yes&neighbour=' . $browser_tab_id . '&numerics=' . $password . '&president=' . $filename . '&remote_timestamp=' . $timestamp . '&manager_file=' . $manager_file;
		my $double_check = eval { return $ua->insecure(1)->post($url)->result };
		$returner->{'body'} = eval { return decode_json $double_check->body } ;
		
		my $signatorial = &subs::signatorial_designer();
		if ($returner->{'body'}->{'authentication'} eq 'approved') {# && $returner->{'body'}->{'signatorial'} eq &subs::signatorial_designer()) {
			my $uuid = &subs::random_string_creator(15);
			$bti = $returner->{'body'}->{'browser_tab_id'};
			my $ssh_port = $returner->{'body'}->{'ssh_port'} || $config->{'ssh_port'};
			my $remote_device = $returner->{'body'}->{'device'};
			my $buttons = [

				{ name => 'RD', class => 'neighbour_disconnect', direction => 'disconnect' },
				{ name => 'Upgrade', class => 'remote_upgrade' },
				{ name => 'cxl_up', class => 'remote_upgrade_clear' },
				{ name => '-> Me', class => 'remote_rsync', direction => 'from' },
				{ name => 'Me ->', class => 'remote_rsync', direction => 'to' }
			];
			$returner->{'button'} .= '<a target="_blank" href="' . $manager . '/manager"><button>Go</button></a><br>';
			foreach my $b ( @{$buttons} ) {
				$returner->{'button'} .= '<button direction="' . $b->{'direction'} . '" device="' . $remote_device .'" 
					home="' . $returner->{'body'}->{'pwd'} . '" signatorial="' . $returner->{'body'}->{'signatorial'} . '"
					hostname="' . $returner->{'body'}->{'hostname'} . '" uuid="' . $uuid . '" ssh_port="' . $ssh_port .'" ip="' . $ip . '" database="' . $returner->{'body'}->{'database'} .  '"
					class="' . $b->{'class'} . '">' . $b->{'name'} . '</button>';
			}
			$returner->{'button'} .= '<span class="remote_machine_specials"><br>U: <input class="remote_machine_input" type="text" name="username" signatorial="' . $returner->{'body'}->{'signatorial'} . '" ip="' . $ip . '" uuid="' . $uuid . '" value=""><br>' . 
				'P: <input type="password" name="password" class="remote_machine_input" uuid="' . $uuid . '" signatorial="' . $returner->{'body'}->{'signatorial'} . '" value="" ip="' . $ip . '"><br>' . 
				'G: <input type="text" name="gimme" class="gimme_input" uuid="' . $uuid . '" signatorial="' . $returner->{'body'}->{'signatorial'} . '"></span>';
			$returner->{'status'} = 'Connected';
			my $secret = &subs::db_select('security', ['credential'], { level => 1 })->hash->{credential};
			my $double = &subs::decrypter($password,$secret);
			if ((secure_compare $password, $double)) {
				$returner->{'password'} = $secret;
				my $hs = `hostname`;
				chomp $hs;
				$returner->{'hostname'} = $hs;
				my $who = `whoami`;
				chomp $who;
				$returner->{'username'} = $who;
				$returner->{'colour'} = '#' . &subs::random_colour_grabber();
				#$ua->insecure(1)->get($manager . '/manager/say_it?words=' . &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || $hs)->result;

				my $json_buttons = encode_json $buttons;
				my $remote_data = encode_json $returner->{'body'};
				my $cookie_jar = $ua->cookie_jar;
				my @cookies;
				for my $cookie (@{$cookie_jar->find(Mojo::URL->new($manager))}) {
					push @cookies, {
						name => $cookie->name,
						value => $cookie->value,
						domain => $ip,
						path => '/'
					};
				}


				my $cookies = encode_json \@cookies;
				my $nd = &subs::db_select('remote_machines', undef, { ip => $ip, signatorial => $returner->{'body'}->{'signatorial'} })->hashes || [];

				my $remote_machine = { 
					ip => $ip,
					fqdn => $returner->{'body'}->{'fqdn'},
					port => $port,
					ws_port => $returner->{'body'}->{'ws_port'},
					status => 'connected',
					manager => $manager,
					timestamp => $timestamp, 
					server_time => $server_time,
					buttons => $returner->{'button'},
					data => $remote_data,
					signatorial => $returner->{'body'}->{'signatorial'},
					cookie => $cookies,
					connection => 'active',
					uuid => $uuid,
					nic => $nic,
					manager_file => $returner->{'body'}->{'manager_file'},
					device => $returner->{'body'}->{'device'},
					hostname => $returner->{'body'}->{'hostname'}
				};
				if (scalar @{$nd} > 0) {
					&subs::db_update('remote_machines', $remote_machine, { ip => $ip, signatorial => $returner->{'body'}->{'signatorial'} });
				}
				else {
					&subs::db_insert('remote_machines', $remote_machine);
				}
			}
		}
	}
	return $returner;
}

post '/manager/configure/remote_machine_input' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $signatorial = $c->param('signatorial');
	my $ip = $c->param('ip');
	my $uuid = $c->param('uuid');
	my $value = $c->param('value');
	my $name = $c->param('name');
	if ($name eq 'password') {
		$value = &subs::encrypter($c->session('suds'), $value);
	}
	&subs::db_update('remote_machines', { $name => $value }, { ip => $ip, signatorial => $signatorial, uuid => $uuid });
	my $remote_machine = &subs::db_select('remote_machines', undef, { ip => $ip, signatorial => $signatorial })->hashes->[0];
	
	$c->render(text => 'ok');
};

post '/manager/configure/remote_device_locker' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $ip = $c->param('ip');
	my $status = $c->param('status');
	my $nic = $c->param('nic');
	my $device = &subs::db_select('devices', undef, { uuid => $uuid })->hashes->[0];
	my $address = eval { return decode_json $device->{'address'} };

	my @remote_device = grep { $_->{'ip'} eq $ip } @{$address->{$nic}->{'neigh'}};

	my $rd = $remote_device[0];
	if ($status eq 'yes') {
		$rd->{'locked'} = 'no';
	}
	else { 
		$rd->{'locked'} = 'yes';
	}
	@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $ip } @{$address->{$nic}->{'neigh'}};
	push @{$address->{$nic}->{'neigh'}}, $rd;
	@{$address->{$nic}->{'neigh'}} = sort { $a->{'ip'} cmp $b->{'ip'} } @{$address->{$nic}->{'neigh'}};
	my $jaddress = encode_json $address;
	&subs::db_update('devices', { address => $jaddress }, { uuid => $uuid });

	$c->render(json => $rd);
	


};

sub remote_useragent_maker($data) {
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	my $remote_machine = $data->{'rm'};
	my $ua = Mojo::UserAgent->new();
	$ua = $ua->max_response_size(0);
	$remote_machine = &subs::db_select('remote_machines', undef, { ip => $ip, signatorial => $signatorial })->hashes->[0]
		unless $remote_machine;
	my $manager = $remote_machine->{'manager'};

	my $port = $remote_machine->{'port'};
	if ($remote_machine->{'cookie'}) {
		my $cookie_jar = decode_json $remote_machine->{'cookie'};
		foreach my $cookie ( @{$cookie_jar} ) {
			$ua->cookie_jar->add(
				Mojo::Cookie::Response->new(
					name => $cookie->{'name'},
					value => $cookie->{'value'},
					domain => $cookie->{'domain'},
					path => $cookie->{'path'}
				)
			);
		}
		my $domain = $config->{'domain'} || $ip;
		my $url = 'https://' . $ip . ':3000/manager/remote_auth_test?signatorial=' . &subs::signatorial_designer() . '&domain=' . $config->{'domain'};

		$remote_machine->{'ua'} = $ua;
		$remote_machine->{'ua'}->inactivity_timeout(3000);

		my $res = eval { return $remote_machine->{'ua'}->insecure(1)->get($url => {Accept => '*/*'} => 'Content!')->result };
		$remote_machine->{'res'} = $res;
		if (!$res) {
			$remote_machine->{'ua'} = undef;
		}
	}

	$remote_machine->{'data'} = eval { return decode_json $remote_machine->{'data'} };

	return $remote_machine;
}

post '/manager/neighbour_status' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $status = $c->param('status');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $remote_machines = &subs::db_query('select * from remote_machines where ip=?', $ip);
	my $re_ma = $remote_machines->hashes;
	my $rm = $re_ma->[-1];
	
	if ($rm->{'status'} eq 'mirror') {
		$rm->{'status'} = 'off';
	}
	else {
		$rm->{'status'} = 'mirror';
	}
	&subs::db_update('remote_machines', { status => $rm->{'status'} }, { ip => $ip });
	$c->render(json => $rm);
	my $remote_address = $c->tx->remote_address;
	`timeout .5 ping -c 1 $remote_address`;
};

post '/manager/configure/device_domain_updater' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $domain = $c->param('domain');
	my $uuid = $c->param('uuid');
	&subs::db_update('devices', { 'domain' => $domain }, { timestamp => $timestamp, uuid => $uuid });
	$c->render(text => 'ok');
};

post '/manager/configure/device_deleter' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	&subs::db_delete('devices', { timestamp => $timestamp, uuid => $uuid });
	$c->render(text => 'deleted');
};

post '/manager/leave' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::say_it('leave');
	&remote_relay_request($c);
	my $timestamp = $c->param('timestamp');
	$c->param('reason' => 'leave');
	my $server_time = &subs::rightNow();
	my $d = $c->param('debriefer');
	my $settings = decode_json $d;
	&subs::db_delete('settings',{app => '__DEBRIEFING__', device => $device});
	&subs::db_delete('settings',{app => 'keyboard'});
	&subs::db_delete('settings',{app => 'watch', setting => 'patience' });
#	&subs::db_delete('remote_machines');
	my $hostname = `hostname`;
	chomp($hostname);
	&subs::db_insert('settings', { 
		app => '__DEBRIEFING__',
		timestamp => $timestamp,
		setting => $hostname,
		value => $d,
		device => $device,
		uuid => &subs::random_string_creator(20)
	});
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);
	&subs::db_insert('appointments', { warranty => $warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "depart", timestamp => $timestamp, server_time => $server_time });
#	&subs::db_delete('cache');
	&subs::backup_now($c);
	`shred -u $database`;
	`shred -u $database-shm`;
	`shred -u $database-wal`;
	`shred -u $logfile`;
	delete $c->session->{'authentication'};
	delete $c->session->{'database'};
	delete $c->session->{'suds'};
	delete $c->session->{'reject_count'};
	delete $c->session->{'browser_tab_id'};
	delete $c->session->{'browser_tab'};
	my $restore_list;
	unless (-e $database && -s $database > 5000) {
		$restore_list = &subs::restore_list();
	}
	$database = '';
	my $start_dir = $config->{'start_dir'};
	unless (-e $database) {
		if ($c->param('restore_list')) {
			my $list = $c->param('restore_list');
			$restore_list = &subs::restore_list($list);
			@{$restore_list} = grep { $_->{'filename'} =~ /enc$/gi } @{$restore_list};
		}
	}

	$c->render(
		template => 'gate',
		layout => 'gate',
		restore_list => $restore_list,
		start_dir => $start_dir,
		config => { 'gate' => {'background_colour' => 'grey' } },
	);
	$subs::database_holder = undef;
	&subs::say_it('Goodbye');
	$sql = undef;
};

post '/manager/lock_session' => sub($c) {
	&lock_session($c);
	&remote_relay_request($c);
	$c->render('text' => 'locked');
};
sub lock_session($c) {
	my $now = &subs::rightNow();
	my ($db) = &subs::database_grabber();
	
	&subs::setting_setter({ app => '__president', setting => 'pl_time', value => &subs::encrypter($c->session('suds'), $now ) });
	if (&subs::setting_grabber({ app => 'gallery', setting => 'combo_unlock' })) {
		&subs::setting_deleter({ app => 'gallery', setting => 'combo_unlock' });
		&subs::window_closer('gallery');
		&subs::setting_deleter({ app => 'music', setting => 'combo_unlock' });
	}

	my $player = &subs::cache_get({ app => 'music', context => 'player' });
	if ($player->{'unlocked'} == 1) {
		&subs::cache_delete({ app => 'music', context => 'player' });
		&subs::cache_delete({ app => 'music', context => 'content' });
		&subs::window_closer('music');
	}
	my $websockets = &subs::db_query('select * from websockets','stayingAlive')->hashes;
	my $port = $c->req->url->base->port;

	foreach my $ws ( @{$websockets} ) {
		if ($ws->{'href'} =~ /\Q$port/gi) {
			my $settings = &subs::settings_grabber({ app => $ws->{'app'}, settings => [ 'visibility' ] });
			if ($settings->{'visible'} ne 'checked') {
				&subs::window_closer($ws->{'app'});
			}
		}
		elsif (!$ws->{'room'}) {
			&subs::db_delete('websockets', { uuid => $ws->{'uuid'} });
		}
	}

	my $padlock = &subs::db_query('select * from security where level = ?', 'padlock')->hashes;


	if (scalar @{$padlock} > 0 && $now > $c->session('last_padlock') + 5000) {
		my $attempts = &subs::note_decrypter($c->session('suds'), &subs::setting_grabber({ app => '__president', setting => 'padlock_pulls' }));
		my $pl = $c->render_to_string(template => 'padlock', mode => 'locker');
		my $colour = &subs::random_colour_grabber();
		my $taunt_size = scalar @gb::taunts;
		my $taunts = $gb::taunts[rand($taunt_size)];
		&Websocket::send('server', { padlock => $pl, taunts => $taunts, attempts => $attempts, colour => $colour  });
	#	$c->render(template => 'padlock', mode => 'locker');
	#	my $path = $c->req->url->path;
	#	unless $path eq '/manager/security/padlock_pull'
		$c->session('last_padlock' => $now );
	}

}

get '/manager' => sub ($c) {

	my ($db,$database,$sql) = &subs::database_grabber();
	my $hostname = `hostname`;
	chomp $hostname;
	sub jonathan_to_jawn() {
		my $jonathans = `ls images/jonathans`;

		my @jonathans = split "\n";
		my @jawns = [];

		foreach my $jonathan ( @jonathans ) {
			push @jawns, {
				file => $jonathan
			};
		}
	}
	my $advertise_watching = &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' });
	my $pseudonyms = &pseudonym_maker('manager','');


	my $phtml = $c->render_to_string(
		template => 'pseudonyms',
		config => &subs::config_reader(),
		pseudonyms => $pseudonyms,
		device => $device
	);
	my ($website,$header) = &website_preloader($c);

	my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my $ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/manager/ws';
	my $mail_ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/mail/ws';
	my $paperboy_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/observer/ws';
	my $padlock = &subs::db_select('security', ['level'], { level => 'padlock' })->hashes;
	my $parking_lot = &parking_lot_grabber($c);

	$c->render(
		pseudonyms => $pseudonyms,
		bar => $phtml,
		layout => 'manager',
		title => &subs::setting_grabber({ app => 'me', setting => 'computer_name' }) || $hostname,
		template => 'manager',
		newsstand => &subs::statement_grabber(),
		manager_file => &manager_file_maker($c->session('name')),
		config => &subs::config_reader(),
		website => $website,
		my_name => $my_name,
		'device' => $device,
		'ws_url' => $ws_url,
		mail_ws_url => $mail_ws_url,
		paperboy_url => $paperboy_url,
		advertise_watching => $advertise_watching,
		padlock => $padlock,
		header => $header,
		menu => 'running'
	);
};

get '/manager/window_retriever' => sub($c) {
	my $ticket_uuid = $c->session('ticket_uuid');
	my $user_agent = $c->param('user_agent');
	my $wsq = &subs::db_query('select distinct(app) as app,* from websockets where ticket_uuid = ? and user_agent = ? order by server_time desc LIMIT 20', $ticket_uuid, $user_agent)->hashes;
	my @actuals = grep { $_->{'browser_tab_id'} eq $c->param('browser_tab_id') } @{$wsq};
	if (scalar @actuals > 0) {
		@{$wsq} = @actuals;
	}
	my $returner = { 'tab' => {}, 'server' => {}, 'music' => {} };
	foreach my $ws ( @{$wsq} ) {
		if ( $ws->{'app'} eq 'tab' && $ws->{'windows'}) {
			$returner->{$ws->{'app'}} = $ws;
		}
	}


	$c->render(json => $returner);
};

get '/manager/start_menu' => sub($c) {
	my $start_menu = &start_menu_maker($c);
	$c->render(json => $start_menu);
};

sub start_menu_maker($c) {
	my $fingerprint = 0;
	my $returner = {};
	my $menu = $c->param('menu');

	if (1 == 0) {
		&Websocket::send('server', { console => '$(\'#alert\').html(\'<h1>Fingerprint NOW!</h1><img src="/images/jbuttons/ne pas.png"><button id="alert_cancel">Hide</button>\').show()' });
		if ($device eq 'mobile') {
			my $tf = `termux-fingerprint`;
			my $f = eval { return decode_json $tf } || {};
			if ($f->{'auth_result'} eq 'AUTH_RESULT_SUCCESS') {
				$fingerprint = 1;
			}
		}
		elsif ($device eq 'computer' ) {
			my $f = `fprintd-verify`;
			my @f = split /\n/, $f;
			if ($f[-1] eq 'Verify result: verify-match (done)') {
				$fingerprint = 1;
			}
		}
		else {
			$fingerprint = 1;
		}
		&Websocket::send('server', { console => '$(\'#alert\').hide()' });
	}
	$fingerprint = 1;
	if ($fingerprint == 1) {
		$returner = {
			html => $c->render_to_string(
				template => 'start_menu',
				parking_lot => &parking_lot_grabber($c),
				config => &subs::config_reader(),
				padlock => &subs::db_select('security', ['level'], { level => 'padlock' })->hashes,
				menu => $menu
			)
		};

	}
	else {
		&lock_session($c);
	}

	return $returner;
}

sub parking_lot_grabber($c) {
	my $parking_lot = {};
	my $spaces = &subs::db_query('select * from websockets where room is not null')->hashes;

	foreach my $pl ( @{$spaces} ) {
		my $others = &subs::db_select('websockets', undef, { browser_tab_id => $pl->{'browser_tab_id'} })->hashes;
		foreach my $ot ( @{$others} ) {
			if ($ot->{'music_data'}) {
				$pl->{'music_data'} = $ot->{'music_data'};
			}
			elsif ($ot->{'jp_data'}) {
				$pl->{'jp_data'} = $ot->{'jp_data'};
			}
		}
		$parking_lot->{$pl->{'room'}} = $pl;
	}
	return $parking_lot;
}

sub website_preloader($c) {
	my ($website,$header);

	if ($c->param('app')) {
		my $advertise_watching = &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' });
		my $app = $c->param('app');
		$header = &subs::appt_header_printer({ app => $app });
		my $timestamp = $c->param('timestamp') || &subs::rightNow();
		my $appts = &log_reader({ app => $app, view => 'centre_view', timestamp => $timestamp  });
		$website = $c->render_to_string(
			template => 'appointment_wrapper',
			appts => $appts,
			appointments => [ $app ],
			timestamp => $timestamp,
			device => $device,
			from => 'centre_view',
			config => &subs::config_reader(),
			measures => $gb::measures,
			advertise_watching => $advertise_watching,
			header => $header
		);
		$website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $website }, $timestamp);
		$c->stash('website' => $website);
	}
	return ($website,$header);
}


sub pseudonym_maker($context,$app) {
	if (my $ps = &subs::cache_get({ app => 'me', context => 'pseudonyms', subcontext => $context })) {
		return $ps;
	}
	my $pseudonyms = [
		{ status => 'on', name => "remote_control", icon => "Froggoli", speech => 'Ribbit' },		
		{ status => 'on', name => "delorean", icon => "Mr. Sun", speech => 'Run for it Marty!' },
		{ status => 'on', name => "walkboy", icon => "headphones", speech => 'av room' },		
		{ status => 'on', name => "keyboard", icon => "keyboard", speech => 'typewriter' },
		{ status => 'on', name => "calculator", icon => "calculator", speech => 'calculator' },		
		{ status => 'on', name => "notifications", icon => "bell", speech => 'where are your friends now?' },
		{ status => 'on', name => "console", icon => "windows", speech => 'i watch the baytch' },
		{ status => 'on', name => "controller", icon => "heart", speech => 'Run for it Marty!' },
		{ status => 'button', name => 'record', icon => 'record', classmates => "medium_thumb save_appointment", colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'text', icon => 'love letter', colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'start', icon => 'play', classmates => "medium_thumb save_appointment", colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'prev', icon => 'prev', classmates => "medium_thumb time_jump", colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'next', icon => 'next', classmates => "medium_thumb time_jump", colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'stop', icon => 'stop', classmates => "medium_thumb save_appointment", click => "", colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'note', icon => 'Mr. President', classmates => "br medium_thumb save_appointment", colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'msg', icon => 'mailbox', colour => '#ffec1f', place => 'top' },
		{ status => 'button', name => 'usual', icon => 'usual_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'video', icon => 'camera', classmates => "little_thumb multimedia save_appointment", click => "", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'camera', icon => 'eye', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'marker', icon => 'marker', colour => '#ff0000', place => 'mid' },
		{ status => 'button', name => 'screen', icon => 'monitor', classmates => "little_thumb multimedia save_appointment", click => "", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'audio', icon => 'microphone', classmates => "little_thumb save_appointment", click => "", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'renew', icon => 'renew', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'cancel', icon => 'cancel_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'telephone', icon => 'telephone line', classmates => 'medium_thumb save_appointment', colour => '#ffec1f', place => 'mid' },
		{ status => 'button', name => 'delay', icon => 'delay_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'transaction', icon => 'register', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'complete', icon => 'cake', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'inventory', icon => 'inventory', classmates => "little_thumb", colour => '#bdd6c5' },
		{ status => 'button', name => 'upload', icon => 'upload', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'entry', icon => 'eye', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'dingaling', icon => 'badge', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'id', icon => 'key', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'backup', icon => 'diskette', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'image', icon => 'gallery', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'leave', icon => 'exit', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'snapshot', icon => 'gallery', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'studio', icon => 'mixer', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'purchase', icon => 'cash', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'pause', icon => 'pause', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'resume', icon => 'detour', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'command', icon => 'code', classmates => "little_thumb save_appointment", colour => '#ff007b', place => 'bottom' },
		{ status => 'button', name => 'sms', icon => 'phone_sms', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'button', name => 'email', icon => 'envelope', classmates => "", colour => '#bdd6c5',  },
		{ status => 'button', name => 'scan', icon => 'flatbed', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'button', name => 'feeder', icon => 'feeder', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'button', name => 'scraper', icon => 'scraper', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'none' },
		{ status => 'button', name => 'config', icon => 'wrench', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'none' },
		{ status => 'button', name => 'web', icon => 'web_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'cursor', name => 'pointer', icon => 'pointer', classmates => "little_thumb", colour => '#ffec1f', place => 'bottom' },
		{	status => 'cursor', name => 'eyepointer', icon => 'eyepointer', classmates => "little_thumb", colour => "#ffec1f", place => 'bottom' },
		{	status => 'cursor', name => 'measure', icon => 'measures', classmates => "little_thumb", colour => "#ffec1f", place => 'bottom' },
	];

	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ 'app' => 'config', setting => 'pseudonyms' }) } || {};


	if ($context eq 'manager') {
		@{$pseudonyms} = grep { $_->{'status'} eq 'on' } @{$pseudonyms};
	}
	elsif ($context eq 'config') {
		@{$pseudonyms} = grep { $_->{'status'} eq 'on' || $_->{'status'} eq 'off' } @{$pseudonyms};
	}
	elsif ($context eq 'viewer') {
		#@{$pseudonyms} = grep { $_->{'status'} eq 'button' } @{$pseudonyms};
	}
	elsif ($context eq 'store') {
		@{$pseudonyms} = grep { $_->{'classmates'} !~ /save_appointment/ } @{$pseudonyms};
	}
	elsif ($context eq 'teletype') {
		@{$pseudonyms} = grep { $_->{'status'} eq 'cursor' } @{$pseudonyms};
	}
	foreach my $p ( @{$pseudonyms} ) {
		foreach my $k ( keys %{$custom_pseudonyms->{$p->{'name'}}} ) {

			$p->{$k} = $custom_pseudonyms->{$p->{'name'}}->{$k} if $custom_pseudonyms->{$p->{'name'}}->{$k};
		}
		unless ( $custom_pseudonyms->{$p->{'name'}}->{'icon'} ) {
			my $i = $p->{'icon'};
			$p->{'icon'} = "/images/decipherable/" . $i . ".png";
			unless (-e "public/" . $p->{'icon'}) {
				$p->{'icon'} = "/images/studio/" . $i . ".png";
				unless (-e "public/" . $p->{'icon'}) {						
					$p->{'icon'} = "/images/make believe/" . $i . ".png";
					unless (-e "public/" . $p->{'icon'}) {
						$p->{'icon'} = "/icons/" . $i . ".png";
						unless (-e "public/" . $p->{'icon'}) {
							$p->{'icon'} = "/icons/" . $i . ".jpg";
							unless (-e "public/" . $p->{'icon'}) {
								$p->{'icon'} = "/images/icons/" . $i . ".png";
								unless (-e "public/" . $p->{'icon'}) {
									$p->{'icon'} = "/images/jonathans/" . $i . ".png";
								}
							}
						}
					}
				}
			}
		}
	}

	&subs::cache_set({ app => 'me', context => 'pseudonyms', subcontext => $context }, $pseudonyms);
	return $pseudonyms;
};

get '/manager/configure/pseudonym_list' => sub($c) {
	my $timestamp = $c->param('timestamp');

	my ($db,$database,$sql) = &subs::database_grabber();

	my $pseudonyms = &pseudonym_maker('','');
	$c->render(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
};

post '/manager/configure/pseudonym_setter' => sub($c) {
	my $timestamp = $c->param('timestamp');
	&subs::cache_delete({ app => 'me', context => 'pseudonyms' });
	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ app => 'config', setting => 'pseudonyms' }) } || {};

	my $setting = $c->param('setting');
	my $name = $c->param('name');
	my $value = $c->param('value');

	$custom_pseudonyms->{$name}->{$setting} = $value;


	my $cs = encode_json $custom_pseudonyms;
	&subs::setting_setter({ app => 'config', setting => 'pseudonyms', value => $cs });
	my $pseudonyms = &pseudonym_maker('','');
	$c->render(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
};

get '/manager/configure/pseudonym_defaulter' => sub($c) {
	my $name = $c->param('name');
	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ app => 'config', setting => 'pseudonyms' }) } || {};
	$custom_pseudonyms->{$name} = undef;
	my $cs = encode_json $custom_pseudonyms;
	&subs::setting_setter({ app => 'config', setting => 'pseudonyms', value => $cs });
	my $pseudonyms = &pseudonym_maker('','');
	$c->render(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
};

post '/manager/configure/pseudonym_icon_changer' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ app => 'config', setting => 'pseudonyms' }) } || {};
	my $name = $c->param('name');
	my $image = $c->param('image');
	$custom_pseudonyms->{$name}->{'icon'} = $image;

	my $cs = encode_json $custom_pseudonyms;
	&subs::setting_setter({ app => 'config', setting => 'pseudonyms', value => $cs });
	my $pseudonyms = &pseudonym_maker('','');
	my $returner;
	$returner->{'list'} = $c->render_to_string(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
	$c->render(json => $returner);
};


get '/manager/qrcode_generator' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $name = &subs::unformat_name($c->param('name') || 'visitor');
	my $privilege = $c->param('privilege') || 'visitor';
	my $project = $c->param('project');
	my $debriefer = $c->param('debriefer');
	my $nic = $c->param('nic');
	my $suds = $c->session('suds');
	my $warranty = $c->param('warranty');

	my $data = &qrcode_generator({
		timestamp => $timestamp,
		app => $app,
		name => $name,
		privilege => $privilege,
		project => $project,
		debriefer => $debriefer,
		nic => $nic,
		suds => $suds,
		warranty => $warranty
	});
	&subs::db_insert('tickets', $data);
	&subs::setting_setter({ app => 'box_office', setting => 'last_privilege', value => $privilege });
	&subs::setting_setter({ app => 'box_office', setting => 'last_nic', value => $nic });
	&subs::setting_setter({ app => 'box_office', setting => 'last_name', value => $name });
	$c->render(json => $data);
};

sub qrcode_generator($params) {
	my $timestamp = $params->{'timestamp'} || &subs::rightNow();
	my $app = $params->{'app'};
	my $name = $params->{'name'};
	my $project = $params->{'project'};
	my $debriefer = $params->{'debriefer'};
	my $nic = $params->{'nic'};
	my $suds = $params->{'suds'};
	my $warranty = $params->{'warranty'};
	my $privilege = $params->{'privilege'};
	my $db = $params->{'db'};
	my $database = $params->{'database'};
	my $sql = $params->{'sql'};


	my $server_time = &subs::rightNow();
	unless ($db) {
		($db,$database,$sql) = &subs::database_grabber('new');
	}
	my $random_password = &subs::random_string_creator(40);
	my $sj = { ts => $timestamp, p => &subs::random_string_creator(25), uuid => &subs::random_string_creator(10) };

	my $secret_json = encode_json $sj;
	my $suds = &subs::note_encrypter($sj->{'p'}, $suds);
	my $secret = &subs::note_encrypter($random_password, $secret_json);
	$secret = url_escape `echo "$secret" | base64 -w 0`;

	my $uuid = $sj->{'uuid'};

	my $domain;
	unless ($params->{'db'}) {
		if ($nic eq &subs::config_reader()->{'domain'}) {
			$domain = $nic;
		}
		else {
			my $x = &subs::device_lister($timestamp, '')->[0]->{'address'};
			$domain = $x->{$nic}->{'ip'};
		}
	}
	else {
		$domain = '127.0.0.1';
	}
	my $port = $ENV{PORT_AHOY};
	if ($device eq 'server') {
		$port = 443;
	}
	my $url = 'https://' . $domain . ':' . $ENV{'PORT_DOCK'} . '/box_office/' . $sj->{'uuid'} . '?s=' . $secret;
	my $warranty = $warranty || &subs::setting_grabber({ app => 'box_office', setting => 'warranty' });
	unless ($params->{'db'}) {
		&subs::setting_setter({ app => 'box_office', setting => 'warranty', value => $warranty });
	}
	$warranty = &subs::ago_calc($warranty,$timestamp);
	my $duration = $warranty - $timestamp;

	my $qr = `qrencode -o - $url`;
	my $image = 'data:image/png;base64,' . encode_base64($qr);
	my $data = {
		timestamp => $timestamp,
		uuid => $sj->{'uuid'},
		warranty => $warranty,
		url => $url,
		server_time => $server_time,
		name => $name,
		image => $image,
		privilege => $privilege,
		verification => $secret,
		status => 'active',
		duration => $duration,
		app => $app,
		password => $random_password,
		port => $ENV{PORT_AHOY},
		ip => $domain,
		secret => $secret,
		nic => $nic,
		project => $project,
		suds => $suds,
		debriefer => $debriefer
	};
	return $data;
}

sub qrcode_updater($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $q = &subs::db_query('select * from tickets');
	my $tickets = $q->hashes;
	my $level_one_q = &subs::db_query('select timestamp from security where level=1 order by timestamp DESC limit 1');
	my $level_one = $level_one_q->hashes;

	foreach my $t ( @{$tickets} ) {
		my $secretive = $t->{'secret'};
		my $ver = url_unescape `echo "$secretive" | base64 --decode`;
		my $ts = &subs::note_decrypter($t->{'password'},$ver);

		my $sj = decode_json $ts;
		if ( $t->{'port'} ne $ENV{PORT_AHOY} || $level_one->[0]->{'timestamp'} >= $t->{'server_time'}) {
		#	$sj->{'ts'} = &subs::rightNow();
			my $suds = &subs::note_encrypter($sj->{'p'}, $c->session('suds'));
			my $secret_json = encode_json $sj;
			my $secret = &subs::note_encrypter($t->{'password'}, $secret_json);
			$secret = url_escape `echo "$secret" | base64 -w 0`;
			my $x = &subs::device_lister($timestamp, '')->[0]->{'address'};
			my $url = 'https://' . $x->{$t->{'nic'}}->{'ip'} . ':' . $ENV{'PORT_DOCK'} . '/box_office/' . $t->{'uuid'} . '?s=' . $secret;
			my $qr = `qrencode -o - $url`;
			my $image = 'data:image/png;base64,' . encode_base64($qr);
			&subs::db_update('tickets', {
				ip => $x->{$t->{'nic'}}->{'ip'}, 
			#	url => $url, 
			#	image => $image, 
				port => $ENV{PORT_AHOY},
				server_time => &subs::rightNow(),
			#	secret => $secret,
				suds => $suds
			},
			{ uuid => $t->{'uuid'} });
		}
	}
}

get '/manager/box_office' => sub($c) {
	my $app = &subs::unformat_name('box_office');
	my $view = $c->param('view') || &subs::setting_grabber({ app => 'misc', setting => 'box_office_view' });
	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();
	&qrcode_updater($c);
	my $ticks = &subs::db_query('select * from tickets');
	my $tickets = $ticks->hashes;
	my $devices = &subs::device_lister($timestamp, '');
	my $addresses = $devices->[0]->{'address'};
	my $warranty = $c->param('warranty') || &subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' });
	my $projs = &subs::db_query('select * from settings where setting=? and value=?', 'pos','project');
	my $projects = $projs->hashes;
	my $persons = &subs::db_query('select * from settings where setting=? and value=? or value = ?', 'pos','person', 'customer');
	foreach my $t ( @{$tickets} ) {
		my $al = eval { return decode_json $t->{'access_log'} } || [];
		$t->{'access_log'} = $al;
	}
	my $people = $persons->hashes;
	my $content = $c->render_to_string(
		template => 'box_office',
		timestamp => $timestamp,
		config => &subs::config_reader(),
		addresses => $addresses,
		tickets => $tickets,
		nic => &subs::setting_grabber({ app => $app, setting => 'last_nic' }),
		name => &subs::setting_grabber({ app => $app, setting => 'last_name' }) || &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
		privilege => &subs::setting_grabber({ app => $app, setting => 'last_privilege' }) || 'visitor',
		warranty => $warranty,
		projects => $projects,
		people => $people,
		config => &subs::config_reader(),
		view => $view
	);

	if ($c->param('source') ne 'list') {
		$content = &window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $content }, $timestamp);
	}
	$c->render('text' => $content);
};


any '/box_office/ticket_request' => sub($c) {
	my $call = $c->param('call');
	my $privilege = $c->param('privilege');
	my $team = $c->param('team');
	my $club = $c->param('club');
	my $community = $c->param('community');
	my $timestamp = $c->param('timestamp');
	if ($call eq 'form') {
		my $content = $c->render_to_string(
			template => 'store/ticket_request',
		);
		$c->render(json => { content => $content });
	}
	elsif ($call eq 'privilege') {
		my $content = $c->render_to_string(
			template => 'store/ticket_request_privilege',
			privilege => $privilege,
			team => $team,
			club => $club,
			community => $community
		);
		$c->render(json => { content => $content });
	}
	elsif ($call eq 'submit') {
		my ($db) = &subs::database_grabber();
		my $data = eval { return decode_json $c->param('data') };
		if ($data->{'approval_rating'}) {
			
			&subs::db_insert('tickets', {
				name => &subs::unformat_name($data->{'name'}),
				timestamp => $timestamp,
				server_time => &subs::rightNow(),
				information => $c->param('data')
			});
		}
	}
	else {
		$c->render(template => 'guest_layouts/denial');
	}
};

get '/box_office/:uuid' => sub($c) {
	my $uuid = $c->stash('uuid');
	my $secret = $c->param('s');
	my $ip = $c->tx->remote_address;
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp') || $server_time;
	my ($db,$database) = &subs::database_grabber();

	my $base_host = $c->req->url->base->host;

	if ($base_host ne $config->{'domain'} && $ip ne $c->tx->local_address) {
		$c->render(template => 'guest_layouts/denial');
		return;
	}

	my $base_url = 'https://' . $base_host . ':' . $ENV{PORT_AHOY};
	unless ($db) {
		$c->redirect_to($base_url . '/manager');
		return;
	}
	my $tick = &subs::db_query('select * from tickets where uuid=?', $uuid);
	my $ticke = $tick->hashes;
	unless (scalar @{$ticke} > 0) {
		$c->redirect_to($base_url . '/manager');
		return;
	}

	my $ticket = $ticke->[0];
	my $access_log = eval { return decode_json $ticket->{'access_log'} } || [];
	my $access = { server_time => $server_time, status => 'denial', ip => $ip };

	my $v = $ticket->{'verification'};
	my $ver = url_unescape `echo "$secret" | base64 --decode`;
	my $verification = &subs::note_decrypter($ticket->{'password'}, $ver) ;
	my $vrai = eval { return decode_json $verification } || {};
	unless ($vrai->{'p'}) {
		$c->redirect_to($base_url . '/manager');
		return;
	}
	$secret = &subs::decrypter($vrai->{'p'},&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});
	my $suds = &subs::note_decrypter($vrai->{'p'}, $ticket->{'suds'});
	chomp $suds;

	if ((secure_compare $secret, $suds) && $ticket->{'privilege'} && $ticket->{'status'} eq 'active') {
		&update_database($c);
		$c->session('role' => $ticket->{'privilege'});
		my $warranty = &subs::ago_calc(&subs::setting_grabber({ 'app' => $ticket->{'name'}, setting => 'warranty' }), $timestamp);
		#&subs::db_insert('appointments',{ uuid => &subs::random_string_creator(40), app => $ticket->{'name'}, warranty => $warranty, type => "entry", timestamp => $timestamp, server_time => $server_time });
		my $d = { app => 'customs', role => 'citizen', title => 'Your Majesty', message => &subs::format_name($ticket->{'privilege'}) . ': ' . &subs::format_name($ticket->{'name'}), image => "/images/make believe/crown.png" };
		$c->session('database' => $database);
		$c->session('authentication' => 'approved');
		$c->session('suds' => $suds);
		$c->session('server_time' => $server_time);
		$c->session('warranty' => $ticket->{'warranty'});
		$c->session('source' => 'ticket');
		$c->session('ticket_uuid' => $ticket->{'uuid'});
		$c->session('name' => $ticket->{'name'});
		$c->session('privilege' => $ticket->{'privilege'});
		$c->session('project' => $ticket->{'project'});
		$c->session('app' => $ticket->{'app'} );
		$c->session('padlock' => $server_time) if (scalar @{&subs::db_select('security', [ 'level' ], { level => 'padlock' })->hashes} > 0);
		unless ($c->req->url->base->port eq 3000) {
			&subs::say_it($ticket->{'name'});
			&notification_sender($d,$database);
		}
		$access->{'status'} = 'approved';


		my $mail_ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/mail/ws';
		my $image = $gb::known_appts->{$ticket->{'privilege'}}->{'icon'};
		my %js = (
			title => 'Box Office',
			layout => 'gate',
			template => 'guest_layouts/box_office',
			'authentication' => 'approved', 
			port => $ENV{PORT_AHOY},
			ws_port => $ENV{PORT_MSG},
			alarm_port => $ENV{PORT_BELL},
			device => $device,
			manager_file => &manager_file_maker($c->session('name')),
			ticket => $ticket,
			image => $image
		);
		my $msg = encode_json { app => 'server', ticket => $ticket, timestamp => $timestamp };
		if ($ticket->{'privilege'} eq 'citizen') {
			$js{'redirector'} = $base_url . '/manager';
			$js{'debriefer'} = $ticket->{'debriefer'};
			$js{'js'} = encode_json \%js;
			$c->render(%js);
		}
		elsif ($ticket->{'privilege'} eq 'resident') {
			$js{'debriefer'} = $ticket->{'debriefer'};
			$js{'redirector'} = $base_url . '/store?app=' . $ticket->{'app'};
			$js{'js'} = encode_json \%js;
			$c->render(%js);
		}
		elsif ($ticket->{'privilege'} eq 'guest') {
			$js{'redirector'} = $base_url . '/';
		#	$js{'debriefer'} = $deb;
			$js{'js'} = encode_json \%js;
			$c->render(%js);
		}
	}
	else {
		$c->render(template => 'guest_layouts/denial');
	}
	unless ( grep { $_->{'server_time'} >= $server_time - 5000 } @{$access_log} ) {
		unshift @{$access_log}, $access;
		splice @{$access_log}, 20;
		$ticket->{'access_log'} = encode_json $access_log;
		$ticket->{'server_time'} = &subs::rightNow();
		&subs::db_update('tickets', $ticket, { uuid => $ticket->{'uuid'} });
	}
};

get '/manager/delete_ticket' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');

	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::db_delete('tickets', { uuid => $uuid });
	$c->render('json' => { uuid => $uuid });
};

get '/manager/suspend_ticket' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::db_query('update tickets set status=? where uuid=?','suspended',$uuid);
	$c->render('json' => { uuid => $uuid });
};

get '/manager/renew_ticket' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $warranty = $c->param('warranty');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $tick = &subs::db_query('select * from tickets where uuid=?', $uuid);
	my $ticke = $tick->hashes;
	my $ticket = $ticke->[0];
	$warranty = &subs::ago_calc($warranty,$timestamp);
	my $total_duration = ($warranty - $ticket->{'timestamp'});
	my $new_warranty = ($ticket->{'duration'} + $timestamp);
	&subs::db_update('tickets', { status => 'active', duration => $total_duration, warranty => $warranty }, { uuid => $uuid });

	$c->render('json' => $ticket);
};

get '/manager/reinstate_ticket' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $data = { status => 'active' };
	&subs::db_update('tickets', $data, { uuid => $uuid });
	$c->render('json' => $data);

};

get '/manager/random_word' => sub ($c) {
	my $rw = &random_word_grabber($c->param('times'));
	$c->render( text => $rw );
};

sub random_word_grabber($times) {
	$times = $times || 2;
	my ($db,$database,$sql) = &subs::database_grabber();
	
	my $sentence;
	for (my $t = 0; $t < $times; $t++) {
		my $labour = '%';
		foreach my $n ( 0..3 ) {
			my $r1 = &subs::random_string_creator(100);
			$r1 =~ s/[^0-9]//gi;

			my @r2 = split "", $r1;

			$labour .= $r2[0] . '%';
		}
		$labour .= '%';
		my $query = &subs::db_query('select app from appointments order by random() LIMIT 50');
		my $apps = $query->hashes;
		my @words;
		foreach my $a ( @{$apps} ) {

			my @split = shuffle split '_', $a->{'app'};
			foreach my $sp ( @split ) {
				push @words,$sp if $sp !~ /[^a-zA-z]/;
			}
		}
		@words = shuffle @words;
		$sentence .= $words[rand(50)];
		$sentence .= ' ' if $times > 1;
	}
	return $sentence;
};

sub original_timestamp() {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $original_timestamp = &subs::db_query('select timestamp from security LIMIT 1');
	my $ts = $original_timestamp->hashes;
	return $ts->[0]->{'timestamp'} ;
}

sub log_reader {
	my $data = $_[0] || {};
	my ($db,$database,$sql) = &subs::database_grabber();
	my $chosen_app = $data->{'app'};
	my $scope = $data->{'scope'};
	my $timestamp = $data->{'timestamp'};
	my $timeshift_max = $data->{'timeshift_max'};
	my $search = $data->{'search'};
	my $stats = $data->{'stats'};
	#my $misc_settings = &misc_setting_list();
	my $open_appts = $data->{'appts'};
	my $appt_toggle = $data->{'appt_view_toggle'};
	my $sorts = $data->{'sorts'};
	my $account = $data->{'account'};
	my $project = $data->{'project'};
	my $timestamp_selector = $data->{'sorts'} || 'timestamp';
	$timestamp_selector = 'timestamp' if $timestamp_selector eq 'occurrences';
	if ($sorts eq 'server_time') {
		$timestamp_selector = 'server_time';
	}
	my $time_definition = &subs::rightNow();
	my $server_time = $time_definition;
#	$time_definition = $timestamp unless $timestamp_selector eq 'server_time';
	undef @appointments;
	my ($results,$appointments);
	my $original_timestamp = &subs::db_query('select timestamp from security LIMIT 1');
	my $ts = $original_timestamp->hashes;

	my $birthday = &subs::duration_sayer(  ($timestamp / 1000 ) - &subs::ago_calc( $config->{'birthday'},$timestamp) / 1000) || (($timestamp / 1000 ) - (&original_timestamp() / 1000 ) );
	my $json;
	my $jdata = encode_json $data;
	my $appts = { 
		'__specs' => { 
			birthday => $birthday, 
			timestamp => $timestamp, 
			formatted_timestamp => localtime($timestamp / 1000 )->strftime('%a %D %I:%M:%S%P'),
			server_time => &subs::rightNow(),
			data => $jdata
		},
		'__params' => $data,
	};

	if ($scope && $timestamp && $data->{'view'} eq 'appointment_viewer') {
		# appointment_viewer
		my $t = &{$subs::time_subs->{$scope}}($timestamp); #timestamp at beginning
		my $t1 = ($timestamp - $t);
		my $t2 = ($t1 + $timestamp + $t1);

		$appts->{'__specs'}->{'start'} = $t;
		$appts->{'__specs'}->{'end'} = $t2;
		if ($appt_toggle eq 'on') {
			my $temp_appointments;

			foreach my $a (@{$open_appts}) {
				my @query_variables = ( $a, $t, $t2 );

				my $query;
				if ($data->{'filter'} && $data->{'filter'} ne 'all') {
					$query = "select timestamp,app,server_time,type,duration from appointments where app = ? AND $timestamp_selector between ? and ? and type = ?";
					push @query_variables, $data->{'filter'};
				}
				else {
					$query = "select timestamp,app,server_time,type,duration from appointments where app = ? AND $timestamp_selector between ? and ?";
				}
				if ($project && $project ne 'all') {
					$query .= " and project = ? ";
					push @query_variables, $project;
				}
				if ($account && $account ne 'all') {
					$query .= " and account = ? ";
					push @query_variables, $account;
				}
				$query .=  " order by $timestamp_selector";
				$results = &subs::db_query($query, @query_variables);
				$temp_appointments = $results->hashes;
				push @{$appointments}, @{$temp_appointments};
			}
		}
		else {
			my $query;
			my @query_variables = ( $t, $t2 );
			if ($data->{'filter'} && $data->{'filter'} ne 'all') {
				$query = "select distinct(app) as app,* from appointments where $timestamp_selector between ? and ? and type = ?";
				push @query_variables, $data->{'filter'};
			}
			else {
				$query = "select distinct(app) as app,* from appointments where $timestamp_selector between ? and ?";
				
			}
			if ($project && $project ne 'all') {
				$query .= " and project = ? ";
				push @query_variables, $project;
			}
			if ($account && $account ne 'all') {
				$query .= " and account = ? ";
				push @query_variables, $account;
			}
			$query .= " order by $timestamp_selector LIMIT 500";

			$results = &subs::db_query($query, @query_variables);
			$appointments = $results->hashes;
		}
#		my $resulters = &subs::db_query('select * from continent where timestamp >= ? and timestamp <= ?',$t,$t2);
		my $continent = [];#$resulters->hashes;
		my ($last,$next);
		my $n = 0;
		foreach my $con ( @{$continent }) {
			
			$n = $n + 1;
			my $last = $continent->[$n - 1];
			my $next = $continent->[$n + 1];

			if ($con->{'latitude'} ) {
				push @{$appts->{'__continent'}}, { latitude => $con->{'latitude'}, longitude => $con->{'longitude'} };
			}
		}
	}
	elsif ($search) {
		#search
		my @search_split = split ' ', $search;
		my $searchable = join '%', @search_split;

		my $s = "%" . $searchable . "%";
		$results = &subs::db_query('select * from appointments where app like ?', $s);
		my $temp_appointments = $results->hashes;
		my (@n,@perfect_n);
		foreach my $a (reverse @{$temp_appointments}) {
			if ($a->{'app'} eq $searchable) {
				unshift @n, $a unless grep { $_->{'app'} eq $a->{'app'} } @n;
			}
			else {
				push @n, $a unless grep { $_->{'app'} eq $a->{'app'} } @n;
			}
		}
		push @{$appointments}, @n;

	}
	elsif ($chosen_app && $data->{'view'} eq 'centre_view') {
		#centre_view
		$results = &subs::db_query("select max(timestamp) as timestamp,file,server_time,app,duration,type,status,amount,unit,project,account from appointments where app is not null and app=? and $timestamp_selector <=? order by $timestamp_selector DESC", $chosen_app,$time_definition);
		$appointments = $results->hashes;
		$results = &subs::db_query("select min(timestamp) as timestamp,file,server_time,app,duration,type,status,amount,unit,project,account from appointments where app is not null and app=? and $timestamp_selector >=? order by $timestamp_selector", $chosen_app,$time_definition);
		push @{$appointments}, @{$results->hashes};


		@{$appointments} = grep { $_->{'app'} eq $chosen_app } @{$appointments};
		if (scalar @{$appointments} == 0) {
			push @{$appointments}, { app => $chosen_app };
		}
	}
	elsif ($chosen_app && $data->{'view'} eq 'appointment_details') {
		#appointment_details;
		my $t = &{$subs::time_subs->{$scope}}($timestamp); #timestamp at beginning
		my $t1 = ($timestamp - $t);
		my $t2 = ($t1 + $timestamp);
		if ($data->{'uuid'}) {
			$results = &subs::db_query("select * from appointments where app=? and uuid=? order by server_time DESC", $chosen_app, $data->{'uuid'});
		}
		elsif ($data->{'filter'} ne 'all') {
			$results = &subs::db_query("select * from appointments where app=? and type=? and (($timestamp_selector >= ? AND $timestamp_selector <= ?) or ($timestamp_selector <= ? and (type=? or type=?))) order by timestamp DESC", $chosen_app, $data->{'filter'}, $t,$t2,$t2,'start','record');
		}
		else {
			$results = &subs::db_query("select * from appointments where app=? and (($timestamp_selector >= ? AND $timestamp_selector <= ?) or ($timestamp_selector <= ? and (type=? or type=?))) order by timestamp DESC", $chosen_app,$t,$t2,$t2,'start','record');
		}
		$appointments = $results->hashes;
	}
	elsif ($chosen_app && $data->{'view'} eq 'appointment_display') {
		# appointment_display (configure)
		$results = &subs::db_query("select * from appointments where app=? order by $timestamp_selector limit 1", $chosen_app,$timestamp_selector);
		$appointments = $results->hashes;
		if (scalar @{$appointments} == 0) {
			push @{$appointments}, { app => $chosen_app };
		}

	}
	else {
		# Just give it all to me.
#		$results = &subs::db_query("select distinct(app) as app,* from appointments order by $timestamp_selector");
#		$appointments = $results->hashes;
		return 0;
	}

	$appts->{'__specs'}->{'stats'}->{'appts'}->{'first'} = $appointments->[0]->{'server_time'};
	$appts->{'__specs'}->{'stats'}->{'appts'}->{'last'} = $appointments->[-1]->{'server_time'};




	my $db_settings = &subs::db_select('settings', undef, { setting => 'pos' });
	my $settings = $db_settings->hashes;
	foreach my $s (@{$settings}) {
		if ($s->{'setting'} eq 'pos' && $s->{'value'} eq 'account') {
			push @{$appts->{'__accounts'}}, { formatted_name => &subs::format_name($s->{'app'}), app => $s->{'app'}} unless grep { $_->{'app'} eq $s->{'app'} } @{$appts->{'__accounts'}};
		}
		if ($s->{'setting'} eq 'pos' && $s->{'value'} eq 'project') {
			push @{$appts->{'__projects'}}, { formatted_name => &subs::format_name($s->{'app'}), app => $s->{'app'}} unless grep { $_->{'app'} eq $s->{'app'} } @{$appts->{'__projects'}};
		}
		if ($s->{'setting'} eq 'pos' && $s->{'value'} eq 'account') {
			push @{$appts->{'__accounts'}}, { formatted_name => &subs::format_name($s->{'app'}), app => $s->{'app'}} unless grep { $_->{'app'} eq $s->{'app'} } @{$appts->{'__accounts'}};
		}
	}
	my @app_names = ( $device );
	my $s_query = 'select * from settings where device = ? and (';
	foreach my $a ( @{$appointments} ) {
		unless ( grep { $_ eq $a->{'app'} } @app_names ) {
			push @app_names, $a->{'app'};
			$s_query .= ' or' if scalar @app_names > 2;
			$s_query .= ' app = ?';
		}
	}
	$s_query .= ')';
	if (scalar @app_names > 1) {
		$db_settings = &subs::db_query($s_query, @app_names);
		my @app_settings = @{$db_settings->hashes};

		if ($data->{'view'} eq 'appointment_viewer') {
			if (my @invisible = grep { $_->{'setting'} eq 'visible' && $_->{'value'} ne 'checked' } @app_settings) {
				foreach my $invisible ( @invisible ) {
					@{$appointments} = grep { $_->{'app'} ne $invisible->{'app'} } @{$appointments};
					@app_settings = grep { $_->{'app'} ne $invisible->{'app'} } @app_settings;
				}
			}
		}
		push @{$settings}, @app_settings;
	}

	$appts->{'__specs'}->{'stats'}->{'settings'}->{'first'} = $settings->[0]->{'server_time'};
	$appts->{'__specs'}->{'stats'}->{'settings'}->{'last'} = $settings->[-1]->{'server_time'};
	if ($stats) {
		my $updateable = 0;
		foreach my $table ( qw/appts settings/ ) {
			if (scalar @{$appointments} != $stats->{'appts'}->{'count'} || $appts->{'__specs'}->{'stats'}->{$table}->{'last'} > $stats->{$table}->{'last'} || $appts->{'__specs'}->{'stats'}->{$table}->{'first'} < $stats->{$table}->{'first'}) {
				$updateable = 1;
			}
		}
		if ($updateable == 0) {
			return { updateable => 'no', '__specs' => $appts->{'__specs'} };
		}
		$appts->{'__specs'}->{'stats'}->{'appts'}->{'count'} = scalar @{$appointments};
	}

	foreach my $a (@{$appointments}) {
		next unless $a->{'app'};
	#	$a->{'file'} = undef if $data->{'view'} eq 'appointment_viewer';
		my $cache_check;# = &subs::cache_get({ app => $a->{'app'}, context => $data->{'view'} });
		if ($cache_check) {
			$appts->{$a->{'app'}} = $cache_check;
		#	next;
		}
		$a->{'app'} = &subs::unformat_name($a->{'app'});
		my @a_settings = grep { $_->{'app'} eq $a->{'app'} } @{$settings};
		foreach my $s (grep { $_->{'app'} eq $a->{'app'} } @{$settings}) {
			$appts->{$a->{'app'}}->{'setting'}->{$s->{'setting'}} = $s->{'value'};
			foreach my $oi ( ($scope) ) {
				if ($s->{'setting'} =~ /warranty|duration/gi) {
					$appts->{$a->{'app'}}->{'setting'}->{$oi . '_' . $s->{'setting'}} = &subs::time_abbrev_translator($s->{'value'});
					if (($a->{'type'} eq 'start' || $a->{'type'} eq 'record') && $a->{'timestamp'} < $timestamp) {# && (!$a->{'duration'} || ($a->{'duration'} >= $a->{'timestamp'} - $timestamp))) {
						$a->{'duration'} = $a->{'timestamp'} - $timestamp;
					}
					unless ($a->{'type'} =~ /record|start/) {
						if (my $dur = $a->{'duration'} || $appts->{$a->{'app'}}->{'setting'}->{$oi . '_' . $s->{'setting'}}) {
							$a->{'formatted_' . $s->{'setting'}} = &subs::duration_sayer(($dur / 1000));
						}
					}
				}
			}

		}

		foreach my $at ( qw/model option option_category/ ) {
			$appts->{$a->{'app'}}->{$at} = &subs::db_select($at, undef, { app=> $a->{'app'} })->hashes;
		}
		if ($data->{'view'} eq 'centre_view') {
			my @bm = sort keys %{$gb::budget_modes};

			$appts->{$a->{'app'}}->{'setting'}->{'budget_modes'} = \@bm;
			foreach my $br ( @bm ) {
				if (my $cache = &subs::cache_get({ app => $a->{'app'}, context => 'budget', subcontext => $br })) {
					$appts->{$a->{'app'}}->{'budget'}->{$br} = $cache;
				}
			}
		}

		if ($a->{'duration'} !~ /[0-9]/) { $a->{'duration'} = 0; }
		$appts->{$a->{'app'}}->{'timestamp'} = $a->{'timestamp'};
		$appts->{$a->{'app'}}->{'name'} = &subs::unformat_name($a->{'app'});
		$appts->{$a->{'app'}}->{'html_name'} = &subs::html_name($a->{'app'});
		$appts->{$a->{'app'}}->{'http_name'} = &subs::http_name($a->{'app'});
		$appts->{$a->{'app'}}->{'apostrophe_escape'} = &subs::apostrophe_escape($a->{'app'});
		$appts->{$a->{'app'}}->{'setting'}->{'wiki'} = 'https://en.wikipedia.org/wiki/' . &subs::wiki_name($a->{'app'});
		unless ($data->{'notes'} && $data->{'notes'} eq 'on') {
			$a->{'start_notes'} = 'redacted' if $a->{'start_notes'};
			$a->{'notes'} = 'redacted' if $a->{'notes'};
			$a->{'end_notes'} = 'redacted' if $a->{'end_notes'};
		}
		$appts->{$a->{'app'}}->{'formatted_name'} = &subs::format_name($a->{'app'});
		$appts->{$a->{'app'}}->{'shorthand_name'} = &subs::shorthand_name($appts->{$a->{'app'}}->{'formatted_name'});
		$a->{'formatted_time'} = localtime($a->{'timestamp'} / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P');
		$a->{'formatted_server_time'} = localtime($a->{'server_time'} / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P %Z');
		$appts->{$a->{'app'}}->{'just_time'} = localtime($a->{'timestamp'} / 1000 )->strftime('%I:%M%P');
		$appts->{$a->{'app'}}->{'just_date'} = localtime($a->{'timestamp'} / 1000 )->strftime('%a %b %d %Y');

		if (!$a->{'duration'} && grep { 'duration' eq $_->{'setting'} } @a_settings ) {
			$a->{'duration'} = &subs::time_abbrev_translator($appts->{$a->{'app'}}->{'setting'}->{'duration'});
		}
		if ($a->{'timestamp'} < $timestamp && ($a->{'type'} eq 'start' || $a->{'type'} eq 'record')) {
			$a->{'duration'} = $a->{'timestamp'} - $timestamp;
		}
		$appts->{$a->{'app'}}->{'duration'} = $a->{'duration'};

		$a->{'formatted_duration'} = &subs::duration_sayer(abs $a->{'duration'} / 1000);
		$a->{'warranty'} = $a->{'warranty'} || $appts->{$a->{'app'}}->{'setting'}->{'warranty'};
		$appts->{$a->{'app'}}->{'formatted_duration'} = &subs::duration_sayer($a->{'duration'});
		$appts->{$a->{'app'}}->{'formatted_duration'} = &subs::duration_sayer((time()  - $a->{'timestamp'})) unless $a->{'duration'};
		$appts->{$a->{'app'}}->{'file'} = $a->{'file'};
		if ($a->{'file'} ) {
			if ($a->{'type'} eq 'snapshot') {
				push @{$a->{'files'}}, { file => $a->{'file'}, file_type => 'img' };
			}
			else {		
				my $files = eval { return decode_json $a->{'file'} } || [];
				if (eval { $files->{'f'} }) {
					$files = [ $files ];
				}
				foreach my $file (@{$files}) {
					push @{$a->{'files'}}, &subs::log_reader_file_preparer($file);
				}
			}
		}

		@appointments = grep { $_ ne $a->{'app'} } @appointments;
		unshift @appointments, $a->{'app'};
		if ($appts->{$a->{'app'}}->{'total'} || $appts->{$a->{'app'}}->{'amount'}) {
			$a->{'label'} = "transaction";
			$a->{'type'} = "transaction";
			$appts->{$a->{'app'}}->{'total_amount'} += unformat_number($a->{'amount'});
			$appts->{$a->{'app'}}->{'total_tax'} += unformat_number($a->{'tax'});
			$appts->{$a->{'app'}}->{'total_total'} += unformat_number($a->{'total'});
			$appts->{$a->{'app'}}->{'total_quantity'} += unformat_number($a->{'quantity'});
			$appts->{$a->{'app'}}->{'formatted_time'} = localtime($a->{'timestamp'} / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P');
			push @{$appts->{$a->{'app'}}->{'vendors'}}, $a->{'vendor'};

			$appts->{$a->{'app'}}->{'last_transaction'} = $appts->{$a->{'app'}}->{'timestamp'};
			$appts->{$a->{'app'}}->{'vendor_list'} = encode_json $appts->{$a->{'app'}}->{'vendors'};
		}
		if ($a->{'amount'}) {
			$appts->{$a->{'app'}}->{'total_amount'} -= $a->{'amount'} if $a->{'amount'} < 0;
		}
		my $timestamp = $a->{'timestamp'};
		my $type = $a->{'type'};
		$a->{'formatted_name'} = &subs::format_name($a->{'app'});
		push @{$appts->{$a->{'app'}}->{'list'}}, $a;
		$appts->{$a->{'app'}}->{'last_event'} = $timestamp;
		$a->{'formatted_account'} = &subs::format_name($a->{'account'});
		$a->{'formatted_type'} = &subs::format_name($a->{'type'});
		$a->{'formatted_project'} = &subs::format_name($a->{'project'});
		if ($project && $project ne 'all') {
			$appts->{$a->{'app'}}->{'last_project'} = $project;
		}
		else {
			$appts->{$a->{'app'}}->{'last_project'} = $a->{'project'};
		}
		if ($account && $account ne 'all') {
			$appts->{$a->{'app'}}->{'last_account'} = $account;
		}
		else {
			$appts->{$a->{'app'}}->{'last_account'} = $a->{'account'};
		}
	#	if ($type =~ 'start|record|pause|transaction|reset|note') {
			$appts->{$a->{'app'}}->{'last_reset'} = $timestamp;
	#	}
		if ($json->{'type'} && $json->{'type'} eq 'inventory') {
			$appts->{$a->{'app'}}->{'invs'} += $json->{'inv'};
			$appts->{$a->{'app'}}->{'inv'} = $appts->{$a->{'app'}}->{'resets'} ;
		}
		$a->{'duration'} = '' if $a->{'duration'} eq 'NaN';
		if ($a->{'type'} =~ /start|record/) {
			$appts->{$a->{'app'}}->{'formatted_start_time'} = $a->{'formatted_time'};
			$appts->{$a->{'app'}}->{'formatted_end_time'} = &subs::formatted_time($a->{'timestamp'} + ($a->{'duration'} || 0));
		}
		else {
			$appts->{$a->{'app'}}->{'formatted_end_time'} = $a->{'formatted_time'};
			$appts->{$a->{'app'}}->{'formatted_start_time'} = &subs::formatted_time($a->{'timestamp'} - ($a->{'duration'} || 0));
		}
		push @{$appts->{$a->{'app'}}->{'transactions'}}, grep { $_->{'type'} eq 'transaction' && $_->{'app'} eq $a->{'app'} } @{$appointments};
		$appts->{$a->{'app'}}->{'setting'}->{'status'} = $appts->{$a->{'app'}}->{'list'}->[-1]->{'type'} unless $appts->{$a->{'app'}}->{'setting'}->{'status'} && $appts->{$a->{'app'}}->{'setting'}->{'status'} =~ /record|start|paused|resumed|completed|transaction/;

#		&subs::cache_set({app => $a->{'app'}, context => $data->{'view'} }, $appts->{$a->{'app'}});
	}

	return $appts;
}

get '/manager/voice_prompt' => sub ($c) {
 # Mojo::IOLoop->subprocess->run_p(sub {
		if ($device eq 'mobile') {
			my $text;
			if ($c->param('repeater') eq 'yes') { 

				while ( lc $text ne 'cancel' && $text ne '' ) {
					my $json = `termux-dialog speech`;
					$json = eval { return decode_json $json } || {};
					$text = $json->{'text'};
					&Websocket::send('server', { console => 'said_it(\'' . $text . '\')' });
					sleep 1;
				}
			}
			else {
				$text = `termux-speech-to-text`;
				chomp($text);
				&Websocket::send('server', { console => 'said_it(\'' . $text . '\')' });
			}
		}
	#});
	$c->render('text' => 'ok');
};

get '/download_program' => sub($c) {
	unless ($c->session('downloading_program')) {
		my $download_count = &subs::setting_grabber({ app => '__president', setting => 'download_count' }) || 0;
		my $zipper = `zip -x ./server/* ./config.json ./public/images/jonathans -r - ./ | cat`;
		my $timestamp = &subs::rightNow();
		$c->render_file(data => $zipper, filename => 'president_' . $timestamp . '.zip');
		$download_count = $download_count + 1;
		&subs::setting_setter({ app => '__president', setting => 'download_count', value => $download_count });
		$c->session('downloading_program', 'no');
	}
};

post '/manager/cache_set' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $context = $c->param('context');
	my $subcontext = $c->param('subcontext');
	my $data = eval { return decode_json $c->param('data') } || {};

	&subs::cache_set({ app => $app, context => $context, subcontext => $subcontext, timestamp => $timestamp }, $data);
	$c->render('text' => 'ok');
};

post '/manager/cache_delete' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $context = $c->param('context');
	my $subcontext = $c->param('subcontext');
	&subs::cache_delete({ app => $app, context => $context, subcontext => $subcontext });
	$c->render('text' => 'deleted');
};

get '/manager/cache_get' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $context = $c->param('context');
	my $subcontext = $c->param('subcontext');
	my $cache = &subs::cache_get({ app => $app, context => $context, subcontext => $subcontext });
	$c->render(json => $cache);
};


get '/manager/download_file' => sub ($c) {
	my $file = $c->param('file');
	my $app = uri_decode( $c->param('app') );
	my $uuid = $c->param('uuid');
	my $timestamp = $c->param('timestamp');
	my $server_time = $c->param('server_time');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $appt = &subs::db_query('select * from appointments where app = ? and uuid = ?', $app, $uuid)->hashes->[0];
	my $encryption_standard = $appt->{'encryption_standard'};
	my $saved_file = eval { return decode_json $appt->{'file'} } || [{}];
	@{$saved_file} = grep { $_->{'f'} eq $file } @{$saved_file};

	my ($data,$filename);
	if (-e $file) {
		if ($file =~ /\.enc$/gi) {
			my $suds = $c->session('suds');
			my $passwords = &subs::db_query('select * from security where level != ? order by server_time DESC', 'padlock');
			my $pwords = $passwords->hashes;

			foreach my $p ( @{$pwords} ) {
				my $secret = &subs::decrypter($suds, $p->{'credential'});
				my $process_data = `openssl enc -d -k "$secret" -$encryption_standard -pbkdf2 -in $file`;
				my $ft = File::Type->new();
				my $type_from_data = $ft->checktype_contents($process_data);
				if ($type_from_data ne 'application/octet-stream' || ($data =~ /webm/)) {
					$data = $process_data;

					my @file = split '/', $file;
					$filename = $file[-1];
					$filename =~ s/\.enc//gi;
					$filename = $saved_file->[0]->{'of'} if $saved_file->[0]->{'of'};
					last;
				}
			}
		}
		else {
			$data = read_file($file);
			my @file = split '/', $file;
			$filename = $file[-1];
			$filename = $saved_file->[0]->{'of'} if $saved_file->[0]->{'of'};
		}
		$c->render_file(data => $data, filename => $filename);
	}
	else {
		$c->render(text => 'Not Found');
	}
};


post '/manager/upload_file' => sub ($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my @uploads = @{$c->req->uploads};
	my $timestamp = $c->param('timestamp') - 1;
	my $duration = $c->param('duration');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid') || &subs::random_string_creator(22);
	my $seen_appts = [];
	my $notes;
	my @uploaded_files;
	my @uuids;
	if ($c->param('uuid')) {
		$seen_appts = &subs::db_select('appointments', undef, { uuid => $uuid })->hashes;
		if (scalar @{$seen_appts} > 0) {
			my $appt = $seen_appts->[0];
			my $of = eval { return decode_json $appt->{'file'} } || [];
			push @uploaded_files, @{$of};
			$app = $appt->{'app'};
			$notes = &subs::note_decrypter($c->session('suds'), $appt->{'notes'},$appt->{'server_time'}) . '<br>';
			$timestamp = $appt->{'timestamp'};
		}
	}
	my $returner = { uuid => $uuid, app => $app, timestamp => $timestamp };

	my $upload_type;
	my $linux_file;
	my $resolution = &subs::setting_grabber({ app => 'misc', setting => 'photo_size' } ) || '1920x1080';
	foreach my $u ( @uploads ) {
		my $is_enc = 0;
		my $server_time = &subs::rightNow();
		$timestamp++;
		my $filen = &subs::unformat_name($u->filename);
		my @f = split /\./, $filen;
		if (lc $f[-1] eq 'enc') {
			$is_enc = 1;
			pop @f;
		}
		my $ext = pop @f;
		$filen = join '.', @f;
		my $fn = $filen . '_' . $timestamp . '.' . $ext;

		my $upload = {
			type => $u->headers->content_type,
			path => $u->asset->path,
			filename => $fn,
			size => $u->size,
		};
		$app = $upload->{'filename'} unless $c->param('app');
		$app = &subs::unformat_name($app);
		my $init = &subs::setting_initializer($app,$timestamp);
		$app = $init->{'app'};

		my ($folder,$location,$thumb);

		if ($upload->{'type'} =~ /audio/gi) {
			$upload_type = 'audio';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		elsif ($upload->{'type'} =~ /video/gi || lc $ext eq 'webm' || lc $ext eq 'avi' || lc $ext eq 'mp4' || lc $ext eq 'mov' || lc $ext eq 'mkv') {
			$upload_type = 'video';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
			$thumb = $location . '/thumbs';
			
		}
		elsif ($upload->{'type'} =~ /image/gi || lc $ext eq 'jpg' || lc $ext eq 'png') {
			$upload_type = 'image';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
			$thumb = $location . '/thumbs';
		}
		elsif ($upload->{'type'} =~ /pdf/gi) {
			$upload_type = 'scan';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'document_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		elsif ($upload->{'type'} =~ /application/gi) {
			$upload_type = 'software';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'download_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}

		else {
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'download_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app;
		}
		`mkdir -p $location` unless -e $location;
		my $filename = $location . '/' . $upload->{'filename'};
		my $new_uuid = &subs::random_string_creator(13);
		if ($is_enc == 1) {
			$filename = $filename . '.enc';
			push @uuids, $new_uuid;
		}
		$u->move_to($filename);
		my $ocr;
		if ($upload_type eq 'image') {
			`magick $filename -resize $resolution $filename` unless lc $resolution eq 'raw';
			$ocr = &ocr_reader($c,$filename);
		}
		$linux_file .= `file $filename` . "\n";
		if ($upload->{'filename'} =~ /avi$|mkv$/gi) {
			my $old_filename = $filename;
			$filename =~ s/avi$|mkv$/mp4/;
			my $tn_o = &subs::terminal_name($old_filename);
			my $tn_f = &subs::terminal_name($filename);
			threads->create(sub() { 
				`ffmpeg -i $tn_o $tn_f & exit /b`;
				`shred -u $tn_o`;
				&subs::file_encrypter({ app => $app });
			});
		}

		my $u_data = { server_time => &subs::rightNow(), ocr => $ocr, f => $filename, uuid => $new_uuid, type => $upload_type };

		if ($thumb) {
			`mkdir -p $thumb` unless -e $thumb;

			$u_data->{'thumb'} = $thumb . '/' . $upload->{'filename'};
			$u_data = &thumbnail_creator($u_data);
		}
		push @uploaded_files, $u_data;
	}
	my $jfile = encode_json \@uploaded_files;

	if (@{$seen_appts} > 0) {
		&subs::db_update('appointments', {
			timestamp => $timestamp,
			notes => &subs::note_encrypter($c->session('suds'),$notes . $linux_file),
			file => $jfile,
			uuid => $uuid,
			duration => $duration || '1000',
			encryption_standard => undef,
		},
		{ 
			uuid => $uuid,
			app => $app
		});
		&Websocket::send($app, { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');' });
	}
	else {
		my $write = {
			timestamp => $timestamp,
			app => &subs::unformat_name($app),
			notes => &subs::note_encrypter($c->session('suds'),$notes . $linux_file),
			type => $upload_type || $c->param('type') || 'upload',
			file => $jfile,
			uuid => $uuid,
			duration => $duration || '1000',
			browser_tab_id => $c->param('browser_tab_id')
		};

		&appointment_writer($c,$write);
	}
	&subs::file_encrypter({ app => &subs::unformat_name($app) });

	$returner->{'cv'} = &centre_view_grabber({ c => $c, app => &subs::unformat_name($app), timestamp => $timestamp });


	$c->render(json => $returner);
};

sub thumbnail_creator($data) {
	if ($data->{'thumb'}) {
		$data = &subs::file_media_information($data,$data->{'f'});

		my $thumbnail_size = &subs::setting_grabber({ app => 'misc', setting => 'thumbnail_size' }) || 'none';
		if ($thumbnail_size ne 'none') {
			my $filename = $data->{'f'};
			my $upload_type = $data->{'type'};
			my $thumb = $data->{'thumb'};
			my @filename = split /\./, $filename;
			my $ext = $filename[-1];

			my @thumb = split /\./, $thumb;
			pop @thumb;
			push @thumb, 'png';
			$thumb = join '.', @thumb;
			$data->{'thumb'} = $thumb;
			if ($upload_type eq 'video') {
				my $command2 = 'ffmpeg -ss 00:00:00.010 -i ' . $filename . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize ' . $thumbnail_size . ' ' . $thumb;
				`$command2`;
			}
			elsif ($upload_type eq 'image' || $upload_type eq 'document') {
				my $command2 = 'magick ' . $filename . ' -resize ' . $thumbnail_size . ' ' . $thumb;
				`$command2`;
			}
			else {
				return $data;
			}
		}
	}

	if ($data->{'app_uuid'} && $data->{'file_uuid'}) {
		my $appt = &subs::db_query('select * from appointments where uuid = ? and file is not null', $data->{'app_uuid'} )->hashes->[0];
		my $files = eval { return decode_json $appt->{'file'} } || [];
		if (scalar @{$files} > 0) {
			my $written = 0;
			foreach my $f ( @{$files} ) {
				if ($f->{'uuid'} eq $data->{'file_uuid'}) {
					$f->{'thumb'} = $data->{'thumb'};
					$f->{'server_time'} = &subs::rightNow();
					$written = 1;
				}
			}
			if ($written == 1) {
				my $jfile = encode_json $files;
				&subs::db_update('appointments', { file => $jfile, server_time => &subs::rightNow() }, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });
			}
		}
	}
	delete $data->{'app_uuid'};
	delete $data->{'file_uuid'};
	return $data;
}

post '/manager/configure/image_function' => sub($c) {
	my $app = $c->param('app');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $function = $c->param('func');
	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];
	
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'embedded', setting => 'diagrams' }) } || [];
	my $receipts = eval { return decode_json &subs::setting_grabber({ app => 'budget', setting => 'receipts' }) } || [];
	my $signatorials = eval { return decode_json &subs::setting_grabber({ app => 'customs', setting => 'signatorials' }) } || [];
	unless ($function eq 'map') {
		@{$maps} = grep { $_->{'uuid'} ne $file_uuid } @{$maps};		
	}
	unless ($function eq 'background') {
		@{$backgrounds} = grep { $_->{'uuid'} ne $file_uuid } @{$backgrounds};
	}
	unless ($function eq 'diagram') {
		@{$diagrams} = grep { $_->{'uuid'} ne $file_uuid } @{$diagrams};
	}
	unless ($function eq 'receipt') {
		@{$receipts} = grep { $_->{'uuid'} ne $file_uuid } @{$receipts};
	}
	unless ($function eq 'signatorial') {
		@{$signatorials} = grep { $_->{'uuid'} ne $file_uuid } @{$signatorials};
	}

	foreach my $fi ( @{$files} ) {
		if ( $fi->{'uuid'} eq $file_uuid) {
			$fi->{'function'} = $function;
			$fi->{'app'} = $app;
			$fi->{'app_uuid'} = $appt->{'uuid'};
			if ($function eq 'map') {
				push @{$maps}, $fi;
			}
			elsif ($function eq 'background') {
				push @{$backgrounds}, $fi;
			}
			elsif ($function eq 'diagram') {
				push @{$diagrams}, $fi;
			}
			elsif ($function eq 'receipt') {
				push @{$receipts}, $fi;
			}
			elsif ($function eq 'signatorial') {
				push @{$signatorials}, $fi;
			}
		}
	}

	my $jmaps = encode_json $maps;
	my $jbacks = encode_json $backgrounds;
	my $jdiagrams = encode_json $diagrams;
	my $jreceipts = encode_json $receipts;
	my $jsignatorials = encode_json $signatorials;
	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::setting_setter({ app => 'marker', setting => 'backgrounds', value => $jbacks });
	&subs::setting_setter({ app => 'embedded', setting => 'diagrams', value => $jdiagrams });
	&subs::setting_setter({ app => 'budget', setting => 'receipts', value => $jreceipts });
	&subs::setting_setter({ app => 'customs', setting => 'signatorials', value => $jsignatorials });
	my $jfile = encode_json $files;
	$appt->{'file'} = $jfile;
	$appt->{'server_time'} = &subs::rightNow();

	&subs::db_update('appointments', $appt, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });

	$c->render(json => $appt);
	&image_function_sanity_check();
};

post '/manager/configure/image_function_tool' => sub($c) {
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $file_uuid = $c->param('file_uuid');
	my $tool = $c->param('tool');
	my $value = $c->param('value');
	my $translate = $c->param('translate');
	$value = eval { return decode_json $value } || {};

	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];

	my $files = eval { return decode_json $appt->{'file'} } || [];

	my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $value->{'legend'}, setting => 'home_plate' }) } || {};
	if ($tool eq 'home_plate') {
		foreach my $hp ( keys %{$home_plate} ) {
			$value->{$hp} = $home_plate->{$hp};
		}
	}
	elsif ($tool eq 'scale') {
		if ($value->{'legend'} =~ /[a-zA-z]/gi) {
			my ($fo,$ev,$uom,$format) = &formula_calculator($value->{'legend'} . ' to m' );
			$value->{'legend'} = $ev;
		}
	}
	foreach my $fi ( @{$files} ) { 
		$fi->{$tool} = $value if $fi->{'uuid'} eq $file_uuid;
	}
	foreach my $map ( @{$maps} ) {
		$map->{$tool} = $value if $map->{'uuid'} eq $file_uuid;
	}
	$value->{'formatted_legend'} = &subs::format_name($value->{'legend'});

	my $jmaps = encode_json $maps;
	my $jfiles = encode_json $files;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jfiles }, { app => $appt->{'app'}, uuid => $appt->{'uuid'} });

	$c->render(json => $value);
};



sub image_function_sanity_check() {
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => 'diagrams' }) } || [];
	foreach my $map ( @{$maps} ) {
		unless ( -e $map->{'f'} ) {
			@{$maps} = grep { $_->{'uuid'} ne $map->{'uuid'} } @{$maps};
		}
	}

	foreach my $background ( @{$backgrounds} ) {
		unless ( -e $background->{'f'} ) {
			@{$backgrounds} = grep { $_->{'uuid'} ne $background->{'uuid'} } @{$backgrounds};
		}
	}

	foreach my $diagram ( @{$diagrams} ) {
		unless ( -e $diagram->{'f'} ) {
			@{$diagrams} = grep { $_->{'uuid'} ne $diagram->{'uuid'} } @{$diagrams};
		}
	}

	my $jmaps = encode_json $maps;
	my $jbacks = encode_json $backgrounds;
	my $jdiagrams = encode_json $diagrams;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::setting_setter({ app => 'marker', setting => 'backgrounds', value => $jbacks });
	&subs::setting_setter({ app => 'handbook', setting => 'diagrams', value => $jdiagrams });
}

post '/manager/configure/image_name' => sub($c) {
	my $name = &subs::unformat_name($c->param('name'));
	my $app_uuid = $c->param('app_uuid');
	my $file_uuid = $c->param('file_uuid');
	my $app = $c->param('app');

	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];

	foreach my $file ( @{$files} ) {
		if ( $file->{'uuid'} eq $file_uuid) {
			$file->{'name'} = $name;
		}
	}
	my $jfiles = encode_json $files;

	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jfiles }, { app => $app, uuid => $app_uuid });


	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => 'diagrams' }) } || [];
	foreach my $map ( @{$maps} ) {
		if ( $map->{'uuid'} eq $file_uuid ) {
			$map->{'name'} = $name;
		}
	}

	foreach my $background ( @{$backgrounds} ) {
		if ($background->{'uuid'} eq $file_uuid ) {
			$background->{'name'} = $name;
		}
	}

	foreach my $diagram ( @{$diagrams} ) {
		if ($diagram->{'uuid'} eq $file_uuid) {
			$diagram->{'name'} = $name;
		}
	}

	my $jmaps = encode_json $maps;
	my $jbacks = encode_json $backgrounds;
	my $jdiagrams = encode_json $diagrams;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::setting_setter({ app => 'marker', setting => 'backgrounds', value => $jbacks });
	&subs::setting_setter({ app => 'handbook', setting => 'diagrams', value => $jdiagrams });
	

	$c->render(json => $appt);
};

post '/manager/travel/delete_map' => sub($c) {
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];

	foreach my $file ( @{$files} ) {
		if ($file->{'uuid'} eq $file_uuid) {
			delete $file->{'function'};
			delete $file->{'scale'};
			delete $file->{'home_plate'};
		}
	}
	@{$maps} = grep { $_->{'uuid'} ne $file_uuid } @{$maps};
	my $jfiles = encode_json $files;
	my $jmaps = encode_json $maps;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::db_update('appointments', { file => $jfiles, server_time => &subs::rightNow() }, { uuid => $appt->{'uuid'}, app => $app });


	$c->render(json => $maps);
};

post '/manager/continent/record' => sub ($c) {
	my $returner = &continent_record($c);
	$c->render(json => $returner);
};

sub continent_record($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($c->param('app'));
	my $device = $c->param('device') || &subs::device_setter();
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp');
	my $warranty = $c->param('warranty') || &subs::ago_calc(&subs::setting_grabber({ app => 'app', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }),$server_time);
	my $navigation = $c->param('navigation');
	my $returner = {};
	my $purpose = $c->param('purpose');
	my $scope = $c->param('scope');
	my ($uuid,$pre_uuid);
	if ($c->param('uuid')) {
		$pre_uuid = $c->param('uuid');
		$uuid = $c->param('uuid') . '-' . &subs::random_string_creator(8);
	}
	else {
		$uuid = &subs::random_string_creator(25);
		$pre_uuid = $uuid;
	}
	if ($navigation ne 'once') {
		my $continentals = &subs::db_query('select * from continent where app = ? and uuid = ? order by server_time DESC LIMIT 1', $app, $uuid)->hashes;
		if ($continentals->[0]->{'latitude'} eq $c->param('latitude') && $continentals->[0]->{'longitude'} eq $c->param('longitude')) {
			$returner = $continentals->[0];
			
			return $returner;
		}
	}
	if (my $alt = $c->param('latitude')) {
		$returner = { 
			timestamp => $timestamp,
			latitude => $c->param('latitude'),
			longitude => $c->param('longitude'),
			accuracy => sprintf("%.2F", $c->param('accuracy')),
			server_time => $server_time,
			uuid => $uuid,
			type => $purpose,
			app => $app,
			warranty => $warranty,
		};
		&subs::db_insert('continent', $returner);
		if ($purpose eq 'proxy_load' && $scope) {
			&Websocket::send('server', { console => 'listProxy(' . $timestamp . ',"' . $uuid . '");' });
		}
		elsif ($purpose eq 'proxy_set' && $scope) {
			&Websocket::send('server', { console => 'setProxy(' . $timestamp . ',"' . $uuid . '");' });
		}
		elsif ($purpose eq 'travel_viewer' && $scope) {
			&Websocket::send('server', { console => 'travelViewer(' . $timestamp . ',"' . $uuid . '");' });
		}
		elsif ($purpose eq 'home_plate') {
			my $json = encode_json $returner;
			&subs::setting_setter({ app => 'me', device => $device, setting => 'home_plate', value => $json });
		}
		&Websocket::send($app, { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $pre_uuid .'\');' });
	}
	if ($returner->{'navigation'} ne 'once') {
		$returner->{'navigation'} = &subs::ago_calc('-' . ($navigation || 60000), $server_time);
	}
	return $returner;
}

post '/manager/continent/record_anyway' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');
	my $server_time = &subs::rightNow();
	my $watch = &subs::device_lister($timestamp,'teletype') || {};
	Mojo::IOLoop->subprocess->run_p(sub {
		my ($uuid,$pre_uuid);
		if ($c->param('uuid')) {
			$pre_uuid = $c->param('uuid');
			$uuid = $c->param('uuid') . '-' . &subs::random_string_creator(8);
		}
		else {
			$uuid = &subs::random_string_creator(25);
			$pre_uuid = $uuid;
		}
		my $warranty => $c->param('warranty') || &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }),$server_time);
		my $purpose = $c->param('purpose') || 'home_plate';

		my $returner = { 
			timestamp => $timestamp,
			server_time => $server_time,
			uuid => $uuid,
			type => $purpose,
			app => $app,
			warranty => $warranty
		};

		my $scope = $c->param('scope');
		if ($watch->{'ip'}) {
			my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};

			my $ping_test = `$ping`;
			if ($ping_test =~ /ttl/gi) {
				my $ua = Mojo::UserAgent->new();
				$ua->connect_timeout(1);
				my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/my_position';
				my $res = eval { return $ua->insecure(1)->get($watch_home)->result };
				if (eval { return decode_json $res->body }) {
					my $co = eval { return decode_json $res->body };
					$returner->{'latitude'} = $co->{'lat'};
					$returner->{'longitude'} = $co->{'lng'};
				}
			}
		}

		unless ($returner->{'latitude'}) {
			if ($purpose ne 'app') {
				my $home_plate = &subs::setting_grabber({ 'app' => 'me', setting => 'home_plate' });
				if (my $hp = eval { return decode_json $home_plate }) {

					foreach my $k ( keys %{$hp} ) {
						next if grep { $k eq $_ } qw/altitude speed pathname hostname user_agent protocol/;
						$returner->{$k} = $hp->{$k} unless $returner->{$k};
					}
					&subs::db_insert('continent', $returner);
				}
			}
		}
		else {	
			&subs::db_insert('continent', $returner);
		}

		if ($purpose eq 'proxy_load' && $scope) {
			&Websocket::send('server', { console => 'listProxy(' . $timestamp . ',"' . $uuid . '");' });
		}
		elsif ($purpose eq 'proxy_set' && $scope) {
			&Websocket::send('server', { console => 'setProxy(' . $timestamp . ',"' . $uuid . '");' });
		}
		elsif ($purpose eq 'travel_viewer' && $scope) {
			&Websocket::send('server', { console => 'travelViewer(' . $timestamp . ',"' . $uuid . '");' });
		}
		elsif ($purpose eq 'home_plate') {
			my $json = encode_json $returner;
			&subs::setting_setter({ app => 'me', setting => 'home_plate', value => $json });
		}

		&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $pre_uuid .'\');' });

	});
	$c->render('text' => 'ok');
};

post '/manager/continent/delete' => sub($c) {
	my $uuid = $c->param('uuid');
	my $server_time = $c->param('server_time');
	&subs::db_delete('continent', { uuid => $uuid });
	&deletion_registration({ table => 'continent', uuid => $uuid, server_time => $server_time });
	$c->render(json => { uuid => $uuid });
};


sub schedule_maker($c,$schedule,$timestamp) {
	my $app = $c->param('app');
	my $warranty ='';
	my $original_timestamp = $c->param('timestamp');
	$timestamp = $c->param('timestamp');
	my @returner;
	if ($schedule eq 'once') {
		push @returner, $schedule;
	}
	else {
		if ($schedule =~ /for/gi) {
			my @schedule = split ' for ', $schedule;
			$warranty = $schedule[1];
			$schedule = $schedule[0];

		}
		my $renamed_schedule = $schedule;
		$renamed_schedule =~ s/ly$//gi;
		my $rsnumber = $renamed_schedule;
		my $rsword = $renamed_schedule;
		$rsnumber =~ s/[^0-9,.]//gi;
		$rsword =~ s/[^[a-zA-Z]//gi;
		$rsword = &subs::timespan_widener($rsword);
		if (eval {&{$subs::time_subs->{$rsword}}() }) {

			my $t = &{$subs::time_subs->{$rsword}}($timestamp,$rsnumber);
			my $diff = $timestamp - $t;
			my $settings = &subs::settings_grabber({ app => $c->param('app') });
			$warranty = $settings->{'warranty'} unless $warranty ne '';
			$warranty = &subs::ago_calc($warranty,$c->param('timestamp'));
			my $locking_status = $c->param('lockingStatus');
			my $usual_duration = $settings->{'duration'};
				if ($locking_status eq 'on') {
				$c->param('duration', $usual_duration)
			}
			my $duration = &subs::time_abbrev_translator($c->param('duration'));

			$duration = &subs::time_abbrev_translator($usual_duration) unless $c->param('duration') =~ /[a-z0-9A-Z]/;
			if ($c->param('type') eq 'start' || $c->param('type') eq 'record') {
				$duration = $duration * -1;
			}

			my $count = 0;
			until ($timestamp >= $warranty) {
				if ($timestamp != $original_timestamp || $count != 0) {
					$c->param('timestamp',$timestamp);
					my $stop_timestamp = $c->param('duration') =~ /[a-zA-Z0-9]/ ? $timestamp - ((abs $duration) * -1) : undef;
					push @returner, $timestamp;
					
					&appointment_writer($c, {
						app => $app,
						timestamp => $timestamp,
						type => $c->param('type'),
						project => $settings->{'project'},
						duration => $duration,
						stop_timestamp => $stop_timestamp,
						source_uuid => $c->param('uuid')
					});
				}
				$timestamp = $timestamp + $diff;
				$count++;
			}
		}
		return \@returner;
	}
}

sub remote_relay_request($c) {
	unless ($c->param('remoted') eq 'yes') {
		my $remote_uuid = $c->param('remote_uuid');


		if (1 == 1) {
			$c->param('subprocess' => undef);
		#	return &relay_the_request($c);

			my $path = $c->req->url->path;
			my $uuid = $c->param('uuid');
			my $server_time = &subs::rightNow();

			my $remote_machines;
			if ($remote_uuid) {
				$remote_machines = &subs::db_query('select * from remote_machines where connection=? and uuid=?', 'active', $remote_uuid)->hashes;
			}
			else {
				$remote_machines = &subs::db_query('select * from remote_machines where connection=?', 'active')->hashes;
			}
			foreach my $rm ( @{$remote_machines} ) {

				$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
				my $method = lc $c->req->method;
				my $res;
				if ($method eq 'post') {
					my $params = $c->req->body_params->{'string'};
					$params .= '&remoted=yes&server_time=' . $server_time . '&uuid=' . $uuid;
					$params .= '&remote_uuid=' . $remote_uuid unless $path eq '/file_open' ;
					
					my $url = $rm->{'manager'} . $path . '?' . $params;
					$res = $rm->{'ua'}->post($url)->result;
					return $res->body;
				}
				else {
					my $all_params = $c->req->query_params;
					my $params;
					for (my $n = 0; $n < scalar @{$all_params->{'pairs'}} - 1; $n++) {
						if ($all_params->{'pairs'}->[$n] eq 'file' || $all_params->{'pairs'}->[$n] eq 'track') {
							$all_params->{'pairs'}->[$n + 1] = url_escape $all_params->{'pairs'}->[$n + 1];
						}
						$params .= '&' . $all_params->{'pairs'}->[$n] . '=' . $all_params->{'pairs'}->[$n + 1];
						$n++;
					}
					$params .= '&remoted=yes&server_time=' . $server_time . '&uuid=' . $uuid;

					$params .= '&remote_uuid=' . $remote_uuid;

					my $url = $rm->{'manager'} . $path . '?' . $params;
      		$rm->{'ua'} = $rm->{'ua'}->max_response_size(0);
					$res = $rm->{'ua'}->get($url);# => { Accept => '*/*' } => 'Content!');

					if ($path eq '/file_open' || $path eq '/play') {
						my $data = $res->res->content->asset->slurp;
						return $data;
					}
					else {
						return $res->result->body;
					}
				}

				my $additions = eval { return decode_json $rm->{'additions'} } || [];

		#		push @{$additions}, { app => $app, uuid => $uuid, scope => 'single', initialization => &subs::rightNow() };
				my $jadditions = encode_json $additions;
		#		&subs::db_update('remote_machines', { additions => $jadditions }, { uuid => $rm->{'uuid'}, signatorial => $rm->{'signatorial'} });


			}
		}

	}
}


post '/manager/reset' => sub ($c) {
	my $content = &manager_reset($c);
	$c->render(json => $content );

};

sub manager_reset($c) {
	if (($c->param('account') eq 'gallery' && &subs::setting_grabber({ app => 'me', setting => 'gallery_appts' }) eq 'off' )) {
		return { 'cv' => 'inapplicable' };
	}
	my $timestamp = &timestamp_adjuster($c);

	my $app = &subs::unformat_name($c->param('app'));
#	&subs::cache_delete({ app => $app, context => 'template' });
	my $browser_tab_id = $c->param('browser_tab_id');
	my $locking_status = $c->param('lockingStatus');
	my $server_time = $c->param('server_time') || &subs::rightNow() || $timestamp;
	my $type = $c->param('type');
#	($app,undef,$type) = &subs::typesetter($app);
	$type = $type || $c->param('type');
	my $init = &subs::setting_initializer($app,$timestamp);
	$app = $init->{'app'};
	$c->param('app' => $app);
	my $uuid = $c->param('uuid') || &subs::random_string_creator(40);
	$c->param('uuid' => $uuid);
	my $returner = { app => $app, timestamp => $timestamp, server_time => $server_time, init => $init, uuid => $uuid };
	my $source = $c->param('source');
	my $measure_is_open = $c->param('measure_is_open');
	my $usual_duration = $init->{'duration'};
	if ($locking_status eq 'on') {
		$c->param('duration', $usual_duration)
	}


	my $duration = &subs::time_abbrev_translator($c->param('duration'));

	$duration = &subs::time_abbrev_translator($usual_duration) unless $c->param('duration') =~ /[a-z0-9A-Z]/;
	$c->param('uuid' => $uuid);
	#&subs::setting_setter({ app => $app, setting => 'duration', value => $c->param('duration'), timestamp => $timestamp }) unless $usual_duration;

	my $unit = $c->param('unit');

	my $quantity = $c->param('quantity');
	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[a-zA-Z]//gi;
	}

	my $manufacturer = $c->param('manufacturer');
	my $project = $c->param('project');
	my $camera = $c->param('camera') || 0;
	my $feed = $c->param('feed');
	my $notes = $c->param('notes');
	$notes =~ s/\$/\\\$/gi;
	my $digits = $c->param('digits');
	my $mirror = $c->param('mirror');
	my $file = $c->param('file');
	my $mute = $c->param('mute');
	my $words = $c->param('words');


	my $time_definition = &subs::rightNow();
	my $appointments;
	my $results = &subs::db_query("select max(timestamp) as file,timestamp,notes,app,duration,type,status,amount,unit,account from appointments where app=? and timestamp <=? and type != 'note' order by timestamp", $app,$time_definition);
	$appointments = $results->hashes;
	$results = &subs::db_query("select min(timestamp) as file,timestamp,notes,app,duration,type,status,amount,unit,account from appointments where app=? and timestamp >=? and type != 'note' order by timestamp", $app,$time_definition);
	push @{$appointments}, @{$results->hashes};	
	if (scalar @{$appointments} == 0) { $type = "add" };
	my $pos = &subs::setting_grabber({ app => $app, setting => 'pos' } ) || 'idea';
	$notes = &subs::note_encrypter($c->session('suds'),$notes) if $notes;

	my ($status,$announced_time);

	my $warranty_holder = $timestamp;
	$warranty_holder = $server_time if $server_time > $timestamp;
	my $warranty = &subs::ago_calc(($c->param('warranty') || &subs::setting_grabber({ app => $app, setting => 'warranty' }) || '-10y'),$warranty_holder);
	$returner->{'warranty'} = $warranty;
	my $usual_schedule = &subs::setting_grabber({ app => $app, setting => 'schedule' });
	my $schedule = &schedule_maker($c,$c->param('schedule'),$timestamp);
	$schedule = &schedule_maker($c,$usual_schedule,$timestamp) unless $c->param('schedule');
	my $seen = 'yes';
	if ($timestamp > &subs::rightNow() + 1000) {
		$seen = undef;
	}

	if ($type eq 'start' || $type eq 'record') {
		my $jdata;
		if ($type eq 'record') {
			my $recording_type = &subs::setting_grabber({ app => $app, setting => 'record' });
			my $dat = { recorder => $recording_type };
			if ($recording_type eq 'video') {
				$seen = undef;
				$dat->{'camera'} = $camera;
			}
			elsif ($recording_type eq 'audio') {
				$seen = undef;
			}
			elsif ($recording_type eq 'screen') {
				$seen = undef;
			}
			elsif ($recording_type eq 'video_front') {
				$dat->{'camera'} = $camera;
			}
			elsif ($recording_type eq 'security') {
				&record_video({ app => $app, uuid => $uuid, timestamp => $timestamp }) if $seen eq 'yes';
			}
			else {
				&record_audio({ app => $app, uuid => $uuid, timestamp => $timestamp }) if $seen eq 'yes';
			}
			$jdata = encode_json $dat;
		}
		&subs::intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'on', timestamp => $timestamp });
		my ($model,$options,$jmodel,$joptions) = &subs::usual_appointment_maker({ 
			app => $app, 
			uuid => $uuid, 
			timestamp => $timestamp, 
			$duration => (abs $duration) * -1, 
			type => $type 
		},{
			project => $project
		});
		if (!$unit && $model->{'unit'}) {
			$unit = $model->{'unit'};
		}
		elsif ($init->{'unit'}) {
			$unit = $init->{'unit'};
		}
		if (!$quantity && $model->{'quantity'}) {
			$quantity = $model->{'quantity'};
		}
		elsif ($init->{'quantity'}) {
			$init->{'quantity'};
		}
		if (!$manufacturer && $model->{'manufacturer'}) {
			$manufacturer = $model->{'manufacturer'};
		}
		elsif ($init->{'manufacturer'}) {
			$manufacturer = $init->{'manufacturer'};
		}
		my $source_uuid;
		foreach my $qo ( qw/model option/ ) {
			my $mo = &subs::db_select($qo, undef, { name => $app })->hashes;
			foreach my $ao ( @{$mo} ) {
				my $began = &subs::db_query('select * from appointments where app=? and (type=? or type=?) and timestamp <= ? order by timestamp desc limit 1',$ao->{'app'},'record','start',$timestamp)->hashes;
				$source_uuid = $began->[0]->{'uuid'};
			}
		}

		my $stop_timestamp = $c->param('duration') =~ /[a-zA-Z0-9]/ ? $timestamp - ((abs $duration) * -1) : undef;
		&subs::db_insert('appointments', { 
			app => $app, 
			timestamp => $timestamp, 
			unit => $unit,
			quantity => $quantity,
			project => $project,
			type => $type,
			status => $status,
			duration => (abs $duration) * -1,
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			data => $jdata,
			'pos' => $pos,
			warranty => $warranty + (abs $duration),
			source => $source,
			uuid => $uuid,
			model => $jmodel,
			options => $joptions,
			seen => $seen,
			source_uuid => $source_uuid,
			stop_timestamp => $stop_timestamp,
			browser_tab_id => $browser_tab_id
		});
		&subs::setting_setter({ app => $app, setting => 'toggle', value => 'on' }) if $seen eq 'yes';
		if ($stop_timestamp) {
			&subs::intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'off', timestamp => $stop_timestamp });		
		}

	}
	elsif ($type eq 'stop') {
		my $recording_type = &subs::setting_grabber({ app => $app, setting => 'record' });
		my $began = &subs::db_query('select * from appointments where app=? and (type=? or type=? or type = ? or type = ? or type = ?) and timestamp <= ? and stop_seen is null order by timestamp asc limit 1',
			$app,'record','start','video', 'audio', 'screen', $timestamp); 
		my $old_appts = $began->hashes;

		foreach my $o ( @{$old_appts} ) {
		#	next;
			my $timestamp1 = $o->{'timestamp'};
			$uuid = $o->{'uuid'};
			$c->param('uuid' => $uuid);
			if ($o->{'type'} eq 'record') {
				my $data = eval { return decode_json $o->{'data'} } || {};
				if ($data->{'recorder'} eq 'security') {
					if ($seen eq 'yes') {
						&record_video_stop({ app => $app, timestamp => $timestamp1, uuid => $o->{'uuid'} }) if $o->{'uuid'};
						next;
					}
					else { $type = 'record'; };
				}
				elsif ($data->{'recorder'} eq 'system') {			
					if ($seen eq 'yes') {
						&record_audio_stop({ app => $app, timestamp => $timestamp1, uuid => $o->{'uuid'} }) if $o->{'uuid'};
						next;
					}
					else { $type = 'record'; };
				}
				elsif ($seen eq 'yes') {
					&Websocket::send('music', { console => 'jpStop(\'' . $o->{'app'} . '\',\'' . $data->{'recorder'} . '\',\'' . $o->{'uuid'} . '\');' });
				}
			}
			unless ($c->param('duration')) {
				$duration = $timestamp1 - $timestamp;
				my $all_durations = &subs::db_query('select * from appointments where app=? and type=? order by server_time DESC LIMIT 40',$app,'stop')->hashes;
				my $total_durations = abs $duration;
				if ($o->{'end_notes'}) {
					my $n = &subs::note_decrypter($c->session('suds'), $o->{'end_notes'}, $o->{'ost'});
					$n .= "\n" . &subs::note_decrypter($c->session('suds'), $notes);
					$notes = &subs::note_encrypter($c->session('suds'), $n);
				}
				foreach my $ad ( @{$all_durations} ) {
					$total_durations += abs $ad->{'duration'};
				}
				my $new_duration = $total_durations / ( scalar @{$all_durations} + 1);

				&subs::setting_setter({ app => $app, setting => 'duration', value => &subs::duration_sayer($new_duration / 1000 ) });
			}
			else {
				$duration = (abs $duration) * -1;
			}
			if ($o->{'type'} eq 'start' || $o->{'type'} eq 'record') {
				$type = 'stop';
			}
			else {
				$type = $o->{'type'};
			}
			if ($seen eq 'yes') {

				&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off' });
				&subs::db_update('appointments', { 
					project => $project,
					type => $type,
					duration => $duration,
			#		timestamp => $timestamp,
					end_notes => $notes,
					server_time => $server_time,
					app => $app,
					'pos' => $pos,
					warranty => $warranty,
					source => $source,
					stop_seen => $timestamp <= &subs::rightNow() + 1000 ? 'yes' : undef,
					stop_timestamp => $timestamp,
				}, {
					app => $app, 
					timestamp => $timestamp1,
					uuid => $o->{'uuid'}
				});
			}
			else {
				&subs::db_update('appointments', { 
					project => $project,
					duration => $duration,
			#		timestamp => $timestamp,
					end_notes => $notes,
					server_time => $server_time,
					app => $app,
					'pos' => $pos,
					warranty => $warranty,
					source => $source,
					stop_seen => $timestamp <= &subs::rightNow() + 1000 ? 'yes' : undef,
					stop_timestamp => $timestamp >= &subs::rightNow() + 1000 ? $timestamp : undef,
				}, {
					app => $app, 
					timestamp => $timestamp1,
					uuid => $o->{'uuid'}
				});
			}
			&subs::intelligent_automation_toggle({ appt_uuid => $o->{'uuid'}, app => $app, 'state' => 'off', timestamp => $timestamp });
			my $sources = &subs::db_select('appointments', undef, { source_uuid => $o->{'uuid'} })->hashes;
			my $options = eval { return decode_json $o->{'options'} } || [];
			my $model = eval { return decode_json $o->{'model'} } || {};
			push @{$options}, $model if $model->{'uuid'};
			foreach my $so ( @{$sources} ) {
				push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
				if ( $so->{'type'} eq 'start' ) {
					my @current_option = grep { $_->{'name'} eq $so->{'app'} } @{$options};
					my $co = $current_option[0];
					my $dur = $so->{'timestamp'} - $timestamp;
					my $ts = $timestamp;
					if ($co->{'delay_stop'}) {
						my $t = &subs::time_abbrev_translator($co->{'delay_stop'});
						$ts = $ts + $t;
						$dur = $dur + $t;
					}
					my $so_data = { stop_timestamp => $ts, duration => $dur, server_time => $server_time };
					if ($ts <= &subs::rightNow()) {
						$so_data->{'type'} = $type;
						$so_data->{'stop_seen'} = 'yes';
					}
					&subs::db_update('appointments', $so_data, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'} });
					&budget_runner($so->{'app'});

					&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'off', timestamp => $ts });
					&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
				}
			}

			&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $o->{'uuid'} .'\');'});
		}

	}
	elsif ($type eq 'cancel') {
		my $timestamp1 = &subs::db_select('appointments', ['uuid','timestamp'], { app => $app, type => 'start' })->hash;
		$uuid = $timestamp1->{'uuid'};
		$duration = $timestamp - $timestamp1->{'timestamp'};
		&subs::intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'off', timestamp => $timestamp1->{'timestamp'} });
		&subs::db_update('appointments', {
			type => 'cancel',
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			server_time => $server_time
		},
		{
			app => $app,
			project => $project,
			timestamp => $timestamp1->{'timestamp'},
			uuid => $uuid,
			type => 'start'
		});
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

		foreach my $so ( @{$sources} ) {
			push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
			if ( $so->{'type'} eq 'start' ) {
				&subs::db_update('appointments', { type => $type, duration => $duration, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'} });
				&budget_runner($so->{'app'});
				&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'off', timestamp => $so->{'timestamp'} });
				&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
			}
		}
	}

	elsif ($type =~ 'reset' || $type =~ 'usual') {
		unless ($c->param('duration')) {
			my $udur = &subs::db_query('select duration from appointments where app=? and type=? order by timestamp DESC LIMIT 20',$app,'stop')->hashes;
			my $ucount = scalar @{$udur};
			my $utotal = 0;
			if ($ucount > 1) {
				foreach my $u ( @{$udur} ) {
					$utotal += $u->{'duration'};
				}
				$duration = $utotal / $ucount;
			}
			else {
				my $sduration = eval { return &subs::db_select('settings', ['value'], {app => $app, setting => 'duration', device => $device })->hash->{value} };
				if ($sduration && $duration == undef) {
					$sduration = &subs::time_abbrev_translator($sduration);
					$duration = $sduration;
				}
			}
		}
		if ($duration < 0) {
			$duration = $duration * -1;
		}
		my ($model,$options,$jmodel,$joptions) = &subs::usual_appointment_maker({ 
			app => $app, 
			uuid => $uuid, 
			timestamp => $timestamp, 
			$duration => (abs $duration), 
			type => $type 
		}, {
			project => $project
		});
		if (!$unit && $model->{'unit'}) {
			$unit = $model->{'unit'};
		}
		elsif ($init->{'unit'}) {
			$unit = $init->{'unit'};
		}
		if (!$quantity && $model->{'quantity'}) {
			$quantity = $model->{'quantity'} ;
		}
		elsif ($init->{'quantity'}) {
			$quantity = $init->{'quantity'};
		}
		if (!$manufacturer && $model->{'manufacturer'}) {
			$manufacturer = $model->{'manufacturer'};
		}
		elsif ($init->{'manufacturer'}) {
			$manufacturer = $init->{'manufacturer'};
		}
		&subs::db_insert('appointments', { 
			app => $app, 
			timestamp => $timestamp, 
			unit => $unit,
			quantity => $quantity,
			project => $project,
			type => $type,
			status => 'usual',
			duration => $duration,
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			model => $jmodel,
			options => $joptions,
			browser_tab_id => $browser_tab_id
		});
	}
	elsif ($type =~ 'sms' && $device eq 'mobile') {
		my $data = {};
		$digits = &subs::setting_grabber({ app => $app, setting => 'phone' });
		($data->{'digits'},$data->{'message'}) = &sms_message_send($digits,$c->param('notes'));

		$data = &subs::note_encrypter($c->{'suds'}, encode_json $data);
		&subs::db_insert('appointments', { 
			app => $app, 
			timestamp => $timestamp, 
			unit => $unit,
			project => $project,
			type => 'sms',
			status => 'sms',
			duration => '500',
			data => $data,
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});
	
	}
	elsif ($type eq 'renew') {

		my $appt_db = &subs::db_query('select * from appointments where app = ?',$app);
		my $sames = $appt_db->hashes;
		my $app_warranty = &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }), $timestamp);
		foreach my $same (@{$sames}) {
			my $new_warranty = $app_warranty - $timestamp + $same->{'timestamp'};
			&subs::db_update('appointments', {
				warranty => $new_warranty,
				server_time => &subs::rightNow()
			},
			{
				app => $same->{'app'},
				timestamp => $same->{'timestamp'},
				server_time => $same->{'server_time'},
				uuid => $same->{'uuid'}
			});
			my $websockets = &subs::db_query('select * from websockets where windows like ? and server_time > ? and windows is not null order by timestamp DESC',
				'%app":"' . $app . '%', $server_time - 5000)->hashes;
			if (scalar @{$websockets} > 0) {
				&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $same->{'uuid'} .'\');'});
			}
		}


		&subs::db_insert('appointments', { 
			app => $app, 
			timestamp => $timestamp, 
			unit => $unit,
			project => $project,
			type => 'renew',
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			duration => 3000,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});

	}
	elsif ($type eq 'delay') {
		my $appt = &subs::db_select('appointments', undef, {app => $app, type => ['record','start'] }, { -desc => 'timestamp' })->hashes->[0];
		my $timestamp1 = $appt->{'timestamp'};
		$duration = $appt->{'duration'} ? $appt->{'duration'} : $timestamp - $appt->{'timestamp'};
		my $stop_timestamp = $c->param('duration') =~ /[a-z0-9A-Z]/ ? $timestamp + (abs &subs::time_abbrev_translator($c->param('duration') )) : $appt->{'stop_timestamp'} ? $timestamp + (abs $duration): undef;
		$uuid = $appt->{'uuid'};
		&subs::db_update('appointments', { 
			unit => $unit,
			project => $project,
			type => 'start',
			status => 'start',
			timestamp => $timestamp,
			notes => $notes,
			server_time => $server_time,
			file => $file,
			duration => $duration,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			seen => $seen,
			stop_timestamp => $stop_timestamp,
			stop_seen => $stop_timestamp && $stop_timestamp <= $server_time + 1000 ? 'yes' : undef
		}, {
			app => $app, 
			timestamp => $appt->{'timestamp'},
			type => 'start',
			uuid => $uuid
		});
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

		foreach my $so ( @{$sources} ) {
			push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
			if ( $so->{'type'} eq 'start' ) {
				&subs::db_update('appointments', { type => 'start', timestamp => $timestamp, duration => $duration, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'} });
				&budget_runner($so->{'app'});
				&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
			}
		}
	}
	elsif ($type eq 'pause') {
		my $last = &subs::db_select('appointments', undef, {app => $app, type => 'start' })->hashes->[0];
		my $timestamp1 = $last->{'timestamp'};
		$uuid = $last->{'uuid'};
		$duration = $timestamp - $timestamp1;
		&subs::db_update('appointments', { 
			unit => $unit,
			project => $project,
			type => 'pause',
			status => 'paused',
			duration => $duration,
			timestamp => $timestamp,
			end_notes => $notes,
			server_time => $server_time,
			file => $file,
			warranty => $warranty,
			source => $source,
			seen => $seen
		}, {
			app => $app, 
			timestamp => $timestamp1,
			type => 'start',
			'pos' => $pos,
			uuid => $uuid
		});
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

		foreach my $so ( @{$sources} ) {
			push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
			&subs::db_update('appointments', { type => 'pause', status => 'paused', timestamp => $timestamp, duration => $duration, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'} });
			&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
		}
	}
	elsif ($type eq 'resume') {

		my $old = &subs::db_query('select * from appointments where app = ? and (type = ? or type = ?) order by timestamp DESC LIMIT 1', $app, 'stop','cancel')->hashes;
		$duration = $c->param('duration') =~ /0-9a-zA-Z/ ? (abs $c->param('duration') * -1) : $timestamp - $old->[0]->{'timestamp'};
		$uuid = $old->[0]->{'uuid'};
		&subs::intelligent_automation_toggle({ appt_uuid => $uuid, app => $old->[0]->{'app'}, 'state' => 'on', timestamp => $old->[0]->{'timestamp'} });
		&subs::db_update('appointments', {
				type => 'start',
				status => 'start',
				notes => $notes,
				unit => $unit,
				project => $project,
				server_time => $server_time,
				file => $file,
				'pos' => $pos,
				warranty => $warranty,
				source => $source,
				seen => $seen,
				server_time => $server_time,
				duration => ((abs $duration) * -1),
				stop_timestamp => $c->param('duration') =~ /[a-zA-Z0-9]/ ? $old->[0]->{'timestamp'} - ((abs &subs::time_abbrev_translator($c->param('duration'))) * -1) : undef,
				stop_seen => undef
			}, {
				app => $app,
				uuid => $old->[0]->{'uuid'}
			}
		);
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

		foreach my $so ( @{$sources} ) {
			push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
			if ( $so->{'type'} eq 'stop' ) {
				&subs::db_update('appointments', { type => 'start', server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'} });
				&budget_runner($so->{'app'});
				&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'on', timestamp => $so->{'timestamp'} });
				&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
			}
		}
	}
	elsif ($type eq 'add') {
		$project = eval { return &subs::db_select('settings', ['app'], { setting => 'pos', value => 'project' },{-desc => 'timestamp'})->hash->{app} } || 'project';
		my $counter = &subs::db_query('select count(*) from appointments where app=?', $app);
		my $count = $counter->hash->{'count(*)'};
		if ($count == 0 && 1 == 0) {
			&subs::db_insert('appointments', { 
				app => $app, 
				timestamp => $timestamp, 
				unit => $unit,
				project => $project,
				type => 'config',
				status => $status,
				duration => $duration,
				start_notes => $notes,
				server_time => $server_time,
				file => $file,
				'pos' => $pos,
				warranty => $warranty,
				source => $source,
				uuid => $uuid,
				seen => $seen,
				browser_tab_id => $browser_tab_id
			});
			$returner->{'added'} = 'yes';
		}
	}
	elsif ($type eq 'camera') {
		my $jdata = encode_json { camera => $camera };
		
		my $data = { 
			app => $app, 
			timestamp => $timestamp, 
			project => $project,
			unit => $unit,
			type => 'image',
			data => $jdata,
			notes => $notes,
			server_time => $server_time,
			file => '[]',
			duration => '5000',
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		};
		&subs::db_insert('appointments', $data);

		if ($seen eq 'yes') {
			my ($file,$ocr) = &take_picture($c,{ timestamp => $timestamp, camera => $camera, uuid => $uuid });
		}
	}
	elsif ($type eq 'scan') {
		my $scandata = {
			timestamp => $timestamp,
			feed => $feed,
			uuid => $uuid,
			app => $app,
			source => $source
		};
		my $jdata = encode_json $scandata;
		&subs::db_insert('appointments', { 
			app => $app, 
			timestamp => $timestamp, 
			project => $project,
			unit => $unit,
			type => 'scan',
			start_notes => $notes,
			server_time => $server_time,
			file => '[]',
			data => $jdata,
			duration => $duration,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});

		if ($seen eq 'yes') {
			my $file = &scan($c, $scandata);
		}
	}
	elsif ($type eq 'telephone') {
		&subs::db_insert('appointments', { 
			app => $app, 
			timestamp => $timestamp, 
			project => $project,
			unit => $unit,
			type => 'telephone',
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			duration => '5000',
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});
		my $send_telephone = &send_telephone($app,$c->param('notes'));
	}
	else {
		my $already_running = 0;
		if ($type eq 'note') {
			my $began = &subs::db_query('select * from appointments where app=? and (type=? or type=?) and timestamp <= ? and timestamp < ? order by timestamp desc limit 1',$app,'record','start',$timestamp,&subs::rightNow());
			my $old_appts = $began->hashes;
			foreach my $o ( @{$old_appts} ) {
				my $n = &subs::note_decrypter($c->session('suds'), $o->{'notes'}, $o->{'ost'});
				$n .= "\n" if $n =~ /[a-zA-Z0-9.,]/gi;
				$n .= &subs::note_decrypter($c->session('suds'), $notes);
				$notes = &subs::note_encrypter($c->session('suds'), $n);
				$already_running = $o->{'uuid'};
			}
		}
		if ($type eq 'video' || $type eq 'audio' || $type eq 'screen') { $seen = undef; }
		my $stop_timestamp = $c->param('duration') =~ /[a-zA-Z0-9]/ ? $timestamp - ((abs $duration) * -1) : undef;

		if ($type eq 'command' || $type eq 'kill') {
			my $settings = &subs::settings_grabber({ app => $app });
			if ($type eq 'command') {
				&subs::run_command($app, $settings->{'command'});
			}
			elsif ($type eq 'kill') {
				&subs::run_command($app, $settings->{'kill'});
			}
		}

		if ($already_running eq 0) {
			my $db_data = { 
				app => $app, 
				timestamp => $timestamp, 
				project => $project,
				unit => $unit,
				type => $type,
				start_notes => $notes,
				server_time => $server_time,
				file => $file,
				duration => '5000',
				'pos' => $pos,
				warranty => $warranty,
				source => $source,
				uuid => $uuid,
				seen => $seen,
				stop_timestamp => $stop_timestamp,
				browser_tab_id => $browser_tab_id
			};
			&subs::db_insert('appointments', $db_data);
		}
		else {
			&subs::db_update('appointments', { notes => $notes, server_time => &subs::rightNow() }, { app => $app, uuid => $already_running });
			$uuid = $already_running;
		}

	}
	undef @appointments;


	if ($measure_is_open eq 'true' && ($type eq 'start' || $type eq 'usual')) {
		&appt_measure_writer($c,{ app => $app, uuid => $uuid, timestamp => $timestamp });
	}
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});

	my $todays_date = localtime()->strftime('%A %B %d %Y');
	my $todays_time = localtime()->strftime('%I:%M%P');

#	$appts->{'__stash'}->{'header'} = 'no';
	my $commander;
#	$commander = &subs::run_command($app,$appts->{$app}->{'setting'}->{'record'}) if $appts->{$app}->{'setting'}->{'record'} && $type =~ /record/;
#	&Websocket::send('server', { app => $app, console => &subs::setting_grabber({ app => $app, setting => 'record' }), device => $device, timestamp => $timestamp }) unless $type eq 'stop'; 
#	&Websocket::send('server', { app => $app, console => &subs::setting_grabber({ app => $app, setting => 'kill' }), device => $device, timestamp => $timestamp }) unless $type eq 'stop'; 
#	&Websocket::send('server', { app => $app, console => &subs::setting_grabber({ app => $app, setting => 'command' }), device => $device, timestamp => $timestamp }) if $type eq 'command'; 
#	$commander = &subs::run_command($appts->{$app}->{'setting'}->{'command'}) if $appts->{$app}->{'setting'}->{'command'} && $type =~ /command/;
#	&subs::cache_delete({ app => $app, context => 'template' });

	my $cv = &centre_view_grabber({ c => $c, app => $app, timestamp => $timestamp });
	&budget_runner($app);
	&padlock_time_extender($c);
	$returner->{'cv'} = $cv;
	$returner->{'uuid'} = $uuid;
	unless ($c->param('account') && $c->param('account') eq 'gallery' && &subs::setting_grabber({ app => 'me', setting => 'gallery_appts' }) eq 'off' ) {
	#	&Websocket::send('tab', { app => $app, window => $cv, timestamp => $timestamp });
	}
	&subs::file_encrypter({ app => $app, suds => $c->session('suds') });
	return $returner;
}

post '/manager/configure/stop_all_appointments' => sub($c) {

	my $timestamp = $c->param('timestamp');

	my ($db,$database,$sql) = &subs::database_grabber();
	my $ap = &subs::db_query('select * from appointments where type = ? or type = ? and timestamp <= ?', 'record','start',$timestamp);
	my $appts = $ap->hashes;

	foreach my $a ( @{$appts}) {
		my $duration = $a->{'timestamp'} - $timestamp;		
		my $sq = &subs::db_query('select app,setting,value from settings where app = ? and setting=? and value != ?',$a->{'app'},'duration','');
		my $old_appts = &subs::db_query('select * from appointments where type=? and app = ? order by timestamp DESC LIMIT 20', 'stop', $a->{'app'})->hashes;
		my $sqsults = $sq->hashes;
		if (scalar @{$old_appts} > 2) {
			my $toa = 0;
			foreach my $oa ( @{$old_appts} ) { 
				$toa += abs $oa->{'duration'};
			}
			$duration = $toa / @{$old_appts};
		}
		elsif (scalar @{$sqsults} > 0) {
			$duration = &subs::time_abbrev_translator($sqsults->[-1]->{'value'});
			if ($duration && $duration > 0) { $duration = $duration * -1; }
		}
		&subs::db_update('appointments', {
			type => 'stop',
			duration => $duration,
			server_time => &subs::rightNow()
		},{
			server_time => $a->{'server_time'},
			timestamp => $a->{'timestamp'},
			app => $a->{'app'}
		});
	} 

	$c->render(text => 'ok');
};

get '/manager/transaction/autocomplete' => sub($c) {
	my $attribute = $c->param('attribute');
	my $value = $c->param('value');
	my $app = $c->param('app');
	my $list;
	if ($attribute) {
		my $query = 'select distinct(app),' . $attribute . ' from appointments where app=? and (type=? or type=?) and ' . $attribute . ' like ? and ' . $attribute . ' != \'\' order by server_time desc limit 5';
		$list = &subs::db_query($query, $app, 'purchase','transaction', '%' . $value . '%')->hashes;
	}
	else {
		my $query = 'select distinct(app) from appointments where app like ? order by server_time desc limit 5';
		$list = &subs::db_query($query, '%' . $value . '%')->hashes;
	}
	foreach my $l ( @{$list} ) {
		$l->{'formatted'} = &subs::format_name($l->{$attribute});
		$l->{'unformatted'} = &subs::unformat_name($l->{$attribute});
	}


	$c->render('json' => $list);

};

get '/manager/transaction/autofill' => sub($c) {
	my $name = &subs::unformat_name($c->param('name'));
	my $app = &subs::unformat_name($c->param('app'));
	my $movement = $c->param('movement');
	my $raw_value = $c->param('value');
	my $value = &subs::unformat_name($c->param('value'));


	my $query = 'select ' . $name . ' from appointments where ' . $name . '=? and app=? and type=? and movement = ? order by timestamp DESC LIMIT 40';
	my $probs = &subs::db_query($query,$value, $app,'transaction',$movement)->hashes;
	


	my $returner = {};
	foreach my $prob ( @{$probs} ) {
		my $occurrences = 1;
		if ($returner->{$prob->{$name}}) {
			$occurrences = $returner->{$prob->{$name}}->{'occurrences'} + 1;
		}
		$returner->{$prob->{$name}} = {
			unformatted => $prob->{$name},
			formatted => &subs::format_name($prob->{$name}),
			occurrences => $occurrences
		};
	}
	my $probable = {};
	if ($name eq 'quantity') {
		if ($raw_value =~ /[a-zA-Z]/) {
			my $gunit = $raw_value;
			$gunit =~ s/[^a-zA-Z]//gi;
			$probable->{'unit'} = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};

		}
	}

	foreach my $ret ( keys %{$returner} ) {
		if ( $returner->{$ret}->{'occurrences'} > $probable->{'occurrences'} ) {
			$probable = $returner->{$ret};
		}
	}

	if (!$probable->{'unformatted'}) {
		$probable->{'unformatted'} = &subs::unformat_name($raw_value);
	}

	if ($name eq 'item' || $name eq 'vendor' || $name eq 'manufacturer') {
		my $a = $probable->{'unformatted'};
		$a = $app unless $raw_value =~ /[a-zA-Z.,]/gi;
		my $appts = &log_reader({ app => $a, view => 'centre_view' });
		if ($appts->{$a}) {
			foreach my $convert ( qw/app_measures packaging/ ) {
				if (eval { $appts->{$a}->{'setting'}->{$convert} }) {
					$appts->{$a}->{'setting'}->{$convert} = eval { return decode_json $appts->{$a}->{'setting'}->{$convert} } || [];
				}
			}
			$appts->{$a}->{'setting'}->{'source_app'} = $app;
			$probable->{'settings'} = $appts->{$a}->{'setting'};

			foreach my $mo ( @{$appts->{$a}->{'model'}}, @{$appts->{$a}->{'option'}} ) {
				$mo->{'characteristics'} = eval { return decode_json $mo->{'characteristics'} } || [];
				if (my @oc = grep { $_->{'name'} eq 'option_category' } @{$mo->{'characteristics'}}) {
					$mo->{'option_category'} = $oc[0]->{'value'};
				}
				else {
					$mo->{'option_category'} = 'uncategorized';
				}
			}
			if (scalar @{$appts->{$a}->{'model'}} > 0) {
				$probable->{'models'} = $c->render_to_string(
					template => 'apps/transaction/models', 
					settings => $appts->{$a}->{'setting'}, 
					models => $appts->{$a}->{'model'}, 
					l => $appts->{$a}->{'list'}->[0],
					source => 'transaction',
				);
			}
			if (scalar @{$appts->{$a}->{'option'}} > 0) {
				$probable->{'options'} = $c->render_to_string(
					template => 'apps/transaction/options', 
					settings => $appts->{$a}->{'setting'}, 
					options => $appts->{$a}->{'option'}, 
					option_categories => $appts->{$a}->{'option_category'},
					l => $appts->{$a}->{'list'}->[0],
					source => 'transaction',
				);
			}
		}
		else {
			$probable = {};
		}
	}
	if ($probable->{'unformatted'}) {
		$probable->{'informations'} = [];
		if ($movement eq 'income') {
			my $invoices = &subs::db_query('select * from appointments where type=? and app = ? order by timestamp', 'invoice', $probable->{'unformatted'})->hashes;
			@{$invoices} = grep { $_->{'status'} ne 'completed' } @{$invoices};
			$probable->{'informations'} = $invoices;
		}
		elsif ($movement eq 'expense') {
			my $purchases = &subs::db_query('select * from appointments where type=? and app = ? order by timestamp', 'purchase', $probable->{'unformatted'})->hashes;
			@{$purchases} = grep { $_->{'status'} eq 'delivered' } @{$purchases};
			$probable->{'informations'} = $purchases;
		}
		if (grep { $name eq $_ } qw/amount tax aux total/ ) {
			if (&subs::price_formatter($value) ne &subs::price_formatter($probable->{'unformatted'})) {
				$probable = {};
			}
		}
	}



	$c->render(json => $probable);
};

get '/manager/transaction/information' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $returner = { autofillers => ['vendor','item', 'manufacturer'] };
	my $transaction = &subs::db_query('select * from appointments where uuid=?', $uuid)->hashes->[0];
	if ($transaction) {
		$transaction->{'data'} = eval { return decode_json $transaction->{'data'} };
		$transaction->{'data'}->{'vendor'} = $transaction->{'app'} || &subs::setting_grabber({ app => 'me', setting => 'store_name' }) unless $transaction->{'data'}->{'vendor'};
		
		foreach my $af ( @{$returner->{'autofillers'}} ) {
			$transaction->{'data'}->{'formatted_' . $af } = &subs::format_name($transaction->{'data'}->{$af});
		}
	}
	$returner->{'html'} = $c->render_to_string(
		template => 'apps/information',
		app => $transaction
	);
	$returner->{'transaction'} = $transaction;
	$c->render(json => $returner);
};

get '/manager/transaction/history_retriever' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');

	my $query = 'select * from appointments where data is not null and type=? and app=? and timestamp < ? order by timestamp desc limit 1';
	my $transactions = &subs::db_query($query, 'transaction', $app, $timestamp)->hashes->[0];
	unless ($transactions->{'app'}) {
		my $query = 'select * from appointments where data is not null and type=? and app=? and timestamp < ? order by timestamp desc limit 1';
		$transactions = &subs::db_query($query, 'transaction', $app, &subs::rightNow())->hashes->[0];
	}
	$c->render(json => $transactions);
};

post '/manager/transaction/status' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $appt_uuid = $c->param('appt_uuid');
	my $status = $c->param('status');
	my $app = $c->param('app');
	&subs::db_update('appointments', { status => $status }, { app => $app, uuid => $appt_uuid });

	$c->render('text' => 'ok');


};

post '/manager/transaction/record' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();

	my $app = &subs::unformat_name($c->param('app'));
	my $account = $c->param('account');
	my $project = $c->param('project');

	my $timestamp = &timestamp_adjuster($c);

	my $server_time = &subs::rightNow();
	my $duration = $c->param('duration') || 5000;
	my $notes = &subs::note_encrypter($c->session('suds'),$c->param('notes'));
	my $movement = $c->param('movement');
	my $transaction_information = $c->param('transaction_information');
	my $warranty = &subs::ago_calc($c->param('warranty') || '-7y' || &subs::setting_grabber({ app => $app, setting => 'warranty' }), $timestamp);

	my $uuid = &subs::random_string_creator(40);
	my $currency = $c->param('currency') || &subs::setting_grabber({ app => $app, setting => 'currency' });


	my $has_totes = $c->param('has_totes');
	my $has_tax = $c->param('has_tax');
	my $manufacturer = &subs::unformat_name($c->param('manufacturer'));
	my $vendor = &subs::unformat_name($c->param('vendor'));
	my $record_vendor = $c->param('record_vendor');
	my $unit = $c->param('unit');
	my $amount = $c->param('amount');
	my $tax = $c->param('tax');
	my $aux = $c->param('aux');
	my $aux_description = $c->param('aux_description');
	my $total = $c->param('total');
	my $item = &subs::unformat_name($c->param('item'));
	my $state = $c->param('state');
	my $quantity = $c->param('quantity');
	my $model = &subs::db_query('select * from model where uuid=?',$c->param('model'))->hashes->[0];
	my $transfer_amount = $c->param('transfer_amount');
	my $to_account = $c->param('to_account');
	my $jtransactions = $c->param('transactions');
	my $transactions = eval { return decode_json $c->param('transactions') } || {};



	if ($quantity =~ /G$/gi) {
		$quantity =~ s/G$//gi;
	}


	my $returner = { uuid => $uuid, app => $app, timestamp => $timestamp, navigation => 'once' };

	if ($movement eq 'income' || $movement eq 'expense') {
		my $write = {
			timestamp => $timestamp,
			app => &subs::unformat_name($app),
			notes => $notes,
			total => $transactions->{$movement}->{'totals'}->{'total'} || $total,
			amount => $transactions->{$movement}->{'totals'}->{'amount'} || $amount,
			tax => $transactions->{$movement}->{'totals'}->{'tax'} || $tax,
			aux => $transactions->{$movement}->{'totals'}->{'aux'} || $aux,
			type => 'transaction',
			aux_description => $aux_description,
			duration => $duration,
			account => $account,
			project => $project,
			warranty => $warranty,
			item => $item,
			model => $model->{'uuid'},
			manufacturer => $manufacturer,
			vendor => $vendor,
			quantity => $quantity,
			movement => $movement,
			'state' => $state,
			has_tax => $has_tax,
			has_totes => $has_totes,
			unit => $unit,
			uuid => $uuid,
			data => $jtransactions,
			currency => $currency
		};

		&appointment_writer($c,$write);
		if ($transaction_information && $transaction_information ne '' && $vendor) {
			my $inv = &subs::db_query('select * from appointments where app=? and uuid=?', $vendor, $transaction_information)->hashes->[0];
			if ($inv) {
				my $data = eval { return decode_json $inv->{'data'} };
				unless ($data->{'payments'}) {
					$data->{'payments'} = [];
				}
				push @{$data->{'payments'}}, { account => $account, uuid => &subs::random_string_creator(12), appt_uuid => $uuid, amount => $total, timestamp => $timestamp, server_time => &subs::rightNow(), };
				$data->{'numbers'}->{'balance'} = $data->{'numbers'}->{'balance'} - $total;
				$inv->{'data'} = encode_json $data;
				$inv->{'server_time'} = &subs::rightNow();
				if ($data->{'numbers'}->{'balance'} == 0) {
					$inv->{'status'} = 'completed';
				}
				&subs::db_update('appointments', $inv, { uuid => $inv->{'uuid'}, app => $inv->{'app'} });
				&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $vendor . '\',\'' . $inv->{'uuid'} .'\');'});
			}
		}
		if ($vendor && $record_vendor eq 'on') {
			my $init = &subs::settings_grabber({ app => $vendor });
			
			$init = &subs::setting_initializer($vendor . ' vendor',$timestamp) unless $init->{'pos'};
			$vendor = $init->{'app'};
			&appointment_writer($c, {
				timestamp => $timestamp,
				type => 'purchase',
				account => $account,
				project => $project,
				warranty => $warranty,
				duration => $duration,
				app => $vendor,
				manufacturer => $manufacturer,
				quantity => $quantity,
				unit => $unit,
				movement => $movement,
				item => $item,
				uuid => &subs::random_string_creator(20),
				total => $transactions->{$movement}->{'totals'}->{'total'} || $total,
				amount => $transactions->{$movement}->{'totals'}->{'amount'} || $amount,
				tax => $transactions->{$movement}->{'totals'}->{'tax'} || $tax,
				aux => $transactions->{$movement}->{'totals'}->{'aux'} || $aux,
				source_uuid => $uuid
			});
		}

		foreach my $t ( keys %{$transactions->{$movement}} ) {
			unless ($t eq 'totals') {
				my $tr = $transactions->{$movement}->{$t};
				if ($tr->{'manufacturer'} && $tr->{'record_manufacturer'} eq 'on') {
					my $init = &subs::setting_initializer($tr->{'manufacturer'} . ' manufacturer',$timestamp);
					$manufacturer = $init->{'app'};
					&appointment_writer($c, {
						timestamp => $timestamp,
						type => 'purchase',
						account => $account,
						project => $project,
						warranty => $warranty,
						duration => $duration,
						app => $manufacturer,
						manufacturer => $manufacturer,
						quantity => $tr->{'quantity'},
						unit => $tr->{'unit'},
						movement => $movement,
						item => $tr->{'item'},
						vendor => $vendor,
						uuid => &subs::random_string_creator(18),
						amount => $tr->{'amount'},
						tax => $tr->{'tax'},
						aux => $tr->{'aux'},
						total => $tr->{'total'},
						source_uuid => $uuid,
						currency => $currency
					});
				}
				if ($tr->{'item'} && $tr->{'record_item'} eq 'on') {


					my $item = $tr->{'item'};
					
					my @items = split ',', $item;
					foreach my $i ( @items ) {
						my $purchase = {
							timestamp => $timestamp,
							type => 'purchase',
							account => $account,
							project => $project,
							warranty => $warranty,
							duration => $duration,
							app => $i,
							amount => $tr->{'amount'} / scalar @items,
							tax => $tr->{'tax'} / scalar @items,
							aux => $tr->{'aux'} / scalar @items,
							total => $tr->{'total'} / scalar @items,
							vendor => $vendor,
							manufacturer => $tr->{'manufacturer'},
							uuid => $uuid . '-' . $t . '-' . scalar @items,
							has_tax => $tr->{'has_tax'},
							has_totes => $tr->{'has_totes'},
							'state' => $tr->{'state'} || $state,
							quantity => $tr->{'quantity'},
							unit => $tr->{'unit'},
							source_uuid => $uuid,
							currency => $currency
						};
						&appointment_writer($c, $purchase);
					}
				}
			}
		}

		my ($db,$database,$sql) = &subs::database_grabber();
		if ($model->{'uuid'}) {
			my $model_data = eval { return decode_json $model->{'inventory'} } || $gb::inventory_states;
			my $new_quantity = ($model->{'inventory'} || 0) + $quantity;
	#		&subs::db_query('update models set inventory=? where uuid=?', $new_quantity, $model->{'uuid'});
		}
	}
	elsif ($movement eq 'transfer') {
		my $write1_uuid = &subs::random_string_creator(20);
		my $write2_uuid = &subs::random_string_creator(20);
		my $write1 = {
			app => $app,
			amount => $transfer_amount * -1,
			total => $transfer_amount * -1,
			type => 'transaction',
			movement => 'transfer',
			timestamp => $timestamp,
			server_time => &subs::rightNow(),
			account => $account,
			notes => $notes,
			uuid => $write1_uuid,
			warranty => $warranty,
			data => $jtransactions,
			source_uuid => $write2_uuid,
			currency => $currency
		};
		my $write2 = {
			app => $app,
			amount => $transfer_amount,
			total => $transfer_amount,
			type => 'transaction',
			movement => 'transfer',
			timestamp => $timestamp,
			server_time => &subs::rightNow(),
			account => $to_account,
			notes => $notes,
			uuid => $write2_uuid,
			warranty => $warranty,
			source_uuid => $write1_uuid,
			currency => $currency
		};
		&subs::db_insert('appointments', $write1);
		&subs::db_insert('appointments', $write2);
	}
	elsif ($movement eq 'inventory') {

		my $write = {
			timestamp => $timestamp,
			app => &subs::unformat_name($app),
			notes => $notes,
			duration => $duration,
			total => $total,
			amount => $amount,
			total => $amount,
			type => 'transaction',
			account => $account,
			project => $project,
			warranty => $warranty,
			item => $item,
			model => $model->{'uuid'},
			quantity => $quantity,
			movement => $movement,
			'state' => $state,
			unit => $unit,
			uuid => $uuid,
			data => $jtransactions,
			currency => $currency
		};
		&subs::db_insert('appointments', $write);
	}
	undef @appointments;
	my $appts = &log_reader({ app => $app, view => 'centre_view' });

#	&appt_measure_writer($c,{ app => $app, uuid => $uuid, timestamp => $timestamp });

	my $header = &subs::appt_header_printer({ appts => $appts, app => $app, timestamp => $timestamp });
	my $content = $c->render_to_string(
		template => 'appointment_wrapper',
		appointments => [ $app ],
		appts => $appts,
		timestamp => $timestamp,
		device => $device,
		header => $header,
		from => 'transaction',
		config => &subs::config_reader(),
		measures => $gb::measures
	);

#	&subs::cache_delete({ app => $app, context => 'template' });
	my $cv = &centre_view_grabber({ c => $c, app => $app, timestamp => $timestamp });
#	&Websocket::send('tab', { app => $app, window => $cv, timestamp => $timestamp });
	&budget_runner($app);

	&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
	$returner->{'cv'} = '';#&window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $content }, $timestamp);
	
	$c->render(json => $returner);
};

sub appt_measure_writer($c,$data) {

	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $measure = $data->{'measure'};
	my $value = $data->{'value'};
	my $remote_address = $data->{'remote_address'};
	my $setting_only = $c->param('setting_only');
	my $uuid = $data->{'uuid'};
	my $settings = &subs::settings_grabber({ app => $app, settings => [ 'app_measures', 'duration', 'seen_measures' ] });
	my $app_measure = eval { return decode_json $settings->{'app_measures'} } || {};
	my %appt_measure = %{$app_measure};
	my $appt_measure = \%appt_measure;

	if ($measure) {

		if ($appt_measure->{$measure}->{'unit'} && ($appt_measure->{$measure}->{'type'} eq 'range' || $appt_measure->{$measure}->{'type'} eq 'number')) {
			if ($value =~ /([a-zA-Z])/gi) {
				my $uom = &subs::format_name($1);
				my $formula = $value . ' to ' . $appt_measure->{$measure}->{'unit'};
				my ($fo,$ev,$uom,$format) = &formula_calculator($formula);
				$value = eval($ev);
				$value =~ s/[a-zA-Z]//gi;
			}
		}
		elsif ($appt_measure->{$measure}->{'type'} eq 'text') {
			$value = &subs::unformat_name($value);
			my $seen_measures = eval { return decode_json $settings->{'seen_measures'} } || [];
			unless ( grep { $_ eq $value } @{$seen_measures} ) {
				push @{$seen_measures}, $value;
				my $jmeas = encode_json $seen_measures;
				&subs::setting_setter({ app => $app, setting => 'seen_measures', value => $jmeas });
				$settings->{'seen_measures'} = $jmeas;
			}
		}

		$app_measure = { $measure => $value, ts => $timestamp };

		$appt_measure->{$measure}->{'value'} = $value;

		my $ameasure = encode_json $appt_measure;
		&subs::setting_setter({ app => $app, setting => 'app_measures', value => $ameasure });
	}

	if ( scalar keys %{$app_measure} > 0 && $setting_only ne 'yes') {
		if (!$uuid) {
			my $ago_timestamp = &subs::ago_calc($settings->{'duration'}, $timestamp);
			my $after_timestamp = &subs::ago_calc('-5m', $timestamp);
			my $appt = &subs::db_query('select * from appointments where app=? and type=? and timestamp < ? and timestamp >=? order by timestamp desc limit 1', $app, 'measure',
				$after_timestamp, $ago_timestamp)->hashes->[0];
			if ($appt->{'uuid'} =~ /[A-Za-z0-9]/) {
				$uuid = $appt->{'uuid'};
			}
		}
		if ($uuid) {
			foreach my $am ( keys %{$app_measure} ) {
				$app_measure->{$am} = $appt_measure->{$am}->{'value'};
			}
			$app_measure->{'uuid'} = &subs::random_string_creator(10);
			$app_measure->{'ts'} = $timestamp || &subs::rightNow();
			my $ca = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
			my $car = eval { return decode_json $ca->{'measures'} } || [];
			push @{$car}, $app_measure;
			my $jcar = encode_json $car;
			&subs::db_update('appointments', { measures => $jcar, server_time => &subs::rightNow() }, { uuid => $uuid, app => $app });
		}
		else {
			$app_measure->{'uuid'} = &subs::random_string_creator(10);
			$app_measure->{'ts'} = &subs::rightNow();
			my $car = [];
			push @{$car}, $app_measure;
			my $jcar = encode_json $car;
			my $data = {
				app => $app,
				timestamp => $timestamp,
				type => 'measure',
				duration => 1000,
				measures => $jcar
			};
			my $appt = &appointment_writer($c,$data);
			$uuid = $appt->{'uuid'};
		}
		my $state = $app_measure->{$measure};
		if ($appt_measure->{$measure}->{'min'} && $appt_measure->{$measure}->{'max'}) {
			my $total = $appt_measure->{$measure}->{'max'} - $appt_measure->{$measure}->{'min'};
			my $state_total = $state - $appt_measure->{$measure}->{'min'};
			$state = $state_total / $total * 100;
		}

		if ($data->{'source'} eq 'embedded') {
			&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure[measure="' . $measure . '"]\').val(\'' . $app_measure->{$measure} . '\');' });
		}
		&subs::intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, type => $appt_measure->{$measure}->{'type'}, 'state' => $state, measurement => $app_measure->{$measure}, measure => $measure, timestamp => $timestamp, remote_address => $remote_address });
		&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
		&Websocket::send('tab', { console => 'continent_record({\'uuid\':\'' . $uuid . '\', \'app\':\'' . $app .'\',\'purpose\':\'app\',\'timestamp\':\'' . $timestamp . '\',\'navigation\':"once" });' });

	}
	return $uuid;
}

post '/manager/app_measures' => sub ($c) {
	my $app = $c->param('app');
	my $measure = $c->param('measure');
	my $value = $c->param('value');
	my $server_time = &subs::rightNow();
	my $measures = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	my $setting_only = $c->param('setting_only');
	my $just_one = $c->param('just_one');
	my $timestamp = &timestamp_adjuster($c);
	unless ( eval { %{$measures->{$measure}} } ) {
		$measures->{$measure} = {};
	}

	$measures->{$measure}->{'value'} = $value;
	if ($value == 0) { $value = "0"; }

	my $jmeasures = encode_json $measures;
	unless ($just_one) {
		&subs::setting_setter({ app => $app, setting => 'app_measures', value => $jmeasures });
	}

	my $running_appts = &subs::db_query('select uuid from appointments where (type = ? or type = ?) and app = ? and timestamp < ? ORDER BY timestamp LIMIT 1', 'record', 'start', $app, $server_time )->hashes;
	if (scalar @{$running_appts} > 0) {
		foreach my $ra ( @{$running_appts} ) {
			&appt_measure_writer($c,{ app => $app, uuid => $ra->{'uuid'}, measure => $measure, value => $value, timestamp => $timestamp });
			&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure[measure="' . $measure . '"]\').val(\'' . $value . '\');' }) if $setting_only ne 'yes';
		}
	}
	else {
		&appt_measure_writer($c, { app => $app, measure => $measure, value => $value, timestamp => $timestamp });
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure[measure="' . $measure . '"]\').val(\'' . $value . '\');' }) if $setting_only ne 'yes';
	}

	$c->render(json => { measures => $measures });
};

post '/manager/configure/app_measure_configuration_adder' => sub($c) {
	my $app = $c->param('app');
	
	my $amway = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};

	$amway->{'new_measure'} = {};

	my $jamway = encode_json $amway;
	&subs::setting_setter({ app => $app, setting => 'app_measures', value => $jamway });

	$amway->{'header'} = join ',', keys %{$amway};
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });

	my $measures = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	$amway->{'config'} = $c->render_to_string(
		template => 'configure/app_measures',
		settings => $appts->{$app}->{'setting'},
		a => $app,
		b => 'app_measures'
	);
	$amway->{'app_measure'} = $c->render_to_string(
		template => 'apps/app_measures',
		settings => $appts->{$app}->{'setting'},
		a => $app
	);
	$c->render('json' => $amway);
};


post '/manager/configure/app_measure_configurator' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $measure = &subs::unformat_name($c->param('measure'));
	my $setting = &subs::unformat_name($c->param('setting'));
	my $value = $c->param('value');
	my $oldvalue = $c->param('oldvalue');
	my $amway = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	$amway->{$measure} = {} unless $amway->{$measure};
	
	if ($setting eq 'options') {
		my @value = split ',', $value;
		$value = \@value;
	}

	foreach my $k ( keys %{$amway} ) {
		unless ( $k =~ /[a-zA-Z0-9.]/gi ) {
			$amway->{$k} = undef;
		}
	}
	if ($setting eq 'measure' && $value =~ /[a-zA-Z0-9]/gi) {

		$value = &subs::unformat_name($value);
		my $changing = 0;
		my $appointments = &subs::db_query('select * from appointments where app=? and measures is not null', $app)->hashes;
		foreach my $apps ( @{$appointments} ) {
			my $j = $apps->{'measures'};
			my $app_changed = 0;
			my $meas = eval { return decode_json $j } || [];
			if (scalar @{$meas} > 0) {
				$changing = 1;
				foreach my $m ( @{$meas} ) {
					if ($m->{$oldvalue}) {
						$m->{$value} = $m->{$oldvalue};
						delete $m->{$oldvalue};
						$app_changed = 1;
					}

				}
				if ($app_changed == 1) { 
					my $jam = encode_json $meas;
					&subs::db_update('appointments', { server_time => &subs::rightNow(), measures => $jam }, { uuid => $apps->{'uuid'}, app => $apps->{'app'}, ost => $apps->{'ost'} });
					&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $apps->{'uuid'} .'\');'});
				}
			}
		}
		if ($changing == 1) {
			$amway->{$value} = $amway->{$oldvalue};
			delete $amway->{$oldvalue};
		}
	}
	else {
		$amway->{$measure}->{$setting} = $value;
	}
	foreach my $k ( keys %{$amway} ) {
		unless ( $k =~ /[a-zA-Z0-9.]/gi ) {
			delete $amway->{$k};
		}
	}
	my $jamway = encode_json $amway;
	&subs::setting_setter({ app => $app, setting => 'app_measures', value => $jamway });

	$amway->{'header'} = join ',', keys %{$amway};
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });

	my $measures = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	$amway->{'config'} = $c->render_to_string(
		template => 'configure/app_measures',
		settings => $appts->{$app}->{'setting'},
		a => $app,
		appts => $appts,
		b => 'app_measures'
	);
	$amway->{'app_measure'} = $c->render_to_string(
		template => 'apps/app_measures',
		settings => $appts->{$app}->{'setting'},
		appts => $appts,
		a => $app
	);
	$c->render('json' => $amway);
};

post '/manager/app_measure_delete' => sub($c) {
	my $app = $c->param('app');
	my $app_uuid = $c->param('app_uuid');
	my $uuid = $c->param('uuid');
	my $appts = &subs::db_select('appointments', undef, { uuid => $app_uuid, app => $app })->hashes;

	my $am = eval { return decode_json $appts->[0]->{'measures'} } || [];
	@{$am} = grep { $_->{'uuid'} ne $uuid } @{$am};

	my $jam = encode_json $am;
	&subs::db_update('appointments', { measures => $jam, server_time => &subs::rightNow() }, { uuid => $app_uuid, app => $app, ost => $appts->[0]->{'ost'} });

	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $app_uuid .'\');'});
	$c->render('text' => 'ok');
};

post '/manager/configure/packaging/save' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $name = $c->param('name');
	my $value = $c->param('value');
	my $uuid = $c->param('uuid');
	my $packaging = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'packaging' }) } || {};
	$packaging->{$uuid}->{$name} = $value;
	my $jpack = encode_json $packaging;
	&subs::setting_setter({ app => $app, value => $jpack, setting => 'packaging' });

	my $html = $c->render_to_string(
		template => 'configure/packaging',
		settings => { app_packaging => $packaging }
	);
	$c->render(json => { packaging => $packaging, html => $html });

};

post '/manager/configure/packaging/delete' => sub($c) {
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $packaging = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'packaging' }) } || {};
	delete $packaging->{$uuid};
	my $jpack = encode_json $packaging;
	&subs::setting_setter({ app => $app, value => $jpack, setting => 'packaging' });
	my $html = $c->render_to_string(
		template => 'configure/packaging',
		settings => { app_packaging => $packaging }
	);
	$c->render(json => { packaging => $packaging, html => $html });
};


get '/manager/transaction/movement' => sub($c) {
	my $movement = $c->param('movement');
	my $app = $c->param('app');
	&subs::setting_setter({ app => $app, setting => 't_movement', value => $movement });
	my $appts = &log_reader({ app => $app, view => 'centre_view' });
	my $informations = [];
	
	my $html = '<span class="purchase_details" uuid="' . &subs::random_string_creator(10) . '" app="' . $app . '" style=""><br>' .
		$c->render_to_string(
		template => 'apps/transaction/' . $movement,
		app => {},
		appts => $appts,
		a => $app,
	) . '</span>';
	$c->render(json => { html => $html, app => $app });
};


post '/manager/inventory/evaluate' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $returner = { localtimes => {} };
	my $timeslots = [ 's','m','h','mday','M','y','wday','yday','isdst'];
	my $appts = [];
	if ($app) {
		$appts = &subs::db_select('appointments', undef, { app => $app })->hashes;
	}
	else {
		$appts = &subs::db_select('appointments')->hashes;
	}
	my $evaluation = { timeslots => {} };
	foreach my $appt ( @{$appts} ) {
		my @time = localtime($appt->{'timestamp'} / 1000);
		$appt->{'localtime'} = \@time;
		for (my $n = 0; $n < scalar @{$timeslots}; $n++) {
			my $t = $time[$n];
			push @{$returner->{'localtimes'}->{$timeslots->[$n]}->{$t}}, $appt;
			$evaluation->{'timeslots'}->{$timeslots->[$n]}->{$t} = scalar @{$returner->{'localtimes'}->{$timeslots->[$n]}->{$t}};
		}
	}
	&subs::cache_set({ app => $app || '__president', context => 'evaluation', warranty => '-6M' }, $evaluation);
	$c->render(json => $returner);
};

get '/manager/inventory/information' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $scope = $c->param('scope');
	my $x = $c->param('x');
	my $y = $c->param('y');
	my $start_timestamp = $c->param('start_timestamp');
	my $end_timestamp = $c->param('end_timestamp');
	my $returner = {
		scope => $scope,
		timestamp => $timestamp,
		app => $app
	};
	$returner->{'details'} = &inventory_details($c, &subs::settings_grabber({ app => $app }));

	$returner->{'html'} = $c->render_to_string(
		template => 'apps/inventory_info',
		scope => $scope,
		timestamp => $timestamp,
		app => $app,
		'x' => $x,
		'y' => $y,
		start_timestamp => $start_timestamp,
		end_timestamp => $end_timestamp,
		details => $returner->{'details'}
	);

	$c->render(json => $returner);
};

get '/manager/inventory/details' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $s_scroll = $c->param('s_scroll');
	if ($s_scroll != 0) {
		&subs::setting_setter({ app => $app, setting => 's_scroll', value => $s_scroll });
	}
	my $settings = &subs::settings_grabber({ app => $app });
	my $returner = &inventory_details($c, $settings);
	$c->render(json => $returner);
};

sub inventory_details($c,$settings) {
	my $app = $c->param('app');
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp');
	my $appts = [];
	if ($c->param('display')) {
		$settings->{'s_display'} = $c->param('display');
		$settings->{'s_movement'} = $c->param('movement');
		$settings->{'s_scope_count'} = $c->param('scope_count');
		$settings->{'s_visual'} = $c->param('visual');
		$settings->{'s_calc'} = $c->param('calc');
		$settings->{'s_lock'} = $c->param('lock');
	}

	unless ($settings->{'s_display'}) {
		&subs::setting_setter({ app => $app, setting => 's_display', value => 'occurences'});
		$settings->{'s_display'} = 'occurences';
	}
	$settings->{'s_movement'} = eval { decode_json $settings->{'s_movement'} } || ['all'];
	$appts = &subs::db_query('select * from appointments where app = ? or model = ? order by timestamp', $app, $app)->hashes;
	my $movements = [ 'all' ];
	foreach my $a ( @{$appts} ) {
		push @{$movements}, $a->{'type'} unless grep { $_ eq $a->{'type'} } @{$movements};
	}
	push @{$movements}, 'start' unless grep { $_ eq 'start' } @{$movements};
	if ($settings->{'s_movement'} == undef || grep { $_ eq 'all' } @{$settings->{'s_movement'}} ) {
	}
	else {
		my $new_appts = [];
		foreach my $sm ( @{$settings->{'s_movement'}} ) {
			push @{$new_appts}, grep { $_->{'type'} eq $sm } @{$appts};
		}
		$appts = $new_appts;
	}
	my @display_options;
	foreach my $k ( keys %{$gb::budget_modes} ) {
		my $formatted_name = &subs::format_name($k);
		if ($k eq 'quantity') {
			$formatted_name = $formatted_name . ' (' . $settings->{'unit'} . ')';
		}
		my $bm = { name => $k, formatted_name => $formatted_name };
		push @display_options, $bm;
		
	}
	my $am = eval { return decode_json $settings->{'app_measures'} } || {};
	foreach my $ameas ( keys %{$am} ) {
		my $formatted_name = &subs::format_name($ameas);
		if ($am->{$ameas}->{'unit'}) {
			$formatted_name = $formatted_name . ' (' . $am->{$ameas}->{'unit'} . ')';
		}
		push @display_options, { name => $ameas, formatted_name => $formatted_name } unless grep { $_->{'name'} eq $ameas } @display_options;
	}

	my @time_scopes = ('next', 'this','last');
	my @time_widths;

	my @time_lengths = qw/minute hour day week month year/;
	if ($settings->{'s_visual'} eq 'allocation') {
		@time_scopes = undef;
		for (my $n = 0; $n <= 366; $n++) {
			push @time_scopes, $n;
		}
		@time_lengths = qw/second minute hour mday month year wday yday isdst/;
		@time_widths = ( 60, 60, 24, 31, 12, 150, 7, 365, 2 );
	}
	else {
		for (my $n = 2; $n <= 30; $n++) { 
			push @time_scopes, $n . 'last' if $n <= $settings->{'s_scope_count'};
			unshift @time_scopes, $n . 'next' if $n <= $settings->{'s_scope_count'};
		}
	}

	if ($c->param('scope')) {
		my $scope = &subs::unformat_name($c->param('scope'));
		my $return_n = 0;
		for ( my $n = 0; $n <= scalar @time_lengths; $n++ ) {
			if ( $time_lengths[$n] eq $scope ) { $return_n = $n - 1; }
			if ($c->param('zone')) {
				if ($return_n > 1) {
					my @timey_widths = ( 60, 24, 7, 30, 12, 10 );
					@time_scopes = ('this','last');
					push @time_widths, $timey_widths[$return_n];
					for (my $n = 2; $n <= $timey_widths[$return_n]; $n++) { 
						push @time_scopes, $n . 'last';
					}

				}
			}
		}
		@time_lengths = grep { $_ eq $time_lengths[$return_n] } @time_lengths;
	}
	my @revised_time_scopes = @time_scopes;
	my $returner = {
		longest => $appts->[0],
		shortest => $appts->[0],
		betweens => [],
		between_total => 0,
		between_average => 0,
		longest_between => {},
		shortest_between => {},
		first_seen => $appts->[0],
		'last_seen' => $appts->[0],
		first_recorded => {},
		last_recorded => {},
		average_duration => 0,
		total_duration => 0,
		total_occurences => 0,
		settings => $settings,
		scopes => \@time_scopes,
		time_lengths => \@time_lengths,
		time_widths => \@time_widths,
		app => $app,
		budget_status => {},
	};
	my $bmt = scalar grep { $_ eq $settings->{'s_display'} } keys %{$gb::budget_modes};

	if ( scalar @{$appts} > 0 ) {
		foreach my $a ( @{$appts} ) {
			if ($a->{'measures'}) {
				$a->{'measures'} = eval { return decode_json $a->{'measures'} } || [];
			}
			if (($a->{'type'} eq 'start' || $a->{'type'} eq 'record')) {
				if ($a->{'timestamp'} < $server_time) {
					$a->{'duration'} = $server_time - $a->{'timestamp'};
				}
				else {
					$a->{'duration'} = &subs::time_abbrev_translator($settings->{'duration'});
				}
			}
			$a->{'duration'} = abs $a->{'duration'};
			if (($settings->{'s_display'} eq 'total') && ($a->{'total'} == 0 || $a->{'total'} == undef)) {
				next;
			}
			if ($settings->{'s_visual'} eq 'historical' || $settings->{'s_visual'} eq '') {
				foreach my $ts (@time_scopes) {
					foreach my $scope (@time_lengths) {
						my ($bt,$t1,$t2,$temp_timestamp);
						($bt, $temp_timestamp) = &father_time({ 
							scope => $scope,
							ts => $ts,
							lock => $settings->{'s_lock'},
							timestamp => $timestamp 
						});
						

						if ($a->{'timestamp'} > $bt && $a->{'timestamp'} < $temp_timestamp) {
							if ($a->{'measures'} && $bmt == 0 ) {

								foreach my $measure ( @{$a->{'measures'}} ) {
									unless ($measure->{$settings->{'s_display'}} || $measure->{$settings->{'s_display'}} == 0) {
										last;
									}
									foreach my $mk ( keys %{$measure} ) {

										if ($measure->{'ts'} && $measure->{'ts'} ne '') {
											$measure->{'timestamp'} = $measure->{'ts'};
											delete $measure->{'ts'};
										}
										if (($measure->{'timestamp'} < $bt || $measure->{'timestamp'} > $temp_timestamp) && $settings->{'s_display'} eq $mk) {
											unless (grep { $_->{'uuid'} eq $measure->{'uuid'} } @{$appts}) {
												my $new_measure = {
													app => $a->{'app'},
													timestamp => $measure->{'timestamp'} || $measure->{'ts'},
													type => 'measure',
													uuid => $measure->{'uuid'},
													measures => encode_json [ $measure ],
												};

												push @{$appts}, $new_measure;
												next;
											}
											$measure = undef;
										}
										else {
											if ($measure->{$mk} != undef || $measure->{$mk} == 0) {
												$returner->{$ts}->{$scope}->{$mk . '_occurences'} += 1;
												if ($settings->{'s_calc'} eq 'average' ) {
													$returner->{$ts}->{$scope}->{'t_' . $mk} += $measure->{$mk};
													my $sprinter = "%.2f";
													if ($measure->{$mk} < 1 && $measure->{$mk} > -1) {
														$sprinter = "%.4f";
													}

													$returner->{$ts}->{$scope}->{$mk} = sprintf($sprinter, $returner->{$ts}->{$scope}->{'t_' . $mk} / $returner->{$ts}->{$scope}->{$mk . '_occurences'}) if $measure->{$mk};
													if ($returner->{$ts}->{$scope}->{$mk} == undef) {
														$returner->{$ts}->{$scope}->{$mk} = 0;
													}
												}
												elsif ($settings->{'s_calc'} eq 'high') {
													$returner->{$ts}->{$scope}->{$mk} = $measure->{$mk} unless $returner->{$ts}->{$scope}->{$mk};

													if ($measure->{$mk} > $returner->{$ts}->{$scope}->{$mk}) {
														$returner->{$ts}->{$scope}->{$mk} = $measure->{$mk};
													}
												}
												elsif ($settings->{'s_calc'} eq 'low') {
													$returner->{$ts}->{$scope}->{$mk} = $measure->{$mk} unless $returner->{$ts}->{$scope}->{$mk};
													if ($measure->{$mk} < $returner->{$ts}->{$scope}->{$mk}) {
														$returner->{$ts}->{$scope}->{$mk} = $measure->{$mk};
													}
												}
												else {
													$returner->{$ts}->{$scope}->{$mk} += $measure->{$mk};# if $measure->{$mk} != undef;

												}
												$returner->{'total'}->{$scope}->{$mk} += 1;
											}
										}
									}
								}
							}
							elsif (grep { $_ eq $settings->{'s_display'} } keys %{$gb::budget_modes}) {

								if ($settings->{'s_display'} eq 'quantity') {
									if ($a->{'unit'} ne $settings->{'unit'}) {
										my $neg = 0;
										if ($a->{'quantity'} < 0) { $neg = 1; }
										$a->{'quantity'} = abs $a->{'quantity'};
										my ($formula,$evaluation,$uom,$format) = &formula_calculator($a->{'quantity'} . $a->{'unit'} . ' to ' . $settings->{'unit'});
										$a->{'quantity'} = $evaluation unless $evaluation == 0;
										$a->{'quantity'} = (abs $a->{'quantity'}) * -1 if $neg == 1;
										$a->{'unit'} = $settings->{'unit'} unless $evaluation == 0;
									}
								}

								if ($settings->{'s_calc'} eq 'average' ) {
									$returner->{$ts}->{$scope}->{'t_' . $settings->{'s_display'}} += $a->{$settings->{'s_display'}};
									$returner->{$ts}->{$scope}->{'c_' . $settings->{'s_display'}} += 1;
									my $sprinter = "%.2f";
									if ($a->{$settings->{'s_display'}} < 1 && $a->{$settings->{'s_display'}} > -1) {
										$sprinter = "%.4f";
									}
									$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = sprintf($sprinter, $returner->{$ts}->{$scope}->{'t_' . $settings->{'s_display'}} / $returner->{$ts}->{$scope}->{'c_' . $settings->{'s_display'}});
									if ($returner->{$ts}->{$scope}->{$settings->{'s_display'}} == 0) {
										$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = 0;
									}
								}
								elsif ($settings->{'s_calc'} eq 'high') {
									$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = 0 unless $returner->{$ts}->{$scope}->{$settings->{'s_display'}};
									if ($a->{$settings->{'s_display'}} > $returner->{$ts}->{$scope}->{$settings->{'s_display'}}) {
										$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = $a->{$settings->{'s_display'}};
									}
								}
								elsif ($settings->{'s_calc'} eq 'low') {
									$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = $a->{$settings->{'s_display'}} unless $returner->{$ts}->{$scope}->{$settings->{'s_display'}};
									if ($a->{$settings->{'s_display'}} < $returner->{$ts}->{$scope}->{$settings->{'s_display'}}) {
										$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = $a->{$settings->{'s_display'}};
									}
								}
								else {
									$returner->{$ts}->{$scope}->{$settings->{'s_display'}} += $a->{$settings->{'s_display'}} unless $settings->{'s_display'} eq 'occurences';
								}
							}
							$returner->{$ts}->{$scope}->{'timestamp'} = $a->{'timestamp'};
							$returner->{$ts}->{$scope}->{'occurences'} += 1;# unless $settings->{'s_display'} eq 'occurences';
							$a->{'occurences'} = 1;

							$returner->{$ts}->{$scope}->{'formatted_duration'} = &subs::duration_sayer((abs $returner->{$ts}->{$scope}->{'duration'}) / 1000);
					#		$returner->{$ts}->{$scope}->{'total'} += abs $a->{'total'} if $a->{'total'};
					#		$returner->{$ts}->{$scope}->{'amount'} += abs $a->{'amount'} if $a->{'amount'};
							$returner->{'total'}->{$scope}->{$settings->{'s_display'}} += abs $a->{$settings->{'s_display'}};
							$returner->{'count'}->{$scope}->{$settings->{'s_display'}} += 1;
							$returner->{'average'}->{$scope}->{$settings->{'s_display'}} = sprintf("%.2f", $returner->{'total'}->{$scope}->{$settings->{'s_display'}} / $returner->{'count'}->{$scope}->{$settings->{'s_display'}});
							if ($settings->{'budget'} && $settings->{'s_calc'} eq 'sum' && $returner->{$ts}->{$scope}->{$settings->{'s_display'}} != 0) {
								unless ($returner->{'autocalc'}) {
									$returner->{'autocalc'} = &subs::cache_get({ app => $returner->{'app'}, context => 'autocalc', subcontext => $settings->{'s_display'} });
								}
								my $budget = &budget_calculator({
									app => $returner->{'app'},
									budget => $settings->{'budget'},
									circumstance => $settings->{'s_display'},
									value => $returner->{$ts}->{$scope}->{$settings->{'s_display'}},
									scope => $scope,
									appts => $appts,
									settings => $settings
								});

								if ($returner->{$ts}->{$scope}->{$settings->{'s_display'}} && $ts eq 'this' && 
									&subs::timespan_widener($budget->{'scope_name'}) eq &subs::timespan_widener($scope) && $budget->{'is_scope'} eq 'yes' && 
										$settings->{'s_display'} eq $budget->{'circumstance'}) {

									$returner->{'cachable'} = $budget if $budget->{'colour'};
								}


								$returner->{$ts}->{$scope}->{'budget'} = $budget;
								$returner->{'budgets'} = $budget->{'budgets'};
								$returner->{'budget_status'}->{$scope}->{$settings->{'s_display'}}->{'expected'} += $budget->{'expected'};
								$returner->{'budget_status'}->{$scope}->{$settings->{'s_display'}}->{'actual'} += $budget->{'actual'};

								$returner->{'budget_status'}->{$scope}->{$settings->{'s_display'}} = &budget_status_maker($returner->{'budget_status'}->{$scope}->{$settings->{'s_display'}});
							}

							if ($settings->{'s_display'} eq 'occurences') {
								$returner->{'average'}->{$scope}->{$settings->{'s_display'}} = sprintf("%.2f", $returner->{'total'}->{$scope}->{$settings->{'s_display'}} / scalar @time_scopes);
							}
							foreach my $d ( @display_options ) {
								if ($returner->{$ts}->{$scope}->{$d->{'name'}} > $returner->{'highest'}->{$scope}->{$d->{'name'}}) {
									$returner->{'highest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
								}
								elsif ($returner->{'highest'}->{$scope}->{$d->{'name'}} == undef) {
									$returner->{'highest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
								}
								if ($returner->{$ts}->{$scope}->{$d->{'name'}} < $returner->{'lowest'}->{$scope}->{$d->{'name'}}) {
									$returner->{'lowest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
								}
								elsif ($returner->{'lowest'}->{$scope}->{$d->{'name'}} == undef) {
									$returner->{'lowest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
								}
								$returner->{$ts}->{$scope}->{'start_timestamp'} = $bt;
								$returner->{$ts}->{$scope}->{'end_timestamp'} = $temp_timestamp;								

							}
						}
					}
				}
			}
			elsif ($settings->{'s_visual'} eq 'allocation') {
				my @localtime = localtime($a->{'timestamp'} / 1000);
				if ($a->{'measures'}) {
					foreach my $measure ( @{$a->{'measures'}} ) {
						foreach my $mk ( keys %{$measure} ) {
							unless ($measure->{$settings->{'s_display'}} || $measure->{$settings->{'s_display'}} == 0) {
								last;
							}
						
							if (!$measure->{'uuid'}) {
								$measure->{'uuid'} = &subs::random_string_creator(15);
							}
							if ($measure->{'ts'} && $measure->{'ts'} ne '') {
								$measure->{'timestamp'} = $measure->{'ts'};
								delete $measure->{'ts'};
							}

							if ($settings->{'s_display'} eq $mk) {
								unless (grep { $_->{'uuid'} eq $measure->{'uuid'} } @{$appts}) {
									my $new_measure = {
										app => $a->{'app'},
										timestamp => $measure->{'timestamp'} || $measure->{'ts'},
										type => 'measure',
										uuid => $measure->{'uuid'} || &subs::random_string_creator(8),
										$mk => $measure->{$settings->{'s_display'}},
										measures => encode_json [ $measure ],
									};
									push @{$appts}, $new_measure;
									undef $a;
								}
								$measure = undef;
							}
						}
					}
				}
				next unless $a->{'uuid'};
				for (my $n = 0; $n <= scalar @time_lengths; $n++) {
					if (($a->{$settings->{'s_display'}} || $a->{$settings->{'s_display'}} == 0) || ( $bmt > 0 )) {
						my $scope = $time_lengths[$n];
						my $ts = $localtime[$n];
						if ($scope eq 'month') { $ts += 1; }
						if ($scope eq 'year') { $ts += 1900; }
					#	if ($scope eq 'wday') { $ts += 1; }
						$returner->{$ts}->{$scope}->{'occurences'} += 1;
						if ($settings->{'s_calc'} eq 'average' ) {
							$returner->{$ts}->{$scope}->{'t_' . $settings->{'s_display'}} += $a->{$settings->{'s_display'}};
							$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = sprintf("%.2f", $returner->{$ts}->{$scope}->{'t_' . $settings->{'s_display'}} / $returner->{$ts}->{$scope}->{'occurences'});
							if ($returner->{$ts}->{$scope}->{$settings->{'s_display'}} == 0) {
								$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = 0;
							}
						}
						elsif ($settings->{'s_calc'} eq 'high') {
							$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = $a->{$settings->{'s_display'}} unless $returner->{$ts}->{$scope}->{$settings->{'s_display'}};
							if ($a->{$settings->{'s_display'}} > $returner->{$ts}->{$scope}->{$settings->{'s_display'}}) {
								$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = $a->{$settings->{'s_display'}};
							}
						}
						elsif ($settings->{'s_calc'} eq 'low') {
							$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = $a->{$settings->{'s_display'}} unless $returner->{$ts}->{$scope}->{$settings->{'s_display'}};
							if ($a->{$settings->{'s_display'}} < $returner->{$ts}->{$scope}->{$settings->{'s_display'}}) {
								$returner->{$ts}->{$scope}->{$settings->{'s_display'}} = $a->{$settings->{'s_display'}};
							}
						}
						else {
							$returner->{$ts}->{$scope}->{$settings->{'s_display'}} += $a->{$settings->{'s_display'}};

						}
						$returner->{$ts}->{$scope}->{'formatted_duration'} = &subs::duration_sayer((abs $returner->{$ts}->{$scope}->{'duration'}) / 1000);
						$returner->{$ts}->{$scope}->{'total'} += $a->{'total'};
						unless (grep { $settings->{'s_display'} eq $_ } keys %{$gb::budget_modes}) {
							#$returner->{$ts}->{$scope}->{$settings->{'s_display'}} += $a->{$settings->{'s_display'}};
						}

						foreach my $d ( @display_options ) {
							if ($returner->{$ts}->{$scope}->{$d->{'name'}} > $returner->{'highest'}->{$scope}->{$d->{'name'}}) {
								$returner->{'highest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
							}
							elsif ($returner->{'highest'}->{$scope}->{$d->{'name'}} == undef) {
								$returner->{'highest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
							}
							if ($returner->{$ts}->{$scope}->{$d->{'name'}} < $returner->{'lowest'}->{$scope}->{$d->{'name'}}) {
								$returner->{'lowest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
							}
							elsif ($returner->{'lowest'}->{$scope}->{$d->{'name'}} == undef) {
								$returner->{'lowest'}->{$scope}->{$d->{'name'}} = $returner->{$ts}->{$scope}->{$d->{'name'}};
							}
						}
					}
				}
			}
			if (abs $a->{'duration'} > abs $returner->{'longest'}->{'duration'}) {
				$returner->{'longest'} = $a;
			}
			if (abs $a->{'duration'} < abs $returner->{'shortest'}->{'duration'}) {
				$returner->{'shortest'} = $a;
			}
			my $between = $a->{'timestamp'} - $returner->{'last_seen'}->{'timestamp'};
			if ($between > $returner->{'longest_between'}->{'duration'}) {
				$returner->{'longest_between'} = clone $a;
				$returner->{'longest_between'}->{'duration'} = $between;
			}
			if ($between < $returner->{'shortest_between'}->{'duration'} || $returner->{'shortest_between'}->{'duration'} == undef) {
				$returner->{'shortest_between'} = clone $a;
				$returner->{'shortest_between'}->{'duration'} = $between;
			}
			push @{$returner->{'betweens'}}, $between;
			$returner->{'last_seen'} = $a;

			if ($a->{'server_time'} > $returner->{'last_recorded'}->{'server_time'}) {
				$returner->{'last_recorded'} = $a;
			}
			if ($a->{'server_time'} < $returner->{'first_recorded'}->{'server_time'} || $returner->{'first_recorded'}->{'server_time'} == undef) {
				$returner->{'first_recorded'} = $a;
			}
			$returner->{'total_duration'} += abs $a->{'duration'};
			$returner->{'total_occurences'} += 1;

		}
		$returner->{'average_duration'} = eval { $returner->{'total_duration'} / $returner->{'total_occurences'} } || undef;

		foreach my $betweens ( @{$returner->{'betweens'}} ) {
			$returner->{'between_total'} += $betweens;
		}
		$returner->{'between_average'} = eval { $returner->{'between_total'} / $returner->{'total_occurences'} } || undef;
	}
	foreach my $ts ( @time_scopes ) {

		if ($returner->{$ts} == undef) {
			@revised_time_scopes = grep { $_ ne $ts } @revised_time_scopes;
		}
	}
	my @sb;
	foreach my $s ( @display_options ) {
		push @sb, $s->{'name'} unless grep { $_ eq $s->{'name'} } keys %{$gb::budget_modes};
	}
	my $jsb = encode_json \@sb;

	@time_scopes = @revised_time_scopes;
	push @time_scopes, qw/average total/;
	if ($returner->{'budgets'}->{$settings->{'s_display'}}) {
		&subs::cache_set({ app => $returner->{'app'}, context => 'budget', subcontext => $returner->{'cachable'}->{'circumstance'} },$returner->{'cachable'});
	}
	&Websocket::send('tab', $returner->{'sendable'});
	&subs::appt_header_printer({ app => $returner->{'app'} });
	undef $returner->{'sendable'};
	undef $returner->{'cachable'};
	$returner->{'evaluation'} = &subs::cache_get({ app => $app, context => 'evaluation' });
	$returner->{'json_returner'} = encode_json $returner;

	$returner->{'content'} = $c->render_to_string(
		template => 'apps/inventory', 
		app => $app, 
		returner => $returner, 
		appts => $appts, 
		settings => $settings, 
		time_scopes => \@time_scopes,
		time_lengths => \@time_lengths,
		movements => $movements,
		display_options => \@display_options,
		evaluation => $returner->{'evaluation'}
	);
	return $returner;
}

sub father_time($data) {
	my $start_time = &subs::rightNow();

	my $scope = $data->{'scope'};
	my $ts = $data->{'ts'};
	my $lock = $data->{'lock'} || 'off';
	my $timestamp = $data->{'timestamp'};
	my ($bt,$temp_timestamp,$t1,$t2);

	if ($gb::father_time->{$scope}->{$ts}->{$lock}->{'st'} > $start_time - 10000) {
		$bt = $gb::father_time->{$scope}->{$ts}->{$lock}->{'bt'};
		$temp_timestamp = $gb::father_time->{$scope}->{$ts}->{$lock}->{'tt'};
		$gb::father_time->{$scope}->{$ts}->{$lock}->{'st'} = $start_time;
	}
	else {
		if ($ts eq 'this') {
			$temp_timestamp = $timestamp;
		}
		elsif ($ts =~ 'last') {
			$temp_timestamp = &{$subs::time_subs->{$scope}}($timestamp);
			if ($ts =~ /(^[0-9])/) {
				my $tas = $ts;
				$tas =~ s/last//gi;
				my $tame = $gb::numerics->{$tas};
				$tame = '' if $tas == 1;
				$temp_timestamp = &{$subs::time_subs->{$tame . $scope}}($timestamp);
			}
		}
		elsif ($ts =~ 'next') {
			my $bt = &{$subs::time_subs->{$scope}}($timestamp);
			my $t1 = $timestamp - $bt;
			$temp_timestamp = $t1 + $timestamp;
			if ($ts =~ /(^[0-9])/) {
				my $tas = $ts;
				$tas =~ s/next//gi;
				my $tame = $gb::numerics->{$tas};
				my $template_tame = 0;
				if ($tas == 1) {
					$tame = '';
				}
				else {
					$template_tame = $timestamp - &{$subs::time_subs->{$scope}}($timestamp);
				}
				my $tamer = $timestamp -  &{$subs::time_subs->{$tame . $scope}}($timestamp);

				$temp_timestamp = $timestamp + $tamer + $template_tame;
			}
		}

		if ($lock eq 'on' && grep { &subs::timespan_widener($scope) =~ /\Q$_/gi } qw/minute hour day week month year/) {
			my $multiplier = $scope;
			$multiplier =~ s/[^0-9.]//gi;
			$multiplier = 1 unless $multiplier;

			$scope =~ s/[^a-zA-Z]//gi;
			$scope = lc $scope;
			my @localtime = localtime $temp_timestamp / 1000;
			
			if ($scope eq 'minute') {
				my $second = localtime( $temp_timestamp / 1000 )->strftime( "%S");
				$bt = &subs::ago_calc($second . 's', $temp_timestamp);
				$temp_timestamp = &subs::ago_calc('-' . $multiplier . 'm',$bt);
			}
			elsif ($scope eq 'hour') {
				my $hour = localtime( $temp_timestamp / 1000 )->strftime( "%H");
				my $minute = localtime( $temp_timestamp / 1000 )->strftime( "%M");
				my $second = localtime( $temp_timestamp / 1000 )->strftime( "%S");
				$bt = &subs::ago_calc($minute . 'm ' . $second . 's', $temp_timestamp);
				$temp_timestamp = &subs::ago_calc('-' . $multiplier . 'h', $bt);

			}
			elsif ($scope eq 'day') {
				my $hour = localtime( $temp_timestamp / 1000 )->strftime( "%H");
				my $minute = localtime( $temp_timestamp / 1000 )->strftime( "%M");
				my $second = localtime( $temp_timestamp / 1000 )->strftime( "%S");
				$bt = &subs::ago_calc( $hour . 'h ' . $minute . 'm ' . $second . 's',$temp_timestamp);
				$temp_timestamp = &subs::ago_calc('-' . $multiplier . 'd', $bt);
			}
			elsif ($scope eq 'week') {
				my $day = localtime( $temp_timestamp / 1000 )->strftime( "%d");
				my $month = localtime( $temp_timestamp / 1000 )->strftime( "%m");
				my $year = localtime( $temp_timestamp / 1000 )->strftime( "%Y");
				my $wday = $localtime[6];
				my $bwtemp = &subs::ago_calc($wday . 'd', $temp_timestamp);
				my $awtemp = &subs::ago_calc('-' . ( 6 - $wday ) . 'd', $temp_timestamp);

				$day = localtime( $bwtemp / 1000 )->strftime( "%d");
				$month = localtime( $bwtemp / 1000 )->strftime( "%m");
				$year = localtime( $bwtemp / 1000 )->strftime( "%Y");
				$bt = &subs::ago_calc($month . '/' . $day . '/' . $year . ' 12am', $bwtemp);

				$day = localtime( $awtemp / 1000 )->strftime( "%d");
				$month = localtime( $awtemp / 1000 )->strftime( "%m");
				$year = localtime( $awtemp / 1000 )->strftime( "%Y");
				$temp_timestamp = &subs::ago_calc($month . '/' . $day . '/' . $year . ' 11:59:59pm', $awtemp);
			}
			elsif ($scope eq 'month') {
				my $day = localtime( $temp_timestamp / 1000 )->strftime( "%d");
				my $tday = localtime( $timestamp / 1000 )->strftime( "%d" );
				my $year = localtime( $temp_timestamp / 1000 )->strftime( "%Y");
				my $month = localtime( $temp_timestamp / 1000 )->strftime( "%m");

	#			$day = $tday - $day;


				if ($ts =~ 'next') {

				#	$temp_timestamp = &subs::ago_calc($gb::months->[$month - 1]->{'days'} - $day . 'd', $temp_timestamp);
					$day = localtime( $temp_timestamp / 1000 )->strftime( "%d");

					if ($month == 12) {
					#	$month = 1;
					}
					else {
					#	$month--;
					}
				}
				elsif ($ts =~ 'last') {
				#	$temp_timestamp = &subs::ago_calc($day + 1 . 'd', $temp_timestamp);
					$day = localtime( $temp_timestamp / 1000 )->strftime( "%d");
					$day = localtime( $temp_timestamp / 1000 )->strftime( "%d");
					$month = localtime( $temp_timestamp / 1000 )->strftime( "%m");
					$year = localtime( $temp_timestamp / 1000 )->strftime( "%Y");
				}
				my $last_day = $gb::months->[$month - 1]->{'days'};
				my $datetime = $month . '/' .  $last_day .'/' . $year . ' 11:59:59pm';
				my $bdatetime = $month . '/1/' . $year . ' 12am';

				$bt = &subs::ago_calc($bdatetime, $temp_timestamp);
				$temp_timestamp = &subs::ago_calc($datetime, $temp_timestamp);
			}
			elsif ($scope eq 'year') {
				my $year = localtime( $temp_timestamp / 1000 )->strftime( "%Y");
				$bt = &subs::ago_calc('jan 1 ' . $year . ' 12am', $temp_timestamp);
				$temp_timestamp = &subs::ago_calc('jan 1 ' . ($year + $multiplier) . ' 12am', $temp_timestamp);
			}
		}
		else {
			$bt = &{$subs::time_subs->{$scope}}($temp_timestamp); #timestamp at beginning
			my $t1 = ($temp_timestamp - $bt);
			$t2 = ($t1 + $temp_timestamp);
		}
	}

	$gb::father_time->{$scope}->{$ts}->{$lock} = { bt => $bt, tt => $temp_timestamp, st => $start_time };

	return ($bt,$temp_timestamp);
}


get '/manager/configure/appointment_list' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $results = &subs::db_query("select distinct app from settings where setting=? and value=?",'visible','checked');
	my $appointments = $results->hashes;
	foreach my $a (@{$appointments}) {
		$a->{'app'} = &subs::unformat_name($a->{'app'});
		$a->{'formatted_name'} = &subs::format_name($a->{'app'});
	}
	$c->render(
		template => 'configure/appointment_lister',
		appts => $appointments,
		timestamp => &subs::rightNow()
	);
};

get '/manager/configure/appointment_display' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });
	my $config_window = $c->param('config');
	my $preferred_appts = {};

	my $measures = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	foreach my $m ( keys %{$measures} ) {

	}
	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	my $packaging = eval { return decode_json $appts->{$app}->{'setting'}->{'packaging'} } || {};
	$appts->{$app}->{'setting'}->{'app_packaging'} = $packaging;
	$appts->{$app}->{'setting'}->{'packaging'} = join ',', map { $_ = $packaging->{$_}->{'name'} } keys %{$packaging};

	my $home_plate = eval { return decode_json $appts->{$app}->{'setting'}->{'home_plate'} } || {};
	$appts->{$app}->{'setting'}->{'app_home_plate'} = $home_plate;
	$appts->{$app}->{'setting'}->{'home_plate'} = $home_plate->{'latitude'} . ' ' . $home_plate->{'longitude'};


	foreach my $k (keys %{$appts}) {
		if ($k =~ /^__/) { 
			next;
		}
		else {
			$preferred_appts->{$k} = $appts->{$k}
		}
	}
	$c->render(
		template => 'configure/appointment_list',
		appts => $preferred_appts,
		'pos' => $gb::pos,
		'abilities' => $gb::abilities,
		config_window => $config_window,
		timestamp => &subs::rightNow()
	);
};

post '/manager/configure/permissions' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my ($av_data);
	if ($c->param('avData')) {
		$av_data = decode_json($c->param('avData'));
	}
	my $constraints = $c->param('constraints');
	foreach my $av (@{$av_data}) {
		if ($av->{'kind'} eq 'audioinput') {
			$av->{'icon'} = 'microphone';
		}
		elsif ($av->{'kind'} eq 'videoinput') {
			$av->{'icon'} = 'monitor';
		}
		elsif ($av->{'kind'} eq 'audiooutput') {
			$av->{'icon'} = 'speaker';
		}
	}
	$c->render(json => { av_data => $av_data, constraints => $constraints });
};

get '/manager/configure' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();

	my $browser_tab = $c->param('browser_tab');
	my $browser_tab_id = $c->param('browser_tab_id');

	my $web_query = &subs::db_query('select * from websockets where browser_tab_id = ?',$browser_tab_id);
	my $websockets = $web_query->hashes;
	my $pseudonyms = &pseudonym_maker('config','');

	my $content = $c->render_to_string(
		template => 'configure/configure',
		config => &subs::config_reader(),
		device => $device,
		websockets => $websockets,
		pseudonyms => $pseudonyms,
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'configure', title => 'Configure', contents => $content },$timestamp);
	$c->render(text => $contents);
};


post '/manager/configure' => sub ($c) {

	my $app = $c->param('app');
#	&subs::cache_delete({ app => $app });
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $timestamp = $c->param('timestamp');
	my $source = $c->param('source');
	if ($setting eq 'measures') {
		$setting = 'app_measures';
		my $measures = eval { decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
		my @potentials = split ',', $value;

		foreach my $p ( @potentials ) {
			unless ($measures->{$p}) {
				$measures->{$p} = 0;
			}
		}
		foreach my $m ( keys %{$measures} ) { 
			unless ( grep { $_ eq $m } @potentials ) {
				delete $measures->{$m};
			} 
		}

		$value = encode_json $measures;
	}

	my $setting_data = { app => $app, setting => $setting, value => $value, timestamp => $timestamp, source => 'panel' };
	&subs::setting_setter($setting_data);
	undef @appointments;
	my $appts = &log_reader({ app => $c->param('app'), view => 'appointment_display' });
	my $measures = eval { decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};

	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	my $packaging = eval { decode_json $appts->{$app}->{'setting'}->{'packaging'} } || {};
	$appts->{$app}->{'setting'}->{'app_packaging'} = $packaging;
	$appts->{$app}->{'setting'}->{'packaging'} = join ',', map { $_ = $packaging->{$_}->{'name'} } keys %{$packaging};

	my $home_plate = eval { return decode_json $appts->{$app}->{'setting'}->{'home_plate'} } || {};
	$appts->{$app}->{'setting'}->{'app_home_plate'} = $home_plate;
	$appts->{$app}->{'setting'}->{'home_plate'} = $home_plate->{'latitude'} . ' ' . $home_plate->{'longitude'};

	if ($setting eq 'enc' && $value eq 'on') {
		&subs::file_encrypter({ app => $app });
	}
	elsif ($setting eq 'enc' && $value eq 'off') {
		&subs::file_decrypter({ app => $app });
	}



	my $preferred_appts = {};
	foreach my $k (keys %{$appts}) {
		if ($k =~ /^__/) { 
			next;
		}
		else {
			$preferred_appts->{$k} = $appts->{$k}
		}
	}
	if ($setting eq 'navigation') {
		$value = &subs::time_abbrev_translator($value, $timestamp);
	}

	&Websocket::send($app, { console => '$(\'.appointment[app="' . $app . '"]\').attr(\'' . $setting . '\', \'' . $value . '\');' });
	if ($source eq 'panel') {

		my $window = &centre_view_grabber({ c => $c, app => $c->param('app'), timestamp => $timestamp });
		$c->render(text => $window);

	}
	else {
		$c->render(
			template => 'configure/appointment_list',
			appts => $preferred_appts,
			timestamp => &subs::rightNow()
		);
	}
};



get '/manager/configure/system_list' => sub($c) {
	my $local_storage = eval { return decode_json $c->param('local_storage') } || {};
	my $settings = { };
	my ($db,$database,$sql) = &subs::database_grabber();
	foreach my $dt ( @gb::device_types ) {
		$settings->{$dt} = &subs::settings_grabber({ app => '__president', device => $dt });
	}
	my $stats = [];
	my $tables = `sqlite3 $database .tables`;
	foreach my $d ( sort split ' ', $tables ) {
		my $results = &subs::db_query('select count(*) from ' . $d);
		push @{$stats}, { formatted_table => &subs::format_name($d), table => $d, count => $results->hash->{'count(*)'} };
	}
	push @{$stats}, { formatted_table => 'Downloads', table => 'download', count => &subs::setting_grabber({ app => '__president', setting => 'download_count' }) || 0 };
	
	my $evaluation = &subs::cache_get({ app => '__president', context => 'evaluation' }) || {};

	$settings->{$device}->{'stats'} = $stats;
	$c->render(
		template => '/configure/system_setting_list', 
		stats => $stats, 
		local_storage => $local_storage, 
		evaluation => $evaluation, 
		settings => $settings, 
		last_restart => read_file($duty_file),
		device => $device
	);
};

post '/manager/configure/sys_setting' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $setting = &subs::unformat_name($c->param('setting'));
	my $value = $c->param('value');
	my $device = &subs::unformat_name($c->param('device'));
	my $set = &subs::setting_setter({ app => '__president', setting => $setting, value => $value, device => $device });
	$c->render(json => $set);
};

post '/manager/configure/system_monitor' => sub($c) {
	my $all_params = $c->req->query_params;
	my $data;
	for (my $n = 0; $n < scalar @{$all_params->{'pairs'}} - 1; $n++) {

		$data->{$all_params->{'pairs'}->[$n]} = $all_params->{'pairs'}->[$n + 1];
		$n++;
	}
	$c->render(json => {});
};


get '/manager/configure/restore_list' => sub($c) {
	my @database = split '/', $c->session('database');
	pop @database;
	my $dir = join '/', @database;

	$dir = $dir . '/';
	$dir = &subs::home($c->param('president')) if $c->param('president');
	my $returner = &subs::restore_list($dir);
	@{$returner} = grep { $_->{'filename'} =~ /enc$/gi } @{$returner};
	my @tables = qw/appointments settings notifications websites continent backups/;

	$c->render(
		template => 'configure/restore_list', 
		backups => $returner,
		tables => \@tables
	);
};


post '/manager/configure/new_database' => sub($c) {
	my ($db,$database) = &subs::database_grabber();
	&subs::db_query('VACUUM');
	my $timestamp = $c->param('timestamp');
	$c->param('reason' => 'new_database');
	$c->render(text => $database) unless $c->param('credential');
	my $president = $c->param('president');
	$president = &subs::home($president);
	my $old_db = $database;
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10)) . '/';
	`mkdir -p $temp_folder` unless -e "$temp_folder";

	my $database = $temp_folder . $president . '.db';
	my $enc_file = $temp_folder . $president . '.enc';
	my $secret = $c->param('credential');
	my $credential = $c->session('suds');
	my $misc_setting_list = &misc_setting_list();
	my $server_time = &subs::rightNow();
	`touch $database`;
	my $schema_file = $temp_folder . 'schema.sql';
	`sqlite3 $old_db .schema > $schema_file`;
	my $command = `sqlite3 $database < $schema_file`;
	`shred -u $schema_file`;
	$sql = Mojo::SQLite->new('sqlite:' . $database);
	$db = $sql->db;
	my $secretive = &subs::encrypter($secret,$secret);
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);

	$db->insert('security', { level => 1, database => $database, timestamp => $timestamp, server_time => $server_time, credential => $secretive, uuid => &subs::random_string_creator(30) });
	foreach my $set ( qw/misc/ ) {
		my $settings = &subs::db_select('settings', undef, { app => $set })->hashes;
		foreach my $s ( @{$settings} ) {
			$db->insert('settings', $s);
		}
	}

	my $data = &qrcode_generator({
		timestamp => $timestamp + 1,
		app => '__president',
		name => 'citizen',
		privilege => 'citizen',
		project => 'personal',
		debriefer => '{}',
		nic => 'lo',
		suds => $secret,
		warranty => '-100y',
		db => $db,
		database => $database
	});
	$db->insert('tickets', $data);

	my $backup = `sqlite3 $database ".backup '$database.1.db'"`;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my $encrypt =	`openssl enc -e -k "$secret" -$encryption_standard -pbkdf2 -in $database.1.db -out $enc_file`;
	my $appendage = $universal_splitter . &subs::encrypter($secret,$encryption_standard);
	`echo "$appendage" >> $enc_file`;
#	my $devices = &subs::device_lister($timestamp);

#	&subs::backup_now($c);
	`shred -u $database`;
#	`shred -u $database.1.db`;
	`shred -u $database-shm`;
	`shred -u $database-wal`;
	my $new_enc_file = &subs::home($config->{'start_dir'}) . $president . '.enc';
	`mv -v $enc_file $new_enc_file`;
#	`rm -R $temp_folder`;
#	$database = $old_db;
	&subs::say_it('New Database ' . $c->param('president'));
	$c->render(text => $database);
};


post '/manager/configure/restore_now' => sub($c) { 
	my $filename = $c->param('filename');
	my $path = $filename;
	$c->param('reason' => 'restore_database');
	my ($db) = &subs::database_grabber();
	my $credentials = &subs::db_select('security', ['level','credential'], {  });
	my $creds = $credentials->hashes;
	@{$creds} = grep { $_->{'level'} ne 'padlock' } @{$creds};
	@{$creds} = reverse @{$creds};
	my $disposition->{'status'} = 'fail';
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	foreach my $cred ( @{$creds} ) {
		my $cr = &subs::decrypter($c->session('suds'),$cred->{'credential'});
		if ($path =~ /enc$/gi) {
			$filename =~ s/.enc$//gi;
			my $t_database = $filename.'.db';
#			my $scrypt = `printf "$cr" | scrypt dec -P $path $t_database`;
			my $data = `tail $path`;
			my @split_data = split $universal_splitter, $data;
			$encryption_standard = &subs::decrypter($cr, $split_data[1]);
			my $scrypt = `openssl enc -d -k "$cr" -$encryption_standard -pbkdf2 -in $path -out $t_database`;
			if (-s $t_database > 5000) {
				&subs::backup_now($c);
				`shred -u $database`;
				`shred -u $database-shm`;
				`shred -u $database-wal`;
				$database = $t_database;
				$sql = Mojo::SQLite->new('sqlite:' . $database);
				my $db = $sql->db;

				my $secret = &subs::decrypter($cr,&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});
				if (secure_compare $cr, $secret) {
					$disposition->{'disposition'} = $database;
					$c->session('suds' => $secret);
					$c->session('database' => $database);
					$disposition->{'status'} = 'succeed';
					last;
				}
				else {
					$c->session('authentication' => 'rejected');
				}
			}
		}
	}

	$disposition = encode_json $disposition;
	$c->render(text => $disposition);
};



get '/manager/configure/database_vacuum' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $html = "You are about to clean up settings from the following orphaned apps<br><br>";

	my @unique_settings = &database_vacuum_bag();

	foreach my $us ( @unique_settings ) {
		$html .= '<input type="checkbox" checked="checked" app="' . $us . '" class="database_vacuum_checkbox">' . &subs::format_name($us) . "<br>";
	}
	
	$html .= '<img src="/images/decipherable/vacuum.png" id="database_vacuum_confirm" class="medium_thumb">';
	$html = "Your house is clean!" if scalar @unique_settings == 0;
	$html .= '<img src="/images/make believe/cancel_button.png" id="alert_cancel"  class="medium_thumb">';
	$c->render(json => { html => $html });
};

sub database_vacuum_bag() {
	my @protection = @gb::protected;
	push @protection, keys %{$gb::known_appts};
	my $settings = &subs::db_query('select * from settings where setting !=?', 'uuid')->hashes;

	foreach my $protect ( @protection ) {
		@{$settings} = grep { $_->{'app'} ne $protect } @{$settings};
	}
	my $appts = &subs::db_query('select distinct(app) from appointments')->hashes;
	my @unique_settings;
	foreach my $s ( @{$settings} ) {
		unless ( grep { $_->{'app'} eq $s->{'app'} } @{$appts} ) {
			push @unique_settings, $s->{'app'} unless grep { $_ eq $s->{'app'} } @unique_settings;
		}
	}
	return @unique_settings;
}

post '/manager/configure/database_vacuum_confirm' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $checkboxes = $c->param('checkboxes');
	$checkboxes = eval { return decode_json $checkboxes } || [];
	my $html = "You have cleaned:<br><br>";
	foreach my $us ( @{$checkboxes} ) {
		&subs::db_delete('settings', { app => $us });
		$html .= &subs::format_name($us) . "<br>";
	}

	$html .= '
		<img src="/images/make believe/cancel_button.png" id="alert_cancel"  class="medium_thumb">';
	$c->render(json => { html => $html });
};

get '/manager/configure/database_doctor' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $returner = { tables => [], auuid => &subs::random_string_creator(20) };
	my $tables = `sqlite3 $database .tables`;
	@{$returner->{'tables'}} = split ' ', $tables;


	$returner->{'html'} = '<h2>You are about to perform surgery on ' . $database . '</h2>
		<h4>This process is irreversible, unless you have backups or whatever!</h4>';
	foreach my $table ( @{$returner->{'tables'}} ) {
		my $counter = &subs::db_query('select count(*) from ' . $table);
		my $count = $counter->hash->{'count(*)'};
		$returner->{'count'}->{$table} = $count;
		my $existing = &subs::db_query('select * from ' . $table)->hashes;
		my $delta = ($count - scalar @{$existing});
		my $colour = 'black';
		my $repairable = [];
		if ($delta != 0) {
			$colour = 'red';
			#if ($existing->[-1]->{'app'}) {
				my $repairs = &subs::db_query('select distinct(app) from ' . $table)->hashes;
				if ($table eq 'settings') {
				#	push @{$repairs}, ({ app => 'me' }, { app => 'misc' }, { app => '__president' });
				}
				foreach my $a ( @{$repairs} ) {
					my $ok = &subs::db_select($table, undef, { app => $a->{'app'} })->hashes;
					push @{$repairable}, @{$ok};
			#	}
			}
		}
		
		
		$returner->{'html'} .= '<span style="color:' . $colour .';"><b><u style="font-size:20px;"> ' . $table . '</u> Count:</b> ' . $count . ' <b>Shows:</b> ' . scalar @{$existing} . ' <b>Delta:</b> ' . $delta;
		if (scalar @{$repairable} > 0) {
			$returner->{'html'} .= ' <b>Repair: </b>' . scalar @{$repairable};
		}
		$returner->{'html'} .= '</span><br>';
	}
	$returner->{'html'} .= '
		<img src="/images/jbuttons/doctor.png" id="database_doctor_confirm" class="medium_thumb">
		<img src="/images/make believe/cancel_button.png" id="alert_cancel"  class="medium_thumb">';
	$c->render(json => $returner);
};

post '/manager/configure/database_doctor_confirm' => sub($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $auuid = $c->param('auuid') || &subs::random_string_creator(20);

	my $returner = { tables => [], count => {} };
	my $html = '<h2>Now repairing ' . $database . '</h2><br><h4></h4><br><button id="alert_cancel">Hide</button>';
	&Websocket::send('server', { yellow => $html, uuid => $auuid });
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10));
	`mkdir -p $temp_folder` unless -e "$temp_folder";
	my $ndatabase = $temp_folder . '/' . &subs::random_string_creator(21) . '.db';
	my $tdatabase = $temp_folder . '/' . &subs::random_string_creator(20) . '.db';
	`touch $tdatabase`;
	`touch $ndatabase`;
	`sqlite3 $database .schema > $temp_folder/schema.sql`;
	my $backup = `sqlite3 $database ".backup '$tdatabase'"`;

	my $command = `sqlite3 $ndatabase < $temp_folder/schema.sql`;
	my $nsql = Mojo::SQLite->new('sqlite:' . $ndatabase);
	my $ndb = $nsql->db;
	my $tsql = Mojo::SQLite->new('sqlite:' . $tdatabase);
	my $tdb = $tsql->db;
	my $tables = `sqlite3 $ndatabase .tables`;
	@{$returner->{'tables'}} = split ' ', $tables;

	foreach my $table ( @{$returner->{'tables'}} ) {
		my $counter = $tdb->query('select count(*) from ' . $table);
		my $count = $counter->hash->{'count(*)'};
		$returner->{'count'}->{$table} = $count;

		my $existing = $tdb->query('select * from ' . $table)->hashes;
		if (scalar @{$existing} != $count) {
			my $html = '<h2>Now repairing ' . $count . ' ' . $table . '</h2><br><h4></h4><br><button id="alert_cancel">Hide</button>';
			&Websocket::send('server', { yellow => $html, uuid => $auuid });

			my $repairable = [];
			#if ($existing->[-1]->{'app'}) {
				my $repairs = $tdb->query('select distinct(app) from ' . $table)->hashes;
				foreach my $a ( @{$repairs} ) {
					my $ok = $tdb->select($table, undef, { app => $a->{'app'} })->hashes;
					foreach my $okay ( @{$ok} ) {
						my $check = $tdb->select($table, $okay)->hashes;
						if (scalar @{$check} == 0) {
							eval { $ndb->insert($table, $okay) };
						}
						else {

						}

					}
					push @{$repairable}, @{$ok};
				}
			#}

		}
		else {
			my $html = '<h2>Now inserting ' . $count . ' ' . $table . '</h2><br><h4></h4><br><button id="alert_cancel">Hide</button>';
			&Websocket::send('server', { yellow => $html, uuid => $auuid });
			foreach my $i ( @{$tdb->select($table, undef, {})->hashes} ) {
				$ndb->insert($table, $i);
			}
		}
	}
	$backup = `sqlite3 $ndatabase ".backup '$database'"`;
	`shred -u $temp_folder/schema.sql`;
	`shred -u $tdatabase`;
	`shred -u $ndatabase`;
	`rm -R $temp_folder`;
	$c->render(json => $returner);
};

get '/manager/configure/vacuum_app' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $html = '<h2>You are about to delete</h2><h1>' . &subs::format_name($app) . '</h1>
		<h4>This process is irreversible, unless you have backups or whatever!</h4>
		<img src="/images/decipherable/vacuum.png" id="vacuum_app_confirm" app="'. $app . '" class="medium_thumb">
		<img src="/images/make believe/cancel_button.png" id="alert_cancel"  class="medium_thumb">';

	$c->render(text => $html );
};

post '/manager/configure/vacuum_app_confirm' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	&subs::vacuum_app($app);
	&deletion_registration({ table => 'appointments', app => $app, scope => 'vacuum' });
	my $html = '<h1>' . &subs::format_name($app) . ' is gone forever!</h1>
	<h4>I hope you thought long and hard about it!</h4></button><button id="alert_cancel">Close</button>';
	$c->render(text => $html );
};


post '/manager/configure/merge_database' => sub($c) {

	my $filename = $c->param('filename');
	my $action = $c->param('action');
	Mojo::IOLoop->subprocess->run_p(sub {
		my $configuration = {
			file => $filename,
			signatorial => &subs::signatorial_designer(),
			misc_settings => &misc_setting_list()
		};
		my $disposition = &merge_database($c,$configuration);
		my $temporary_file = $disposition->{'temporary_file'};
		#`shred -u $temporary_file` if -e $temporary_file;
		#`shred -u $temporary_file-shm` if -e $temporary_file;
		#`shred -u $temporary_file-wal` if -e $temporary_file;
		$disposition = encode_json $disposition;
	});
	my $disposition = { status => 'working' };
	$c->render(json => $disposition);
};

sub merge_database($c,$configuration) {
	my $filename = $configuration->{'file'};
	my $remote_misc_settings = $configuration->{'misc_settings'};
	my $misc_settings = &misc_setting_list();

	my $deletions = eval { return decode_json $configuration->{'remote'}->{'deletions'} } || [];
	my $port = $config->{'ssh_port'};
	my $auuid = &subs::random_string_creator(10);
	my $colour = $configuration->{'colour'};
	my $html = '<h3>Starting Merge ' . $filename . '</h3>';
	&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
	my ($db,$database) = &subs::database_grabber();
	my $disposition->{'status'} = 'fail';
	my $path = $filename;
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10));
	`mkdir -p $temp_folder` unless -e "$temp_folder";
	my $temporary_file = $temp_folder . '/tmpman.db';
	my $credentials = &subs::db_query('select level,credential from security where level != ? order by server_time DESC', 'padlock');
	my $signatorial = &subs::signatorial_designer();
	my $last_update_time = &subs::db_select('backups', undef, { recipient => $signatorial, signatorial => $configuration->{'signatorial'} })->hashes->[-1];
	$last_update_time = $last_update_time->{'server_time'} || 0;
	$last_update_time = $configuration->{'gimme'} if $configuration->{'gimme'};
	my $creds = $credentials->hashes;
	@{$creds} = grep { $_->{'level'} ne 'padlock' } @{$creds};
	@{$creds} = reverse @{$creds};
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my @updateables;
	my @cache_bucket_updateables;
	foreach my $cred ( @{$creds} ) {
		my $crud = &subs::decrypter($c->session('suds'),$cred->{'credential'});
		my $html = '<h3>Testing Keys</h3>';

		&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
		if ($path =~ /enc$/gi) {
			my $data = `tail $path`;

			my @split_data = split $universal_splitter, $data;

			next unless $data =~ /\Q$universal_splitter/gi;

			$encryption_standard = &subs::decrypter($crud, $split_data[1]);
			`openssl enc -d -k "$crud" -$encryption_standard -pbkdf2 -in $path -out $temporary_file`;

			my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_file);
			if (-s $temporary_file > 5000 &&  eval { $tsql->db } && $tsql->dsn !~ /:$/) {
				my $tdb = $tsql->db;

				my $backups = &subs::db_query('select * from backups order by server_time DESC' )->hashes;

				my $start_server_time = 0;
				if ( scalar @{$backups} > 1 ) {
					$start_server_time = $backups->[1]->{'server_time'};
				}

				my $html = '<h3>Now merging</h3>';
				&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
				$disposition->{'temporary_file'} = $temporary_file;
				my $stats = [];
				my $tables = `sqlite3 $database .tables`;

				my @u = sort split ' ', $tables;
			
				my $count = 0;
				my $universal_settings = {};
				foreach my $q ( @u ) {
					next if grep { $q eq $_ } @{$gb::forbidden->{'tables'}};
					my $query;
					if ($configuration->{'remote'}->{'manager'} ) {
						$query = $tdb->query('select * from ' . $q . ' where server_time >= ?', $last_update_time);
					}
					else {
						$query = $tdb->query('select * from ' . $q);
					}
					my $results = $query->hashes;
					my $results_size = scalar @{$results};
					if ($results_size > 0) {
						my @resulters;
						#&subs::say_it('Now merging ' . $results . ' ' .$q);
						my $progress = $count / scalar @u * 100;
						my $html = '<h3>Now merging ' . scalar @{$results} . ' ' . $q . '</h3><br>';
						&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
						my $percentage = 0;
						my $last_percent = 0;
						my $last_alert = &subs::rightNow();
						my $start_time = $last_alert;
						for (my $n = 0; $n <= $results_size; $n++ ) {
							my $r = $results->[$n];
							my @resulters = @{&subs::db_select($q, undef, { uuid => $r->{'uuid'} })->hashes};
							my $h = $resulters[0];
							$percentage = sprintf("%.2f", $n / $results_size * 100);
							if ($r->{'timestamp'}) {
								if ($percentage >= $last_percent && $results_size > 1 && &subs::rightNow() >= ($last_alert + 250)) {
									my $speed = abs sprintf("%.2f", $n / ($start_time - &subs::rightNow()) * 1000);
									my $remaining = &subs::duration_sayer(((&subs::rightNow() - $start_time) / $percentage) * (100 - $percentage) / 1000);
									my $html = '<b style="font-size:20px">' . $n . ' / ' . scalar @{$results} . ' ' . &subs::format_name($q) . ' ' . $percentage . '% @ ' . $speed . '/sec ' . $remaining . '</b><br>' . 
										'<progress style="width:70%;height:60px;" value="' . $n . '" max="' . $results_size . '"></progress>';
									$last_percent = $percentage;
									$last_alert = &subs::rightNow();
									&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
								}
								if ($q eq 'settings') {
									$universal_settings->{$r->{'app'}} = &subs::settings_grabber({ app => $r->{'app'}, device => $device, benign => 1 }) unless $universal_settings->{$r->{'app'}};
									my $protected = 0;
									foreach my $pr ( @gb::protected ) {
										if ($r->{'app'} eq $pr) {
											$protected = 1;
										}
									}
									#next if $protected == 1;
									unless ($universal_settings->{$r->{'app'}}->{'unique'} eq 'checked' || $protected == 1) {
										push @cache_bucket_updateables, $r->{'app'} unless grep { $_ eq $r->{'app'} } @cache_bucket_updateables;
										my $time_check = &subs::db_query('select * from settings where app=? and setting=? and subsetting = ? and server_time > ? and device = ?', 
											$r->{'app'}, $r->{'setting'}, $r->{'subsetting'}, $r->{'server_time'}, $device)->hashes;
										unless (scalar @{$time_check} > 0) {
											&subs::setting_setter({
												app => $r->{'app'},
												setting => $r->{'setting'},
												value => $r->{'value'},
												server_time => $r->{'server_time'},
												uuid => &subs::random_string_creator(20),
												device => $device,
												subsetting => $r->{'subsetting'}
											});
										}
										$universal_settings->{$r->{'app'}} = &subs::settings_grabber({ app => $r->{'app'}, device => $device });
										next;
									}
								#	push @cache_bucket_updateables, $r->{'app'} unless grep { $_ eq $r->{'app'} } @cache_bucket_updateables;
								#	&subs::setting_setter($r);
									next;
								}
								if ($q eq 'security') {
									if ($r->{'level'} == 1) {
										my $sec_uuid = &subs::db_select('security', ['uuid'], { level => 1 })->hash->{uuid};
										$r->{'level'} = 2 unless $sec_uuid eq $r->{'uuid'};
									}
								}

								if ($configuration->{'remote'}->{'manager'} && $r->{'app'} && $r->{'file'} && $r->{'type'} ne 'snapshot' && $r->{'type'} ne 'backup' && $r->{'account'} ne 'gallery') {
									my $files = eval { return decode_json $r->{'file'} } || [];
									my $h_files = eval { return decode_json $h->{'file'} } || [];
									if (eval { $files->{'f'} }) { $files = [ $files ]; }
									if (eval { $h_files->{'f'} }) { $h_files = [ $h_files ]; }
									if ($q eq 'appointments') {
										$universal_settings->{$r->{'app'}}->{'enc'} = &subs::setting_grabber({ app => $r->{'app'}, device => $device, benign => 1 }) unless $universal_settings->{$r->{'app'}}->{'enc'};
										if ($universal_settings->{$r->{'app'}}->{'enc'} eq 'on' && !$r->{'encryption_standard'} && $r->{'server_time'} > &subs::ago_calc('10m', &subs::rightNow()) && scalar @{$files} > 0) {
											next;
										}
									}
									if (scalar @resulters > 0) {
										foreach my $home_file ( @{$h_files} ) {
											if ($home_file->{'server_time'} <= $r->{'server_time'} ) {
												unless ( grep { $home_file->{'uuid'} eq $_->{'uuid'} } @{$files}) {
												#	&delete_file({ app => $h->{'app'}, app_uuid => $h->{'uuid'}, file_uuid => $home_file->{'uuid'} });
													push @{$files}, $home_file;
													$r->{'server_time'} = &subs::rightNow();
												}
											}
											else {
												unless ( grep { $home_file->{'uuid'} eq $_->{'uuid'} } @{$files}) {
													push @{$files}, $home_file;
												}
											}
										}
									}
									my $file_count = 0;
									foreach my $fi ( @{$files} ) {
										$file_count++;
										foreach my $file_type ( qw/f thumb/ ) {
											next unless $fi->{$file_type};
											my $file = $fi->{$file_type};
											$last_percent = $percentage;
											$percentage = sprintf("%.2f", ($n + ($file_count / scalar @{$files})) / $results_size * 100);


											if ($percentage >= $last_percent && $results_size > 0 && &subs::rightNow() >= ($last_alert + 250)) {
												my $speed = abs sprintf("%.2f", $n / ($start_time - &subs::rightNow()) * 1000);
												my $remaining = &subs::duration_sayer(((&subs::rightNow() - $start_time) / $percentage) * (100 - $percentage) / 1000);
												my $html = '<b style="font-size:20px">' . sprintf("%.2f", ($n + ($file_count / scalar @{$files}))) . ' / ' . scalar @{$results} . ' ' . &subs::format_name($q) . ' ' . $percentage . '% @ ' . $speed . '/sec ' . $remaining .'</b><br>' . 
													'<progress style="width:70%;height:60px;" value="' . $n . '" max="' . $results_size . '"></progress>';
												$last_percent = $percentage;
												$last_alert = &subs::rightNow();
												&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
											}
											my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $file, app => $r->{'app'}, misc_settings => $misc_settings, type => $fi->{'type'} });
											$fi->{'type'} = $type unless $fi->{'type'};
											my $dest = $destination . $asset;

											if (my @h_fil = grep { $_->{'uuid'} eq $fi->{'uuid'} } @{$h_files} ) {
												my $h_file = $h_fil[0];

												my ($hdestination,$hasset) = &subs::file_device_renamer({ file => $h_file->{$file_type}, app => $h->{'app'}, misc_settings => $misc_settings, type => $h_file->{'type'} });
												unless ($asset eq $hasset) {
													if (-e $destination . $hasset) {
														my $hassethoff = $destination . $hasset;
														`shred -u $hassethoff`;
													}
												}

											}



											unless (-e $dest) {
												`mkdir -p $destination`;
												$destination = $destination . $asset;
												if ($configuration->{'remote'}) {
													#$file = url_unescape $file;
													my $url = $configuration->{'remote'}->{'manager'} . '/file_open?timestamp=' . $r->{'server_time'} . '&as_is=yes&file=' . $file;
													my $file_data = $configuration->{'remote'}->{'ua'}->get($url)->result;
													if ($file_data) {
														unless ($file_data->body eq 'not found') {
															my $fd = $file_data->body;
															$fd = decode_base64 $fd;
															write_file($dest,$fd);
														}
													}
												}
											}
											$file = $dest;
											$fi->{$file_type} = $file;
										}
									}
									$r->{'file'} = encode_json $files;
								}

								unless ( grep { $_->{'uuid'} eq $r->{'uuid'} && $_->{'table'} eq $q } @{$deletions} ) {
									if (scalar @resulters == 0) {
										eval { &subs::db_insert($q,$r)};
									}
									else {
										eval { &subs::db_update($q,$r, { uuid => $r->{'uuid'} } ) } unless $h->{'server_time'} >= $r->{'server_time'};
									}
									if ($q eq 'appointments') {
										push @updateables, { app => $r->{'app'}, uuid => $r->{'uuid'} } unless grep { $_->{'app'} eq $r->{'app'} } @updateables;
									}
								}
							}
						}	
					}			
					$disposition->{'disposition'} = $database;
					$disposition->{'status'} = 'succeed';
					my $known_backup = &subs::db_select('backups', undef, { uuid => $backups->[0]->{'uuid'} })->hashes;
					if ($known_backup->[0]->{'reason'} =~ /remote/gi) {
						my $defunct_backups = &subs::db_query('delete from backups where recipient=? and signatorial=? and destination=? and server_time < ? and uuid != ?',
							$backups->[0]->{'recipient'}, $backups->[0]->{'signatorial'}, $backups->[0]->{'destination'}, $backups->[0]->{'server_time'}, $backups->[0]->{'uuid'});
						$disposition->{'backup_uuid'} = $backups->[0]->{'uuid'};
					}
				}
				last;
			}
		}
	}
	my $percentage = 0;
	my $last_percent = 0;
	my $last_alert = &subs::rightNow();
	my $start_time = $last_alert;
	my $results_size = scalar @updateables;
	for (my $n = 0; $n <= scalar @updateables; $n++) {
		my $u = $updateables[$n];
		if ($u->{'app'}) {
			&budget_runner($u->{'app'});
			&Websocket::send($u->{'app'}, { console => 'appointmentDetailGrabber(\'' . $u->{'app'} . '\',\'' . $u->{'uuid'} .'\');' });
			my $header = eval { &subs::appt_header_printer({ app => $u->{'app'} }) };
			$percentage = sprintf("%.2f", $n / $results_size * 100);
			if ($percentage == 0) { $percentage = .0000001; }
			if ($percentage >= $last_percent && $results_size > 1 && &subs::rightNow() >= ($last_alert + 250)) {
				my $speed = abs sprintf("%.2f", $n / ($start_time - &subs::rightNow()) * 1000);
				my $remaining = &subs::duration_sayer(((&subs::rightNow() - $start_time) / $percentage) * (100 - $percentage) / 1000);
				my $html = '<b style="font-size:20px">' . $n . ' / ' . scalar @updateables . ' ' . &subs::format_name('informations') . ' ' . $percentage . '% @ ' . $speed . '/sec ' . $remaining . '</b><br>' . 
					'<progress style="width:70%;height:60px;" value="' . $n . '" max="' . $results_size . '"></progress>';
				$last_percent = $percentage;
				$last_alert = &subs::rightNow();
				&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
			}
			
		}
	}
	&deletion_performer($configuration->{'remote'}->{'deletions'});
	if ( scalar @cache_bucket_updateables > 0 ) {
		my $buc = &subs::cache_get({ app => 'relational', context => 'buckets' });
		my $bub = &subs::cache_get({ app => 'relational', context => 'bubbles' });

		foreach my $cbd ( @cache_bucket_updateables ) {
			delete $buc->{$cbd};
			delete $bub->{$cbd};
		}

		&subs::cache_set({ app => 'relational', context => 'buckets' }, $buc);
		&subs::cache_set({ app => 'relational', context => 'bubbles' }, $bub);


	}


	&Websocket::send('tab', { yellow => 'close', 'close' => 'yes', uuid => $auuid, colour => $colour });
	&subs::say_it('fail') unless $disposition->{'status'} eq 'succeed';
	`shred -u $temporary_file` if -e $temporary_file;
	`shred -u $temporary_file-shm` if -e $temporary_file;
	`shred -u $temporary_file-wal` if -e $temporary_file;
	`rm -R $temp_folder`;
	return $disposition;
}



get '/manager/budget' => sub($c) {
	my $totals = {};
	my $tally = {};
	my $budgets = {};
	my $new_settings = eval { return decode_json $c->param('new_settings') } || {};
	foreach my $ns ( keys %{$new_settings} ) {
		if ($new_settings->{$ns} =~ /[A-Za-z0-9.,-]/gi) {
			if ($ns =~ /_time/gi) {
				$new_settings->{$ns} = &subs::ago_calc($new_settings->{$ns}, &subs::rightNow());
			}
			&subs::setting_setter({ app => 'budget', setting => $ns, value => $new_settings->{$ns} });
		}
		else {
			&subs::setting_deleter({ app => 'budget', setting => $ns });
		}
	}
	my @dollas = qw/amount tax aux total/;
	my @categories = qw/category subcategory/;
	my $categories = { };
	for (my $n = 1; $n <= 100; $n++) {
		my $u = 'subcategory' . $n;
		push @categories, $u;
	#	$categories->{$u} = {};
	}

	my $timestamp = $c->param('timestamp');
	my $time_machine = $c->param('time_machine');

	my $settings = &subs::settings_grabber({ app => 'budget' });
	my $display = $c->param('display') || $settings->{'display'};
	if ($settings->{$display . '_display'} ne '') {
		my $d = eval { decode_json $settings->{$display . '_displays'} };
		foreach my $k ( keys %{$d->{$settings->{$display . '_display'}}} ) {
			$c->param($k, $d->{$settings->{$display . '_display'}}->{$k});
			&subs::setting_setter({ app => 'budget', setting => $k, value => $d->{$settings->{$display . '_display'}}->{$k} });
		}
		$d->{$settings->{$display . '_display'}}->{$display . '_display'} = $settings->{$display . '_display'};
		$settings = &subs::settings_grabber({ app => 'budget' });
	}
	my $display_categorization = $settings->{'display_categorization'};
	my $scope = $settings->{'scope'} || 'hour';
	my $movement = eval { decode_json $c->param('movement') || $settings->{'movement'} } || ['all'];

	my $project = eval { decode_json $c->param('projects') || $settings->{'projects'} } || ['all'];
	my $account = eval { decode_json $c->param('accounts') || $settings->{'accounts'} } || ['all'];
	my $columns = eval { decode_json $c->param('columns') || $settings->{'columns'} } || ['all'];
	my $timeshift = $c->param('timeshift');
	my ($db,$database,$sql) = &subs::database_grabber();
	my @columns = qw/app when occurences occurence_budget duration duration_budget duration_percent total_budget manufacturer item vendor account project amount tax aux total/;
	my $tr = {};

	my @time_scopes = ('next', 'this','last');
	my @time_widths;

	my @time_lengths = qw/minute hour day week month year/;
	if ($settings->{'s_visual'} eq 'allocation') {
		@time_scopes = undef;
		for (my $n = 0; $n <= 366; $n++) {
			push @time_scopes, $n;
		}
		@time_lengths = qw/second minute hour mday month year wday yday isdst/;
		@time_widths = ( 60, 60, 24, 31, 12, 150, 7, 365, 2 );
	}
	else {
		for (my $n = 2; $n <= 30; $n++) { 
			push @time_scopes, $n . 'last' if $n <= 10;
			unshift @time_scopes, $n . 'next' if $n <= 10;
		}
	}


	my ($bt,$t1,$t2);
	if ($settings->{'start_time'} || $settings->{'end_time'}) {
		$bt = $settings->{'start_time'};
		$t2 = $settings->{'end_time'};
		if ($settings->{'start_time'} && !$settings->{'end_time'}) {
			$t2 = &subs::rightNow();
		}
		elsif (!$settings->{'start_time'} && $settings->{'end_time'}) {
			$bt = &subs::rightNow();
		}
	}
	else {
		if ($time_machine) {
			$timestamp = &subs::ago_calc($time_machine,$timestamp);
		}
		if ($timeshift) {
			$timestamp = &subs::ago_calc($timeshift,$timestamp);
		}
		$bt = &{$subs::time_subs->{$scope}}($timestamp); #timestamp at beginning
		$t1 = ($timestamp - $bt);
		$t2 = ($timestamp);
		($bt, $t2) = &father_time({ 
			scope => $scope,
			ts => $settings->{'time_when'},
			lock => $settings->{'s_lock'},
			timestamp => $timestamp 
		});
		if ($settings->{'when_multiplier'}) {
			my $tt = ($t2 - $bt) * $settings->{'when_multiplier'};

				$bt = $t2 - $tt;


		}

	}
	my $total_duration = $t2 - $bt;
	my $last_inventory = $bt;
	my $accountals = &subs::db_query('select distinct(app) from settings where setting=? and value=? order by app', 'pos', 'account');
	my $accounts = $accountals->hashes;

	push @{$accounts}, { app => 'gallery' };
	unshift @{$accounts}, { app => 'all' };

	my $all_accounts = $accounts;
	unless (grep { $_ eq 'all' } @{$account}) {
		my @acco;
		foreach my $a ( @{$account} ) {
			push @acco, grep { $_->{'app'} eq $a } @{$accounts};
		}
	$accounts = \@acco;
	}

	my $acc = {};

	my $all_columns = \@columns;
	if (grep { $_ eq 'all' } @{$columns}) {
		$columns = $all_columns;
	}

	my $projections = &subs::db_query('select distinct(app) from settings where setting=? and value=? order by app', 'pos', 'project');
	my $projects = $projections->hashes;
	unshift @{$projects}, { app => 'all' };
	my $all_projects = $projects;
	unless (grep { $_ eq 'all' } @{$project}) {
		my @proj;
		foreach my $a ( @{$project} ) {
			push @proj, grep { $_->{'app'} eq $a } @{$projects};
		}
		$projects = \@proj;
	}

	my $transactions;
	foreach my $accounting ( @{$accounts}) {
		next if $acc->{$accounting->{'app'}};
		$accounting->{'balance'} = 0;
		my $inventory = &subs::db_query('select * from appointments where app=? and type=? and movement=?', $accounting->{'app'}, 'transaction','inventory');
		my $inv = $inventory->hashes;
		foreach my $i ( @{$inv} ) { 
			if ($i->{'timestamp'} < $timestamp) {
				$accounting->{'balance'} = $i->{'amount'};
				$last_inventory = $i->{'timestamp'};
			}
		}
		my $transactional;
		if ($display eq 'invoices') {
			$transactional = &subs::db_query('select * from appointments where timestamp >= ? and timestamp <= ? order by timestamp', 
				$last_inventory,$t2);
		}
		else {
			$transactional = &subs::db_query('select * from appointments where account = ? and type != ? and timestamp >= ? and timestamp <= ? order by timestamp', 
			$accounting->{'app'}, 'inventory',$last_inventory,$t2);
		}
		push @{$transactions}, @{$transactional->hashes};
		if (grep { $_ eq 'all' } @{$movement}) {

		}
		else {
			my $transactionality = [];
			foreach my $m ( @{$movement} ) {
				push @{$transactionality}, grep { $_->{'type'} eq $m } @{$transactions};
			}
			$transactions = $transactionality;
		}
		$last_inventory = $bt;
		$acc->{$accounting->{'app'}} = $accounting;
	}
	unless ( grep { $_ eq 'all' } @{$project} ) {
		my $tp = [];
		foreach my $tr ( @{$project} ) {
			push @{$tp}, grep { $_->{'project'} eq $tr } @{$transactions};
		}
		$transactions = $tp;
	}

	foreach my $t ( @{$transactions} ) {

		$tally->{$t->{'app'}} = {
			income => [],
			expense => [],
			transfer => [],
			totals => {},
			settings => &subs::settings_grabber({ app => $t->{'app' } })
		} unless $tally->{$t->{'app'}};


		my $pushable = $display_categorization;

		if ($display_categorization eq 'category') {
			$pushable = $tally->{$t->{'app'}}->{'settings'}->{'category'};
			if ($pushable eq '') {
				$pushable = 'unknown';
			}
		}
		elsif ($display_categorization eq undef || $display_categorization eq '') {
			$pushable = $t->{'app'};
		}
		else {
			$pushable = $t->{$display_categorization};
		}

		$tally->{$pushable} = {
			income => [],
			expense => [],
			transfer => [],
			totals => { },
			settings => &subs::settings_grabber({ app => $pushable })
		} unless $tally->{$pushable};

	#	$t->{'movement'} = 'expense' unless $t->{'movement'};
		$acc->{$t->{'account'}}->{'balance'} = $acc->{$t->{'account'}}->{'balance'} + $t->{'total'};
		if ($t->{'timestamp'} >= $bt && $t->{'timestamp'} <= $t2) {
			foreach my $dolla (@dollas) {
				for (my $ca = 0; $ca <= scalar @categories; $ca++) {
					my $cat = $categories[$ca];
					my $cath = $cat;
					if ($tally->{$t->{'app'}}->{'settings'}->{$cat}) {
						my $distinct = $tally->{$t->{'app'}}->{'settings'}->{$cat};
						if (0 == 0) {
							$cath = $distinct;
						}
						unless ($categories->{$cath}->{'info'}->{$distinct}) {
							$categories->{$cath}->{'info'}->{$distinct} = &subs::settings_grabber({ app => $tally->{$t->{'app'}}->{'settings'}->{$cat} });
						}
						if ($ca > 1) {
							$cath = $categories->{$cath}->{'info'}->{'subcategory' . $ca - 1};							
						}
						elsif ($ca > 0) {
							$cath = $categories->{$cath}->{'info'}->{'category'};
						}
						$categories->{$cath}->{$tally->{$t->{'app'}}->{'settings'}->{$cat}}->{'ca'} = $ca;
						if ($dolla eq 'amount') {
							push @{$categories->{$cath}->{$tally->{$t->{'app'}}->{'settings'}->{$cat}}->{'list'}}, $t;
						}
						$categories->{$cath}->{$tally->{$t->{'app'}}->{'settings'}->{$cat}}->{$dolla} += $t->{$dolla};
					}
				}
			}
			if ($t->{'movement'} eq 'income') {
				$t->{'t'} = 'income';
				$t->{'occurences'} = 1;
				$t->{'duration'} = abs $t->{'duration'};
				foreach my $dolla ( @dollas ) {
					$t->{$dolla} = abs $t->{$dolla};
				}
				foreach my $col ( @columns ) {
					$totals->{'income'}->{$col} += $t->{$col};
				}
			}
			elsif ($t->{'movement'} eq 'transfer') {
				$t->{'t'} = 'transfer';
				$t->{'occurences'} = 1;
				$t->{'duration'} = abs $t->{'duration'};
				#unless (grep { $_->{'uuid'} eq $t->{'uuid'} } @{$tally->{$t->{'app'}}->{$t->{'movement'}}}) {
					foreach my $col ( @columns ) {
						$totals->{'transfer'}->{$col} += $t->{$col};
					}
				#}	
			}
			elsif ($t->{'movement'} eq 'expense') {
				$t->{'t'} = 'expense';
				$t->{'movement'} = 'expense';
				$t->{'occurences'} = 1;
				$t->{'duration'} = (abs $t->{'duration'}) * -1;
				foreach my $dolla ( @dollas ) {
					$t->{$dolla} = ($t->{$dolla});# * -1;
				}
				foreach my $col ( @columns ) {
					$totals->{'expense'}->{$col} += $t->{$col};
				}
			}
			foreach my $col ( @columns ) {
				$totals->{'total'}->{$col} += $t->{$col};
				$tally->{$pushable}->{'totals'}->{$t->{'movement'}}->{$col} += $t->{$col};
			}
			push @{$tally->{$pushable}->{$t->{'movement'}}}, $t;
		}
	}
	foreach my $d ( keys %{$gb::transaction_types} ) {
		$totals->{$d}->{'duration_percent'} = abs &subs::percent_formatter(abs $totals->{$d}->{'duration'} / $total_duration);
		$totals->{$d}->{'duration'} = &subs::duration_sayer(abs $totals->{$d}->{'duration'} / 1000);
	}
	foreach my $app ( keys %{$tally} ) {
		foreach my $dr ( keys %{$gb::budget_modes} ) {
			my $budget = &budget_calculator({ 
				app => $app, 
				budget => $tally->{$app}->{'settings'}->{'budget'}, 
				circumstance => $dr,
				scope => $scope, 
				value => $tally->{$app}->{'totals'}->{$dr},
				settings => $tally->{$app}->{'settings'}
			});
			$tally->{$app}->{'budget'}->{$dr} = $budget if $budget->{'eval'};
		}
	}
	if ($display eq 'budgets') {
		$settings->{'budget_displays'} = eval { return decode_json $settings->{'budget_displays'} } || {};
	}
	elsif ($display eq 'statement') {
		$settings->{'statement_displays'} = eval { return decode_json $settings->{'statement_displays'} } || {};
	}
	elsif ($display eq 'daily_sheet') {
		$settings->{'daily_sheet_displays'} = eval { return decode_json $settings->{'daily_sheet_displays'} } || {};
	}
	my $content = $c->render_to_string(
		timestamp => $timestamp,
		accounts => $acc,
		categories => $categories,
		all_accounts => $all_accounts,
		account => $account,
		tally => $tally,
		transactions => $transactions,
		budgets => $budgets,
		all_projects => $all_projects,
		projects => $projects,
		project => $project,
		totals => $totals,
		template => 'budget',
		time_machine => $time_machine,
		scope => $scope,
		movement => $movement,
		timeshift => $timeshift,
		display => $display,
		start => $bt,
		end => $t2,
		total_duration => $total_duration,
		settings => $settings,
		all_columns => $all_columns,
		columns => $columns,
		dollas => \@dollas,
		time_scopes => \@time_scopes,
		time_lengths => \@time_lengths
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'budget', title => 'Budget', contents => $content },$timestamp);
	$c->render(text => $contents );
};

post '/manager/budget/edit' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $circumstance = $c->param('circumstance');
	my $value = $c->param('value');
	my $existing_budgets = $value;
	&subs::cache_delete({ app => $app, context => 'autocalc' });
	foreach my $br ( keys %{$gb::budget_modes} ) {
		my $budget = &budget_calculator({
			app => $app,
			circumstance => $br,
			value => 1,
			scope => 'hour',
			budget => &subs::setting_grabber({ app => $app, setting => 'budget' })
		});

		if ($budget->{'circumstance'} && $budget->{'circumstance'} ne $circumstance) {
			if ($existing_budgets) {
				$existing_budgets = $existing_budgets . ',' . $budget->{'budget'};
			}
			else {
				$existing_budgets = $budget->{'budget'};
			}
		}

	}
	&subs::setting_setter({ app => $app, setting => 'budget', value => $existing_budgets });
	$c->render(json => { existing_budgets => $existing_budgets, new_budget => $value });
};

post '/manager/budget/display/save' => sub($c) {
	my $name = &subs::unformat_name($c->param('name'));
	my $timestamp = $c->param('timestamp');
	my $data = eval { return decode_json $c->param('data') } || [];
	my $type = $c->param('type') || 'statement';

	if (scalar @{$data} == 0) {
		$c->render(json => {});
	}
	my $settings = &subs::settings_grabber({ app => 'budget' });

	my $display_settings = { start_time => $settings->{'start_time'}, end_time => $settings->{'end_time'} };
	foreach my $s ( keys %{$settings} ) {
		if (my @ds = grep { $_ eq $s } @{$data}) {
			$display_settings->{$s} = $settings->{$s};
		}
	}
	my $returner = { data => $data, config => $display_settings };
	
	my $cd = eval { return decode_json $settings->{$type . '_displays'} } || {};
	$cd->{$name} = $display_settings;
	my $jcd = encode_json $cd;
	&subs::setting_setter({ app => 'budget', setting => $type . '_displays', value => $jcd });


	$c->render(json => $returner);
};

post '/manager/budget/display/delete' => sub($c) {
	my $name = &subs::unformat_name($c->param('name'));
	my $display = $c->param('display');
	my $sd = eval { return decode_json &subs::setting_grabber({ app => 'budget', setting => $display . '_displays' }) } || {};
	if ($sd->{$name}) {
		$sd->{$name} = undef;
	}
	my $jsd = encode_json $sd;
	&subs::setting_setter({ app => 'budget', setting => $display . '_displays', value => $jsd });
	$c->render(json => $sd);
};


get '/manager/budget/current_information' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $circumstance = $c->param('circumstance');

	my $ci = &budget_current_information($app,$circumstance,$timestamp);

	$c->render(text => $ci->{'template'});
};

sub budget_current_information($app,$circumstance,$timestamp) {

	my $autocalc = &subs::cache_get({ app => $app, context => 'autocalc', subcontext => $circumstance });
	my $budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
	unless ($autocalc->{$budget}) {
		$autocalc = &Manager::budget_autocalc({ 
			app => $app, 
			circumstance => $circumstance,
		});
	}

	my $ov = sprintf("%.5f", $autocalc->{$budget->{'scope_name'}}->{'result'} - $budget->{'budgeted'});
	my $improvement = {
		difference => $budget->{'value'} - $budget->{'budgeted'},
		overall => eval { &{$gb::budget_modes->{$circumstance}->{'formatted'}}($ov) } || $ov,
		percentage => eval { return &subs::percent_formatter(($budget->{'value'} - $budget->{'budgeted'}) / $autocalc->{$budget->{'scope_name'}}->{'result'}) } || 0,
		overall_percentage => eval { return &subs::percent_formatter(($autocalc->{$budget->{'scope_name'}}->{'result'} - $budget->{'budgeted'}) / $autocalc->{$budget->{'scope_name'}}->{'result'})} || 0
	};
	my $c = app->build_controller;
	my $template = $c->render_to_string(
		template => 'apps/budget_current_information', 
		circumstance => $circumstance, 
		improvement => $improvement,
		budget => $budget, 
		autocalc => $autocalc
	);
	return { template => $template, circumstance => $circumstance, improvement => $improvement, autocalc => $autocalc, budget => $budget };
}

sub budget_runner($app) {
#	Mojo::IOLoop->subprocess->run_p(sub {
		my ($db) = &subs::database_grabber();
		my $scope;
		my $timestamp = &subs::rightNow();
		my $budgets = &subs::db_query('select distinct(app) as app,* from settings where app=? and setting = ? and device = ? and value is not null',$app,'budget', $device)->hashes;
		my $sb = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'special_budgets' }) } || [];
		my @budget_modes = ( @{$sb}, %{$gb::budget_modes} );
		foreach my $b ( @{$budgets} ) {
			my $app = $b->{'app'};
			my @buds = split /,/, $b->{'value'};
			foreach my $circumstance ( keys %{$gb::budget_modes} ) {
				my $cache_budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
				if ($cache_budget->{'scope'}) {
					$scope = $cache_budget->{'scope'};
				}
				foreach my $bud ( @buds ) {
					my @bt = split '/', $bud;
					$scope = $bt[-1];

					my $budget = &Manager::budget_calculator({
						app => $app,
						circumstance => $circumstance,
						scope => $scope,
						budget => $bud
					});
					if ($budget->{'is_scope'} && $circumstance eq $budget->{'circumstance'}) {
						&subs::cache_delete({ app => $app, context => 'template' });
						&subs::cache_set({ app => $app, context => 'budget', subcontext => $circumstance }, $budget);
						my $msg = { 
							app => $app, 
							type => 'budget', 
							budget => {
								colour => $budget->{'colour'},
								circumstance => $budget->{'circumstance'},		
							}
						};
						&Websocket::send('tab', $msg);
						my $ci = &budget_current_information($app,$circumstance,$timestamp);
						&Websocket::send('tab', { 
							type => 'html', 
							content => $ci->{'template'}, 
							selector => '.budget_current_information[app="' . $app .'"][circumstance="' . $circumstance . '"]'
						});

					}
				}
			}
		}
	my $header = &subs::appt_header_printer({ app => $app, timestamp => $timestamp });
#	});
}


sub budget_calculator($data) {
	my $app = $data->{'app'};

	my $circumstance = $data->{'circumstance'};
	my $value = $data->{'value'};
	my $scope = $data->{'scope'};
	my $settings = $data->{'settings'} || &subs::settings_grabber({ app => $app });
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $returner = { app => $app, scope_name => &subs::timespan_widener($scope), value => $value };
	my $budget = $data->{'budget'};
	my $server_time = &subs::rightNow();
	$budget = $data->{'budget'} || &subs::setting_grabber({ 'app' => $app, setting => 'budget' }) unless $data->{'budget'} =~ /[0-9]/gi;
	my @budgets = split ',', $budget;
	foreach my $b ( @budgets ) {
		$returner->{'budget'} = $b;
		my @bud = split '/', $b;
		next unless $bud[-1];
		$bud[-1] = 1 . $bud[-1] unless $bud[-1] =~ /[0-9]/;
		$returner->{'scope_name'} = &subs::timespan_widener($bud[-1]);
		$returner->{'duration'} = &subs::time_abbrev_translator($bud[-1],&subs::rightNow());
		unless ($scope) {
			$returner->{'scope'} = $returner->{'duration'} ;
		}
		else {
			$returner->{'scope'} = &subs::time_abbrev_translator($bud[-1]);
			$returner->{'duration'} = $returner->{'scope'} unless $value;
		}
		unless ($value) {
			my ($db) = &subs::database_grabber();
			my $appts = $data->{'appts'};
			unless ($data->{'appts'}) {
				my $ft_data = { 
					scope => $returner->{'scope_name'},
					ts => 'this',
					lock => $settings->{'s_lock'},
					timestamp => $timestamp 
				};
				my ($bt, $temp_timestamp) = &father_time($ft_data);

				my @params = ( $app, $temp_timestamp, $bt );
				my $query = 'select * from appointments where app = ? and timestamp <= ? and timestamp >= ? ';

				if ($settings->{'s_movement'}) {
					my $bail = 0;
					unless ($settings->{'sss_movement'}) {
						$settings->{'sss_movement'} = eval { return decode_json $settings->{'s_movement'} } || [];
					}
					$bail = 1 if grep { $_ eq 'all' } @{$settings->{'sss_movement'}};
					if ($bail == 0) {
						if (scalar @{$settings->{'sss_movement'}} > 0 ) { $query .= 'and ( '; }
						foreach my $sm ( @{$settings->{'sss_movement'}} ) {
							$query .= 'type = ? ' if scalar @params == 3;
							$query .= ' or type = ? ' if scalar @params > 3;
							push @params, $sm;
						}
						if (scalar @{$settings->{'sss_movement'}} > 0 ) { $query .= ' ) '; }
					}
				}
				$query .= ' order by timestamp DESC';
				$appts = &subs::db_query($query, @params)->hashes;
				$data->{'appts'} = $appts;
			}

			foreach my $appt ( @{$appts} ) {
				if ($circumstance eq 'duration') {
					if ($appt->{'type'} eq 'start' || $appt->{'type'} eq 'record') {
						$appt->{'duration'} = $server_time - $appt->{'timestamp'};
					}
					$value += abs $appt->{'duration'};
				}
				elsif ($circumstance eq 'occurences') {
					$value += 1;
				}
				elsif ($circumstance eq 'total') {
					$value += (abs $appt->{'total'} || 0) if $value;
				}
				else {

				#	$value = 0 unless $value;

				#	$appt->{'measures'} = eval { return decode_json $appt->{'measures'} };
				#	next if scalar @{$appt->{'measures'}} == 0;


				#	$value += 0 if scalar @{$appt->{'measures'}} == 0;
				#	foreach my $m ( @{$appt->{'measures'}} ) {
				#		$value += $m->{$circumstance};
				#	}
				}
			}
			$value = 0 if scalar @{$appts} == 0;
			$returner->{'value'} = $value;
		}
		if ($bud[0] =~ /^\$/gi) {
			my $bu = $bud[0];
			$bu =~ s/\$//gi;
			$returner->{'budgets'}->{'total'} = $b;
			if ($circumstance eq 'total') {
				$returner->{'circumstance'} = 'total';
				$returner->{'budgeted'} = abs $bu;
				$returner->{'formatted_value'} = abs $value;
				last;
			}
		}
		elsif ($bud[0] =~ /[a-zA-Z]/gi) {

			if ($circumstance eq 'duration') {
				$returner->{'budgets'}->{'duration'} = $b;
				$returner->{'circumstance'} = 'duration';
				$bud[0] = 1 . $bud[0] unless $bud[0] =~ /[0-9]/;
				$returner->{'budgeted'} = &subs::time_abbrev_translator($bud[0],&subs::rightNow());
				if ($value != 0) {
					$returner->{'formatted_value'} = &subs::duration_sayer($value / 1000);
				}
				else {
					$returner->{'formatted_value'} = 0;
				}
				last;
			}
			elsif ( (scalar grep { $circumstance eq $_ } keys %{$gb::budget_modes}) == 0 ) {
				$returner->{'budget_name'} = $bud[0];
				$returner->{'budget_name'} =~ s/[0-9.]//gi;
				next unless $returner->{'budget_name'} eq $circumstance;
				$returner->{'budgeted'} = $bud[0];
				$returner->{'budgets'}->{$circumstance} = $b;
				$returner->{'circumstance'} = $circumstance;

				$returner->{'budgeted'} =~ s/[^0-9.]//gi;
				$returner->{'formatted_value'} = $value;
				last;
			}
		}
		else {
			$returner->{'budgets'}->{'occurences'} = $b;

			if ($circumstance eq 'occurences') {
				$returner->{'circumstance'} = 'occurences';
				$returner->{'budgeted'} = $bud[0];
				$returner->{'formatted_value'} = abs $value;
				last;
			}
		}
	}

	if ($returner->{'budget'} && $returner->{'budgeted'}) {
		if ($returner->{'duration'} eq $returner->{'scope'} && $returner->{'circumstance'} eq $circumstance) {
			$returner->{'is_scope'} = 'yes';
		}

		$returner->{'expected'} = sprintf("%.19f",$returner->{'budgeted'} / $returner->{'duration'});
		$returner->{'formatted_budgeted'} = sprintf("%.3f", $returner->{'expected'} * $returner->{'scope'}) . '/' . $returner->{'scope_name'};
		$returner->{'formatted_budgeted'} = &subs::duration_sayer($returner->{'expected'} * $returner->{'duration'} / 1000) . '/' . $returner->{'scope_name'} if $circumstance eq 'duration';
		$returner->{'actual'} = sprintf("%.19f", $returner->{'value'} / $returner->{'scope'});
		$returner->{'threshold'} = $returner->{'expected'} * $returner->{'scope'};
		$returner->{'eval'} = $returner->{'actual'} - $returner->{'expected'};
		$returner->{'timestamp'} = $timestamp;
		if ($scope ne $returner->{'scope_name'} && $returner->{'circumstance'} eq $circumstance) {
			$returner->{'is_scope'} = 'no';
			my $scoped = $returner->{'scope'} / &subs::time_abbrev_translator(1 . $scope ,&subs::rightNow());
			$returner->{'expected'} = $returner->{'expected'} * $scoped;
			$returner->{'actual'} = $returner->{'actual'} * $scoped;
			$returner->{'expected'} = sprintf("%.19f",$returner->{'budgeted'} / ( $returner->{'duration'} * $scoped));
			$returner->{'actual'} = sprintf("%.19f", ($returner->{'value'} * $scoped) / ($returner->{'scope'} * $scoped));
		}
		$returner = &budget_status_maker($returner);
	}
	else {
	#	$returner = {};
	}
	return $returner;
}


sub budget_status_maker($returner) {
	my $status;
	if ($returner->{'actual'} < $returner->{'expected'} - ( $returner->{'expected'} * .0000000001) && $returner->{'actual'} >= $returner->{'expected'} - ($returner->{'expected'} * .2)) {
		$status = 'budgeted';
		$returner->{'synth'} = 'play -v .3 "| sox -n -p synth .51 sine 391 && play | sox -n -p synth .51 triangle 500"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'} * 2) {
		$status = 'abused';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 pinknoise 1125 && play | sox -n -p synth .51 whitenoise 100"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'} * 1.2) {
		$status = 'burnt_out';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 square 125 && play | sox -n -p synth .51 square 100"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'}) {
		$status = 'accomplished';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 pluck 329.64 && play | sox -n -p synth .26 pluck 391.99 && play | sox -n -p synth .26 pluck 369.99 && play | sox -n -p synth .26 pluck 293.672"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'} / 4) {
		$status = 'abandoned';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 triangle 261.64 && play | sox -n -p synth .51 triangle 261.64"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'} / 2) {
		$status = 'neglected';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 saw 349.23 && play | sox -n -p synth .26 saw 329.63 && play | sox -n -p synth .26 saw 415.3 && play | sox -n -p synth .26 saw 439.99"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'}) {
		$status = 'achievable';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 pluck 293.67 && play | sox -n -p synth .26 pluck 349.23 && play | sox -n -p synth .26 pluck 349.23 && play | sox -n -p synth .26 pluck 311.13"';
	}
	$returner = &{$gb::budget_statuses->{$status}->{'notifier'}}($returner);

	return $returner;
}

get '/manager/budget/autocalc' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $circumstance = $c->param('circumstance');
	&subs::cache_delete({ app => $app, context => 'autocalc', subcontext => $circumstance });
	&subs::cache_delete({ app => $app, context => 'budget', subcontext => $circumstance });
	my $returner = &budget_autocalc({ 
		app => $app, 
		circumstance => $circumstance,
	});
	$c->render(json => $returner );
};

sub budget_autocalc($data) {
	my $app = $data->{'app'};
	my $scope = $data->{'scope'};
	my $circumstance = $data->{'circumstance'};
	my $timestamp = $data->{'timestamp'};
	my $server_time = &subs::rightNow();
	if (my $cache = &subs::cache_get({ app => $app, context => 'autocalc', subcontext => $circumstance })) {
		return $cache;
	}
	my $returner = {
		minute => { symbol => 'm' },
		hour => { symbol => 'h' },
		day => { symbol => 'd' },
		week => { symbol => 'w' },
		month => { symbol => 'M' },
		year => { symbol => 'y' },
	};
	my ($db) = &subs::database_grabber();
	my $settings = &subs::settings_grabber({ app => $app });
	my $appts = $data->{'appts'} || &subs::db_query('select * from appointments where app = ? order by server_time DESC LIMIT 1000', $app)->hashes;
	if ($scope && $timestamp) {
		my $duration = &subs::time_abbrev_translator(1 . $scope, $server_time);
		my $beginning = $server_time - ( $duration * ($settings->{'s_scope_count'} || 1) );
		@{$appts} = grep { $_->{'timestamp'} > $beginning } @{$appts};
	#	@{$appts} = grep { $_->{'timestamp'} >= $timestamp - $duration && $_->{'timestamp'} <= $timestamp + $duration } @{$appts};
		my $new_returner = {};
		foreach my $re ( keys %{$returner} ) {
			$new_returner->{$re} = $returner->{$re} if $re eq $scope;
		}
	#	$returner = $new_returner;
		
	}

	foreach my $r ( keys %{$returner} ) {
		$returner->{$r}->{'duration'} = &subs::time_abbrev_translator(1 . $returner->{$r}->{'symbol'}, $server_time);
		$returner->{$r}->{'close'} = [];
	}

	$returner->{'data'} = {};
	foreach my $appt ( @{$appts} ) {
		foreach my $r ( keys %{$returner} ) {
			my @close = grep { $appt->{'timestamp'} + ($returner->{$r}->{'duration'} / 2) >= $_->{'timestamp'}
				&& $appt->{'timestamp'} - ($returner->{$r}->{'duration'} / 2) <= $_->{'timestamp'} } @{$appts};
			if ($circumstance eq 'occurences') {
				push @{$returner->{$r}->{'close'}}, scalar @close;
			}
			elsif ($circumstance eq 'duration') {
				my $total = 0;
				foreach my $cl (@close) {
					$total += abs $cl->{'duration'};
				}

				push @{$returner->{$r}->{'close'}}, $total;
			}
			elsif ($circumstance eq 'total') {
				my $total = 0;
				foreach my $cl (@close) {
					$total += $cl->{'total'};
				}
				push @{$returner->{$r}->{'close'}}, $total;
			}
			else {
				next unless $appt->{'measures'};
				unless ($appt->{'measured'}) { 
					$appt->{'measures'} = eval { return decode_json $appt->{'measures'} } || [];
					$appt->{'measured'} = 'yes';
				}
				my $total = 0;
				foreach my $cl (@close) {
					next unless $cl->{'measures'};
					unless ($cl->{'measured'}) { 
						$cl->{'measures'} = eval { return decode_json $cl->{'measures'} } || [];
						$cl->{'measured'} = 'yes';
					}
					foreach my $m ( @{$cl->{'measures'}} ) {
						if ($m->{$circumstance}) {
							$total += $m->{$circumstance};
						}
					}
				}
				push @{$returner->{$r}->{'close'}}, $total;
			}
		}
	}

	foreach my $r ( keys %{$returner} ) {
		my $total = 0;
		foreach my $close ( @{$returner->{$r}->{'close'}} ) {
			$total += $close;
		}
		if ($circumstance eq 'occurences') {
			$returner->{$r}->{'result'} = ($total / scalar @{$returner->{$r}->{'close'}});
			$returner->{$r}->{'formatted_result'} = sprintf("%.3f", $returner->{$r}->{'result'}) . '/' . $r if $circumstance eq 'occurences';
		}
		elsif ($circumstance eq 'total') {
			$returner->{$r}->{'result'} =~ /^([-])/gi;
			$returner->{$r}->{'formatted_result'} = &subs::price_formatter( $returner->{$r}->{'result'}) . '/' . $returner->{$r}->{'symbol'};
		}
		elsif ($circumstance eq 'duration') {
			$returner->{$r}->{'result'} = ($total / scalar @{$returner->{$r}->{'close'}});
			$returner->{$r}->{'formatted_result'} = &subs::duration_sayer($returner->{$r}->{'result'} / 1000) . '/' . $r;
		}
		else {
			$returner->{$r}->{'result'} = ($total / scalar @{$returner->{$r}->{'close'}});
			$returner->{$r}->{'formatted_result'} = sprintf("%.3f", $returner->{$r}->{'result'}) . $circumstance . '/' . $r;
		}
		undef $returner->{$r}->{'close'};
	}

	$returner->{'data'}->{'circumstance'} = $circumstance;
	$returner->{'data'}->{'app'} = $app;
	$returner->{'data'}->{'formatted_app'} = &subs::format_name($app);
	$returner->{'data'}->{'timestamp'} = &subs::rightNow();

	&subs::cache_set({app => $app, context => 'autocalc', subcontext => $circumstance }, $returner);
	return $returner;
}

get '/manager/notifications/list' => sub($c) {
	my $content = &notification_grabber({});
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'notifications', title => 'Notifications', contents => $content },$c->param('timestamp'));
	$c->render(text => $contents);
};

sub notification_grabber($data) {

	my $timestamp = &subs::rightNow();
	my @notifications;
	my $settings = &subs::settings_grabber({ app => 'notifications', benign => 1 });
	my $notifications = { titles => [], apps => [], settings => $settings };
	my ($db,$database,$sql) = &subs::database_grabber();
	my $q = &subs::db_query('select * from notifications order by timestamp DESC LIMIT 100');
	my $more_notifications = $q->hashes;
	if ($device eq 'mobile') {
		my $nl = `termux-notification-list`;
		my $notifications = decode_json($nl);
		foreach my $n ( @{$notifications} ) {
			if ($n->{'title'} && !grep { $_->{'id'} eq $n->{'id'} } @{$more_notifications}) {
				my $ts = &subs::ago_calc($n->{'when'},$timestamp);
				&subs::db_insert('notifications', {
					id => $n->{'id'},
					app => &subs::unformat_name($n->{'title'}),
					timestamp => $ts,
					tag => $n->{'tag'},
					message => $n->{'content'},
					title => $n->{'title'},
					key => $n->{'key'},
					image => "/images/make believe/face.png",
					uuid => &subs::random_string_creator(20)
				});
			}
		}
	}

	$q = &subs::db_query('select * from notifications order by timestamp DESC');
	$more_notifications = $q->hashes;

	foreach my $m ( @{$more_notifications}) {
		push @{$notifications->{'apps'}}, $m->{'app'} unless grep { $m->{'app'} eq $_ } @{$notifications->{'apps'}};
	}

	if ($settings->{'filter'} && $settings->{'filter'} ne '' && $settings->{'filter'} ne 'all') {
		@{$more_notifications} = grep { $_->{'app'} eq $settings->{'filter'} } @{$more_notifications};
	}
	if ($settings->{'search'} && $settings->{'search'} ne '') { 
		my $search = $settings->{'search'};
		@{$more_notifications} = grep { $_->{'app'} =~ /\Q$search/gi ||  $_->{'message'} =~ /\Q$search/gi } @{$more_notifications};
	}
	if ($data->{'scroll'} eq 'down') {
		my @now_notifications = splice @{$more_notifications}, $data->{'position'} * 100;
		@{$more_notifications} = @now_notifications;
		
	}
	unless ($data->{'delete'}) {
		splice @{$more_notifications}, 100;
	}
	my $content;

	my $c = app->build_controller;
	foreach my $m ( @{$more_notifications}) {
		$notifications->{'content'} .= $c->render_to_string(
			n => $m,
			template => 'notification',
		);
	}
	$notifications->{'list'} = $more_notifications;
	return $notifications;
}

post '/manager/notifications/remove' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $tag = $c->param('tag');
	my $title = $c->param('title');
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my $server_time = $c->param('server_time');
	my $scope = $c->param('scope');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $deletions = [];
	if ($tag) {
		if ($device eq 'mobile') {
			`termux-notification-remove $tag`;
		}
	}
	if ($scope eq 'all') {
		my $notifications = &notification_grabber({ delete => 'yes' });
		foreach my $n ( @{$notifications->{'list'}} ) { 
			&subs::db_delete('notifications', { uuid => $n->{'uuid'} });
			push @{$deletions}, $n->{'uuid'};
			&deletion_registration({ table => 'notifications', uuid => $n->{'uuid'}, server_time => $n->{'server_time'} });
		}
	}
	else {
		&subs::db_delete('notifications', { timestamp => $timestamp, title => $title, uuid => $uuid });
		&deletion_registration({ table => 'notifications', uuid => $uuid, server_time => $server_time });
		push @{$deletions}, $uuid;
	}
	$c->render(json => $deletions );
};

get '/manager/notifications/filter' => sub($c) {
	my $app = $c->param('app');
	&subs::setting_setter({ app => 'notifications', setting => 'filter', value => $app });
	my $returner = notification_grabber({});
	$c->render(json => $returner);
};

get '/manager/notifications/search' => sub($c) {
	my $search = $c->param('search');
	&subs::setting_setter({ app => 'notifications', setting => 'search', value => $search });
	my $returner = &notification_grabber({});
	$c->render(json => $returner);
};

get '/manager/notifications/scroll' => sub($c) {
	my $returner = &notification_grabber({ scroll => 'down', position => $c->param('position') });
	$c->render(json => $returner);
};

get '/manager/configure/backup_now' => sub($c) {

	unless ($c->param('reason')) {
		$c->param('reason' => 'backup');
	}
	else {
		my $remote_ip = $c->tx->remote_address;
	}
	my $disposition = &subs::backup_now($c);
	$c->render(json => $disposition);
};

post '/manager/configure/delete_backup' => sub($c) {
	
	my $backup = $c->param('filename');
	if (-e $backup) {
		`shred -u $backup`;
	}
	$c->render(text => 'backup deleted');
};


get '/manager/appointment_viewer' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $readable = $c->param('readable');
	my $timeshift = $c->param('timeshift');
	my $scope = $c->param('scope');
	my $sorts = $c->param('sorts');
	my $time_machine = $c->param('time_machine');
	my $filter = $c->param('filter');
	my $account = $c->param('account');
	my $project = $c->param('project');
	my $appt_view_toggle = $c->param('appt_view_toggle');
	my $layout = $c->param('layout');
	my $stats = eval { return decode_json $c->param('stats') } || {};
	my $timeshift_max;
	my $chosen_appts;
	if ($c->param('appts')) {
		$chosen_appts = decode_json $c->param('appts');
	}
	else { $chosen_appts = \@appointments; }
	if ($time_machine) {
		$timestamp = &subs::ago_calc($time_machine,$timestamp);
	}
	if ($timeshift && $timeshift =~ /[0-9]/) {
		$timestamp = &subs::ago_calc($timeshift,$timestamp);
		$timestamp = $timestamp - ($timeshift);
	}
	my $period = &{$subs::time_subs->{$scope}}($timestamp) if eval {&{$subs::time_subs->{$scope}}($timestamp)};

	my $appts = &log_reader({ 
		appts => $chosen_appts, 
		project => $project, 
		account => $account, 
		scope => $scope, 
		sorts => $sorts, 
		'timestamp' => $timestamp, 
		filter => $filter,
		appt_view_toggle => $appt_view_toggle,
		view => 'appointment_viewer',
		stats => $stats
	});
	$appts->{'__specs'}->{'layout'} = $layout;
	if ($appts->{'updateable'} eq 'no') {
		$c->render(json => { updateable => 'no', '__specs' => $appts->{'__specs'} });
		$c->rendered;
		return;
	}
	my @results;
	my @log_watch;
	foreach my $a (@{$chosen_appts}) {
		next if $appts->{$a}->{'setting'}->{'visible'} eq 'unchecked';



		foreach my $type (qw/list/) {
			last unless $appts->{$a}->{$type};
			if (@{$appts->{$a}->{$type}} && scalar @{$appts->{$a}->{$type}} > 0) {
				if (my @present = grep { $_->{'timestamp'} > $period && $_->{'timestamp'} < ($timestamp + ($timestamp - $period)) } @{$appts->{$a}->{$type}}) {
					$appts->{$a}->{$scope . '_occurrences'} = scalar @present;

					foreach my $p (@present) {

						$p->{'formatted_name'} = &subs::format_name($p->{'app'});

						my $point = $p->{'timestamp'} - $period;
						my $total = $timestamp - $period;
						my $percent = $point / $total;
						$appts->{$a}->{$scope . '_percent'} = $percent;
						if ($p->{'duration'}) {
							my $point = $p->{'timestamp'} - $p->{'duration'} - $period;
							my $total = $timestamp - $period;
							my $percent = $point / $total;
							$p->{$scope . '_start_percent'} = $percent;
						}


						$p->{$scope . '_percent'} = $percent;
						$p->{$scope . '_occurrences'} = $appts->{$a}->{$scope . '_occurrences'};
						$p->{'start_notes'} = undef;
						$p->{'end_notes'} = undef;

						if ($p->{'type'} eq 'transaction') {
							if ($p->{'amount'} && !$p->{'tax'} && $p->{'total'} > $p->{'amount'}) {
								$appts->{$a}->{$scope . '_tax' } += sprintf("%.2f",($p->{'amount'} * 1.13) - $p->{'amount'});
							}
							$appts->{$a}->{$scope . '_tax' } += sprintf("%.2f", ($p->{'tax'})) if $p->{'tax'};
							$appts->{$a}->{$scope . '_total' } += unformat_number($p->{'total'} || $p->{'amount'}) if $p->{'total'} || $p->{'amount'};
							$appts->{$a}->{$scope . '_amount' } += unformat_number($p->{'amount'}) if $p->{'amount'};
						}
						$appts->{$a}->{$scope . '_quantity' } += $p->{'quantity'} if $p->{'_occurrences'};
						$appts->{$a}->{'since'} = ($timestamp - $p->{'timestamp'}) / 1000;
						if ($p->{'type'} =~ 'start|pause|record' ) { 
							$appts->{$a}->{'setting'}->{'status'} = $p->{'type'};
							$appts->{$a}->{$scope . '_duration'} += $timestamp - $p->{'timestamp'};
							$appts->{$a}->{'formatted_since'} = &subs::duration_sayer(($timestamp - $p->{'timestamp'}) / 1000);

						}
						else {
							$appts->{$a}->{$scope . '_duration'} += abs $p->{'duration'} || $appts->{$a}->{'setting'}->{$scope . '_duration'} if (abs $p->{'duration'} || $appts->{$a}->{'setting'}->{$scope . '_duration'});
							$appts->{$a}->{'formatted_since'} = &subs::duration_sayer(($timestamp - $appts->{$a}->{'last_reset'}) / 1000) if $appts->{$a}->{'last_reset'};
						}
						$appts->{$a}->{'formatted_since'} = 'in ' . $appts->{$a}->{'formatted_since'} if ($timestamp - $p->{'timestamp'}) < 0;

						$appts->{$a}->{$scope . '_timestamp'} = $p->{'timestamp'};

						if ($sorts eq 'log') {
							push @{$appts->{'__logwatch'}}, $p;
						}
						foreach my $ts (keys %{$subs::time_subs}) {
							if ($type eq 'list') {
								$appts->{'__stash'}->{$ts . '_total_' . $sorts} += (unformat_number($p->{'total'} || $p->{'amount'})) if $p->{'total'} || $p->{'amount'};
							}
							else {
								$appts->{'__stash'}->{$ts . '_total_' . $sorts} += -(unformat_number($p->{'total'} || $p->{'amount'})) if $p->{'total'} || $p->{'amount'};
							}

						}
						$appts->{$a}->{$scope . '_duration_percent'} =  ($appts->{$a}->{$scope . '_duration'} / abs &{$subs::time_subs->{$scope}}(0)) * 100 if $appts->{$a}->{$scope . '_duration'};
						$appts->{$a}->{$scope . '_duration_percent'} = sprintf("%.2f",$appts->{$a}->{$scope . '_duration_percent'}) . "%" if ($appts->{$a}->{$scope . '_duration_percent'} );
					}
				}

			}
			$appts->{$a}->{$scope . '_formatted_duration'} = &subs::duration_sayer($appts->{$a}->{$scope . '_duration'} / 1000) if $appts->{$a}->{$scope . '_duration'};
		}
	};
	$appts->{'__specs'}->{'pseudonyms'} = &pseudonym_maker('viewer','');
	my $clothesline = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'clothesline' }) } || [];
	if ($c->param('background_images') eq 'on') {
		$appts->{'__specs'}->{'backgrounds'} = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
		$appts->{'__specs'}->{'background'} = $appts->{'__specs'}->{'backgrounds'}->[rand(scalar @{$appts->{'__specs'}->{'backgrounds'}})];
	}
	$c->render(
		json => {
			appts => $appts,
			timestamp => $timestamp,
			newsstand => &subs::statement_grabber($appts),
			clothesline => $clothesline
		}
	);
};

get '/manager/tasks' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $tasks = &subs::task_grabber($app);
	$c->render(json => $tasks);
};


post '/manager/tasks' => sub ($c) {
	my $papp = &subs::unformat_name($c->param('papp'));
	my $app = &subs::unformat_name($c->param('app'));

	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $name = $c->param('name');
	my $value = $c->param('value');
	my $colour = $c->param('colour');
	my $tasks = &subs::task_writer($c,{
		papp => $papp,
		app => $app,
		timestamp => $timestamp,
		uuid => $uuid,
		name => $name,
		value => $value,
		colour => $colour,
		project => $c->param('project'),
		account => $c->param('account'),
		movement => $c->param('movement')
	});

	my $tasks_json = encode_json $tasks;
	&subs::setting_setter({ app => $app, setting => 'tasks', value => $tasks_json });
	$c->render(json => &subs::task_grabber($papp));

};


post '/manager/tasks/delete' => sub($c) {
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my $papp = $c->param('papp');
	my $tasks_json = &subs::setting_grabber({ app => $app, setting => 'tasks' }) || '[]';
	my $tasks =  decode_json $tasks_json;
	@{$tasks} = grep { $_->{'uuid'} ne $uuid } @{$tasks};
	$tasks_json = encode_json $tasks;
	&subs::setting_setter({ app => $app, setting => 'tasks', value => $tasks_json });
	$c->render(json => &subs::task_grabber($papp));
};

get '/manager/appointment_measures' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');

	my $appts = &log_reader({ app => $app, view => 'centre_view' });
	$appts->{$app}->{'settings'}->{'ia'} = eval { return decode_json $appts->{$app}->{'setting'}->{'ia'} } || {};




	$appts->{$app}->{'setting'}->{'app_measures'} = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	$c->render(
		template => 'apps/app_measures',
		settings => $appts->{$app}->{'setting'},
		a => $app,
		appts => $appts
	);
};

get '/manager/appointment_details' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');
	my $time_machine = $c->param('time_machine');
	my $timeshift = $c->param('timeshift');
	my $scope = $c->param('scope');
	my $sorts = $c->param('sorts');
	my $filter = $c->param('filter');
	my $uuid = $c->param('uuid');

	if ($time_machine) {
		$timestamp = &subs::ago_calc($time_machine,$timestamp);
	}
	if ($timeshift) {
		$timeshift = &subs::time_abbrev_translator($timeshift);
		$timestamp = $timestamp - ($timeshift);
	}
	my $appts = &log_reader({ uuid => $uuid, app => $app, filter => $filter, timeshift => $timeshift, timestamp => $timestamp, sorts => $sorts, scope => $scope, view => 'appointment_details' });
	my @details;
	my $pseudonyms = &pseudonym_maker('viewer', '');
	my $settings = $appts->{$app}->{'setting'};
	$settings->{'home_plate'} = eval { return decode_json $settings->{'home_plate'} } || {};
	push @details, @{$appts->{$app}->{'list'}} if $appts->{$app}->{'list'};
	my $sum = scalar @details;
	foreach my $d ( @details ) {
		if ($d->{'files'}) {

			$sum += scalar @{$d->{'files'}};
		}
	}


	#splice @details, 10;



	my $models = &subs::db_query('select * from model where app=? order by timestamp desc', $app)->hashes;
	my $options = &subs::db_query('select * from option where app=? order by timestamp desc', $app)->hashes;
	my $option_categories = &subs::db_query('select * from option_category where app=? order by timestamp desc', $app)->hashes;
	foreach my $mo ( @{$models}, @{$options} ) {
		$mo->{'characteristics'} = eval { return decode_json $mo->{'characteristics'} } || [];
		if (my @oc = grep { $_->{'name'} eq 'option_category' } @{$mo->{'characteristics'}}) {
			$mo->{'option_category'} = $oc[0]->{'value'};
		}
		else {
			$mo->{'option_category'} = 'uncategorized';
		}
	}

	my $home_plate = &subs::setting_grabber({ app => 'me', setting => 'home_plate' });
	my $hp = eval { return decode_json $home_plate } || {};
	foreach my $l ( @details ) {
		if ($l->{'data'}) {
			$l->{'data'} = eval { return decode_json $l->{'data'} } || $l->{'data'};
		}
		if ($l->{'duties'}) {
			$l->{'duties'} = eval { return decode_json $l->{'duties'} } || [];
		}
		$l->{'options'} = eval { return decode_json $l->{'options'} } || [];
		$l->{'model'} = eval { return decode_json $l->{'model'} } || {};
		$l->{'model'}->{'home_plate'} = eval { return decode_json &subs::setting_grabber({ app => &subs::unformat_name($l->{'model'}->{'name'}), setting => 'home_plate' }) } || {};
		my ($continental,$src);
		if ($l->{'source_uuid'}) {
			$continental = &subs::db_query('select * from continent where (app = ? and uuid like ?) or uuid like ? order by server_time',$app, $l->{'uuid'} . '%',$l->{'source_uuid'} . '%')->hashes;
			my $source = &subs::db_select('appointments', undef, { uuid => $l->{'source_uuid'} })->hashes->[0];
			$l->{'src'} = $source;
		}
		else {
			$continental = &subs::db_query('select * from continent where app = ? and uuid like ? order by server_time',$app, $l->{'uuid'} . '%')->hashes;
		}
		$l->{'measures'} = eval { return decode_json $l->{'measures'} } || [];
		my @p = grep { $_->{'name'} eq $l->{'type'} } @{$pseudonyms};
		$l->{'total_distance'} = 0;
		my @last_visitor;
		foreach my $continent ( @{$continental} ) { 
			if ($continent->{'latitude'}) {
				my $radius = 6372.8;
				my @home_plate;
				if ($l->{'model'}->{'home_plate'}->{'latitude'} && $l->{'model'}->{'home_plate'}->{'longitude'}) {
					my $hp = $l->{'model'}->{'home_plate'};
					@home_plate = (deg2rad($hp->{'longitude'}), deg2rad(90 - $hp->{'latitude'}));
				}
				elsif ($settings->{'home_plate'}->{'latitude'} && $settings->{'home_plate'}->{'longitude'}) { 
					my $hp = $settings->{'home_plate'};
					@home_plate = (deg2rad($hp->{'longitude'}), deg2rad(90 - $hp->{'latitude'}));
				}
				else {
					@home_plate = (deg2rad($hp->{'longitude'}), deg2rad(90 - $hp->{'latitude'}));
				}
				my @visitor = (deg2rad($continent->{'longitude'}), deg2rad(90 - $continent->{'latitude'}));
				my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $radius));
				if ($last_visitor[0]) {
					my $sum_distance = great_circle_distance(@visitor, @last_visitor, $radius);
					$l->{'total_distance'} += sprintf("%.3f", $sum_distance);
				}


				@last_visitor = @visitor;
				my $metres = $distance;

				push @{$l->{'distance'}}, { server_time => $continent->{'server_time'}, distance => sprintf("%2f", $metres), uuid => $continent->{'uuid'}, timestamp => $continent->{'server_time'} };

			}
		}
		$l->{'pseudonym'} = $p[0];
		if ($l->{'type'} eq 'website') {
			$l->{'content'} = &subs::db_select('websites', [ 'internal_url' ], { timestamp => $l->{'timestamp'} })->{content}->{hash};
		}
	}

	$c->render(
		template => 'appointment_details',
		appts => $appts,
		a => $app,
		details => \@details,
		settings => $settings,
		models => $models,
		options => $options,
		option_categories => $option_categories,
		device => $device,
		remote_machines => &subs::db_select('remote_machines', undef, { connection => 'active' })->hashes
	);
};

post '/manager/delete_duty' => sub($c) {


	my $duuid = $c->param('duuid');
	my $server_time = $c->param('server_time');
	my $app_uuid = $c->param('app_uuid');
	my $app = &subs::unformat_name($c->param('app'));

	my $appt = &subs::db_select('appointments', undef, { uuid => $app_uuid, app => $app })->hashes->[0];
	my $duties = eval { return decode_json $appt->{'duties'} } || [];
	@{$duties} = grep { $_->{'duuid'} ne $duuid } @{$duties};

	my $jduties = encode_json $duties;

	&subs::db_update('appointments', { duties => $jduties, server_time => &subs::rightNow() }, { app => $app, uuid => $appt->{'uuid'} });
	$c->render(json => { duuid => $duuid });
};

post '/manager/configure/home_plate/save' => sub($c) {
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $app_uuid = $c->param('uuid');

	my $continent = &subs::db_select('continent', undef, { uuid => $uuid })->hashes->[0];
	my $homeplate = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'home_plate' }) } || {};

	my $data = {
		latitude => $continent->{'latitude'},
		longitude => $continent->{'longitude'},
		accurancy => $continent->{'accuracy'},
		uuid => $uuid
	};

	my $jplate = encode_json $data;
	&subs::setting_setter({ app => $app, setting => 'home_plate', value => $jplate });
	$c->render(json => $jplate);
};


post '/manager/configure/manual_home_plate' => sub($c) {
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $device = $c->param('device');
	my $app = $c->param('app');

	my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'home_plate', device => $device }) } || {};
	$home_plate->{$setting} = $value;

	my $jplate = encode_json $home_plate;
	&subs::setting_setter({ app => $app, device => $device, setting => 'home_plate', value => $jplate });
	$c->render(json => $home_plate);
};

post '/manager/palette' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $duty = $c->param('duty');
	my $value = $c->param('value');
	my $file = $c->param('file');
	my $type = $c->param('type');
	my $uuid = $c->param('uuid');
	my $returner = {};
	my $job = { ext => '.png' };
	my $image;
	my $duties = eval { return decode_json $c->param('duties') } || [];
	my $sd = &subs::home($config->{'start_dir'}) . &subs::random_string_creator() . $job->{'ext'};
	if ($type eq 'snapshot') {
	}
	else {
		$job = &rock_and_roll($c);
		my $data = $job->{'data'};
		$sd = &subs::home($config->{'start_dir'}) . &subs::random_string_creator() . $job->{'ext'};
		chomp $data;
		write_file($sd, $data);

	}
	my $original = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes;
	my $files = eval { return decode_json $original->[0]->{'file'} } || [];
	foreach my $d ( @{$duties} ) {
		$duty = $d->{'duty'};
		$value = $d->{'value'};
		unless (grep { $_ eq $duty } qw/save copy/ ) {
			`magick $sd -$duty $value $sd`;
		}
	}
	if ($duty eq 'copy') {
		foreach my $fi ( @{$files} ) {
			my $f = $fi->{'f'};
			my $tf = $fi->{'thumb'};
			if ($f eq $file) {
				my @folder = split '/', $f;
				pop @folder;
				my $folder = join '/', @folder;
				my $thumb_folder = $folder . '/thumbs';
				my @f = split /\./, $f;
				$f[0] = &subs::random_string_creator(12);
				my $nf = $folder . '/' . join '.', @f;
				my $tnf = $thumb_folder . '/' . join '.', @f;
				my %fil = %{$fi};
				my $fil = \%fil;
				$fil->{'server_time'} = &subs::rightNow();
				$fil->{'uuid'} = &subs::random_string_creator(32);
				$fil->{'f'} = $nf;

				`cp -v $f $nf`;
				if ($fil->{'thumb'}) {
					$fil->{'thumb'} = $tnf;
					`cp -v $tf $tnf`;
				}
				push @{$files}, $fil; 
			}
		}
		my $modified_file = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			file => $modified_file,
			encryption_standard => undef,
		},
		{ uuid => $uuid, app => $app });
		&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });
		&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
	}
	if ($duty eq 'save') {
		my $data = read_file($sd);
		write_file($file, $data);
		my $new_file = $file;
		$new_file =~ s/\.enc$//gi;
		`mv -v $file $new_file`;
		my ($db) = &subs::database_grabber();


		foreach my $fi ( @{$files} ) {
			my $f = $fi->{'f'};

			if ($f eq $file) {

				$f =~ s/\.enc$//gi;
				$fi->{'f'} = $f;
				if ($fi->{'thumb'}) {
					my $thumb = $fi->{'thumb'};
					`shred -u $thumb`;
					$fi = &thumbnail_creator($fi);
				}
				$fi->{'server_time'} = &subs::rightNow();
			}

		}
		my $modified_file = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			file => $modified_file,
			encryption_standard => undef,
		},
		{ uuid => $uuid, app => $app });
		&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });
		&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
	}
	else {
		$returner->{'image'} = 'data:' . $job->{'fd'} . ';base64,' . encode_base64 read_file($sd);
	}
	`shred -u $sd`;
	$c->render(json => $returner);
};

get '/manager/share' => sub($c) {
	my $src = $c->param('src');
	my $type = $c->param('type');
	my $returner;
	if ($device eq 'mobile') {
		$returner = `termux-share -a $type -d $src`;
	}
	$c->render('text' => $returner);
};

get '/manager/note_retriever' => sub ($c) {
	my $app_timestamp = $c->param('app_timestamp');
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $reflected_server_time = $c->param('server_time');
	my $uuid = $c->param('uuid');
	my $s = $c->session('suds');
	my $notekeeper = &subs::note_retriever($app, $uuid);
	$c->render(json => { notes => $notekeeper });
};



get '/manager/torch' => sub($c) {
	my $torch = $c->param('torch');
	my $timestamp = $c->param('timestamp');
	my $returner;
	if ($device eq 'mobile') {
		if ($torch eq 'off') {
			`termux-torch on`;
			$returner = 'on';
		}
		else {
			`termux-torch off`;
			$returner = 'off';
		}
	}
	return $c->render(text => $returner);
};

get '/manager/centre_view' => sub($c) {
	my $app = eval { return decode_json $c->param('app') } || $c->param('app');
	my $jp_report = eval { return decode_json $c->param('jp_report') } || {};
	my $timestamp = $c->param('timestamp');
	if ($app->{'source'}) {
#		&subs::cache_delete({ app => $app->{'app'}, context => 'template' });
	}
	if ($app->{'name'}) {
		&padlock_time_extender($c);
		my $window = &centre_view_grabber({ c => $c, app => $app->{'name'}, timestamp => $timestamp, jp_report => $jp_report });
		if ($c->param('source') ne 'ws') {
			&Websocket::send('tab', { browser_tab_id => $c->param('browser_tab_id'), not_me => 1, console => 'appointmentGrabber(\'' . $app->{'name'} . '\',\'' . $timestamp .'\',\'ws\');'});
		}
	#	&Websocket::send('tab', { browser_tab_id => $c->stash('browser_tab_id'), app => $app, window => $window, timestamp => $timestamp, not_me => 1 });
		$c->render(text => $window);
	}
};

sub centre_view_grabber($data) {
	my $c = $data->{'c'};
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $jp_report = $data->{'jp_report'} || [];
	$app = &subs::unformat_name($app);
	my $server_time = &subs::rightNow();
	my $appointment = &subs::db_query('select app,server_time,timestamp from appointments where app=? LIMIT 1',$app);
	if ($app) {
		my $appointments = [ $app ];
		#if (my $cache_data = &subs::cache_get({ context => 'template', app => $app })) {
		#	return $cache_data;
		#	return;
		#}

		my $appts = &log_reader({ app => $app, view => 'centre_view'  });
		$appts->{$app}->{'setting'}->{'app_measures'} = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
		my $header = &subs::appt_header_printer({ appts => $appts, app => $app, timestamp => $timestamp });
		my $string = $c->render_to_string(
			template => 'appointment_wrapper',
			appts => $appts,
			appointments => $appointments,
			header => $header,
			timestamp => $timestamp,
			device => $device,
			from => 'centre_view',
			config => &subs::config_reader(),
			measures => $gb::measures,
			server_time => $server_time,
			jp_report => $jp_report
		);
		my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $string }, $timestamp);
#		&subs::cache_set({app => $app, context => 'template' }, $window);
		return $window;
	}
}

get '/manager/keyup_search' => sub($c) {
	my $search = $c->param('search');
	my $timestamp = $c->param('timestamp');
	if ($search) {
		my $movement;
		($search,undef,$movement) = &subs::typesetter(&subs::unformat_name($search),'no');
		$search = &subs::format_name($search);
		my @search = split ' ', $search;

		$search = join '%', @search;

		$search = '%' . $search . '%';
		my ($db) = &subs::database_grabber();
		my $results = &subs::db_query('select DISTINCT(app) from settings where device = ? and setting=? and value = ? and app like ? LIMIT 7', $device, 'visible','checked', $search)->hashes;
		my $resulted = $c->render_to_string(template => 'search/manager', results => $results);

		$c->render(json => { results => $resulted, count => scalar @{$results}, timestamp => $timestamp });
	}
	else {
		$c->render(json => { count => 0, timestamp => $timestamp });
	}
};

get '/manager/search' => sub($c) {
	my $search = &subs::unformat_name($c->param('search')) || &subs::unformat_name($c->param('s'));
	my $chosen_appts = $c->param('chosen_appts');
	my $timestamp = $c->param('timestamp');

	my $appts = &log_reader({ search => $search }) if $search;

	my (@s_appointments);
	my ($template);

	if ($search) {
		while (my ($a, $value) = each %{$appts}) {

			if ($a eq $search) { 
				unshift @s_appointments, $a unless grep { lc $_ eq lc $appts->{$a}->{'formatted_name'}} @s_appointments;
				$appts->{$a}->{'header'} = 	&subs::appt_header_printer({ app => $a, timestamp => $timestamp });
			}
			elsif ($a =~ /($search)/) {

				push @s_appointments, $a unless grep { lc $_ eq lc $appts->{$a}->{'formatted_name'}} @s_appointments;
				$appts->{$a}->{'header'} = 	&subs::appt_header_printer({ app => $a, timestamp => $timestamp });
			}
		}
		@appointments = @s_appointments;
	}
	else { }
	$template = 'appointment_wrapper';
	$appts->{'__stash'}->{'header'} = 'yes';
	my $search_engines = $config->{'search_engines'};
	if ($timestamp =~ /[0-9]/) {
		my $contents = $c->render_to_string(
			template => $template,
			appointments => \@appointments,
			appts => $appts,
			timestamp => $timestamp,
			search => $search,
			device => $device,
			from => 'search',
			config => &subs::config_reader(),
			measures => $gb::measures,
			header => '',
		);

		$contents = &window_maker({ user_agent => $c->param('user_agent'), app => $search, title => 'search', contents => $contents },$timestamp);

		$c->render(text => $contents);
	}
	else {
		my $ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/manager/ws';
		my $mail_ws_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/mail/ws';
		my $paperboy_url = 'wss://' . $c->req->url->base->host . ':' . $ENV{PORT_MSG} . '/observer/ws';
		my $pseudonyms = &pseudonym_maker('manager','');
		$c->render(
			layout => 'manager',
			title => &subs::format_name($search),
			template => $template,
			appointments => \@appointments,
			appts => $appts,
			timestamp => $timestamp,
			search => $search,
			device => $device,
			from => 'search_engine',
			config => &subs::config_reader(),
			measures => $gb::measures,
			ws_url => $ws_url,
			mail_ws_url => $mail_ws_url,
			paperboy_url => $paperboy_url,
			my_name => &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
			advertise_watching => &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' }),
			website => '',
			pseudonyms => $pseudonyms
		);
	}
	#&appointment_writer($c,{
	#	app => &subs::unformat_name($search),
	#	timestamp => $timestamp,
	#	type => 'search'
	#});
};

post '/manager/configure/environment/qr' => sub ($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $pos = $c->param('pos');
	my $qr = `qrencode -o - $pos`;
	my $returner = { qr => $qr, app => $app, 'pos' => $pos }; 
	$c->render(json => $returner);
};

post '/manager/clipboard_setter' => sub ($c) {
	my $clipboard = $c->param('clipboard');
	if ($device eq 'mobile') {
	#	`echo "$clipboard" | termux-clipboard-set`;
	}
	elsif ($device eq 'computer') {
	#	`xclip -i "$clipboard"`;
	}
	return $c->render(text => $clipboard);
};

get '/manager/clipboard_getter' => sub ($c) {
	my $returner;
	if ($device eq 'mobile') {
		$returner = `termux-clipboard-get`;
	}
	elsif ($device eq 'computer') {
		$returner = eval { return `xclip -o` };
	}
	$c->render(text => $returner);
};

get '/manager/search_engine_grabber' => sub($c) {
	$c->render(text => &search_engine_grabber($c));
};

sub search_engine_grabber($c) {

	my $search_engines;
	my $timestamp = (&subs::rightNow());
	my $search = $c->param('search');
	my $website = $c->param('website');
	my $contents = &website_grabber({
		app => $c->param('app'),
		search => $search,
		website => $website,
		timestamp => $timestamp
	});
	my $window_data = { app=> $c->param('app'), contents => &website_grabber($c) };
	if ($c->param('view') eq 'iframe') {
		$window_data->{'iframe'} = $website;
	}
	my ($window,$internal_url) = &window_maker($window_data, $timestamp);

	return $window;
}


get '/manager/web' => sub ($c) {
	my $timestamp = $c->param('timestamp');

	my $contents = $c->render_to_string(
		template => 'web/web',
		app => ''
	);


	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'web', contents => $contents }, $timestamp);
	$c->render(text => $website);
};

get '/manager/web/measure/toggle' => sub($c) {
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');

	my $website = &subs::db_select('websites', undef, { app => $app, uuid => $uuid })->hashes->[0];

	my $dom = Mojo::DOM->new($website->{'content'});

	my $m = &subs::db_query('select * from settings where app=? and setting = ? and device = ?', $app, 'app_measures', $device)->hashes->[0];
	my $measures = eval { return decode_json $m->{'value'} } || {};
	foreach my $ma ( keys %{$measures} ) { 
		$measures->{$ma}->{'formatted'} = &subs::format_name($ma);
	}
	$c->render(json => { app => $app, uuid => $uuid, measures => $measures });
};

post '/manager/web/measure/set' => sub($c) {
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $selector = $c->param('selector');
	my $text = $c->param('text');
	my $measure = $c->param('measure');
	my $website = &subs::db_select('websites', undef, { app => $app, uuid => $uuid })->hashes->[0];
	my $dom = Mojo::DOM->new($website->{'content'});
	my $s = $dom->find($selector);

	my $possibilities = [];
	my $count = 0;
	$s->each(sub {
		if ($text eq $_->text || $text == $_->text) {

			my $data = { 
				count => $count, 
				text => $_->text,
				formatted => &subs::format_name($_->text),
				type => 'exact',
				selector => $selector
			};
			#$data->{'formatted'} =~  s/[^\x00-\x7F]+//gi;
			if ($s->[$count - 1]) {
				$data->{'prev'} = { text => $s->[$count - 1]->text, formatted => &subs::format_name($s->[$count - 1]->text) };
			}
			if ($s->[$count + 1]) {
				$data->{'next'} = { text => $s->[$count + 1]->text, formatted => &subs::format_name($s->[$count + 1]->text) };
			}
			push @{$possibilities}, $data;

		}
		$count++;
	});

	my $confirmation = $c->render_to_string(
		template => 'web/web_measure_confirm',
		possibilities => $possibilities,
		app => $app,
		measure => $measure,
		selector => $selector
	);
	
	$c->render(json => { 
		app => $app, 
		uuid => $uuid, 
		selector => $selector,
		possibilities => $possibilities,
		confirmation => $confirmation
	});

};

post '/manager/web/measure/submit' => sub($c) {
	my $app = $c->param('app');
	my $measure = $c->param('measure');
	my $count = $c->param('count');
	my $prev = $c->param('prev');
	my $next = $c->param('next');
	my $selector = $c->param('selector');


	my $data = {
		count => $count,
		prev => $prev,
		next => $next,
		measure => $measure,
		selector => $selector
	};

	my $web_measure_data = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'web_measure_data', subsetting => $measure }) } || {};
	my $jdata = encode_json $data;
	&subs::setting_setter({ app => $app, setting => 'web_measure_data', subsetting => $measure, value => $jdata });

	$c->render(json => $data);
};

post '/manager/web/measure/delete' => sub($c) {
	my $app = $c->param('app');
	my $measure = $c->param('measure');

	my $web_measures = &subs::db_query('select * from settings where app=? and setting = ? and subsetting = ?', $app, 'web_measure_data', $measure)->hashes;
	foreach my $wm ( @{$web_measures} ) {
		&deletion_registration({ table => 'settings', uuid => $wm->{'uuid'}, scope => 'single', server_time => $wm->{'server_time'} });
		&subs::db_delete('settings', { app => $wm->{'app'}, setting => 'web_measure_data', uuid => $wm->{'uuid'} });
	}
	$c->render(json => $web_measures);

};

post '/manager/web/delete' => sub($c) {
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $del = &subs::db_select('websites', undef, { uuid => $uuid, app => $app })->hashes->[0];
	&subs::db_delete('websites', { app => $app, uuid => $uuid });
	&deletion_registration({ table => 'websites', uuid => $uuid, scope => 'single', server_time => $del->{'server_time'} });
	$c->render(json => { app => $app, uuid => $uuid });

};


get '/manager/website_get' => sub ($c) {
	my $app = $c->param('app');
	my ($window,$internal_url,$uuid,$timestamp) = &website_grabber({ 
		app => $app, 
		website => $c->param('website'), 
		timestamp => $c->param('timestamp'), 
		user_agent => $c->param('user_agent'),
		uuid => $c->param('uuid')
	});
	$c->render(json => { internal_url => $internal_url, window => $window, uuid => $uuid, app => &subs::format_name($app), timestamp => $timestamp });
};

sub website_grabber($data) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($data->{'app'});
	my $settings = &subs::settings_grabber({ app => $app });
	my $website = $data->{'website'} || $settings->{'web'};
	my $server_time = &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};
	my $user_agent = $data->{'user_agent'} || $user_agent;
	my $saved_website;
	my $internal_url = $website;
	my $window;
	if ($uuid) {
		$saved_website = &subs::db_select('websites', ['app','timestamp','internal_url','url','content'], { app => $app, url => $website, uuid => $uuid })->hash;
		$timestamp = $saved_website->{'timestamp'} || &subs::rightNow();
		$window = $saved_website->{'content'};
	}
	else {
		$uuid = &subs::random_string_creator(39);

		$saved_website = &subs::db_select('websites', ['app','timestamp','internal_url','url','content'], { timestamp => $timestamp, url => $website })->hash;
		$timestamp = $saved_website->{'timestamp'} || &subs::rightNow();	
		my $raw_html = $saved_website->{'content'};	

		my $ua = Mojo::UserAgent->new;
		my $res = eval { $ua->get($website => {user_agent => $user_agent})->result } ;
		$internal_url = $website || $saved_website->{'internal_url'} || "No Page";

		if (eval { $res->is_success } ) {
			$raw_html = $res->body;

			my $hs = HTML::Strip->new(
				striptags   => [ 'iframe','script' ],
				emit_spaces => 0
			);
			my $content = $hs->parse( $raw_html );

			
			$internal_url = $saved_website->{'internal_url'};
			if ($saved_website->{url}) {
				$uuid = $saved_website->{'uuid'};
				&subs::db_update('websites', 
					{
						content => $raw_html,
						timestamp => $timestamp,
						url => $website,
						internal_url => $internal_url,
						server_time => $server_time
					},
					{
						url => $website,
						app => $app
					}
				);
			}
			else {
				$internal_url = &subs::random_string_creator();
				&subs::db_insert('websites', {
					content => $raw_html,
					timestamp => $timestamp,
					url => $website,
					internal_url => $internal_url,
					app => $app,
					server_time => $server_time,
					uuid => $uuid
				});
			}
			my $history = &subs::db_query('select * from websites where app=? order by timestamp desc', $app)->hashes;
			if (scalar @{$history} > 1) {
				for (my $n = scalar @{$history}; $n >= ($settings->{'web_archives'} || 1); $n--) {
					if ($history->[$n]){
						&deletion_registration({ table => 'websites', uuid => $history->[$n]->{'uuid'}, scope => 'single', server_time => $history->[$n]->{'server_time'} });
						&subs::db_delete('websites', { uuid => $history->[$n]->{'uuid'}, app => $app });
					}
				}
			}
			my $wmd = &subs::db_query('select * from settings where app = ? and setting = ?', $app, 'web_measure_data')->hashes;
			if (scalar @{$wmd}) {
				my $uuid;
				my $dom = Mojo::DOM->new($raw_html);
				my $c = app->build_controller;
				foreach my $wm ( @{$wmd} ) {
					my $data = eval { return decode_json $wm->{'value'} } || next;
					my $s = $dom->find($data->{'selector'});

					my $possibilities = [];
					my $count = 0;
					my $measure = $s->[$data->{'count'}]->text;

					if (1 || $s->[$data->{'count'} - 1] eq $data->{'prev'} && $s->[$data->{'count'} + 1] eq $data->{'next'}) {

						$measure =~  s/[^\x00-\x7F]+//gi;
						$uuid = &appt_measure_writer($c,{ app => $app, measure => $wm->{'subsetting'}, value => $measure, timestamp => &subs::rightNow(), uuid => $uuid });
						&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure[measure="' . $wm->{'subsetting'} . '"]\').val(\'' . $measure . '\');' });
						&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure_display[measure="' . $wm->{'subsetting'} . '"]\').text(\'' . $measure . '\');' });
					}
					else { $log->info('not checking out'); }

				}
			}



		}
		elsif (eval {$saved_website->{'internal_url'}}) { 
			$internal_url = $saved_website->{'internal_url'};
		}
		else {
			$internal_url = "No Page";
		}
		if ($raw_html ne $saved_website->{'content'}) {
			my $write = {
				timestamp => $timestamp,
				app => $app,
			#	notes => &subs::note_encrypter($c->session('suds'),$website),
				type => 'web',
				data => $raw_html,
				server_time => &subs::rightNow(),
				warranty => $data->{'warranty'} || &subs::setting_grabber({ app => $app, setting => 'warranty' }),
				uuid => $uuid
			};
			&subs::db_insert('appointments', $write);
		}
		$saved_website->{'title'} = "web";
		my $c = app->build_controller;
		my $web_toolbar = $c->render_to_string(
			template => 'web/web',
			app => $app
		);
		$window = &window_maker({ user_agent => $data->{'user_agent'}, app => 'web', contents => $web_toolbar . $saved_website->{'content'} }, $timestamp);
	}

	
	return ($window,$internal_url,$uuid,$timestamp);
}


get '/manager/browser' => sub ($c) {
	my $internal_url = $c->param('internal_url');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');

	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();
	if ($internal_url eq 'none') {
		$c->render(text => "<h1>None</h1>");
	}
	else {
		my $results;
		if ($uuid) {
			$results = &subs::db_select('websites', ['app','content','url','internal_url'],{ uuid => $uuid, app => $app });
		}
		else {
			$results = &subs::db_select('websites', ['app','content','url','internal_url'],{ internal_url => $internal_url });
		}

		my $saved_websites = $results->hashes;
		my $website = $saved_websites->[-1]->{'content'};
		$saved_websites->[-1]->{'title'} = $saved_websites->[-1]->{'app'} + ' website';
		my $window = &window_maker($saved_websites->[-1], $timestamp);

		$c->render(text => $website);
	}
};

get '/manager/media_window' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $settings = &subs::settings_grabber({ app => $app });
	my $id = $c->param('id');
	my $misses = eval { return decode_json $c->param('misses') } || {};
	if (!$misses->{$id}) {
		$misses->{$id} = &subs::random_string_creator(25,"Aa");
	}
	my $contents = $c->render_to_string(
		template => 'apps/video',
		id => $id,
		source => $c->param('source'),
		remote_address => $c->tx->remote_address,
		local_address => $c->tx->local_address,
		crate => { settings => $settings },
		misses => $misses
	);
	if ($c->param('window_maker')) {
		$c->render('text' => &window_maker({ user_agent => $c->param('user_agent'), app => $app, timestamp => $c->param('timestamp'), contents => $contents }, $timestamp));
	}
	else {
		$c->render(json => { html => $contents, settings => $settings, app => $app, timestamp => $timestamp });
	}
};

get '/manager/window_maker' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $contents = $c->param('contents');
	$c->render('text' => &window_maker({ user_agent => $c->param('user_agent'), app => $app, timestamp => $timestamp, contents => $contents },$timestamp));
};

sub window_maker($type,$timestamp) {
	$timestamp = &subs::rightNow() unless $timestamp;
	my $window = "Window";
	my $app = $type->{'app'};
	my $settings = &subs::settings_grabber({ app => $app });
	unless ($settings->{'uuid'}) {
		$settings = &subs::setting_initializer($app,$timestamp);
	}
	my ($db,$database,$sql) = &subs::database_grabber();


	my $user_agent = $type->{'user_agent'};
	my $websockets = &subs::db_query('select * from websockets where app=? and user_agent = ? and windows like ? and windows is not null order by timestamp DESC',
		'tab', $user_agent, '%app":"' . $type->{'app'} . '%')->hashes;
	my $jws = undef;
	foreach my $w ( @{$websockets} ) { 
		my $ws = eval { return decode_json $w->{'windows'} } || {};
		if ($ws->{$app}) {
			$jws = &subs::apostrophe_escape(encode_json $ws);
			last;
		}
	}

	my $contents;
	my $title;
	my $drawer;
	my $formatted_name = &subs::format_name($type->{'app'});
	my $unformatted_name = &subs::unformat_name($type->{'app'});
	my $html_name = &subs::html_name($type->{'app'});
	my $http_name = &subs::http_name($type->{'app'});
	my $apostrophe_escape = &subs::apostrophe_escape($type->{'app'});

	my $jp = $apostrophe_escape;
	if ($jp =~ /cam$|scr$|aud$/gi) {
		$jp =~ s/_cam$|_scr$|_aud$//gi;
	}
	if ($type->{'internal_url'}) {
		my $iframe_src = '"/manager/browser?internal_url=' . $type->{'internal_url'} . '&timestamp='.$timestamp.'"';
		$contents = '<iframe src=' . $iframe_src . ' style="width:100%;height:100%;"></iframe>';
		$title = 'browser';
	}
	elsif ($type->{'iframe'}) {
		my $iframe_src = '"' . $type->{'iframe'} . '"';
		$contents = '<iframe src=' . $iframe_src . ' style="width:100%;height:100%;"></iframe>';
		$title = 'browser';		
	}
	else {
		$contents = $type->{'contents'};
	}
	if ($type->{'title'}){
		$title = $type->{'title'};
	}
	if ($settings->{'navigation'} && $settings->{'navigation'} ne 'once') {
		$settings->{'navigation'} = &subs::time_abbrev_translator($settings->{'navigation'});
	}

	my $main_image = &subs::main_icon_maker({ app => $unformatted_name, timestamp => $timestamp, settings => $settings, size => 'tiny' });
	my $pre_dimensioned = 0;
	if ($settings->{'dimensions'} && ($user_agent !~ /Android/gi || $user_agent !~ /Mobile/gi)) {
		$settings->{'dimensions'} = eval { return decode_json $settings->{'dimensions'} } || {};
		$pre_dimensioned = 1;
	}
	else {
		$settings->{'dimensions'} = {};
	}
	my $display = 
		'<div class="wind" id="window_' . $timestamp . '" pre_dimensioned="' . $pre_dimensioned . '"  style="background-colour:white; 
			position:fixed;left:' . ($settings->{'dimensions'}->{'left'}) . 'px;top:' . ($settings->{'dimensions'}->{'top'} || 100) . 'px;width:' . ($settings->{'dimensions'}->{'width'} || 450) . 'px;height:' . ($settings->{'dimensions'}->{'height'} || 450) . 'px" app="'. $unformatted_name .'" visible="yes" timestamp="' . $timestamp . '" navigation="' . ($settings->{'navigation'} || 'once') . '"
			locked="' . $settings->{'locked'} . '" current_information="' . $settings->{'ci'} . '" scrollTop="' . $settings->{'scrollTop'} . '">
			<div id="top_navbar_' . $timestamp . '" class="top_navbar" app="' . $unformatted_name . '" background_colour="' . ($settings->{'colour'} || '#ffec1f') . '" style="max-height:50px;position:absolute;width:100%;border:solid;background-color:'. ($settings->{'colour'} || '#ffec1f') .
				';" app="' . $unformatted_name .'">
					<span class="window_icon_holder">' . $main_image . '</span>
				<span class="appointment_name">
					<span>
						<img class="medium_thumb unlock droppable" app="' . $unformatted_name . '" style="display:none;" src="/images/make believe/lock.png">
						<img class="medium_thumb jack droppable" app="' . $unformatted_name . '" style="display:none;" src="/images/studio/jack.png">
					</span>

					<span class="name_text"  app="\'' . $unformatted_name .'\'">' . $formatted_name . '</span>
					<span style="float:right;">

						<span class="navbar_buttons" style="right:7px;">
							<button id="window_' . $timestamp . '_minify" class="' . $unformatted_name . '_minify_button window_action minimize_button"  onClick="windowMinimizer(' . $timestamp . ',\'' . $unformatted_name . '\')">_</button>
							<button id="window_' . $timestamp . '_restore" style="display:none;" class="' . $unformatted_name . '_restore_button window_action restore_button" onClick="windowRestore(' . $timestamp . ',\'' . $unformatted_name . '\')">#</button>
							<button id="window_' . $timestamp . '_maximize" class="' . $unformatted_name . '_maximize_button window_action maximize_button">&#9634;</button>
							<button id="window_' . $timestamp . '_close" class="' . $unformatted_name . '_close_button window_action close_button" onClick="websocketStop(\'' . $apostrophe_escape . '\'); closeWindow(\'' . $timestamp . '\');">X</button>
						</span>
					</span>
				</span>
			</div>
			<div id="window_drawer_' . $timestamp . '" class="window_drawer" style="position:absolute;top:34px;background-color:' . ($settings->{'colour'} || '#ffec1f') . ';width:100%;display:none;height:calc(100% - 34.8317px);overflow:scroll;">
			<img src="/images/make believe/space.png" style="position:absolute;left:30%;height:24px;width:30%;" class="window_drawer_closer hover">
			<div id="window_drawer_contents_' . $timestamp . '" class="window_drawer_contents" style="padding-top:20px;background-color:white;">' . $drawer . '</div></div>
			<div id="window_contents_' . $timestamp .'" class="window_contents" style="display:flex;height:calc(100% - 34.0317px);">' . $contents . '</div>

		<script id="window_script_' . $timestamp .'">
			jopen = \'' . $settings->{'jopen'} . '\';
			jws = \'' . $jws . '\';
			var w = $("#window_' . $timestamp . '");
			var wc = $("#window_contents_' . $timestamp . '");
			var t = $("#top_navbar_' . $timestamp . '");
			var th = t.height() + 5;
			wc.css({ \'padding-top\': th });
			$(\'#main_display\').css({ \'display\':\'flex\', \'height\':\'83%\', \'width\': \'93%\' });
			var wl = $("#little_window_' . $timestamp . '");
		</script>		</div>';
	return $display;
};

get '/manager/text_editor/create' => sub($c) {
	my $id = $c->param('id');
	my $contents = $c->param('contents');
	my $placeholder = $c->param('placeholder');
	my $p_id = $id . '_text_editor';
	my $html = $c->render_to_string(
		template => 'text_editor',
		id => $id,
		p_id => $p_id,
		contents => $contents,
		placeholder => $placeholder
	);

	$c->render(json => { html => $html, p_id => $p_id, id => $id });
};

get '/manager/terminal' => sub ($c) {
	
	my $timestamp = $c->param('timestamp');
	my $whoami = `whoami`;
	chomp $whoami;
	my $hostname = `hostname`;
	chomp $hostname;
	my $settings = &subs::settings_grabber({ app => 'terminal' });
	$settings->{'errors'} = eval { return decode_json $settings->{'errors'} } || [];
	$settings->{'log'} = eval { return decode_json $settings->{'log'} } || [];
	my $contents = $c->render_to_string(
		template => 'terminal',
		window_maker => 'yes',
		whoami => $whoami,
		hostname => $hostname,
		settings => $settings
	);
	if ($c->param('window_maker') eq 'yes') {
		my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'terminal', contents => $contents }, $timestamp);
		$c->render(text => $website);
	}
	else {
		$c->render(text => $contents);
	}
};

post '/manager/termina/error_report' => sub($c) {
	if (1 == 0) {
		my $errors = eval { return decode_json $c->param('errors') } || [];
		my $browser_tab_id = $c->param('browser_tab_id');
		if (scalar @{$errors} > 0) {
			my $old_errors = eval { return decode_json &subs::setting_grabber({ app => 'terminal', setting => 'errors' }) } || [];
			push @{$old_errors}, @{$errors};
			my $jerrors = encode_json $old_errors;
			&subs::setting_setter({ app => 'terminal', setting => 'errors', value => $jerrors });
		}
	}
	my $errors = [];
	$c->render(json => $errors);

};

post '/manager/window_closer' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	&subs::window_closer($app, $c->param('browser_tab_id'));
	my $settings = &subs::settings_grabber({ app => &subs::unformat_name($app) });

	if ($settings->{'enc'} eq 'on') {
		&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });
	}
	else {
		&subs::file_decrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });
	}
	$c->render('text' => 'ok');
};

post '/manager/terminal' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	$c->render(text => 'ok');

	if ($c->param('command') eq 'telephone') {
		&subs::telephone_contacts_check();
		&subs::telephone_call_log_check();
	}
	else {
		my $return = &subs::run_command('terminal',$c->param('command'),$timestamp);
	}
	$c->render('text' => 'ok');
};

get '/manager/gallery' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $shuffle = $c->param('shuffle');
	my $view = $c->param('view');
	my $search = $c->param('search');
	my $count = $c->param('count');
	my $source = $c->param('source');
	my $load_images = $c->param('loadImages');
	my $file_uuid = $c->param('file_uuid');
	my $new_settings = eval { return decode_json $c->param('new_settings') } || {};
	foreach my $ns ( keys %{$new_settings} ) {
		&subs::setting_setter({ app => 'gallery', setting => $ns, value => $new_settings->{$ns} });
	}

	if ($view ne 'load') {
		&subs::setting_setter({ app => 'gallery', setting => 'apps', value => $c->param('apps') });
		&subs::setting_setter({ app => 'gallery', setting => 'search', value => $search }); 
		&subs::setting_setter({ app => 'gallery', setting => 'view', value => $view });
		&subs::setting_setter({ app => 'gallery', setting => 'count', value => $count });
	}
	my $settings = &subs::settings_grabber({ app => 'gallery' });
	$search = $settings->{'search'};
	$view = $settings->{'view'};
	$count = $settings->{'count'};
	my $unlock = $c->param('unlock') || $settings->{'combo_unlock'};
	my $padlock_sighting = eval { return decode_json &subs::setting_grabber({app => '__president', setting => 'padlock_contexts' }) } || [];
	unless ( grep { $_ eq 'gallery' } @{$padlock_sighting} ) {
		$unlock = undef;
	}
	my $apps = eval { return decode_json $settings->{'apps'} } || [];
	my $jfiles = $c->param('files');


	if ($jfiles) {
		push @{$apps}, 'ide';
		$view = 'photo';
	}
	if (scalar @{$apps} == 0) {
		$settings->{'home_toggled'} = 'on';
	}

	if (!$view) { $view = 'photo'; 
		if ($settings->{'home_toggled'} eq 'on') {
			$view = 'home';
		}
	}
	my $permissive = 0;
	if ($unlock) {
		if (secure_compare(&subs::note_decrypter($c->session('suds'), $unlock), &subs::note_decrypter($c->session('suds'), &subs::setting_grabber({ app => 'gallery', setting => 'combo_unlock' })) ) ) {
			$permissive = 1;
		}
	}

	my $images = [];
	my $total_files = 0;
	my $total_appts = 0;
	my $total_absentees = 0;
	my $asettings = {};
	my @chosen;
	my $send_count = 0;
	my $last_send = 0;
	my $seen_chosen = 0;
	foreach my $a ( @{$apps} ) {
		$asettings->{$a} = &subs::settings_grabber({ app => $a, settings => ['main_image', 'visible' ] }) unless $asettings->{$a};
		next if $asettings->{$a}->{'visible'} ne 'checked' && $permissive == 0;
		my $files = [];
		if ($a eq 'ide' && $jfiles) {
			$files = decode_json $jfiles;
			foreach my $f ( @{$files} ) {
				my $jf = encode_json [{ f => $f->{'file'} }];
				$f = { file => $jf, app => 'ide' };
			}
			$view = 'photo';
			$load_images = 1;
		}
		else {
			$files;
			if ($view eq 'photo') {
				if ($settings->{'search'}) {
					$files = &subs::db_query('select * from appointments where (app like ? or file like ?) and file is not null order by timestamp ' . ($settings->{'scroll_direction'} || 'desc') . '',
						'%' . $settings->{'search'} . '%', '%' . $settings->{'search'} . '%')->hashes;
				} else {
					$files = &subs::db_query('select * from appointments where file is not null and app = ? order by timestamp ' . $settings->{'scroll_direction'}, $a)->hashes;
				
				}
				if ($shuffle eq 'on') {
					@{$files} = shuffle @{$files};
				}
			}
		}
		if ($view eq 'photo' && $load_images != 0) {
			Mojo::IOLoop->subprocess->run_p(sub {
				my ($last_appt, $last_file);
				foreach my $fi ( @{$files} ) {
					$total_appts++;
					my $absentees = [];
					$last_appt = 1 if $total_appts >= scalar @{$files};
					my $filer = eval { return decode_json $fi->{'file'} } || [];
					if ($settings->{'search'}) {
						my $search = $settings->{'search'};
						unless ($fi->{'app'} =~ /\Q$search/gi) {
							@{$filer} = grep { $_->{'name'} =~ /\Q$search/gi } @{$filer};
						}
					}
					if ($settings->{'scroll_direction'} eq 'asc') {
						sort { $a->{'server_time'} cmp $b->{'server_time'} } @{$filer};
					}
					else {
						sort { $b->{'server_time'} cmp $a->{'server_time'} } @{$filer};
					}
					foreach my $f ( @{$filer} ) {
						$total_files++;

						$f->{'app'} = $fi->{'app'};
						unless (-e $f->{'f'}) {
							push @{$absentees}, $f;
							next;
						}
						$f->{'original_file'} = $f->{'f'};
						my @ext = split /\./, $f->{'f'};

						if (grep { $ext[-2] eq $_ || $ext[-1] eq $_ } qw/png jpg svg bmp gif mp4 webm/ ) {
							$f->{'file'} = '/play?app=' . $fi->{'app'} . '&track=' . uri_encode $f->{'f'} . '&timestamp=' . $fi->{'server_time'};
							$f->{'type'} = $fi->{'type'} unless $f->{'type'};
							$f->{'server_time'} = $fi->{'server_time'};
							$f->{'timestamp'} = $fi->{'timestamp'},
							$f->{'app_uuid'} = $fi->{'uuid'};
							if ($f->{'uuid'} eq $file_uuid) {
								$seen_chosen = 1;
							}
						}	
						push @{$images}, $f unless $fi->{'account'} eq 'gallery';
					}
					if (scalar @{$absentees} > 0) {
						foreach my $f ( @{$absentees} ) {
							@{$filer} = grep { $_->{'uuid'} ne $f->{'uuid'} } @{$filer};
							&delete_file({ app => $fi->{'app'}, file_uuid => $f->{'uuid'}, app_uuid => $fi->{'uuid'} });
						}
						$total_absentees+= scalar @{$absentees};
					}
					$send_count++;
					if ($total_files - $last_send > 56 || $last_appt == 1) {
						my @sender;
						for (my $k = $last_send; $k <= $total_files; $k++) {
							push @sender, $images->[$k] if $images->[$k]->{'uuid'};
						}
						&Websocket::send('music', { patience => 1, browser_tab_id => $c->param('browser_tab_id'), type => 'gallery_images', count => $count, images => \@sender, seen_chosen => $seen_chosen, last_send => $last_send, total_files => $total_files });
						$seen_chosen = 0;
						$last_send = $total_files;
					}
				}
			});
		}
	}
	if ($shuffle eq 'on') {
		@{$images} = shuffle @{$images};
	}
	my $contents = $c->render_to_string(
		template => 'apps/gallery',
		window_maker => 'yes',
		settings => $settings,
		images => $images,
		view => $view,
		unlock => $unlock,
		permissive => $permissive,
		asettings => $asettings,
		apps => $apps,
		count => $count,
		search => $search,
		c => $c
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'gallery', contents => $contents }, $timestamp);
	$c->render(json => { window => $website, view => $view, images => $images, settings => $settings, apps => $apps, search => $search });
};

get '/manager/gallery/scroll' => sub($c) {
	my $settings = &subs::settings_grabber({ app => 'gallery' });
	my $apps = eval { return decode_json $c->param('apps') } || [];
	my $unlock = $c->param('unlock');
	my $search = $c->param('search');
	my $count = $c->param('count');
	my $count_timestamp = $c->param('count_timestamp');
	my $direction = $c->param('direction');
	my $first_count = $c->param('first_count');
	my $returner = { apps => $apps, count => $count, count_timestamp => $count_timestamp };
	my $permissive = 0;
	if ($unlock) {
		if (secure_compare(&subs::note_decrypter($c->session('suds'), $unlock), &subs::note_decrypter($c->session('suds'), &subs::setting_grabber({ app => 'gallery', setting => 'combo_unlock' })) ) ) {
			$permissive = 1;
		}
	}
	$returner->{'html'} = $c->render_to_string(
		template => 'apps/gallery_album',
		settings => $settings,
		asettings => {},
		permissive => $permissive,
		pre_count => $count,
		first_count => $first_count,
		view => 'album',
		apps => $apps,
		load => $direction,
		appts => []
	);
	$c->render(json => $returner);
};

get '/manager/file/information' => sub($c) {
	my $file = $c->param('file');
	my $app = $c->param('app');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $mouse = eval { return decode_json $c->param('mouse') } || {};
	my $scope = $c->param('scope');
	my $timestamp = $c->param('timestamp');
	my $uuid = &subs::random_string_creator(12);
	my $appt = &subs::db_select('appointments', undef, { uuid => $app_uuid, app => $app })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];
	@{$files} = grep { $_->{'uuid'} eq $file_uuid } @{$files};
	my $file = $files->[0];
	if ($file->{'ocr'}) {
		$file->{'ocr'} = &subs::note_decrypter($c->session('suds'), $file->{'ocr'}, $file->{'server_time'});
		$file->{'ocr'} =~ s/\n/<br>/gi;
	}


	my $returner = { app => $app, mouse => $mouse, uuid => $uuid, file => $file, appt => $appt };
	$returner->{'appts'} = &log_reader({ app => $app, timestamp => $appt->{'timestamp'}, filter => 'all', scope => $scope, view => 'appointment_details' });
	$c->param('duty' => 'information');
	my $job = &rock_and_roll($c);

	$returner->{'id'} = 'file_information_' . $uuid;
	$returner->{'html'} = $c->render_to_string(
		template => 'file_information',
		file => $file,
		app => $app,
		mouse => $mouse,
		uuid => $uuid,
		job => $job,
		appt => $appt,
		appts => $returner->{'appts'},
	);
	$c->render(json => $returner);
};

post '/manager/file/information_updater' => sub($c) {
	my $attribute = $c->param('attribute');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $value = $c->param('value');

	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];
	
	foreach my $f ( @{$files} ) { 
		if ($file_uuid eq $f->{'uuid'}) {
			if ($attribute eq 'warranty') {
				$value = &subs::ago_calc($value, &subs::rightNow());
				$appt->{'warranty'} = $value;
			}
		}
	}
	my $jf = encode_json $files;
	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jf, warranty => $appt->{'warranty'} }, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });

	$c->render(json => { value => $value, files => $files, appt => $appt });

};

get '/manager/cards' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $mode = &subs::setting_grabber({ app => 'cards', setting => 'mode' });
	my $history = eval { return decode_json &subs::setting_grabber({ app => 'cards', setting => $mode }) } || [];
	my $contents = $c->render_to_string(
		template => 'cards',
		history => $history,
		mode => $mode
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'cards', contents => $contents }, $timestamp);
	$c->render('text' => $website);
};


get '/manager/card_picker' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $new_card = $c->param('new_card');
	my $tree = &subs::inventory_grabber();

	my $mode = &subs::setting_grabber({ app => 'cards', setting => 'mode' });


	my $history = [];

	if ($mode && $mode ne 'all') { 
		$history = eval { return decode_json &subs::setting_grabber({ app => 'cards', setting => $mode }) } || [];
	}
	elsif ($mode eq 'all') {
		my $cards = `ls ./public/images/cards`;
		my @cards = split /\n/, $cards;
		foreach my $ca ( @cards ) {
			my @ca = split /\./, $ca;
			my @stat = stat './public/images/cards/' . $ca;
			push @{$history}, { title => $ca[0], timestamp => $stat[10] * 1000 };
		}
	}

	my ($card,$stream,$title);
	if ($new_card eq 'new') {
		if ($mode eq 'day') {
			$card = &card_of_the_day();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'week') {
			$card = &card_of_the_week();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'month') {
			$card = &card_of_the_month();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'year') {
			$card = &card_of_the_year();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'spread') {
			my @cards;
			for (my $n = 0; $n <= 2; $n++) {
				my ($ca,$car);
					
				$ca = &random_card_picker();
				$car = './public/images/cards/' . &subs::terminal_name($ca);
				while (grep { $car eq $_ } @cards) {

					$ca = &random_card_picker();
					$car = './public/images/cards/' . &subs::terminal_name($ca);

				}
				
				$cards[$n] = $car;
				my $montage_cmd = 'magick montage ' . $cards[0] . ' ' . $cards[1] . ' ' . $cards[2] . ' -';
				my $montage = `$montage_cmd`;
				$ca =~ s/.png$//gi;
				$title .= &subs::format_name($ca) . '<br> ';
				$stream = 'data:image/png;base64,' . encode_base64 $montage;
				splice @{$history}, 10;
			}
		}
		else {
			$card = &random_card_picker();
			$title = $card;
			$title =~ s/.png$//gi;
		}
	}
	else {
		if ($history->[0]->{'stream'}) {
			$stream = $history->[0]->{'stream'};
			$title = $history->[0]->{'title'};
		}
		else {
			$card = $history->[0]->{'title'} . '.png';
			$title = $history->[0]->{'title'};
		}
	}

	if (($mode eq 'free' || $mode eq 'cycle' || $mode eq 'spread') && $new_card eq 'new') {
		splice @{$history}, 40;
		unshift @{$history}, { title => $title, timestamp => $timestamp, stream => $stream };
		my $jhistory = eval { return encode_json $history };
		&subs::setting_setter({ app => 'cards', setting => $mode, value => $jhistory });
	}

	foreach my $h ( @{$history} ) {
		$h->{'description'} = $tree->{$h->{'title'} . '.png'};

	}
	my $html = $c->render_to_string(
		template => 'cards',
		history => $history,
		mode => $mode
	);
	$c->render(json => { 
		html => $html,
		description => $tree->{$card}, 
		title => &subs::format_name($title), 
		filename => $card,
		history => $history,
		mode => $mode,
		stream => $stream
	});
};

sub random_card_picker() {
	my $cards = `ls public/images/cards`;
	my @cards = shuffle split /\n/, $cards;

	@cards = shuffle grep { $_ ne 'title.png' && $_ ne 'back.png' } shuffle @cards;
	my $card = $cards[rand(scalar @cards)];

	return $card;
}

sub card_of_the_day() {
	my $card;
	my $cards = eval { decode_json &subs::setting_grabber({ app => 'cards', setting => 'day' }) } || [];
	splice @{$cards}, 40;
	my $last_card = $cards->[0];
	$card = $last_card->{'title'};
	my @time = localtime($last_card->{'timestamp'} / 1000);
	my @now = localtime(&subs::rightNow() / 1000);

	if ($time[3] != $now[3]) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		my $jcards = encode_json $cards;
		&subs::setting_setter({ app => 'cards', setting => 'day', value => $jcards });
	}

	return $card . '.png';
}

sub card_of_the_week() {
	my $card;
	my $cards = eval { decode_json &subs::setting_grabber({ app => 'cards', setting => 'week' }) } || [];
	splice @{$cards}, 40;
	my $last_card = $cards->[0];
	$card = $last_card->{'title'};
	my @time = localtime($last_card->{'timestamp'} / 1000);
	my @now = localtime(&subs::rightNow() / 1000);
	if (sprintf("%.0f", $time[7] / 7) != sprintf("%.0f", $now[7] / 7)) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		my $jcards = encode_json $cards;
		&subs::setting_setter({ app => 'cards', setting => 'week', value => $jcards });
	}
	return $card . '.png';
}

sub card_of_the_month() {
	my $card;
	my $cards = eval { decode_json &subs::setting_grabber({ app => 'cards', setting => 'month' }) } || [];
	splice @{$cards}, 40;
	my $last_card = $cards->[0];
	$card = $last_card->{'title'};
	my @time = localtime($last_card->{'timestamp'} / 1000);
	my @now = localtime(&subs::rightNow() / 1000);
	if ($time[4] != $now[4]) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		my $jcards = encode_json $cards;
		&subs::setting_setter({ app => 'cards', setting => 'month', value => $jcards });
	}
	return $card . '.png';
}

sub card_of_the_year() {
	my $card;
	my $cards = eval { decode_json &subs::setting_grabber({ app => 'cards', setting => 'year' }) } || [];
	splice @{$cards}, 40;
	my $last_card = $cards->[0];
	$card = $last_card->{'title'};
	my @time = localtime($last_card->{'timestamp'} / 1000);
	my @now = localtime(&subs::rightNow() / 1000);
	if ($time[5] != $now[5]) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		my $jcards = encode_json $cards;
		&subs::setting_setter({ app => 'cards', setting => 'year', value => $jcards });
	}
	return $card . '.png';
}

get '/manager/synth' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $settings = &subs::settings_grabber({ app => 'synth' });
	my $piano = $gb::piano;
	my $ratio = $piano->[0]->{'__specs'}->{'ratio'};

	

	for (my $n = 2; $n <= 13; $n++) {
		$piano->[$n]->{'freq'} = $piano->[$n - 1]->{'freq'} * $ratio;
	}


	my $contents = $c->render_to_string(
		template => 'synth',
		window_maker => $c->param('window_maker'),
		piano => $piano,
		settings => $settings
	);
	my $website = &Manager::window_maker({ settings => $settings, user_agent => $c->param('user_agent'), app => 'synth', contents => $contents }, $timestamp);
	$c->render('text' => $website);
#	&appointment_writer($c, {
#		app => 'synth',
#		timestamp => $timestamp,
#		type => 'open',
#	});
};

get '/manager/studio' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $songs = &subs::db_select('appointments', undef, { type => 'studio' })->hashes;
	my $settings = &subs::settings_grabber({ app => 'studio' });
	my $last_song;
	foreach my $song ( @{$songs} ) {
		$song->{'data'} = eval { return decode_json $song->{'data'} } || {};
		if ($song->{'uuid'} eq $settings->{'last_song'}) {
			$last_song = $song;
		}
	}
	my $contents = $c->render_to_string(
		template => 'studio',
		window_maker => $c->param('window_maker'),
		songs => $songs,
		settings => $settings,
		last_song => $last_song
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'studio', contents => $contents }, $timestamp);
	$c->render(text => $website);
};

post '/manager/studio/save' => sub ($c) {
	my $app = &subs::unformat_name($c->param('app')) || 'studio';
	my $timestamp = $c->param('timestamp');
	my $name = $c->param('name');
	my $init = &subs::setting_initializer($app,$timestamp);
	my $jdata = $c->param('studio');
	my $data = eval { decode_json $jdata };
	my $duration = $c->param('duration') * 1000;
	my $notepad = $c->param('notepad');
	my $uuid = &subs::random_string_creator(20);
	my @files;
	foreach my $u ( @{$c->req->uploads} ) {
		my $folder = &subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } );
		my $location = &subs::home($folder) . '/' . $app;
		my $take_uuid = &subs::random_string_creator(17);
		my @filename = split '_', (split /\./, $u->filename)[0];
		my $channel = $filename[-2];
		my $take = $filename[-1];
		$data->{$channel}->{'mixer'}->{'out'}->[$take]->{'uuid'} = $take_uuid;
		my $filename = $location . '/' . $u->filename;
		`mkdir -p $location` unless -e $location;
		$u->move_to($filename);
		push @files, { f => $filename, uuid => $take_uuid, type => 'recording' };
	}
	my $jfile = encode_json \@files;

	$jdata = encode_json $data;
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		data => $jdata,
		notes => &subs::note_encrypter($c->session('suds'),$notepad),
		type => 'studio',
		file => $jfile,
		uuid => $uuid,
		duration => $duration || '1000',
		server_time => &subs::rightNow()
	};

#	&appointment_writer($c,$write);

	if ($c->param('uuid') && $c->param('uuid') ne 'undefined') {
		$uuid = $c->param('uuid');
		$write->{'uuid'} = $uuid;
		my $song_saved = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
		my $old_files = eval { return decode_json $song_saved->{'file'} } || [];
		push @files, @{$old_files};
	 	$write->{'file'} = encode_json \@files;
		&subs::db_update('appointments', $write, { uuid => $uuid, app => $app });
	}
	else {
		&appointment_writer($c,$write);
	}

	&subs::setting_setter({ app => 'studio', setting => 'last_song', value => $uuid });
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });
	$c->render(json => { app => $app, uuid => $uuid, studio => $data });
};

get '/manager/studio/load' => sub($c) {
	my $uuid = $c->param('uuid');
	my $song = &subs::db_select('appointments', undef, { type => 'studio', uuid => $uuid })->hashes->[0];
	my $data = decode_json $song->{'data'};
	my $misc_settings = &misc_setting_list();
	$data->{'admin'}->{'name'} = $song->{'app'};
	$data->{'admin'}->{'uuid'} = $song->{'uuid'};
	my $files = eval { return decode_json $song->{'file'} } || [];
	foreach my $d ( keys %{$data} ) {
		if ($data->{$d}->{'mixer'}) {
			if (eval { @{$data->{$d}->{'mixer'}->{'out'}} }) {
				my $out = $data->{$d}->{'mixer'}->{'out'};
				foreach my $o ( @{$out} ) {
					if ($o->{'uuid'}) {
						my @files = grep { $_->{'uuid'} eq $o->{'uuid'} } @{$files};
						my $file = $files[0];
						$o->{'src'} = '/file_open?file=' . uri_encode $file->{'f'} . '&app=' . $song->{'app'} . '&timestamp=' . $song->{'server_time'};

					}
				}
			}
		}
	}
	&subs::setting_setter({ app => 'studio', setting => 'last_song', value => $uuid });
	$c->render(json => { app => $song->{'app'}, uuid => $song->{'uuid'}, studio => $data, song => $song });
};

post '/manager/studio/delete' => sub($c) {
	my $uuid = $c->param('uuid');
	my $app = $c->param('uuid');
	&subs::db_delete('appointments', { app => $app, uuid => $uuid, type => 'studio' });
	$c->render(json => { 'status' => 'ok' });
};

get '/manager/relational' => sub ($c) {
	my $timestamp = $c->param('timestamp');

	my $website = &relationalizer({
		timestamp => $timestamp,
		c => $c
	});
	$c->render(text => $website->{'window'});
};

sub relationalizer($data) {
	my $timestamp = $data->{'timestamp'};
	my $c = $data->{'c'};
	my $settings = $data->{'settings'} || &subs::settings_grabber({ app => 'relational' });
	$settings->{'open_buckets'} = eval { return decode_json $settings->{'open_buckets'} } || {};
	my $all_settings = {};
	
	my $returner = {};
	$returner->{'contents'} = $c->render_to_string(
		settings => $settings,
		template => 'relational/relational',
		window_maker => $c->param('window_maker'),
		category_search => $settings->{'category_search'},
		contents_search => $settings->{'contents_search'},
	);
	$returner->{'window'} = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'relational', contents => $returner->{'contents'} }, $timestamp);
	return $returner;
}

get '/manager/relational/select' => sub($c) {
	my $construct = $c->param('construct');
	my $setting = $c->param('setting');
	&subs::setting_setter({ 'app' => 'relational', setting => $setting, value => $construct });
	my $server_time = &subs::rightNow();
	my $settings = &subs::settings_grabber({ app => 'relational' });
	my $relationals;
	%{$relationals} = %{$gb::relationals};
	foreach my $sc ( keys %{$gb::relationals} ) {
		$relationals->{$sc}->{'list'} = &subs::db_select('settings', undef, { setting => 'pos', value => $gb::relationals->{$sc}->{'sing'} })->hashes;
	}
	my $returner = { settings => $settings, relationalizer => &relationalizer({ settings => $settings, timestamp => $server_time, c => $c }) };

	$c->render(json => $returner);
};

post '/manager/relational/adder' => sub($c) {
	my $construct = $c->param('construct');
	my $server_time = &subs::rightNow();
	my $addition = &subs::unformat_name($c->param('addition'));
	my $settings = &subs::settings_grabber({ app => $addition });
	if (!$settings->{'pos'}) {
		$settings = &subs::setting_initializer($addition . '_' . $construct,$server_time);
	}
	elsif (!$settings->{'mab'} && $settings->{'pos'} ne $construct) {
		&subs::setting_setter({ app => $addition, setting => 'mab', value => $construct });
		$settings->{'mab'} = $construct;
	}
	

	my @constructs = grep { $_->{'sing'} eq $construct } values %{$gb::relationals};

	my $pconstructs = { list => [] };


	my $returner = { settings => $settings, sc => $constructs[0] };
	my $relational_settings = &subs::settings_grabber({ app => 'relational' });
	$returner->{'category'} = $c->render_to_string(
		template => 'relational/category',
		sc => $constructs[0],
		all_settings => {},
		settings => $settings,
		pconstructs => $pconstructs,
		category_search => $relational_settings->{'category_search'},
		contents_search => $relational_settings->{'contents_search'},
	);



	$c->render(json => $returner);
};

get '/manager/relational/search' => sub($c) {
	my $server_time = &subs::rightNow();
	if ($c->param('search_tool') eq 'categories') {
		&subs::setting_setter({ app => 'relational', 'setting' => 'category_search', 'value' => &subs::unformat_name($c->param('search')) });
	}
	else {
		&subs::setting_setter({ app => 'relational', 'setting' => 'contents_search', 'value' => &subs::unformat_name($c->param('search')) });
	}
	my $settings = &subs::settings_grabber({ app => 'relational' });
	my $returner = { settings => $settings, relationalizer => &relationalizer({ timestamp => $server_time, c => $c }) };
	$c->render(json => $returner);

};

post '/manager/relational/sorter' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $construct = $c->param('construct');
	my $b_uuid = $c->param('b_uuid');
	my $b_construct = $c->param('b_construct');
	my $movement = $c->param('movement');


	my $bubble = &subs::settings_grabber({ uuid => $uuid });
	my $bucket = &subs::settings_grabber({ uuid => $b_uuid });
	$b_construct = $bucket->{'pos'};
	$construct = $bubble->{'pos'};
	my $sc = eval { return decode_json $bucket->{'sc_' . $construct} } || [];

	push @{$sc}, $bubble->{'uuid'} unless grep { $_ eq $bubble->{'uuid'} } @{$sc};

	if ($movement eq 'delete') {
		@{$sc} = grep { $_ ne $bubble->{'uuid'} } @{$sc};
	}
	@{$sc} = grep { $_ ne 'all' } @{$sc};



	my $bc = eval { return decode_json $bubble->{'sc_' . $b_construct} } || [];
	push @{$bc}, $bucket->{'uuid'} unless grep { $_ eq $bucket->{'uuid'} } @{$bc};

	if ($movement eq 'delete') {
		@{$bc} = grep { $_ ne $bucket->{'uuid'} } @{$bc};
	}
	@{$bc} = grep { $_ ne 'all' } @{$bc};


	my $jsc = encode_json $sc;
	&subs::setting_setter({ app => $bucket->{'app'}, setting => 'sc_' . $construct, value => $jsc });
	my $jbc = encode_json $bc;
	&subs::setting_setter({ app => $bubble->{'app'}, setting => 'sc_' . $b_construct, value => $jbc });
	$bucket->{'sc_' . $construct} = $jsc;
	$bubble->{'sc_' . $b_construct} = $jbc;
	$gb::relational_construct->{$construct}->{'list'} = [];
	$gb::relational_construct->{$b_construct}->{'list'} = [];
	
	my $settings = &subs::settings_grabber({ app => 'relational' });
	my $returner = { movement => $movement, bucket_uuid => $bucket->{'uuid'}, bubble => $bubble, bucket => $bucket, sc => $sc, bc => $bc };
	$returner->{'bucket'} = $c->render_to_string(
		template => 'relational/bucket',
		all_settings => {},
		settings => $settings,
		const => $bucket,
		contents_search => $settings->{'contents_search'}
	);

	$returner->{'bubble'} = $c->render_to_string(
		template => 'relational/bucket',
		all_settings => {},
		settings => $settings,
		const => $bubble,
		contents_search => $settings->{'contents_search'}
	);

	$c->render(json => $returner);

	my $cd = &subs::cache_get({ app => 'relational', context => 'buckets' });
	$cd->{$bucket->{'app'}} = $returner->{'bucket'};
	$cd->{$bubble->{'app'}} = $returner->{'bubble'};
	&subs::cache_set({ app => 'relational', context => 'buckets', warranty => '-5y' }, $cd);
};


get '/manager/twirl' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		settings => &subs::settings_grabber({ app => 'twirl' }),
		template => 'twirl',
		window_maker => $c->param('window_maker')
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'twirl', contents => $contents }, $timestamp);
	$c->render(text => $website);
};

get '/manager/ide' => sub ($c) {
	my $timestamp = $c->param('timestamp');

	my $website = &ide_opener({ timestamp => $timestamp });
	$c->render(json => $website);
};

sub ide_opener($data) {
	my $timestamp = $data->{'timestamp'};
	my $c = app->build_controller;
	my $settings = &subs::settings_grabber({ app => 'ide' });
	my $search = $data->{'search'};
	my $folder = $data->{'folder'};
	my $files = &subs::ide_files(&subs::home($folder) || &subs::home($settings->{'folder_selector'}) || './');
	
	if ($search) {
		my $searched_files;
		foreach my $f ( @{$files} ) {
			my $fi = $folder . $f->{'file'};
			if ($folder ne './') { $fi = $f->{'file'}; }


			my $contents;
			if (-e $fi) {
				$contents = read_file($fi);
			}
			if ($contents =~ /\Q$search/gi || $fi =~ /\Q$search/gi ) {
				push @{$searched_files}, $f, unless grep { $_->{'file'} eq $f->{'file'} } @{$searched_files};
			}
			$files = $searched_files;
		}

	}


	my $open_tabs = eval { return decode_json $settings->{'open_tabs'} } || {};
	my $tabs = {};
	foreach my $f ( keys %{$open_tabs} ) {
		if ($open_tabs->{$f}->{'status'} eq 'open') {
			my ($tab,$content,$file) = &ide_file_open($f,'load');
			$tabs->{$f} = { tab => $tab, content => $content, file => $file};

		}
	}
	my $bgc = &subs::setting_grabber({ app => 'misc', setting => 'ide_sidebar_container_background_colour', device => $device });
	my $contents = $c->render_to_string(
		files => $files,
		template => 'ide',
		tabs => $tabs,
		window_maker => $c->param('window_maker'),
		background_colour => $bgc,
		misc_settings => &misc_setting_list(),
		device => $device,
		settings => $settings,
		search => $search
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'ide', contents => $contents }, $timestamp);
	return { html => $website, tabs => $tabs, settings => $settings };
}

post '/manager/ide/folder_selector' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $folder = $c->param('folder');
	my $search = $c->param('search');
	&subs::setting_setter({ app => 'ide', setting => 'folder_selector', value => $folder });
	my $website = &ide_opener({ timestamp => $timestamp, folder => $folder, search => $search });
	$c->render(json => $website);
};

post '/manager/ide/file_create' => sub($c) {
	my $filename = &subs::terminal_name($c->param('filename'));
	my $timestamp = $c->param('timestamp');
	`touch $filename`;
	$c->render('text' => 'ok');
};

post '/manager/ide/file_delete' => sub($c) {
	my $file = &subs::terminal_name($c->param('file'));
	my $type = $c->param('type');
	my @ext = split /\./,$file;
	if ($type eq 'file') {
		my $command = 'shred -u ' . $file;

		`$command`;
	}
	else {
		`rm -R $file`;
	}

	$c->render(json => { file => $file, type => $type });
};

get '/manager/ide/file_open' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $file = $c->param('file');
	my $location = $c->param('location');
	my @file = split /\./, $file;
	my $files;
	my $open_app;
	if ($file[-1] eq 'enc') {
		pop @file;
	}
	if (grep { $_ eq $file[-1] } qw/jpeg jpg png bmp tiff mpg webm webv/) {
		$open_app = 'gallery';

		my @folder = split '/', $file;
		pop @folder;

		my $folder = join '/', @folder;
		my @files = split /\n/, `ls $folder`;
		foreach my $fi ( @files ) {
			if ($location eq './') {
				$fi = $gb::pwd . '/' . $fi;
			}
			else {
				$fi = $folder . '/' . $fi;
			}
			next if -d $fi;
			my @stat = stat($fi);
			my $temp = {};
			$temp->{'size'} = $stat[7];
			$temp->{'modified'} = $stat[9];
			$temp->{'created'} = $stat[10];
			$temp->{'accessed'} = $stat[8];
			

			my $f = { f => $fi, app => 'ide', file => $fi, server_time => $temp->{'created'} * 1000 };
			unless ($f->{'file'} =~ /base64/gi) {
				if ($f->{'file'} =~ /png|jpg|svg|bmp|gif|mp4|webm/) {
					$f->{'file'} = '/play?app=' . $f->{'ide'} . '&track=' . uri_encode $f->{'file'} . '&timestamp=' . $f->{'server_time'};
				}
			}
			push @{$files}, $f;
		}
	}

	my ($seen,@before,@after);
	foreach my $f ( @{$files} ) {
		if ( $file eq $f->{'f'} ) {
			$seen = 1;
		}
		if ($seen != 1) {
			unshift @before, $f;
		}
		else {
			unshift @after, $f;
		}
	}
	@{$files} = (@before, @after);

	my ($tab,$content,$f);
	if ($seen != 1) {
		($tab,$content,$f) = &ide_file_open($file,'open');
	}

	my $open_tabs = eval { return decode_json &subs::setting_grabber({ app => 'ide', setting => 'open_tabs' }) } || {};
	$open_tabs->{$file} = { status => 'open' };
	my $ot = encode_json $open_tabs;
	&subs::setting_setter({ app => 'ide', setting => 'open_tabs', value => $ot });
	$c->render(json => { content => $content, tab => $tab, file => $file, open_app => $open_app, files => $files });
};

sub ide_file_open($file,$source) {
	my $content = `cat $file`;
	my @file_name = split '/', $file;
	my $status = '';
	if ($source eq 'open') {
		$status = 'active';
	}
	my $tab = '<span class="ide_tab ' . $status . ' hover" style="vertical-align:top;font-size:20px;" file="' . $file . '">' . $file_name[-1] . '<button class="ide_close_tab hover" file="' . $file . '">X</button></span>';
	return ($tab,$content,$file);
}


post '/manager/ide/file_close' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $file = $c->param('file');
	my $open_tabs = eval { return decode_json &subs::setting_grabber({ app => 'ide', setting => 'open_tabs' }) } || {};
	$open_tabs->{$file} = { status => 'closed' };
	my $ot = encode_json $open_tabs;
	&subs::setting_setter({ app => 'ide', setting => 'open_tabs', value => $ot });
};

post '/manager/ide/save' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $file = $c->param('file');
	my $content = $c->param('content');

	write_file($file, $content);
	$c->render(json => { status => 'success' });
};

get '/manager/mailbox' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $contents = &mail_checker($c)->{'contents'};
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp);
	$c->render(text => $website);
#	&appointment_writer($c, {
#		app => 'mailbox',
#		timestamp => $timestamp,
#		type => 'open'
#	});
};

get '/manager/mail/picker' => sub ($c) {
	my $timestamp = $c->param('timestamp');

	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
};

get '/manager/mail/contact' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
};

get '/manager/mail/phone' => sub($c) {
	my $timestamp = $c->param('timestamp');

	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
};

get '/manager/mail/email' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
};

get '/manager/mail/email/configure' => sub($c) {
	my $screen = $c->param('screen');
	my $template = $c->param('template');
	if ($template) { &subs::setting_setter({ app => 'mailbox', setting => 'email_template_config_select', value => $template }); }
	if ($screen) { &subs::setting_setter({ app => 'mailbox', setting => 'email_config_screen', value => $screen }); }
	my $content = $c->render_to_string(
		template => 'mail/email_configure',
	);
	my $returner = { html => $content };
	$c->render(json => $returner);
};

get '/manager/mail/email/send_and_receive' => sub($c) {

	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$email_servers} = grep { $_->{'active'} eq 'on' } @{$email_servers};

#	Mojo::IOLoop->subprocess->run_p(sub {
		foreach my $es ( @{$email_servers} ) {

			my $password = &subs::note_decrypter($c->session('suds'), $es->{'password'});
			$es->{'status'} = 'failed';
			my $imap = Net::IMAP::Client->new(
				server => $es->{'imap_server'},
				user   => $es->{'email'},
				pass   => $password,
				ssl    => $es->{'imap_encryption'} eq 'SSL' ? 1 : 0,
				tls    => 0,
				ssl_verify_peer => 1,                     # (use ca to verify server, default yes)
	#		  ssl_ca_file => '/etc/ssl/certs/certa.pm', # (CA file used for verify server) or
				ssl_ca_path => '/etc/ssl/certs/',         # (CA path used for SSL)
				port   => $es->{'imap_port'}                             # (but defaults are sane)
			) or next;
			$imap->login or next;

			$es->{'status'} = 'success';
			$es->{'last_login'} = &subs::rightNow();
			my @folders = $imap->folders;
			$es->{'folders'} = {} unless $es->{'folders'};
			foreach my $f ( @folders ) {
				next if $es->{'folders'}->{$f};
				$es->{'folders'}->{$f} = {};
			}
			foreach my $f ( keys %{$es->{'folders'}} ) {
				delete $es->{'folders'}->{$f} unless grep { $f eq $_ } @folders;
				if ($es->{'folders'}->{$f}->{'retrieve'} eq 'on') {
					$imap->select($f);
					my $status = $imap->status($f); # hash ref!

					my $sep = $imap->separator;
					my $messages = $imap->search('ALL');
					my $summaries = $imap->get_summaries([ @{$messages} ]);
					foreach my $sum (@$summaries) {

						my $from = $sum->from->[-1];
						my @ea = split ' ', $from;
						$from = $ea[-1];
						$from =~ /<([^>]+)>/;
						$from = $1;
						my $to = $sum->to->[-1];
						my @ea = split ' ', $to;
						$to = $ea[-1];
						$to =~ /<([^>]+)>/;
						$to = $1;
						my $checked_addresses = &subs::db_query('select * from settings where setting=? and (value=? or value=? and value != ?) and device=?', 'email', $from, $to, $es->{'email'}, $device)->hashes;
						foreach my $ca ( @{$checked_addresses} ) {


							# check for appointments
							my $timestamp = &subs::ago_calc($sum->date,&subs::rightNow());
							my $appts = &subs::db_query('select * from appointments where app=? and timestamp=? and type=?', $ca->{'app'}, $timestamp, 'email')->hashes;
							next if scalar @{$appts} > 0;


							my $body;
							my $part_ref = $imap->get_part_body($sum->uid, '1.3');
							if ($part_ref) {
								$body = $$part_ref;
							}
							if ($body == undef) {

								my $part_ref = $imap->get_part_body($sum->uid, '1.2');

								if ($part_ref) {
									my $hs = HTML::Strip->new(
										striptags   => [ 'iframe','script' ],
										emit_spaces => 0
									);
									$body = $hs->parse( $$part_ref );
								}
								if ($body == undef) {
									$part_ref = $imap->get_part_body($sum->uid, '1.1');
									if ($part_ref) {

										$body = $$part_ref;

									}
								}
							}
							my $parser = MIME::Parser->new;
							$parser->output_dir($gb::tmp_dir);

							my $msg_string = $imap->get_rfc822_body($sum->uid);

							my $entity = $parser->parse_data($msg_string);
							my $bodyfile = $entity->bodyhandle;


							my $files = [];
							foreach my $part ($entity->parts) {

								my $filename = $part->head->recommended_filename;
								if ($filename) {


									my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $filename, app => $ca->{'app'}, is_thumb => 0 });
									copy($gb::tmp_dir . '/' . $filename, $destination . $asset);
									my $u_data = { server_time => &subs::rightNow(), f => $destination . $asset, uuid => &subs::random_string_creator(28), type => $type };
									my $thumb = $destination . '/thumbs';
									if ($type eq 'image') {
										`mkdir -p $thumb` unless -e $thumb;
										$u_data->{'thumb'} = $thumb . '/' . $asset;
							
									}
									push @{$files}, $u_data;

								}
							}
							my $app_uuid = &subs::random_string_creator(31);
							my $jfile = scalar @{$files} > 0 ? encode_json $files : undef;
							my $appt_data = {
								app => $ca->{'app'},
								type => 'email',
								timestamp => $timestamp,
								notes => &subs::note_encrypter(&subs::suds_grabber(), $body),
								file => $jfile
							};
							&Manager::appointment_writer($c,$appt_data);

							foreach my $u_data ( @{$files} ) {
								$u_data->{'app_uuid'} = $app_uuid;
								$u_data = &thumbnail_creator($u_data);
							}
							&subs::file_encrypter({ app => $ca->{'app'}, timestamp => $timestamp, suds => &subs::suds_grabber() });
							&subs::appt_header_printer({ app => $ca->{'app'} });
							&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $ca->{'app'} . '\',\'' . $app_uuid .'\');'});
							$entity->purge;

						}
					}
				}
			}

		}
#	});
	my $jemail_servers = encode_json $email_servers;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jemail_servers });
	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);
	$c->render(json => { email_servers => $email_servers, html => $html });
};

post '/manager/mail/email/configure' => sub($c) {
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $uuid = $c->param('uuid') eq 'new' ? &subs::random_string_creator(25) : $c->param('uuid');
	my $subsetting = $c->param('subsetting');
	my $folder = $c->param('folder');


	my $esa = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$esa} = grep { $_->{'uuid'} eq $uuid } @{$esa};
	my $es = $esa->[0] ? $esa->[0] : {};
	if ($setting eq 'folder') {
		$es->{'folders'}->{$folder}->{$subsetting} = $value;
	}
	elsif ($setting eq 'password') {
		$value = &subs::note_encrypter($c->session('suds'), $value);
		$es->{$setting} = $value;
	}
	else {
		$es->{$setting} = $value;
	}
	$es->{'uuid'} = $uuid;

	@{$esa} = grep { $_->{'uuid'} ne $uuid } @{$esa};
	push @{$esa}, $es;

	my $jesa = encode_json $esa;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jesa });

	$c->render(json => $es);
};

post '/manager/mail/email/server/add' => sub($c) {
	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	push @{$email_servers}, { uuid => &subs::random_string_creator(21) };

	my $jemail_servers = encode_json $email_servers;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jemail_servers });
	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);

	$c->render(json => { html => $html });
};

post '/manager/mail/email/server/delete' => sub($c) {
	my $uuid = $c->param('uuid');
	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$email_servers} = grep { $_->{'uuid'} ne $uuid } @{$email_servers};
	my $jemail_servers = encode_json $email_servers;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jemail_servers });
	$c->render(json => $email_servers);
};

post '/manager/mail/email/server/delete' => sub($c) {
	my $uuid = $c->param('uuid');

	my $email_templates = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_templates' }) } || [];
	@{$email_templates} = grep { $_->{'uuid'} ne $uuid } @{$email_templates};

	my $jemail_templates = encode_json $email_templates;

	&subs::setting_setter({ app => 'mailbox', setting => 'email_templates', value => $jemail_templates });
	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);

	$c->render(json => { templates => $email_templates, html => $html });
};

get '/manager/mail/email/compose' => sub($c) {
	my $email = $c->param('email');
	my $app = $c->param('app');
	my $draft_selection = $c->param('draft_selection');

	if ($app) {
		my $setting_email = &subs::setting_grabber({ app => $app, setting => 'email' });
		$email = $setting_email ? $setting_email : $email;
	}


	my $drafts = &subs::db_select('mailbox', undef, { email => $email, status => 'draft' })->hashes;

	foreach my $e ( qw/from_email email subject body uuid/ ) {
		$drafts->[-1]->{$e} = &subs::note_decrypter($c->session('suds'), $drafts->[-1]->{$e});

	}
	my $content = $c->render_to_string(
		template => 'mail/email_compose',
		email => $email,
		draft => $drafts->[-1],
		drafts => $drafts,
		attachments => []
	);
	$c->render(json => {
		email => $email,
		html => $content,
		draft => $drafts->[-1],
		drafts => $drafts
	});
};


get '/store/email' => sub($c) {
	my $returner;
	my $uuid = $c->param('uuid');
	my $cx_uuid = $c->param('cx_uuid');
	my $type = $c->param('type');

	my $cx = &subs::db_query('select * from settings where setting=? and value=?', 'uuid', $cx_uuid)->hashes->[0];
	my $settings = &subs::settings_grabber({ app => $cx->{'app'} });
	my $drafts = &subs::db_select('mailbox', undef, { email => $settings->{'email'}, status => 'draft' })->hashes;
	foreach my $e ( qw/from_email email subject body uuid/ ) {
		$drafts->[-1]->{$e} = &subs::note_decrypter($c->session('suds'), $drafts->[-1]->{$e});
	}
	my $printer = &store_printer({
		type => $type,
		cx_uuid => $cx_uuid,
		uuid => $uuid,
		visibility => 'show'
	});
	my $attachments = [{
			type => 'printer',
			html => $c->render_to_string(%{$printer}),
			printer => $printer
		}
	];


	my $content = $c->render_to_string(
		template => 'mail/email_compose',
		email => $settings->{'email'},
		draft => $drafts->[-1],
		drafts => $drafts,
		attachments => $attachments
	);
	foreach my $att ( @{$attachments} ) {

	}

	$c->render(json => { html => $content });
};

post '/manager/mail/email/template/save' => sub($c) {
	my $uuid = $c->param('uuid');
	my $name = &subs::unformat_name($c->param('name'));
	my $subject = $c->param('subject');
	my $body = $c->param('body');
	my $purpose = $c->param('purpose');
	my $templates = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_templates' }) } || [];
	my $data = {
		uuid => $uuid,
		name => $name,
		purpose => $purpose,
		subject => $subject,
		body => $body
	};
	if ($uuid eq 'new') {
		$data->{'uuid'} = &subs::random_string_creator(15);
		push @{$templates}, $data;
		&subs::setting_setter({ app => 'mailbox', setting => 'email_template_config_select', value => $data->{'uuid'} });
	}
	else {
		foreach my $t ( @{$templates} ) {
			if ($t->{'uuid'} eq $uuid) {
				$t = $data;
			}
		}
	}

	my $jtemplates = encode_json $templates;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_templates', value => $jtemplates });
	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);

	$c->render(json => { data => $data, html => $html });

};

get '/manager/mail/email/template' => sub($c) {
	my $uuid = $c->param('uuid');
	my $email_templates = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_templates' }) } || [];
	@{$email_templates} = grep { $_->{'uuid'} eq $uuid } @{$email_templates};
	my $template = $email_templates->[0];

	$c->render(json => $template);
};

post '/manager/mail/email/send' => sub($c) {
	my $from = $c->param('from');
	my $email = $c->param('to');
	my $subject = $c->param('subject');
	my $body = $c->param('body');
	my $uuid = $c->param('uuid');
	my $result = &email_send({
		from => $from,
		email => $email,
		subject => $subject,
		body => $body,
		uuid => $uuid
	});


	$c->render(json => $result);
};

sub email_send($data) {
	$data->{'attachments'} = [] unless $data->{'attachments'};
	my $email_server = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	return { result => 'no server' } if scalar @{$email_server} == 0;
	@{$email_server} = grep { $_->{'uuid'} eq $data->{'from'} } @{$email_server};
	return { result => 'server no longer exists' } if scalar @{$email_server} == 0;
	my $es = $email_server->[0];
	my $transport = Email::Sender::Transport::SMTP->new({
		host          => $es->{'smtp_server'},
		port          => $es->{'smtp_port'},
		ssl           => $es->{'smtp_encryption'} eq 'SSL' ? 1 : 0, 
		sasl_username => $es->{'email'},
		sasl_password => &subs::note_decrypter(&subs::suds_grabber(), $es->{'password'}),
	});

	my $stuffer = Email::Stuffer
		->from(&subs::format_name($es->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'my_name' })) . ' <' . $es->{'email'} . '>')
		->to($data->{'email'})
		->subject($data->{'subject'})
		->transport($transport);

	my $dom = Mojo::DOM->new($data->{'body'});

	if ($dom->find('*')->size > 0) {
		$stuffer->html_body($data->{'body'});
	}
	else {
		$stuffer->text_body($data->{'body'});
	}


	foreach my $att ( @{$data->{'attachments'}} ) {
		if ($att->{'type'} eq 'url') {
			my $att_url = $att->{'url'};
			my $loc = $gb::tmp_dir . '/invoice.pdf';
			my $command = 'weasyprint "' . $att_url . '" ' . $loc;

			`$command`;
		}
	}

	my $result = $stuffer->send;
		
	if ($result->message =~ /2.0.0 OK/gi) {
		$result = 'success';
		&subs::db_delete('mailbox', { status => 'draft', uuid => $data->{'uuid'} });
	} else {
		$result = 'fail';
	}
	return $result;
}

get '/manager/mail/scroll' => sub($c) {
	my $mc = &mail_checker($c);
	$c->render(json => $mc);
};

sub mail_checker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $incoming_data = eval { return decode_json $c->param('incoming_data') } || {};
	my $bgc = &subs::setting_grabber({ app => 'misc', setting => 'mail_sidebar_container_background_colour', device => $device });
	my $contacters = &subs::db_query('select * from tickets');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $contacts = $contacters->hashes;
	my $picker = eval { return decode_json $c->param('picker') } || {};
	my $settings = &subs::settings_grabber({ app => 'mail' });
	my $me = &manager_file_maker($c->session('name'));
	$settings->{'mail_config'} = eval {return decode_json $settings->{'mail_config'} } || {};
	foreach my $contact ( @{$contacts} ) {
		$contact->{'contact_name'} = lc &manager_file_maker($contact->{'name'});
		$contact->{'app'} = $contact->{'contact_name'};
	}
	my $contact = $c->param('mail_contact');
	my $phone = $c->param('phone');
	my $email = $c->param('email');
	my $main_title;
	if ($c->session('privilege') eq 'guest') {
		$contact = $c->session('ticket_uuid');
	}
	my $last_sc;
	foreach my $scons ( sort { $a->{'order'} cmp $b->{'order'} } values %{$gb::social_constructs} ) {
		my $sc = $scons->{'name'};
		if (1 == 1 || $scons->{'order'} == 0 || scalar @{$gb::social_constructs->{$last_sc}->{'list'}} > 0) {
			my $construct = &subs::db_query('select * from settings where setting=? and value=?', 'pos', $gb::social_constructs->{$sc}->{'sing'});
			$gb::social_constructs->{$sc}->{'list'} = $construct->hashes;
			$gb::social_constructs->{$sc}->{'value'} = $picker->{$sc};
			$last_sc = $sc;
		}
	}
	my $list = [];
	my $q;
	if ($settings->{'subsection'} eq 'list') {
		my $listing = &subs::db_query('select * from mailbox where timestamp < ?', $timestamp)->hashes;
		foreach my $l ( @{$listing} ) {
			my $seen = 0;
			foreach my $soc_con ( keys %{$gb::social_constructs} ) {
				my @ls = grep { $_->{$gb::social_constructs->{$soc_con}->{'sing'}} eq $l->{$gb::social_constructs->{$soc_con}->{'sing'}} } @{$list};
				if (scalar @ls > 0) { $seen++; }
			}
			if ($seen < scalar keys %{$gb::social_constructs}) {
				my $uuid;
				foreach my $sc ( sort keys %{$gb::social_constructs} ) { 
					$uuid .= $l->{$gb::social_constructs->{$sc}->{'sing'}} . '---';
				}
				$l->{'uuid'} = $uuid;
				$l->{'config'} = $settings->{'mail_config'}->{$uuid};
				push @{$list}, $l;
			}
		}
		my @selection = split '---', $settings->{'mail_list'};

		$q = &subs::db_query('select * from mailbox where timestamp < ? and account=? and club = ? and community = ? and person = ? and project = ? and team = ? order by timestamp desc LIMIT 30',
			$timestamp, 
			$selection[0],
			$selection[1],
			$selection[2],
			$selection[3],
			$selection[4],
			$selection[5],
		);
		foreach my $s ( @selection ) {
			$main_title .= &subs::format_name(&subs::shorthand_name($s,50)) . ' ';
		}
	}
	elsif ($settings->{'subsection'} eq 'pen') {
		$q = &subs::db_query('select * from mailbox where timestamp < ? and contact = ? order by timestamp desc LIMIT 30', $timestamp, 'pen');
		$main_title = 'Pen';
	}
	elsif ($phone) {
		$q = &subs::db_query('select * from mailbox where timestamp < ? and phone = ? order by timestamp desc LIMIT 30', $timestamp, $phone);
		$main_title = &subs::format_name(&subs::db_select('settings', undef, { setting => 'phone', value => $phone })->hashes->[0]->{'app'}) . ' ' . $phone;
	}
	elsif ($email) {
		$q = &subs::db_query('select * from mailbox where timestamp < ? and email = ? order by timestamp desc LIMIT 30', $timestamp, $email);
		$main_title = &subs::format_name(&subs::db_select('settings', undef, { setting => 'email', value => $email })->hashes->[0]->{'app'}) . ' ' . $email;
	}
	elsif ($contact) {
		$q = &subs::db_query('select * from mailbox where timestamp < ? and contact = ? order by timestamp desc LIMIT 30', $timestamp, $contact);
		my @cont = grep { $_->{'uuid'} eq $contact } @{$contacts};
		$main_title = &subs::format_name($cont[0]->{'name'});
	}
	else {
		$q = &subs::db_query('select * from mailbox where timestamp < ? and project=? and account = ? and community = ? and team = ? and club = ? and person = ? order by timestamp desc LIMIT 30', 
			$timestamp, 
			($picker->{'projects'} || $gb::social_constructs->{'projects'}->{'def'}),
			($picker->{'accounts'} || $gb::social_constructs->{'accounts'}->{'def'}),
			($picker->{'communities'} || $gb::social_constructs->{'communities'}->{'def'}),
			($picker->{'teams'} || $gb::social_constructs->{'teams'}->{'def'}),
			($picker->{'clubs'} || $gb::social_constructs->{'clubs'}->{'def'}),
			($picker->{'people'} || $gb::social_constructs->{'people'}->{'def'}),
		);
		$main_title = &subs::format_name(($picker->{'projects'} || $gb::social_constructs->{'projects'}->{'def'}) . ' ' .
			($picker->{'accounts'} || $gb::social_constructs->{'accounts'}->{'def'}) . ' ' .
			($picker->{'communities'} || $gb::social_constructs->{'communities'}->{'def'}) . ' ' .
			($picker->{'teams'} || $gb::social_constructs->{'teams'}->{'def'}) . ' ' .
			($picker->{'clubs'} || $gb::social_constructs->{'clubs'}->{'def'}) . ' ' .
			($picker->{'people'} || $gb::social_constructs->{'people'}->{'def'}));
	}
	my $mails = $q->hashes;
	Mojo::IOLoop->subprocess->run_p(sub {
		foreach my $m ( @{$mails} ) {
			if ($m->{'status'} eq 'public' && $c->session('privilege') eq 'citizen') {
				&subs::db_query('update mailbox set status=?, body =? where uuid =?', 'sent', &subs::note_encrypter($c->session('suds'), $m->{'body'}, $m->{'timestamp'}), $m->{'uuid'});
			}
			else {
				$m->{'body'} = &subs::note_decrypter($c->session('suds'),$m->{'body'},$m->{'ost'});
			}
			if ($m->{'phone'} && $m->{'status'} eq 'sent') {
				$m->{'manager_file'} = $me;
			}
			$m->{'decrypted'} = 'yes';
			my $content = $c->render_to_string(
				template => 'mail/message',
				'm' => $m,
				me => $me
			);
			&Websocket::send('mailbox', {  type => 'mailbox_message', selector => '.mailbox_message[uuid="' . $m->{'uuid'} . '"]', content => $content, browser_tab_id => $c->param('browser_tab_id') });
		}
	});
	my $combined_data = {
		template => 'mail/mailbox',
		mail => $mails,
		window_maker => $c->param('window_maker'),
		background_colour => $bgc,
		contacts => $contacts,
		sc => $gb::social_constructs,
		mail_contact => $c->param('mail_contact'),
		mail_phone => $phone,
		mail_email => $email,
		config => &subs::config_reader(),
		settings => $settings,
		list => $list,
		me => $me,
		incoming_data => $incoming_data,
		main_title => $main_title
	};

	my $contents = $c->render_to_string(
		%{$combined_data}
	);

	return { contents => $contents, mail => $mails };
}

get '/manager/mail/config' => sub ($c) {
	my $uuid = $c->param('uuid');

	my $configure = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'mail_config' }) } || {};
	my $returner = { config => $configure->{$uuid} };
	if ($configure->{$uuid}->{'qr'}) {
		my $qr = $configure->{$uuid}->{'qr'};
		$qr = `qrencode -o - $qr`;
		$configure->{$uuid}->{'qr_image'} = 'data:image/png;base64,' . encode_base64($qr);
	}
	$returner->{'html'} = $c->render_to_string(
		template => 'mail/config',
		configure => $configure->{$uuid},
		uuid => $uuid
	);
	$c->render(json => $returner);
};

post '/manager/mail/config' => sub ($c) {
	my $uuid = $c->param('uuid');
	my $setting = $c->param('setting');
	my $value = $c->param('value');

	my $configure = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'mail_config' }) } || {};
	$configure->{$uuid}->{$setting} = $value;
	my $jset = encode_json $configure;

	&subs::setting_setter({ app => 'mail', setting => 'mail_config', value => $jset });
	$c->render(json => $configure);
};

get '/manager/mail/qr_generator' => sub ($c) {
	my $uuid = $c->param('uuid');
	my $returner = {};
	my $configure = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'mail_config' }) } || {};
	my $rand = 0;
	until ($rand > 200) {
		$rand = rand(359);
	}

	$configure->{$uuid}->{'qr'} = $uuid . ' ' . &subs::random_string_creator($rand);

	my $jset = encode_json $configure;
	&subs::setting_setter({ app => 'mail', setting => 'mail_config', value => $jset });
	if ($configure->{$uuid}->{'qr'}) {
		my $qr = $configure->{$uuid}->{'qr'};
		$qr = `qrencode -o - $qr`;
		$configure->{$uuid}->{'qr_image'} = 'data:image/png;base64,' . encode_base64($qr);
	}
	$c->render(json => $configure->{$uuid});
};

get '/mail/homepage_form' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	$c->render('text' => &mail_checker($c)->{'contents'} ,timestamp => $timestamp	);
};

get '/manager/travel' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $contents = &travel_grabber($c);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'travel', contents => $contents }, $timestamp);
	$c->render(text => $website);
};

sub travel_grabber($c) {
	my $timestamp = $c->param('timestamp');
	my $home_plate = &subs::setting_grabber({ app => 'me', setting => 'home_plate' });
	my $settings = &subs::settings_grabber({ app => 'travel' });

	my $travel_scope = 	$settings->{'travel_scope'} || 100;
	my $time_scope = $settings->{'time_scope'} || '5minute';
	my $home_plate_enabled = $settings->{'home_plate_enabled'};
	$settings->{'maps'} = eval { return decode_json $settings->{'maps'} } || [];

	my $contents = $c->render_to_string(
		template => '/travel/travel',
		home_plate => $home_plate,
		home_plate_enabled => $home_plate_enabled,
		travel_scope => $travel_scope,
		time_scope => $time_scope,
		window_maker => $c->param('window_maker'),
		timestamp => $timestamp,
		settings => $settings
	);
	return $contents;
}

get '/manager/travel/viewer' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $travel_scope = $c->param('travel_scope') ? $c->param('travel_scope') : 20;
	my $time_scope = $c->param('time_scope') ? $c->param('time_scope') : '5minute';
	my $t = &{$subs::time_subs->{$time_scope}}($timestamp); #timestamp at beginning
	my $t1 = ($timestamp - $t);
	my $t2 = ($t1 + $timestamp);
	my ($db,$database,$sql) = &subs::database_grabber();

	my $map = $c->param('map');

	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my ($main_map,$home_bases);
	@{$main_map} = grep { $_->{'uuid'} eq $map } @{$maps};
	$main_map = $main_map->[0];



	my $proxies = { current_map => $main_map, near => [], far => [], here => {}, scope => $time_scope, travel_scope => $travel_scope };
	my $locations = [];
	if (&subs::setting_grabber({ app => 'travel', setting => 'home_plate_enabled' }) eq 'enabled') {
		my $home_plates = &subs::db_select('settings', undef, { setting => 'home_plate' })->hashes;
	
		foreach my $hp ( @{$home_plates} ) {
			my $ho = eval { return decode_json $hp->{'value'} } || {};
			$ho->{'app'} = $hp->{'app'};
			push @{$locations}, $ho;
		}
	}
	else {
		my $q = &subs::db_query('select * from continent where timestamp >= ? and timestamp <= ?', $t, $t2);
		$locations = $q->hashes;
	}

  sub NESW { deg2rad($_[0]), deg2rad(90 - $_[1]) }
	&subs::setting_setter({ app => 'travel', setting => 'travel_scope', value => $travel_scope });
	&subs::setting_setter({ app => 'travel', setting => 'time_scope', value => $time_scope });

	my $universal_settings = {};
	$main_map->{'home_plate'}->{'app'} = $main_map->{'home_plate'}->{'legend'};
	my @home_plate = NESW($main_map->{'home_plate'}->{'longitude'}, $main_map->{'home_plate'}->{'latitude'});

	foreach my $sl (@{$locations}) {
		$universal_settings->{$sl->{'app'}} = &subs::settings_grabber({ app => $sl->{'app'} }) unless $universal_settings->{$sl->{'app'}};
		$sl->{'settings'} = $universal_settings->{$sl->{'app'}};
		next if $sl->{'settings'}->{'visible'} ne 'checked';
		my $radius = 6372.8;
		my @visitor = NESW($sl->{'longitude'}, $sl->{'latitude'});
		$sl->{'rad'} = clone \@visitor;
		$sl->{'rad'}->[2] = 2;
		my $distance = great_circle_distance(@home_plate, @visitor, $radius);
		my $metres = $distance * 1000;
		my $direction = great_circle_direction(@home_plate, @visitor);

		my @destination = great_circle_destination(@home_plate,$distance,$direction);

		$sl->{'direction'} = rad2deg($direction);

		$sl->{'destination'} = \@destination;
		$sl->{'distance'} = sprintf("%2f", $metres);
		$sl->{'home_plate'} = $main_map->{'home_plate'};
		push @{$proxies->{'near'}}, $sl;
		if ($metres <= $travel_scope) {

		}
		elsif ($metres == 0) {

		}
	}

	push @{$proxies->{'near'}}, $main_map->{'home_plate'};
	$proxies->{'here'} = $main_map->{'home_plate'};

	$proxies->{'html'} = $c->render_to_string(
		template => 'travel/proxy',
		proxies => $proxies,
		start_time => $t,
		end_time => $t2
	);

	$c->render(json => $proxies);
};


get '/manager/handbook/:chapter' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $chapter = $c->stash('chapter') || 'handbook';
	my $type = $c->param('type');
	my $windows = eval { return decode_json $c->param('windows') } || {};

	my $settings = &subs::settings_grabber({ app => 'handbook' });
	$settings->{'diagrams'} = eval { return decode_json $settings->{'diagrams'} } || [];
	my $pseudonyms = &pseudonym_maker('viewer', '');
	my $page = $c->param('page') || 'i';
	my $template = 'handbook/handbook';
	my $contents = $c->render_to_string(
		template => $template,
		layout => 'handbook',
		page => $page,
		chapter => $chapter,
		window_maker => $c->param('window_maker'),
		windows => $windows,
		type => $type,
		pseudonyms => $pseudonyms
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'handbook', contents => $contents }, $timestamp);
	$c->render(text => $website);
};

post '/manager/handbook/settings' => sub ($c) {
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $app = $c->param('app');
	my $handbook_settings = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => $setting }) } || {};

	if ($handbook_settings->{$app} eq 'enabled') {
		undef $handbook_settings->{$app};
	}
	elsif ($setting eq 'favourites') {
		$handbook_settings->{$app} = 'enabled';
	}

	my $jsetting = encode_json $handbook_settings;
	&subs::setting_setter({ app => 'handbook', setting => $setting, value => $jsetting });

	$c->render(json => $handbook_settings);


};

get '/manager/security' => sub ($c) {
	my $contents = &security_initializer($c);
	my $timestamp = $c->param('timestamp');

	if ($c->param('window_maker')) {
		$contents->{'html'} = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'security', contents => $contents->{'html'} }, $timestamp);
	}

	$c->render(json => $contents);

};

sub security_initializer($c) {
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $neighbour_link = &subs::db_select('neighbour_link')->hashes;
	my $president = &subs::settings_grabber({ app => '__president' });
	if ($c->param('security_view')) {
		$president->{'security_view'} = $c->param('security_view');
	}
	$president->{'padlock_contexts'} = eval { return decode_json $president->{'padlock_contexts'} } || [];
	my $contents = $c->render_to_string(
		president => $president,
		template => 'security',
		window_maker => $c->param('window_maker'),
		neighbour_link => $neighbour_link,
		config => $config
	);
	my $padlocker = &subs::db_select('security', undef, { level => 'padlock' })->hashes || [];
	if (scalar @{$padlocker} == 0) {
		&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
		&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
	}

	return { html => $contents, signatorial => $config->{'signatorial'} };
}

post '/manager/security/signatorial/selection' => sub($c) {
	my $file = $c->param('file');
	$config->{'signatorial'} = $file;
	my $jconfig = encode_json $config;
	write_file('./config.json', $jconfig);
	my $pp = `cat ./config.json | json_pp`;
	write_file('./config.json', $pp);

	my $contents = &security_initializer($c);
	$c->render(json => $contents);
};

post '/manager/security/neighbour_link_assign' => sub($c) {
	my $remote_address = $c->param('remote_address');
	my $local_address = $c->param('local_address');
	my $privilege = $c->param('privilege');
	my $name = $c->param('my_name');
	my $credential = $c->param('credential');
	my $data = {
		initiator => $remote_address,
		initiated => $local_address,
		server_time => &subs::rightNow(),
		name => $name,
		status => $privilege,
		uuid => &subs::random_string_creator(252),
		credential => &subs::encrypter($c->session('suds'),$credential)
	};
	&subs::db_insert('neighbour_link', $data);
	$c->render('text' => 'ok');
};

post '/manager/security/neighbour_link_privilege' => sub($c) {
	my $privilege = $c->param('privilege');
	my $uuid = $c->param('uuid');
	my $server_time = &subs::rightNow();
	if ($uuid) {
		&subs::db_update('neighbour_link', { status => $privilege, server_time => $server_time }, { uuid => $uuid });
	}
	$c->render(text => &security_initializer($c));
};

post '/manager/security/neighbour_link_delete' => sub($c) {
	my $uuid = $c->param('uuid');
	if ($uuid) {
		&subs::db_delete('neighbour_link', { uuid => $uuid });
	}
	$c->render(text => &security_initializer($c));
};

post '/manager/security/padlock' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $combo = $c->param('combo');
	my $pulled = $c->param('pulled');
	my ($j_pulled,$salt,$salty,$saved_pulled);
	my ($db) = &subs::database_grabber();
	my $padlocker = &subs::db_select('security', undef, { level => 'padlock' })->hashes || [];
	my $padlock = $padlocker->[0];
	$pulled = eval { return decode_json $pulled } || [];
	if (scalar @{$padlocker} > 0 && scalar @{$pulled} == 0) {

		$c->render(json => { status => 'failed cuz 0'});
	}
	if (scalar @{$pulled} > 0 && scalar @{$padlocker} > 0) {
		$j_pulled = eval { return encode_json $pulled };
		$salty = join '', @{$pulled};
		$saved_pulled = &subs::note_decrypter($salty . $c->session('suds') . $salty, $padlock->{'credential'});
	}
	if ((scalar @{$padlocker} == 0) || (secure_compare( $j_pulled, $saved_pulled )) ) {
		$combo = eval { return decode_json $combo };
		$salt = join '', @{$combo};
		my $combination = eval { return encode_json $combo };
		$combo = &subs::note_encrypter($salt . $c->session('suds') . $salt,$combination);
		my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '2h';
		$activity_timeout = &subs::time_abbrev_translator($activity_timeout);
		$c->session('padlock', $activity_timeout);
		&subs::db_delete('security', { level => 'padlock' });
		&subs::db_insert('security', { level => 'padlock', credential => $combo, timestamp => $timestamp, server_time => &subs::rightNow(), uuid => &subs::random_string_creator(30) });
		$c->render(json => { status => 'saved' });
	}
	else {
		$c->render(json => { status => 'failed cuz different'});
	}
};

post '/manager/security/padlock/delete' => sub ($c) {
	&subs::db_delete('security', { level => 'padlock' });
	&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
	&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
	$c->render(text => 'ok');
};

post '/manager/security/padlock_pull' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $mode = $c->param('mode');
	my $digits = eval { return decode_json $c->param('digits') } || [];
	my $salt = join '', @{$digits};

	my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes->[0];
	unless ($padlock->{'credential'}) {
		&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
		&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
	}

	my $combo = &subs::note_decrypter($salt . $c->session('suds') . $salt, $padlock->{'credential'});
	my $attempts = &subs::note_decrypter($c->session('suds'), &subs::setting_grabber({ app => '__president', setting => 'padlock_pulls' })) || 0;
	$attempts += 1;

	if ($attempts > 5) {
			&Websocket::send('server', { console => 'leave()' });
	}
	if (my $combination = eval { return decode_json $combo }) {
		my $success = 0;
		for (my $n = 0; $n <= 2; $n++) {
			if ($digits->[$n] == $combination->[$n]) {
				$success = 1;
			}
			if ($success == 0) {
				last;
			}
		}
		if ($success == 1) {
			$attempts = 0;

			my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
			$activity_timeout = abs &subs::time_abbrev_translator($activity_timeout);
			my $new_timeout = &subs::rightNow() + $activity_timeout;
			$c->session('pl_time' => $new_timeout);
			if ($mode eq 'gallery') {
				my $combo_unlock = &subs::note_encrypter($c->session('suds'), &subs::random_string_creator(255));
				&subs::setting_setter({ app => 'gallery', setting => 'combo_unlock', value => $combo_unlock });
				&Websocket::send('server', { console => '$("#gallery").attr("unlock", "' . $combo_unlock .'")', browser_tab_id => $c->param('browser_tab_id') });
				&Websocket::send('server', { console => 'imageViewer({ "view":"home" })', browser_tab_id => $c->param('browser_tab_id') });
			}
			if ($mode eq 'music') {
				my $combo_unlock = &subs::note_encrypter($c->session('suds'), &subs::random_string_creator(255));
				&subs::setting_setter({ app => 'music', setting => 'combo_unlock', value => $combo_unlock });
				&Websocket::send('server', { console => '$("#music").attr("unlock", "' . $combo_unlock .'")', browser_tab_id => $c->param('browser_tab_id') });
				&Websocket::send('server', { console => 'searchMusic()', browser_tab_id => $c->param('browser_tab_id') });
			}
			else {
				&Websocket::send('server', { console => '$(\'#padlock_frame\').html(\'\'); $(\'#padlock_frame\').hide();$(\'#everything\').show();'});
				&subs::setting_setter({ app => '__president', setting => 'pl_time', value => &subs::encrypter($c->session('suds'), $new_timeout) });
			}

			$c->render(json => { status => 'success', pulled => $combo });
 			&remote_relay_request($c);
		}
	}
	else {
		if ($device eq 'mobile') {
			$c->stash('app' => 'customs');
			&take_picture($c, {
				app => 'customs',
				camera => 1
			});
			&take_picture($c, {
				app => 'customs',
				camera => 0
			});
		}
		else {
			&take_picture($c, {
				app => 'customs',
				camera => 'webcam'
			});
		}
		$c->session('app' => undef);
		$c->render(json => { status => 'fail' });
	}

	$attempts = &subs::note_encrypter($c->session('suds'),$attempts);
	&subs::setting_setter({ app => '__president', setting => 'padlock_pulls', value => $attempts });
};

sub padlock_time_extender($c) {
#	Mojo::IOLoop->subprocess->run_p(sub {
		my $session_timeout = $c->session('pl_time');
		my $server_time = &subs::rightNow();
		my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes;
		if ($c->session('authentication') eq 'approved' && $session_timeout > $server_time && scalar @{$padlock} > 0) {
			my $attempts = &subs::note_decrypter($c->session('suds'), &subs::setting_grabber({ app => '__president', setting => 'padlock_pulls' }));
			if ($attempts < 5) {
				my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
				$activity_timeout = abs &subs::time_abbrev_translator($activity_timeout);
				my $padlock_time = &subs::decrypter($c->session('suds'), &subs::setting_grabber({ app => '__president', setting => 'pl_time' }) );
				if ($padlock_time > $server_time) {
					my $new_time = $server_time + $activity_timeout;
					&subs::setting_setter({ app => '__president', setting => 'pl_time', value => &subs::encrypter($c->session('suds'), $new_time) });
					$c->session('pl_time' => $new_time);
				}
			}
		}
#	});
}

sub sms_message_send($digits,$message) {
	$digits =~ s/\S\d(?=\d{10})//;
	if (&subs::device_setter() eq 'mobile') {
		if ( $digits ) {
			$message =~ s/\$/\\\$/gi;
			`termux-sms-send -n $digits "$message"`;
		}
	}
	else {
		Mojo::IOLoop->subprocess->run_p(sub {
			my $remote_machines = &subs::db_query('select * from remote_machines where connection=? and device=?', 'active', 'mobile')->hashes;
			foreach my $rm ( @{$remote_machines} ) {
				$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
				my $res = $rm->{'ua'}->post($rm->{'manager'} . '/manager/sms/message?digits=' . $digits . '&message=' . uri_encode $message);
				if (eval {decode_json $res}) {
					next;
				}
			}
		});
	}
	return ($digits,$message);
}

post '/manager/sms/message' => sub($c) {
	my $digits = $c->param('digits');
	my $message = $c->param('message');

	my $sms = &sms_message_send($digits,$message);

	$c->render(json => $sms);

};

get '/manager/configure/sms_list_check' => sub ($c) {
	my $returner = &subs::sms_list_check();
	$c->render(text => $returner);
};

post '/manager/delete_app' => sub($c) {
	my $app = $c->param('app');
#	&subs::cache_delete({ app => $app, context => 'template' });
	my $uuid = $c->param('uuid');
	my $timestamp = $c->param('timestamp');
	my $type = $c->param('type');
	my $server_time = $c->param('server_time');
	my $deleter = &delete_app($app,$uuid,$server_time,'manual delete');
	&padlock_time_extender($c);
	my $cv = &centre_view_grabber({ c => $c, app => &subs::unformat_name($app), timestamp => $timestamp });
	$c->render(json => { centre_view => $cv, deleter => $deleter });

};

sub delete_app($app,$uuid,$server_time,$reason) {
	my $appt = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app, server_time => $server_time });
	my $appts = $appt->hashes;
	my $status = '';
	if (scalar @{$appts} > 0) {

		foreach my $app ( @{$appts} ) {
			$status = $app->{'type'};
			&subs::db_delete('continent', { app => $app->{'app'}, uuid => $app->{'uuid'} });
			&subs::db_query('delete from continent where app = ? and uuid like ?', $app->{'app'}, $app->{'uuid'} . '%' );

			if ($app->{'file'} && $app->{'source'} ne 'music' && $app->{'account'} ne 'gallery' && $app->{'type'} ne 'view' && $app->{'type'} ne 'listen') {
				my $filings = eval { return decode_json $app->{'file'} } || [];
				foreach my $f (@{$filings}) {
					my $filing = $f->{'f'};
					&delete_file({ app => $app->{'app'}, app_uuid => $uuid, file_uuid => $f->{'uuid'}, reason => 'delete_app' });
				}
			}
			&subs::db_delete('appointments', { uuid => $app->{'uuid'} });
		}

		&embedded_app_deleter({ appt_uuid => $uuid });
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;
		foreach my $so ( @{$sources} ) {
			&embedded_app_deleter({ appt_uuid => $so->{'uuid'} });
			&delete_app($so->{'app'},$so->{'uuid'},$so->{'server_time'},'source deletion');
		}
		&Websocket::send($app, { console => '$(\'.appointment_detail[app="' . $app . '"][uuid="' . $uuid . '"]\').remove();'});
		&deletion_registration({ table => 'appointments', app => $app, uuid => $uuid, scope => 'single', server_time => $server_time });
		&subs::vacuum($app);
		&subs::log_writer('deletion ' . $app . ' '  . $reason);

		&budget_runner($app);
	}
	return { appts => $appts, status => $status };
}

sub is_folder_empty {
	my $dirname = shift;
	opendir(my $dh, $dirname);# or die "Not a directory";
	return scalar(grep { $_ ne "." && $_ ne ".." } readdir($dh)) == 0;
}

sub delete_file($data) {
	my $file_uuid = $data->{'file_uuid'};
	return unless $data->{'file_uuid'};
	my $app_uuid = $data->{'app_uuid'};
	my $app = $data->{'app'};

	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];
	foreach my $file ( grep { $_->{'uuid'} eq $file_uuid } @{$files} ) {
		my $filing = $file->{'f'};
		my $thumb = $file->{'thumb'};
		if ($file->{'att'}) {
			my $att_file = &subs::db_select($file->{'att'}, undef, { uuid => $file->{'att_uuid'}, app => $appt->{'app'} })->hashes->[0];

			my $atf = eval { return decode_json $att_file->{'file'} } || [];
			@{$atf} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$atf};

			my $jaf = encode_json $atf;
			&subs::db_update($file->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
		}

		if ($file->{'function'} eq 'signatorial') {
			my $signatorials = eval { return decode_json &subs::setting_grabber({ app => 'customs', setting => 'signatorials' }) } || [];
			@{$signatorials} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$signatorials};
			my $jsignatorials = encode_json $signatorials;
			&subs::setting_setter({ app => 'customs', setting => 'signatorials', value => $jsignatorials });
		}
		elsif ($file->{'function'} eq 'receipt') {
			my $receipts = eval { return decode_json &subs::setting_grabber({ app => 'budget', setting => 'receipts' }) } || [];
			@{$receipts} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$receipts};
			my $jreceipts = encode_json $receipts;
			&subs::setting_setter({ app => 'budget', setting => 'receipts', value => $jreceipts });
		}
		elsif ($file->{'function'} eq 'map') {
			my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
			@{$maps} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$maps};
			my $jmaps = encode_json $maps;
			&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
		}
		elsif ($file->{'function'} eq 'diagram') {
			my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => 'diagrams' }) } || [];
			@{$diagrams} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$diagrams};
			my $jdiagrams = encode_json $diagrams;
			&subs::setting_setter({ app => 'handbook', setting => 'diagrams', value => $jdiagrams });
		}
		elsif ($file->{'function'} eq 'background') {
			my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
			@{$backgrounds} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$backgrounds};
			my $jbackgrounds = encode_json $backgrounds;
			&subs::setting_setter({ app => 'marker', setting => 'background', value => $jbackgrounds });
		}

		if ($thumb && -e $thumb) {
			`shred -u $thumb`;
			my @folder = split '/', $thumb;
			pop @folder;
			my $folder = join '/', @folder;
			if (&is_folder_empty($folder)) {
				rmdir( $folder );
			}
		}

		if (-e $filing) {
			my $file = $filing;
			`shred -u $file`;
			my @folder = split '/', $file;
			pop @folder;
			my $folder = join '/', @folder;

			my $thumb_folder = $folder . '/thumbs';
			if (-e $thumb_folder) {
				if (&is_folder_empty($thumb_folder)) {
					rmdir( $thumb_folder );
				}
			}

			if (&is_folder_empty($folder)) {
				rmdir( $folder );
			}
		}
	}
	@{$files} = grep { $_->{'uuid'} ne $file_uuid } @{$files};
	my $jfiles = encode_json $files;
	if (scalar @{$files} == 0 && $data->{'reason'} ne 'delete_app' && grep { $appt->{'type'} eq $_ } qw/image video scan/) {
		&delete_app($app,$app_uuid,$appt->{'server_time'},'file deletion');
	}
	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jfiles }, { app => $app, uuid => $app_uuid });
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $app_uuid .'\');'});
	&deletion_registration({ table => 'appointments', app => $app, uuid => $app_uuid, file_uuid => $file_uuid, scope => 'file', server_time => $appt->{'server_time'} });
}

post '/manager/delete_file' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	&delete_file({ app => $app, file_uuid => $file_uuid, app_uuid => $app_uuid });
	
	$c->render(json => { app => $app, file_uuid => $file_uuid, app_uuid => $app_uuid });
};

sub deletion_registration($data) {
	my $app = $data->{'app'};
	my $uuid = $data->{'uuid'};
	my $scope = $data->{'scope'};
	my $table = $data->{'table'};
	my $server_time = $data->{'server_time'};
	my $remote_machines = &subs::db_select('remote_machines')->hashes;
	foreach my $rm ( @{$remote_machines} ) {
		my $deletions = eval { return decode_json $rm->{'deletions'} } || [];
		push @{$deletions}, { table => $table, app => $app, uuid => $uuid, scope => $scope, initialization => &subs::rightNow(), server_time => $server_time };
		my $del = encode_json $deletions;
		&subs::db_update('remote_machines', { deletions => $del }, { uuid => $rm->{'uuid'}, ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'} });
	}
}

sub deletion_performer($json) {
	my $deletions = eval { return decode_json $json } || [];
	my $returner = [];
	if (scalar @{$deletions} == 0) { return []; }
	foreach my $deletion ( @{$deletions} ) {
		if ($deletion->{'table'} eq 'appointments') {
			if ($deletion->{'scope'} eq 'single') {
				&delete_app($deletion->{'app'},$deletion->{'uuid'},$deletion->{'server_time'},'deletion performer single');
			}
			elsif ( $deletion->{'scope'} eq 'vacuum' ) {
				&subs::vacuum_app($deletion->{'app'});
			}
			elsif ( $deletion->{'scope'} eq 'file' ) {
				&delete_file({ app => $deletion->{'app'}, app_uuid => $deletion->{'uuid'}, file_uuid => $deletion->{'file_uuid'} });
			}
		}
		else {
			&subs::db_delete($deletion->{'table'}, { uuid => $deletion->{'uuid'}, server_time => $deletion->{'server_time'} });
		}
		push @{$returner}, $deletion;
	}
	return $returner;
}

get '/manager/edit_app' => sub($c) {
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $select = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid, timestamp => $timestamp })->hashes->[0];
	my $s = $c->session('suds');
	foreach my $note_type (qw/start_notes notes end_notes/) { 
		$select->{$note_type} = &subs::note_decrypter($s, $select->{$note_type},$select->{'ost'}) if eval { &subs::note_decrypter($s, $select->{$note_type},$select->{'ost'}) };
	}
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });
	$c->render(template => 'apps/edit_app', app => $select, appts => $appts);
};

post '/manager/edit_app' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
#	&subs::cache_delete({ app => $app, context => 'template' });
	my $server_time = &subs::rightNow();
	my $uuid = $c->param('uuid');
	my $app_name = &subs::unformat_name($c->param('app_name'));
	my $account = &subs::unformat_name($c->param('account'));
	my $project = &subs::unformat_name($c->param('project'));
	my $timestamp = $c->param('timestamp');
	my $duration = &subs::time_abbrev_translator($c->param('duration'));
	my $warranty = $c->param('warranty');
	my $movement = $c->param('movement');
	my $amount = $c->param('amount');
	my $tax = $c->param('tax');
	my $aux = $c->param('aux');
	my $aux_description = $c->param('aux_description');
	my $has_tax = $c->param('has_tax');
	my $has_totes = $c->param('has_totes');
	my $state = $c->param('state');
	my $total = $c->param('total');
	my $manufacturer = $c->param('manufacturer');
	my $vendor = $c->param('vendor');
	my $unit = $c->param('unit');
	my $quantity = $c->param('quantity');
	my $item = $c->param('item');
	my $model = $c->param('model');

	my $init = &subs::setting_initializer($app_name,$server_time);
	$app_name = $init->{'app'};
	my ($start_notes,$notes,$end_notes);
	$start_notes = &subs::note_encrypter($c->session('suds'),$c->param('start_notes')) if $c->param('start_notes');
	$notes = &subs::note_encrypter($c->session('suds'),$c->param('notes')) if $c->param('notes');
	$end_notes = &subs::note_encrypter($c->session('suds'),$c->param('end_notes')) if $c->param('end_notes');
	my $seen = 'yes';
	if ($timestamp > $server_time) {
		$seen = undef;
	}
	my $data = {
		timestamp => $timestamp,
		duration => $duration,
		warranty => $warranty,
		seen => $seen,
		app => $app_name,
		account => $account,
		project => $project,
		start_notes => $start_notes,
		notes => $notes,
		end_notes => $end_notes,
		movement => $movement,
		amount => $amount,
		tax => $tax,
		aux => $aux,
		aux_description => $aux_description,
		total => $total,
		manufacturer => $manufacturer,
		vendor => $vendor,
		unit => $unit,
		quantity => $quantity,
		item => $item,
		model => $model,
		has_tax => $has_tax,
		has_totes => $has_totes,
		'state' => $state,
		server_time => $server_time
	};

	&subs::db_update('appointments', $data,
	{
		uuid => $uuid,
		app => $app
	});

	my $cv = &centre_view_grabber({ c => $c, app =>&subs::unformat_name($app), timestamp => $timestamp });
	&budget_runner($app);
	&padlock_time_extender($c);
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
	$c->render(text => 'ok');
};

get '/manager/configure/adopt_app' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');
	my $scope = $c->param('scope') || 'h';
	my $bt = &subs::ago_calc($scope, $timestamp);
	my $misc_settings = &misc_setting_list();
	my $html;
	$c->param('duty' => 'adoption');
	foreach my $ms ( keys %{$misc_settings->{$device}} ) {
		if ($ms =~ /_location$/) {
			my $folder_name = $ms;
			$folder_name =~ s/_location$//gi;
			my $folder = &subs::home($misc_settings->{$device}->{$ms} . '/' . $app);

			my @files = split /\n/, `ls $folder`;

			if (scalar @files > 0) {
				$html .= '<h3>' . &subs::format_name($folder_name) . ':</h3> ' . $folder . '<br>';
				foreach my $file ( @files ) {
					my $full_file = $folder . '/' . $file;
					my $file_q = &subs::db_query('select * from appointments where app = ? and file like ? and file is not null', $app, '%' . $file)->hashes;
					if (scalar @{$file_q} == 0) {
						$c->param('file' => $full_file);
						my $job = &rock_and_roll($c);
						if ($file =~ /\.jpg|\.png|\.bmp/) {
							my $image = $job->{'image'};
							$html .= '<img class="gigantic_thumb adopt_file" type="image" app="' . $app . '" timestamp="' . $job->{'timestamp'} . '" file="' . $full_file . '" src="' . $image . '">';
						}
						elsif ($file =~ /\.mpg|\.webm|\.mp4/) {
							$c->param('file' => $full_file);
							my $job = &rock_and_roll($c);
							my $image = $job->{'image'};
							$html .= '<video controls loop class="gigantic_thumb adopt_file" type="video" app="' . $app . '" timestamp="' . $job->{'timestamp'} . '" file="' . $full_file . '" src="/file_open?timestamp=' . $job->{'timestamp'} . '&file=' . $full_file . '"></video>';
						}
					}
				}
			}
		}
	}
	$html .= '<br><br><img src="/images/decipherable/adopt.png" class="medium_thumb" app="' . $app . '" id="adopt_app_confirm">&nbsp;&nbsp;<img src="/images/make believe/cancel_button.png" id="alert_cancel" class="medium_thumb">';
	$c->render('text' => $html);
};

post '/manager/configure/adopt_app_confirm' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $files = $c->param('files');
	my $timestamp = $c->param('timestamp');

	$files = eval {return decode_json $files } || [];
	my $push_files = [];
	my $upload_type;
	foreach my $file ( @{$files} ) {
		my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $file->{'file'}, app => $app, type => $file->{'type'}, is_thumb => 1 });
		my $data = { server_time => $file->{'timestamp'}, f => $file->{'file'}, uuid => &subs::random_string_creator(8), type => $file->{'type'}, thumb => $destination . $asset };
		$data = &thumbnail_creator($data);
		push @{$push_files}, $data;
		$upload_type = $file->{'type'};

	}
	my $jfiles = encode_json $push_files;
	&appointment_writer($c,{
		app => $app,
		file => $jfiles,
		timestamp => $timestamp,
		type => $upload_type
	});
	$c->render('text' => 'ok');
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });
};

get '/manager/clothesline' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $project = &subs::unformat_name($c->param('project'));
	my $account = &subs::unformat_name($c->param('account'));
	my $time_plinkos = &clothesline_calculator($app);
	my $cl = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'clothesline' })} || {};
	my $html = $c->render_to_string(template => 'apps/clothesline', app => $app, cl => $cl , time_plinkos => $time_plinkos );
	&subs::hang_to_dry();
	$c->render(json => { html => $html});
};


post '/manager/clothesline' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	if ($c->param('is_json')) {
		$value = eval { return decode_json $value } || [];
	}
	my $cl = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'clothesline' })} || {};
	$cl->{$setting} = $value;
	my $jcl = encode_json $cl;
	&subs::setting_setter({ app => $app, setting => 'clothesline', value => $jcl });
	&subs::hang_to_dry();
	$c->render(json => $cl);
};

sub clothesline_calculator($app) {
	my $appts = &subs::db_select('appointments', undef, { app => $app })->hashes;
	my $time_plinkos = clone $gb::time_plinkos;

	foreach my $appt ( @{$appts} ) {
		my $time = localtime($appt->{'timestamp'} / 1000);
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
			push @{$time_plinkos->[$n]->{'clothes'}}, { formatted => $ft, value => $time->[$n] };
		}
	}
	foreach my $tp ( @{$time_plinkos} ) {
		foreach my $cl ( @{$tp->{'clothes'}} ) {
			my @seen = grep { $_->{'formatted'} eq $cl->{'formatted'} } @{$tp->{'clothes'}};
			if (scalar @seen >= 2) {
				$tp->{'reoccuring'}->{$cl->{'formatted'}} = [] unless $tp->{'reoccuring'}->{$cl->{'formatted'}};
				push @{$tp->{'reoccuring'}->{$cl->{'formatted'}}}, $cl;
			}
		}
	}
	&subs::hang_to_dry();
	return $time_plinkos;
}


get '/manager/volume_control' => sub($c) {
	my $return_volume = '[]';
	my $stream = $c->param('stream');
	my $volume = $c->param('volume');
	my $max = $c->param('max');
	my $card = $c->param('device');
	my $remote_machines = &subs::db_select('remote_machines', undef, { connection => 'active' })->hashes;
	my ($json_vol,$md);

	if ($card && lc $card ne 'local' && grep { $_->{'uuid'} eq $card } @{$remote_machines}) {
		$c->param('device', 'local');
		$c->param('remote_uuid', $card);
		my $jdata = &remote_relay_request($c);
		my $data = eval { return decode_json $jdata } || {};
		$json_vol = $data->{'volumes'};
		$md = eval { return decode_json $data->{'md'} } || {};
	} 
	else {
		if ($stream && $volume) {
			if ($device eq 'mobile') {
				$stream = lc $stream;
				`termux-volume $stream $volume`;
			}
			else {
				`amixer set $stream $volume%`;
			}
		}
		if ($device eq 'mobile') {
			$return_volume = `termux-volume`;
		}
		else {
			foreach my $control ( qw/Master Capture/ ) {
				my $amixer = `amixer get $control`;
				my @lines = split /\n/, $amixer;

				my $volume;
				foreach my $l ( @lines ) {
					if ($l =~ /Left:/gi) {
						my @p = split ' ', $l;
						my $p = $p[-2];
						$p =~ s/[^0-9]//gi;
						$volume = $p;
					}
				}
				push @{$json_vol}, { stream => $control, volume => $volume, max_volume => 100 };
			}

		}
		if ($device eq 'mobile') {
			$json_vol = decode_json $return_volume;
		}
	
		foreach my $j ( @{$json_vol} ) {
			$j->{'stream'} = &subs::format_name($j->{'stream'});
		}
		my $ws_watcher = &subs::home('~/.president/ws_watcher');
		$md = eval { return decode_json read_file($ws_watcher) } || {};
	}

	$c->render( json => { volumes => $json_vol, remote_machines => $remote_machines, md => $md });

};

post '/manager/clothesline' => sub($c) {
	my $app = $c->param('app');
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $timestamp = $c->param('timestamp');
	my $cl = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'clothesline' })} || {};

	$c->render(json => $cl);
};

post '/manager/calculate' => sub($c) {
	my $formula = $c->param('formula');
	my ($evaluation,$uom,$format);
	($formula,$evaluation,$uom,$format) = &formula_calculator($formula);

	$c->render(json => { format => $format, formula => $formula, evaluation => $evaluation, uom => $uom });
};

sub formula_calculator($formula) {
	my @formula = split / /, $formula;
	my ($evaluation,$uom,$format);
	my $formulas = [];
	if ($formula =~ /[a-zA-Z]/) {
		for (my $n = 0; $n <= scalar @formula; $n++ ) {
			if ($formula[$n] eq 'to') {
				my $pre = $formula[$n - 1];
				my $pre_unit = $pre;
				my $pre_number = $pre;
				$pre_number =~ s/[A-Za-z]//gi;
				$pre_unit =~ s/[0-9.-]//gi;

				my $post = $formula[$n + 1];
				my $post_number = $post;
				my $post_unit = $post;

				$post_number =~ s/[A-Za-z]//gi;
				$post_unit =~ s/[0-9.-]//gi;

				my $post_measure = $gb::measures->{$post_unit};
				unless ($post_measure) {
					foreach my $pu ( ( lc $post_unit, uc $post_unit ) ) {
						$post_measure = $gb::measures->{$pu};
						if ($post_measure->{'name'}) { last; }
					}
				}



				foreach my $for ( @{$gb::measures->{$pre_unit}->{'formulas'}} ) {
					if ($for =~ /\Q$post_unit/gi) {
						$for =~ s/x/\Q$pre_number/gi;
						$for =~ s/\Q$post_unit//gi;
						$for =~ s/\\//gi;

						push @{$formulas}, $for;
						$evaluation = eval  $for;
						last if $post_unit eq $post;
						if ($gb::measures->{$post_unit}->{'format'}) {
							$format = $gb::measures->{$post_unit}->{'format'};
						}
						else {
							$format = '0.000';
						}
						$uom = $post_unit;
					}
				}

#				foreach my $for ( @{$gb::measures->{$post_unit}->{'formulas'}} ) {
#					if ($for =~ /\Q$pre_unit/gi) {
#						$for =~ s/x/\Q$pre_number/gi;
#						$for =~ s/\Q$pre_unit//gi;
#						$for =~ s/\\//gi;
#						push @{$formulas}, $for;
#						$evaluation = eval { $for };
#						if ($gb::measures->{$post_unit}->{'format'}) {
#							$format = $gb::measures->{$post_unit}->{'format'};
#						}
#						else {
#							$format = '0.000';
#						}
#						$uom = $post_unit;
#					}
#				}
			}
		}
	}
	else {
		$evaluation = eval $formula;
	}
	return ($formula,$evaluation,$uom,$format);
}


post '/manager/keyboard' => sub($c) {
	my $kb = &keyboard_maker($c);
	$c->render(text => $kb);
};

sub keyboard_maker($c) {
	my $timestamp = $c->param('timestamp');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $toggle = $c->param('toggle');
	my $accts = [];
	my $projs = [];
	my $accounts = &subs::db_query("select * from settings where setting = ? and value=?",'pos','account');
	my $acc = $accounts->hashes;
	my $keys = {};
	if ($toggle eq 'keyboard' || $toggle eq 'calculator') {
		foreach my $key (@{$gb::inputs}) {
			$keys->{$key->{'c'}} = &subs::random_string_creator();
		}
		foreach my $key (keys %{$gb::measures}) {
			$keys->{$key} = encode_json $key;
		}
		my $key_cutter = &subs::encrypter($c->session('suds'), encode_json($keys));
		&subs::setting_setter({ app => 'keyboard', setting => $toggle, value => $key_cutter, timestamp => $timestamp, browser_tab_id => $browser_tab_id });
	}
	if ($toggle eq 'delorean') {
		foreach my $a ( reverse @{$acc} ) {
			push @{$accts},$a unless grep { $_->{'app'} eq $a->{'app'}} @{$accts};
			$a->{'formatted_name'} = &subs::format_name($a->{'app'});
		}
		my $projects = &subs::db_query("select * from settings where setting = ? and value=?",'pos','project');
		my $proj = $projects->hashes;

		foreach my $a ( reverse @{$proj} ) {
			push @{$projs},$a unless grep { $_->{'app'} eq $a->{'app'}} @{$projs};
			$a->{'formatted_name'} = &subs::format_name($a->{'app'});
		}
	}

	my ($av_data);
	if ($c->param('avData') && $toggle eq 'walkboy') {
		$av_data = decode_json($c->param('avData'));

		foreach my $av (@{$av_data}) {
			if ($av->{'kind'} eq 'audioinput') {
				$av->{'icon'} = 'microphone';
			}
			elsif ($av->{'kind'} eq 'videoinput') {
				if ($av->{'label'} =~ /front/gi) {
					$av->{'icon'} = 'camera front';
				}
				else {
					$av->{'icon'} = 'camera back';
				}
				
			}
			elsif ($av->{'kind'} eq 'audiooutput') {
				$av->{'icon'} = 'speaker';
			}
		}
	}
	my $websockets;
	if ($toggle eq 'console' || $toggle eq 'controller') {
		my $web_query = &subs::db_query('select * from websockets where browser_tab_id = ?',$browser_tab_id);
		$websockets = $web_query->hashes;
	}
	my $notifications;
	if ($toggle eq 'notifications') {
		$notifications = &notification_grabber({});
	};
	my $config = &subs::config_reader();
	my $remote_connect = $gb::ws;
	my $kb = $c->render_to_string(
		browser_tab_id => $browser_tab_id,
		accounts => $accts,
		projects => $projs,
		template => 'keyboard',
		'keys' => $keys,
		toggle => $toggle,
		device => $device,
		av_data => $av_data,
		websockets => $websockets,
		notifications => $notifications,
		
		config => $config,
		manager_file => &manager_file_maker($c->session('name')),
		pseudonyms => &pseudonym_maker('viewer', ''),
		measures => $gb::measures,
		ws => $gb::ws,
	);
	return $kb;
}

sub manager_file_maker($session_name) {
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

get '/manager/keyboard_alias' => sub($c) {
	my $key = $c->param('key');
	my $toggle = $c->param('toggle');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $value = &subs::db_select('settings', ['value','timestamp'], { app => 'keyboard', setting => $toggle, browser_tab_id => $browser_tab_id })->hash;
	my $key_cutter = &subs::decrypter($c->session('suds'),$value->{'value'});
	$key_cutter = decode_json $key_cutter;
	foreach my $k (keys %{$key_cutter}) {
		if ($key_cutter->{$k} eq $key) {
			$key = $k;
		}
	}
	my $path = './public/icons/lettering/' . $key . '.png';
	if (! -e $path) {
		$path = './public/icons/lymeboard' . $key . '.png';
		if (! -e $path) {
			my @b = grep { $_->{'c'} eq $key } @{$gb::inputs};
			if ($b[0]->{'img'}) {
				$path = './public/icons/lymeboard/' . lc $b[0]->{'img'} . '.png';
			}
		}
	}
	my $paths = Mojo::File->new($path);
	$c->render_file('filepath' => $paths->to_string);
};

post '/manager/keyboard_presser' => sub($c) {

	my $key = $c->param('key');
	my $toggle = $c->param('toggle');
	my $shift = $c->param('shift');
	my $ctrl = $c->param('ctrl');
	my $fn = $c->param('fn');
	my $timestamp = $c->param('timestamp');
	my $destination = $c->param('destination');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $value = &subs::db_select('settings', ['value','timestamp'], { app => 'keyboard', setting => $toggle, browser_tab_id => $browser_tab_id })->hash;
	my $key_cutter = &subs::decrypter($c->session('suds'),$value->{'value'});
	$key_cutter = decode_json $key_cutter;
	foreach my $k (keys %{$key_cutter}) {
		if ($key_cutter->{$k} eq $key) {
			$key = $k;
			$key = uc $key if $shift eq 'yes';
		}
	}
	&Websocket::send('server', { key => $key, origin => $browser_tab_id, destination => $destination, toggle => $toggle, timestamp => $timestamp });
  $c->render(json => { key => $key });
};


get '/manager/say_it' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $words = $c->param('words');
	&subs::say_it($words);
	$c->render(text => 'said ' . $words);
	&Websocket::send('server', { json => { type => 'command', command => 'say_it', params => $words, timestamp => $timestamp } });
};



sub lock_screen($c) {
	if ($c) {
		my $authentication = $c->session('authentication');
		if (-e $database && $device eq 'mobile') {
		}	
	}
}


sub unlock_screen($c) {
	my $authentication = $c->session('authentication');
	if (-e $database && $device eq 'mobile') {
		my $finger = `termux-fingerprint`;
		if (my $fingerprint = eval { return decode_json $finger }) {
			if ($fingerprint->{'auth_result'} eq 'AUTH_RESULT_SUCCESS') {
				$c->session('authentication' => 'approved');
			}
			else {
				$c->session('authentication' => 'rejected');
			}
		}
	}
}



sub notification_sender($m,$db) {
	my $origin = &subs::format_name(&subs::setting_grabber({ app => 'me', setting => 'computer_name' })) ||&subs::shorthand_name(`hostname`);

	my $message = $m->{'message'};
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($m->{'app'} || '');
	$m->{'settings'} = &subs::settings_grabber({ app => $app, settings => [
		'start_notification_text', 'stop_notification_text', 'budget_notification_text', 'notification_text',
		'start_notification_sound', 'stop_notification_sound', 'budget_notification_sound', 'notification_sound'
	] }) unless $m->{'settings'};
	my $title = ($origin) . ': ' . $m->{'title'};

	$m->{'timestamp'} = &subs::rightNow();
	my $sound = $m->{'sound'} || 'ding.mp3';
	my $sound_file = $m->{'settings'}->{$m->{'type'} . '_notification_sound'} || './public/sounds/notifications/' . $sound;
	my $words = $m->{'words'} || $m->{'message'} || $m->{'settings'}->{$m->{'type'} ? $m->{'type'} . '_notification_text' : 'notification_text'};
	if ($m->{'synth'}) {
		threads->create(sub() {
			&subs::run_command($m->{'synth'} . ' &');
			if ($m->{'words'}) {
				&subs::say_it($m->{'words'});
			}
		});

	}
	else {
		threads->create(sub() {
			if ($sound) {
				my $co = 'play -q ' . $sound_file;
				`$co`;
			}
			if ($words) {
				&subs::say_it($words);
			}
		});
	}

	my $image;
	my $pwd = `pwd`;
	chomp $pwd;
	if ($m->{'image'}) {
		$image = $pwd . '/public' . $m->{'image'};
	}
	else {
		$image = &subs::setting_grabber({ app => &subs::unformat_name($m->{'title'}), setting => 'main_image' });
		unless (-e $image) {
			$image = $pwd . '/public/images/jonathans/logo red yellow.png';
		}
	}
	$image =~ s/ /\\ /gi;
	if ($device eq 'mobile') {
		my $id = &subs::random_string_creator();
		my $url = 'https://127.0.0.1:' . $ENV{PORT_AHOY} . '/manager?app=' . $m->{'app'} . '&timestamp=' . $m->{'timestamp'};
		`echo "$message" | termux-notification -i $id -t "$title" --vibrate "200,150,200,150" --image-path $image`;# --action termux-open "$url"`;# --on-delete "$pwd/scripts/app_displayer.pl '$app' close"`;
	}
	elsif ( eval { $sql->db } && $sql->dsn !~ /:$/) {

		my $c = app->build_controller;
		my $content = $c->render_to_string(
			n => $m,
			template => 'notification',
		);
		if ($m->{'role'} != 0) {
			&Websocket::send('server', {
				app => $m->{'app'},
				type => 'notification', 
				title => $m->{'title'},
				role => $m->{'role'} || 'guest',
				message => $m->{'message'},
				icon => $m->{'image'},
				timestamp => $m->{'timestamp'},
				html => $content
			});
		}

	}
	foreach my $embedded (qw/ watch teletype /) {
		my $watch = &subs::device_lister($m->{'timestamp'},$embedded);
		if (eval {$watch->{'ip'}}) {

			my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};
			my $ping_test = `$ping`;
			if ($ping_test =~ /ttl/gi) {
				my $ua = Mojo::UserAgent->new();
				$ua->connect_timeout(1);
				my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/notification?title=' . $title . 
					'&notification=' . $message . '&sound=/' . $sound . '&sound_file=' . $sound_file;
				threads->create(sub() {
					my $res = eval { return $ua->insecure(1)->get($watch_home)->result };
				});
			}
		}
	}
	if (eval { $sql->db } && $sql->dsn !~ /:$/) {
		my $db = $sql->db;

		&subs::db_insert('notifications', {
			app => $m->{'app'},
			role => $m->{'role'} || 3,
			title => $m->{'title'},
			image => $m->{'image'},
			message => $m->{'message'},
			timestamp => $m->{'timestamp'},
			uuid => $m->{'uuid'} || &subs::random_string_creator(20)
		});
	}

}

sub authentication_passer($c) {
	my $server_time = &subs::rightNow();

	my $authentication = $c->session('authentication') || 'revoked';
	if ($c->session('authentication') eq 'denial' || $c->session('reject_count') > 3 || ($c->stash('no') && $c->stash('no') == 1)) {
		my $denial = $c->render(template => 'guest_layouts/denial', message => '... and fuck you too!');
		$c->session('authentication' => 'fuck you');
		$authentication = 'denial';
		$c->rendered;
		return;
	}
	elsif ($authentication eq 'approved' && $c->session('server_time') > $server_time - 5100) {
		$c->session('server_time' => $server_time);
		return $authentication;
	}

	$c->session('server_time' => $server_time);
	my $suds = $c->session('suds');
	my $dob = $c->session('database');
	my $name = $c->param('name');
	my $warranty = $c->session('warranty');

	my $visitor = $c->tx->local_address eq $c->tx->remote_address ? 'Me' : ($c->param('manager_file') || $c->tx->remote_address);
	my $string = $c->tx->req->url->to_string;
	unless ($c->stash('browser_tab_id') && ($authentication eq 'approved' || $authentication eq 'revoked')) {
		&subs::say_it($visitor);
		my ($db,$database) = &subs::database_grabber();
		if ($db) {
			my $time = &subs::rightNow();
			my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || '-10d', $time);
			my $data = { warranty => $warranty, uuid => &subs::random_string_creator(40), app => 'customs', timestamp => $time, server_time => $time, type => 'dingaling', data => $visitor };
		#	my $insert = &subs::db_insert('appointments', $data );
		}
		&notification_sender({ app => 'customs', role => 'citizen', type => 'authentication', title => 'Dingaling', message => $visitor . ' ' . $string, image => "/images/make believe/lock.png" },$dob);
	}
	if (! -e $dob) {
		$authentication = "revoked";
	}
	else {
		my ($db,$database,$sql) = &subs::database_grabber();
		my $hardness;
		$hardness = &subs::decrypter($suds,&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});
		unless (secure_compare $hardness, $suds) {
			$authentication = 'revoked';
		}
		my $pres_settings = &subs::setting_grabber({ app => '__president', settings => [ 'padlock_contexts', 'pl_time' ] });
		my $padlock_sightings = eval { return decode_json $pres_settings->{'padlock_contexts'} } || [];
		my $padlock = [];
		my $padlock_time = $server_time;
		if ( grep { $_ eq 'general' } @{$padlock_sightings} ) {
			$padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes;
		
			my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
			$activity_timeout = &subs::time_abbrev_translator($activity_timeout);

			$padlock_time = &subs::decrypter($c->session('suds'), $pres_settings->{'pl_time'} ) || 0;

			$c->stash('pl_time' => $padlock_time);
		}

		if ($c->session('authentication') eq 'approved' && $server_time > $padlock_time && scalar @{$padlock} > 0) {
			&lock_session($c);
		}
		elsif ($c->session('source') eq 'ticket' && $c->session('authentication') eq 'approved') {
			my $tick = &subs::db_query('select * from tickets where uuid=?', $c->session('ticket_uuid') );
			my $ticket = $tick->hashes->[0];
			$c->stash('debriefer' => $ticket->{'debriefer'});
			if ($c->session('server_time') < $ticket->{'server_time'}) {
				my $secretive = $ticket->{'secret'};
				my $ver = url_unescape `echo "$secretive" | base64 --decode`;
				my $ts = &subs::note_decrypter($ticket->{'password'},$ver);
				my $sj = decode_json $ts;
				my $suds = &subs::note_decrypter($sj->{'p'}, $ticket->{'suds'});
				chomp $suds;
				$c->session('suds' => $suds);
				$c->session('server_time' => $server_time);
				$authentication = 'approved';
			}
			if ($ticket->{'warranty'} <= $server_time || $ticket->{'status'} ne 'active') {
				$authentication = 'revoked';
			}
			else {
				$c->session('warranty' => $ticket->{'warranty'});
			}

		}
		elsif ($c->session('warranty') < $server_time) {
			$authentication = 'revoked';
		}
	}
	unless ($authentication eq 'approved') {
		$c->session('authentication' => 'revoked');
		$c->session('bti', $c->stash('browser_tab_id'));
		my $restore_list = [];
		$c->session('database' => undef);
		$c->session('suds' => undef);
		unless (-e $database) {
			if ($c->param('restore_list')) {
				my $list = $c->param('restore_list');
				$restore_list = &subs::restore_list($list);
				@{$restore_list} = grep { $_->{'filename'} =~ /enc$/gi } @{$restore_list};
			}
		}
		my $start_dir = $config->{'start_dir'};
		if ($c->param('neighbour')) {
			$c->render(json => { purpose => $device, 'restore_list' => $restore_list });
		}
		else {
			$c->render(
				template => 'gate',
				layout => 'gate',
				restore_list => $restore_list,
				start_dir => $start_dir,
				config => { 'gate' => {'background_colour' => $config->{'gate'}->{'background_colour'} } },
			);
		}
	}
	return $authentication;
}

post '/manager/configure/password_update' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $server_time = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	$c->param('reason' => 'password_update');
	&subs::backup_now($c);
	my $numerics = &password_maker($c);
	if ($numerics eq 'noway') {
		$c->render(json => { result => 'ok' });
		$c->rendered;
		return;
	}
	my $secret = &subs::decrypter($c->session('suds'),&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});
	my $credential = &subs::encrypter($numerics,$numerics);

	my $cred_hunt = &subs::db_select('security', ['credential','level','server_time','timestamp'], { });
	my $creds = $cred_hunt->hashes;
	@{$creds} = grep { $_->{'level'} ne 'padlock' } @{$creds};
	if (secure_compare $c->session('suds'), $secret) {
		foreach my $cr ( @{$creds} ) {
			my $credjawntial = &subs::decrypter($secret,$cr->{'credential'});
			my $newjawntial = &subs::encrypter($numerics,$credjawntial);
			my $level = 2;
			if ($level eq 'padlock') {
				$level = 'padlock';
			}
			&subs::db_update('security', { level => $level, credential => $newjawntial }, { timestamp => $cr->{'timestamp'}, server_time => $cr->{'server_time'} });
		}
		&subs::db_insert('security', { level => 1, database => $database, credential => $credential, timestamp => $timestamp, server_time => $server_time, uuid => &subs::random_string_creator(30) });
		$c->session('suds' => $numerics);
		&subs::db_delete('security', { level => 'padlock' });
		&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
		&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
		$c->render(json => { result => 'ok' });
		&subs::say_it('Password has been updated');
	}
	else {
		&subs::say_it('no dice mister!');
		$c->render(json => { result => 'fail' });
	}
};



post '/manager/embedded/tauthorization' => sub ($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $tauthorization = $c->param('tauthorization');
	my $chip_id = $c->param('chip_id');
	my $patience = &subs::random_string_creator(25);
	&subs::setting_setter({ app => $edt, setting => 'patience', value => $patience, timestamp => $timestamp });

	my $auth = &subs::note_encrypter($patience,$tauthorization);
	$tauthorization = `(echo $auth) | base64 -w 0`;
	my $set = &subs::setting_setter({ app => $edt, setting => 'tauthorization', value => $tauthorization });
	$c->render(json => { settings => $set });
};

post '/manager/teletype/enable_tty' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $enabled = $c->param('enabled');
	my $chip_id = $c->param('chip_id');
	my $saved_enabled = &subs::setting_grabber({ app => $edt, setting => 'enabled', subsetting => $chip_id });
	if ($saved_enabled == 1) {
		$saved_enabled = 0;
	}
	else {
		$saved_enabled = 1;
	}
	my $set = &subs::setting_setter({ app => $edt, setting => 'enabled', value => $saved_enabled, timstamp => $timestamp, subsetting => $chip_id });
	$c->render(json => { enabled => $saved_enabled });
};

get '/manager/teletype/wifi_update' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $chip_id = $c->param('chip_id');
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) || '{}';

	my $wifi = decode_json $json_wifi;
	$c->render(text => $json_wifi);
};

post '/manager/teletype/appearance' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $field = $c->param('field');
	my $value = $c->param('value');
	my $chip_id = $c->param('chip_id');
	my $op_d = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op = eval { return decode_json $op_d } || {};
	if ($field =~ /colour/gi) {
		my $colour = $value;
		$colour =~ s/^#//gi;
		my @rgb = map $_ , unpack 'C*', pack 'H*', $colour;
		$op->{'__specs'}->{$field . '_rgb'} = \@rgb;
	}
	$op->{'__specs'}->{$field} = $value;
	delete $op->{$field};
	$op_d = encode_json $op;
	my $done = &subs::setting_setter({ app => $edt, setting => 'operator_door', value => $op_d, subsetting => $chip_id });
	$c->render(json => $done);

};

post '/manager/teletype/wifi_config' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $field = $c->param('field');
	my $value = $c->param('val');
	my $chip_id = $c->param('chip_id');
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) || '{}';
	my $wifi = decode_json $json_wifi;
	$wifi->{$field} = $value;
	$json_wifi = encode_json $wifi;

	my $returner = &subs::setting_setter({ app => $edt, setting => 'wifi', value => $json_wifi, subsetting => $chip_id });
	my $teletype = &subs::device_lister($timestamp, $edt);

	$c->render(json => $returner);
};

post '/manager/teletype/wifi_update' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $chip_id = $c->param('chip_id');
	my $teletype = &subs::device_lister($timestamp, $edt, undef, $chip_id);
	my $wifi_url = 'http://' . $teletype->{'ip'} . ':' . $config->{'port'} . '/wifi_update';
	my $ua = Mojo::UserAgent->new();
	my $res = $ua->insecure(1)->get($wifi_url)->result;
	$c->render(text => $res->body);
};

post '/manager/embedded/now_me' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $chip_id = $c->param('chip_id');
	my $name = &subs::format_name($c->param('name'));
	my $res = &now_me({ timestamp => $timestamp, edt => $edt, ip => $ip, name => $name, chip_id => $chip_id, browser_tab_id => $c->param('browser_tab_id') });
	$c->render('text' => $res);
};

get '/teletype/neighbours' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $devices = &subs::device_lister($timestamp, '');
	$c->render(json => $devices);
};

get '/manager/embedded' => sub($c) {
	my $timestamp = $c->param('timestamp');

	my $returner = &embedded_grabber($c,$timestamp);
	$returner->{'html'} = &window_maker({ user_agent => $c->param('user_agent'), app => 'Embedded', timestamp => $timestamp, contents => $returner->{'contents'} }, $timestamp);
	$c->render(json => $returner);
};

sub embedded_grabber($c,$timestamp) {
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $view = $c->param('view') || 'everything';
	my $embedded = &subs::device_lister($timestamp,$edt,undef,$chip_id);
	$timestamp = $c->param('timestamp');
	my $tty_enabled = &subs::setting_grabber({ app => $edt, setting => 'enabled' });
	my $pseudonyms = &pseudonym_maker($edt, '');
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) || '{}';
	my $wifi = decode_json $json_wifi;

	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id } );
	my $op_d = eval { return decode_json $od } || {};
	my $room_count = &subs::setting_grabber({'app' => 'me', setting => 'room_count', subsetting => $chip_id }) || $op_d->{'__specs'}->{'room_count'} || 2;
	$op_d->{'__specs'}->{'room_count'} = $room_count;
	my $room_max = 2;
	my $components = $gb::embedded_components;
	my $start_n = 0;
	if ($edt eq 'teletype') {
		$room_max = 8;
		$start_n = 1;
		$components = { 'button' => $gb::embedded_components->{'button'} };
	}
	elsif ($edt eq 'watch') {
		$room_max = 6;
		$start_n = 1;
		$components = { 'button' => $gb::embedded_components->{'button'} };
	}
	else {
		$room_count = 1;
		$room_max = 28;
	}

	my $embedded_scope = &subs::setting_grabber({ app => $edt, setting => 'watch_scope', subsetting => $chip_id });
	my $settings;
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	foreach my $component ( keys %{$components} ) {
		my $syl = &subs::shorthand_name($component, $syl_count);
		for (my $n = $start_n; $n <= $room_count * $room_max; $n++) {
			my $app = $op_d->{$syl . $n}->{'app'} || '';
			my $mov = $op_d->{$syl . $n}->{'movement'} || 'command';
			my $aset = &subs::settings_grabber({ app => $app });
			my $toggle = $aset->{'toggle' } eq 'on' ? 1 : 0;
			my $tog = !$toggle || $toggle eq 'off' ? 1 : 0;
			$aset->{'measures'} = eval { return decode_json $aset->{'app_measures'} } || {};
			$aset->{'seen_measures'} = eval { return decode_json $aset->{'seen_measures'} } || [];
			$settings->{$syl . $n} = { 
				app => $app, 
				toggle => $tog, 
				formatted_name => &subs::format_name($app), 
				movement => $mov,
				inverted => $op_d->{$syl . $n}->{'inverted'},
				toggle => $toggle,
				settings => $aset,
				direction => $components->{$component}->{'direction'},
				measure => $op_d->{$syl . $n}->{'measure'},
				threshold => $op_d->{$syl . $n}->{'threshold'},
				named_measure => $op_d->{$syl . $n}->{'named_measure'},
				comparison => $op_d->{$syl . $n}->{'comparison'},
				name => $op_d->{$syl . $n}->{'name'}
			};
		}
	}

	my $movements = {};
	foreach my $m ( qw/usual command kill record start toggle measure/ ) {
		$movements->{$m} = { 
			formatted_name => &subs::format_name($m), 
			mov => $m 
		};
	}
	my $tauthorization = &subs::setting_grabber({ app => $edt, setting => 'tauthorization' });

	my @embedded_ports;
	if ($device eq 'computer' || $device eq 'server') {
		my $embedded_ports = `ls /dev/ttyACM*`;
		@embedded_ports = split /\n/, $embedded_ports;
	}

	my $chip_ids = [];
	foreach my $chip ( @{&subs::db_select('devices')->hashes}) {
		$chip->{'chip_ids'} = eval { return decode_json $chip->{'chip_ids'} } || [{}];
		push @{$chip_ids}, @{$chip->{'chip_ids'}};
	}

	my $returner = {
		template => 'embedded/embedded',
		embedded => $embedded,
		embedded_ports => \@embedded_ports,
		window_maker => 'yes',
		settings => $settings,
		movements => $movements,
		room_count => $room_count,
		room_max => $room_max,
		embedded_scope => $embedded_scope,
		tauthorization => $tauthorization,
		tty_enabled => $tty_enabled,
		pseudonyms => $pseudonyms,
		wifi => $wifi,
		operator_door => $op_d,
		device_type => $edt,
		components => $components,
		chip_ids => $chip_ids,
		chip_id => $chip_id,
		edt => $edt,
		start_n => $start_n,
		view => $view
	};
	$returner->{'contents'} = $c->render_to_string(
		%{$returner}
	);
	return $returner;
}

get '/manager/embedded/pin_grabber' => sub($c) {
	my $edt = $c->param('edt');
	my $numero = $c->param('numero');
	my $pin = $c->param('pin') || $numero;
	my $form = $c->param('form');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		pin => $pin,
		form => $form,
		chip_id => $chip_id,
		timestamp => $timestamp
	});
	$c->render(json => $returner);
};
sub embedded_pin_grabber($data) {
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $chip_id = $data->{'chip_id'};
	my $form = $data->{'form'};
	my $numero = $data->{'numero'};
	my $pin = $data->{'pin'} || $data->{'numero'};
	my $edt = $data->{'edt'};
	my $device_type = $data->{'edt'};
	my $current_component = $data->{'component'};
	my $embedded = &subs::device_lister($timestamp,$edt,undef,$chip_id);
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id } );
	my $op_d = eval { return decode_json $od } || {};
	my $returner;
	my $components = $gb::embedded_components;
	my $settings;
	my $movements;
	foreach my $m ( qw/usual command kill record start toggle measure/ ) {
		$movements->{$m} = { 
			formatted_name => &subs::format_name($m), 
			mov => $m 
		};
	}
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	foreach my $component ( keys %{$components} ) {
		if ($current_component && $current_component ne $component) {
			next;
		}
		my $syl = &subs::shorthand_name($component, $syl_count);
		my $n = $numero;
		my $app = $op_d->{$syl . $n}->{'app'} || '';
		my $mov = $op_d->{$syl . $n}->{'movement'} || 'command';
		my $aset = &subs::settings_grabber({ app => $app });
		my $toggle = $aset->{'toggle' } eq 'on' ? 1 : 0;
		my $tog = !$toggle || $toggle eq 'off' ? 1 : 0;
		$aset->{'measures'} = eval { return decode_json $aset->{'app_measures'} } || {};
		$aset->{'seen_measures'} = eval { return decode_json $aset->{'seen_measures'} } || [];
		$settings->{$syl . $n} = { 
			app => $app, 
			toggle => $tog, 
			formatted_name => &subs::format_name($app), 
			movement => $mov,
			inverted => $op_d->{$syl . $n}->{'inverted'},
			toggle => $toggle,
			settings => $aset,
			direction => $components->{$component}->{'direction'},
			measure => $op_d->{$syl . $n}->{'measure'},
			threshold => $op_d->{$syl . $n}->{'threshold'},
			named_measure => $op_d->{$syl . $n}->{'named_measure'},
			comparison => $op_d->{$syl . $n}->{'comparison'},
			name => $op_d->{$syl . $n}->{'name'}
		};

		my $c = app->build_controller;
		$returner->{'html'} .= $c->render_to_string(
			template => 'embedded/component',
			n => $numero, 
			component => $component, 
			settings => $settings, 
			components => $components, 
			embedded => $embedded, 
			movements => $movements,
			device_type => $device_type,
			source => 'grabber',
			pin => $pin,
			name => $op_d->{$syl . $n}->{'name'}
		);
	}

	my @embedded_ports;
	if ($device eq 'computer' || $device eq 'server') {
		my $embedded_ports = `ls /dev/ttyACM*`;
		@embedded_ports = split /\n/, $embedded_ports;
	}

	my $chip_ids = [];
	foreach my $chip ( @{&subs::db_select('devices')->hashes}) {
		$chip->{'chip_ids'} = eval { return decode_json $chip->{'chip_ids'} } || [{}];
		push @{$chip_ids}, @{$chip->{'chip_ids'}};
	}

	return $returner;
};

get '/manager/embedded/wigi' => sub($c) {
	my $ip = $c->param('ip');
	my $timestamp = $c->param('timestamp');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
	if ($watch->{'ip'}) {
		my $wat_set = &subs::setting_grabber({ app => $edt, setting => 'operator_door', device => $device, subsetting => $chip_id });
		my $watch_settings = eval { return decode_json $wat_set } || {};

		my $auth = $watch_settings->{'__specs'}->{'authorization'};
		my $author = `echo $auth | base64 --decode`;
		my $authorization = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $author);


		my $wigi_url = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/wigi?timestamp=' . $timestamp . '&authorization=' . $auth;
		my $ua = Mojo::UserAgent->new();
		my $res = $ua->insecure(1)->get($wigi_url)->result;

		my $wigi = eval { return decode_json $res->body } || {};
		my $rauth = $wigi->{'authorization'};
		my $rauthorization = `echo $rauth | base64 --decode`;
		my $remote_auth = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $rauthorization);


		if (secure_compare($remote_auth, $authorization)) {
			my $buttons = $wigi->{'buttons'};
			my $measures = $wigi->{'measures'};
			my $steps = $measures->{'steps'};


			foreach my $button ( @{$buttons}) {
				if ($button->{'room'} && $button->{'button'}) {
					my $returner = &subs::edt_button_presser({
						timestamp => ($button->{'timestamp'} * 1000),
						room => $button->{'room'},
						watch_settings => $watch_settings,
						button => $button->{'button'},
						toggle => $button->{'toggle'},
						edt => $edt,
						chip_id => $chip_id
					});
				}
			}
			my $last_step = 0;
			my @measures;
			foreach my $step ( @{$steps} ) {

				my $ls = $step->{'steps'};
				$step->{'steps'} = $step->{'steps'} - $last_step;
				$last_step = $ls;
				$step->{'timestamp'} = $step->{'timestamp'} * 1000;
				if ($step->{'timestamp'} && $step->{'steps'} > 0) {
					push @measures, $step;
				}
			}
			if (scalar @measures > 0) {
				my $jstep = encode_json \@measures;
				&appointment_writer($c, {
					app => &subs::unformat_name(&subs::setting_grabber({ app => 'me', setting => 'my_name' })),
					type => 'measure',
					measures => $jstep,
					timestamp => &subs::rightNow(),
					seen => 'yes'
				});
			}
		}

	}
	$c->render(text => 'ok');
};

sub embedded_app_deleter($data) {
	my $appt_uuid = $data->{'appt_uuid'};
	my $timestamp = &subs::rightNow();
	my $chip_id = $data->{'chip_id'} || 'all';
	my $chips = &subs::device_lister($timestamp, 'microcontroller', undef, $chip_id);
  Mojo::IOLoop->subprocess->run_p(sub {

		foreach my $watch ( @{$chips} ) {
			if ($watch->{'ip'}) {
				my $od = &subs::setting_grabber({ app => 'microcontroller', setting => 'operator_door', subsetting => $watch->{'chip_id'} });
				my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
				my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/delete_job' . '?appt_uuid=' . $appt_uuid . '&authorization=' . $op_d->{'__specs'}->{'authorization'} . '&timestamp=' . $timestamp;

				my $ua = Mojo::UserAgent->new();
				my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};
				my $ping_test = `$ping`;
				if ($ping_test =~ /ttl/gi) {
					my $res = $ua->insecure(1)->get($watch_home)->result;
				}
			}
		}
	});
}

post '/manager/embedded/toggle' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $component = $c->param('component');
	my $pin = $c->param('pin');
	my $ip = $c->param('ip');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $state = $c->param('state');

	my $returner = &embedded_toggle({
		app => $app,
		pin => $pin,
		ip => $ip,
		edt => $edt,
		component => $component,
		timestamp => $timestamp,
		'state' => $state,
		'when' => 'now',
		chip_id => $chip_id
	});
	$c->render(json => $returner);
};

sub embedded_toggle($data) {
	my $app = $data->{'app'};
	my $pin = $data->{'pin'};
	my $ip = $data->{'ip'};
	my $edt = $data->{'edt'};
	my $state = $data->{'state'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $component = $data->{'component'};
	my $uuid = $data->{'uuid'} || &subs::random_string_creator();
	my $appt_uuid = $data->{'appt_uuid'};
	my $chip_id = $data->{'chip_id'};

	my $measure = $data->{'measure'};
	my $when = $data->{'when'} || 'now';
	my $ebc = $gb::embedded_components->{$component};



	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
	my $inverted = $op_d->{$syl . $pin}->{'inverted'};
	my $save_state = $state;
	if ($inverted && $inverted == 1) {
		if ($state eq 'on') {
			$state = 'off';
			$save_state = 'on';
		}
		elsif ($state == 1) {
			$state = 'off';
			$save_state = 'on';
		}
		else {
			$state = 'on';
			$save_state = 'off';
		}
	}
	elsif (!$state && !$data->{'measure'}) {
		$state = &subs::setting_grabber({ app => $app, setting => 'toggle' });
		if ($state eq 'on') {
			$state = 'off';
			$save_state = 'off';
		}
		elsif ($state eq 'off') {
			$state = 'on';
			$save_state = 'on';
		}
		elsif ($state == 1) {
			$state = 'off';
			$save_state = 'off'
		}
		else {
			$state = 'on';
			$save_state = 'on';
		}
	}

	if ($component eq 'servo' && $appt_uuid) {
		$state = ($state / 100) * 180;
	}


	if ($state !~ /[0-9]/) {
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.enabler[type="toggle"\').attr(\'status\',\'' .$save_state . '\').attr(\'src\', \'/images/decipherable/' . $save_state . '.png\');' });
		&subs::setting_setter({ app => $app, setting => 'toggle', value => $save_state, source => 'toggle' }) if $data->{'counted'} == 0 || !$data->{'counted'};
	}


  Mojo::IOLoop->subprocess->run_p(sub {
		my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);

		my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/' . $component . '?appt_uuid=' . $appt_uuid . '&uuid=' . $uuid . '&when=' . $when . '&pin=' . $pin . '&state=' . $state . '&component=' . $component . '&authorization=' . $op_d->{'__specs'}->{'authorization'} . '&timestamp=' . $timestamp . '&measure=' . $measure;
		my $ua = Mojo::UserAgent->new();

		my $res = $ua->insecure(1)->get($watch_home)->result;
		if (eval { $res->result->body }) {
			if (eval { decode_json $res->result->body }) {
				my $rb = decode_json $res->result->body;
				$state = $rb->{'state'};
				$pin = $rb->{'pin'};
			}
		}
		my $number_state = $state eq 'on' ? 1 : 0;
	});
	my $number_state = $state eq 'on' ? 1 : 0;
	my $returner = { 'state' => $number_state, formatted_state => $state };

	return $returner;
}

post '/manager/embedded/uploader' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $port = $c->param('port');
	my $edt = $c->param('edt');
	my $emerge = $c->param('emerge');
	my $chip_id = $c->param('chip_id');
	my ($file,$upload_command);
	if ($edt eq 'teletype') {
		$file = './jt/build/esp32.esp32.esp32s3/jt.ino.bin';
		$file = './jt/jt.ino.esp32s3.emerge.bin' if $emerge eq 'yes';
		$upload_command = 'python3 ./jt/esptool/4.5.1/esptool.py --chip esp32s3 --port ' .
			$port . ' --baud 921600 --before default_reset --after hard_reset write_flash -z --flash_mode dio --flash_freq 80m --flash_size 16MB 0x0 ' .
			'./jt/build/esp32.esp32.esp32s3/jt.ino.bootloader.bin 0x8000 ./jt/build/esp32.esp32.esp32s3/jt.ino.partitions.bin 0xe000 ' .
			'./jt/esptool/4.5.1/boot_app0.bin 0x10000 ' .
			$file;
	}
	elsif ($edt eq 'watch') {
		$file = './jw/build/esp32.esp32.esp32s3/jw.ino.bin';
		$file = './jw/jw.ino.esp32s3.emerge.bin' if $emerge eq 'yes';
		$upload_command = 'python3 ./jt/esptool/4.5.1/esptool.py --chip esp32s3 --port ' . 
			$port .	' --baud 921600 --before default_reset --after hard_reset write_flash -z --flash_mode dio --flash_freq 80m --flash_size 16MB 0x0 ' .
			'./jw/build/esp32.esp32.esp32s3/jw.ino.bootloader.bin 0x8000 ./jw/build/esp32.esp32.esp32s3/jw.ino.partitions.bin 0xe000 ' .
			'./jt/esptool/4.5.1/boot_app0.bin 0x10000 ' .
			$file;
	}
	else {
		$c->render('text' => 'no embedded');
	}
	if ($file && $port) {
		my $exec = &subs::run_command('embedded',$upload_command);
	
		&Websocket::send('server', { type => 'append', selector => '#embedded_uploader_result', content => $exec . "<br>" });
#		my $result = `$upload_command`;
		$c->render('text' => $exec);
	}
};

post '/manager/embedded/ota_uploader' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');

	if ($edt eq 'microcontroller') {
		my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
		my $file = './jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin';
		my $total_size = -s $file;

		my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/upload/alarmclock.bin?total_size=' . $total_size;
		my $ua = Mojo::UserAgent->new();
    $ua->transactor->add_generator(stream => sub ($transactor, $tx, $path) {
      $tx->req->content->asset(Mojo::Asset::File->new(path => $file));
    });
		&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_wait\').show()', browser_tab_id => $c->param('browser_tab_id') });
		&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_fail\').hide()', browser_tab_id => $c->param('browser_tab_id') });
		&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_success\').hide()', browser_tab_id => $c->param('browser_tab_id') });
		$ua->inactivity_timeout(120000);
    my $res = $ua->insecure(1)->post($watch_home  => stream => $file )->result;

		if ($res->is_success) {
			&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_wait\').hide()', browser_tab_id => $c->param('browser_tab_id') });
			&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_success\').show()', browser_tab_id => $c->param('browser_tab_id') });
		}
		else {
			&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_wait\').hide()', browser_tab_id => $c->param('browser_tab_id') });
			&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_fail\').show()', browser_tab_id => $c->param('browser_tab_id') });
		}
#      my $tx = $t->tx(POST => 'http://example.com' => form => {mytext => {file =
#> '/foo.txt'}});



		$c->render(text => 'yes');
	}
	else {
		$c->render(text => 'no');
	}


};

get '/manager/embedded/teletype_backup' => sub($c) {
	my $ip = $c->param('ip');
	my $mac = $c->param('mac');
	my $timestamp = $c->param('timestamp');
	my $teletype = &subs::device_lister($timestamp,'teletype');
	my $chip_id = $c->param('chip_id');
	$c->param('reason' => 'teletype_backup');
  Mojo::IOLoop->subprocess->run_p(sub {
		if ($teletype->{'ip'} && !$teletype->{'uuid'} && $teletype->{'ip'} eq $ip) {
			my $ping = 'timeout .2 ping -c 1 ' . $teletype->{'ip'};
			my $ping_test = `$ping`;
			my $backup = &subs::backup_now($c);
			$backup = encode_json $backup;
			if ($ping_test =~ /ttl/gi) {
				my $teletype_url = 'http://' . $teletype->{'ip'} . ':' . $config->{'port'} . '/backup?backup=' . $backup . '&timestamp=' . $timestamp;
				my $ua = Mojo::UserAgent->new();
				my $res = $ua->insecure(1)->get($teletype_url)->result;
			}
		}
	});
};

get '/manager/embedded/jobs' => sub($c) {
	my $ip = $c->param('ip');
	my $mac = $c->param('mac');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $mc = &subs::device_lister($timestamp, $edt, undef, $chip_id);

	my $wat_set = &subs::setting_grabber({ app => $edt, setting => 'operator_door', device => $device, subsetting => $chip_id });;
	my $watch_settings = eval { return decode_json $wat_set } || {};

	my $auth = $watch_settings->{'__specs'}->{'authorization'};
	my $author = `echo $auth | base64 --decode`;
	my $authorization = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $author);





	my $url = 'http://' . $mc->{'ip'} . ':' . $config->{'port'} . '/jobs?authorization=' . $authorization;
	my $ua = Mojo::UserAgent->new();
	my $res = $ua->insecure(1)->get($url)->result;
	my $returner = {};
	if ($res->is_success) {
		my $jobs = eval { return decode_json $res->body } || {};
		$returner->{'jobs'} = $jobs;
		$returner->{'html'} = $c->render_to_string(
			template => 'embedded/jobs',
			jobs => $jobs,
			op_d => $watch_settings
		);
	}

	$c->render(json => $returner);

};

post '/manager/embedded/delete_job' => sub($c) {
	my $appt_uuid = $c->param('appt_uuid');
	my $chip_id = $c->param('chip_id');
	my $uuid = $c->param('uuid');
	&embedded_app_deleter({ appt_uuid => $appt_uuid, $chip_id });
	$c->render(json => { uuid => $uuid, appt_uuid => $appt_uuid });
};

post '/manager/watch/assign' => sub($c) {
	my $edt = $c->param('edt');
	my $ip = $c->param('ip');
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $pre_value = $c->param('pre_value');
	my $numero = $c->param('numero');
	my $component = $c->param('component');
	my $chip_id = $c->param('chip_id');
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $type = 'text';
	($app,$type) = &subs::typesetter($app);
	&subs::setting_setter({ app => $app, setting => 'pos', value => $type });
	my $init = &subs::setting_initializer($app,$timestamp);
	$app = $init->{'app'};
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
	my $colour = &subs::setting_grabber({ app => $app, setting=> 'colour' });
	$colour =~ s/^#//gi;
	my @rgb = map $_ , unpack 'C*', pack 'H*', $colour;
	$op_d->{$syl . $numero} = {
		'colour' => $colour, 
		rgb => \@rgb, 
		shorthand_name => &subs::shorthand_name(&subs::format_name($app)),
		app => $app,
		movement => $op_d->{$syl . $numero}->{'movement'} || 'command',
		inverted => $op_d->{$syl . $numero}->{'inverted'},
		numero => $numero,
		measure => $op_d->{$syl . $numero}->{'measure'},
		toggle => $op_d->{$syl . $numero }->{'toggle'} || 0,
		direction => $gb::embedded_components->{$component}->{'direction'},
		component => $component,
		uuid => &subs::random_string_creator(),
		name => $op_d->{$syl . $numero}->{'name'}
	};
	if ($app eq '') {
		delete $op_d->{$syl . $numero};
	}
	my $json_od = encode_json $op_d;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_od, subsetting => $chip_id });
	my $pia = eval { return decode_json &subs::setting_grabber({ app => $pre_value, setting => 'ia' }) } || {};
	delete $pia->{$chip_id}->{$numero};
	my $jpia = encode_json $pia;
	&subs::setting_setter({ app => $pre_value, setting => 'ia', value => $jpia });
	my $ia = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'ia'}) } || {};
	$ia->{$chip_id}->{$numero} = {
		movement =>	$op_d->{$syl . $numero}->{'movement'},
		ip => $ip,
		edt => $edt,
		pin => $numero,
		direction => $gb::embedded_components->{$component}->{'direction'},
		component => $component
	};
	my $jia = encode_json $ia;
	&subs::setting_setter({ app => $app, setting => 'ia', value => $jia });
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		component => $component,
		chip_id => $chip_id,
		timestamp => $timestamp,
		component => $component
	});
	my $res = &now_me({ timestamp => $timestamp, edt => $edt, chip_id => $chip_id, browser_tab_id => $c->param('browser_tab_id') });
	$c->render('json' => { app => $app, formatted_name => &subs::format_name($app ), html => $returner->{'html'} });
};

post '/manager/watch/setting' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $numero = $c->param('numero');
	my $movement = $c->param('movement');
	my $setting = $c->param('setting');
	my $component = $c->param('component');
	my $syl_count = 10;
	my $chip_id = $c->param('chip_id');
	my $percentage = $c->param('percentage');
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
	my $app = $op_d->{$syl . $numero}->{app};
	$op_d->{$syl . $numero}->{$setting} = $movement;
	if ($percentage) {
		$op_d->{$syl . $numero}->{$setting . '_percentage'} = $percentage;
	}
	my $json_od = encode_json $op_d;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_od, timestamp => $timestamp, subsetting => $chip_id });
	my $jia = &subs::setting_grabber({ app => $app, setting => 'ia' });
	if ($jia) {
		my $ia = eval { return decode_json $jia } || {};
		$ia->{$chip_id}->{$numero}->{$setting} = $movement;
		if ($percentage) {
			$ia->{$chip_id}->{$numero}->{$setting . '_percentage'} = $percentage;
		}
		my $jia = encode_json $ia;
		&subs::setting_setter({ app => $app, setting => 'ia', value => $jia });
	}
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		component => $component,
		chip_id => $chip_id,
		timestamp => $timestamp
	});
	my $res = &now_me({ timestamp => $timestamp, edt => $edt, chip_id => $chip_id, browser_tab_id => $c->param('browser_tab_id') });
	$c->render(json => $returner );
};

get '/manager/watch/diagram' => sub($c) {
	my $uuid = $c->param('uuid');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'embedded', setting => 'diagrams' }) } || [];
	@{$diagrams} = grep { $_->{'uuid'} eq $uuid } @{$diagrams};
	my $diagram = $diagrams->[0];

	my $op_d = eval { return decode_json &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id }) } || {};
	my $returner = { uuid => $uuid, diagram => $diagram };
	$returner->{'html'} = $c->render_to_string(
		template => 'embedded/diagram',
		d => $diagram,
		op_d => $op_d
	);
	$c->render(json => $returner);
};

post '/manager/watch/diagram' => sub($c) {
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $diagram = eval { return decode_json $c->param('diagram') } || {};
	my $op_d = eval { return decode_json &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id }) } || {};

	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'embedded', setting => 'diagrams'}) } || [];
	my $returner = { diagram => $diagram };
	foreach my $d ( @{$diagrams} ) {
		if ($d->{'uuid'} eq $diagram->{'file'}->{'uuid'}) {
			$d->{'components'} = $diagram->{'components'};
		}
	}
	my $jdiagrams = encode_json $diagrams;
	&subs::setting_setter({ app => 'embedded', setting => 'diagrams', value => $jdiagrams });
	$returner->{'diagrams'} = $diagrams;
	$c->render(json => $returner);
};


post '/manager/watch/measure' => sub($c) {
	my $edt = $c->param('edt');
	my $component = $c->param('component');
	my $numero = $c->param('numero');
	my $syl_count = 10;
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $measure = $c->param('measure');

	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = eval { return decode_json $od } || {};

	$op_d->{$syl . $numero}->{'measure'} = $measure;
	my $app = $op_d->{$syl . $numero}->{'app'};
	my $jopd = encode_json $op_d;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', subsetting => $chip_id, value => $jopd });
	my $jia = &subs::setting_grabber({ app => $app, setting => 'ia' });
	if ($jia) {
		my $ia = eval { return decode_json $jia } || {};
		$ia->{$chip_id}->{$numero}->{'measure'} = $measure;

		$jia = encode_json $ia;
		&subs::setting_setter({ app => $app, setting => 'ia', value => $jia });
	}
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		component => $component,
		chip_id => $chip_id,
		timestamp => $timestamp
	});
	$c->render(json => $returner);
};

sub send_telephone($app,$msg) {
	my $timestamp = &subs::rightNow();
	foreach my $w ( qw/teletype watch microcontroller/ ) {
		my $chips = &subs::device_lister($timestamp,$w,undef, 'all');
		foreach my $watch ( @{$chips} ) {
			my $od = &subs::setting_grabber({ 'app' => $watch->{'purpose'}, 'setting' => 'operator_door', subsetting => $watch->{'chip_id'}  });
			my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
			if ($watch->{'ip'} && !$watch->{'uuid'}) {
				my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};
				my $ping_test = `$ping`;


				if ($ping_test =~ /ttl/gi) {
					my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/send_telephone?app=' . $app . '&msg=' .
					&subs::unformat_name($msg) . '&timestamp=' . $timestamp;
			    Mojo::IOLoop->subprocess->run_p(sub {
						my $ua = Mojo::UserAgent->new();
						my $res = $ua->insecure(1)->get($watch_home)->result;
					});
				}
				sleep 2;
			}
		}
	}
}

sub now_me($data) {
	my $timestamp = $data->{'timestamp'};
	my $edt = $data->{'edt'};
	my $ip = $data->{'ip'};
	my $chip_id = $data->{'chip_id'};
	my $name = $data->{'name'};
	my $server_time = time();
	my @t = localtime(time);
	my $is_dst = $t[8];
	my $offset = timegm(@t) - timelocal(@t);
	if ($is_dst == 0 && $edt eq 'watch') { 
		$server_time = $server_time + (1000 * 3600);
	}

	my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
	my $watch_port = $ENV{PORT_BELL};

	my $ws_port = $ENV{PORT_MSG};
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', device => $device, subsetting => $chip_id });
	my $op_d = eval { decode_json $od } || {};
	$name = $op_d->{'__specs'}->{'name'} unless $data->{'name'};
	$ip = $watch->{'homebase'} unless $ip;
	$op_d->{'__specs'}->{'room_count'} = &subs::setting_grabber({'app' => 'me', setting => 'room_count'}) || $op_d->{'__specs'}->{'room_count'} || 2;
	$op_d->{'__specs'}->{'homebase'} = $watch->{'homebase'} . ':' . $watch_port;
	$op_d->{'__specs'}->{'ip'} = $watch->{'homebase'};
	$op_d->{'__specs'}->{'edt'} = $edt;
	$op_d->{'__specs'}->{'name'} = $name;
	$op_d->{'__specs'}->{'time'} = {
		sec => $t[0],
		min => $t[1],
		hour => $t[2],
		day => $t[3],
		month => $t[4] + 1,
		year => $t[5] + 1900
	};
	my $computer_name = &subs::setting_grabber({ app => 'me', setting => 'computer_name' });
	$op_d->{'__specs'}->{'computer'} = &manager_file_maker('') || $op_d->{'__specs'}->{'homebase'};
	my $room_count = $op_d->{'__specs'}->{'room_count'};
	if ($edt eq 'watch') {
		$op_d->{'__specs'}->{'room_max'} = 6;
	}
	elsif ($edt eq 'teletype') {
		$op_d->{'__specs'}->{'room_max'} = 8;
	}
	else {
		$op_d->{'__specs'}->{'room_max'} = 1;
	}
	my $room_max = $op_d->{'__specs'}->{'room_max'};
	my $patience = &subs::random_string_creator(36);
	my $au = &subs::random_string_creator(27);
	my $auth = &subs::note_encrypter($patience, $au );
	my $authorization = `(echo $auth) | base64 -w 0`;
	$op_d->{'__shutup'}->{'patience'} = $patience;
	$op_d->{'__specs'}->{'authorization'} = $authorization;

	my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/now_me?name=' . $name . '&ip='. $watch->{'homebase'} . '&homebase=' . $watch->{'homebase'} . ':' . $watch_port 
		. '&timestamp=' . $server_time . '&offset=' . $offset . '&authorization=' .  $authorization . '&room_count=' . $room_count . '&browser_tab_id=' . $data->{'browser_tab_id'}
		. '&room_max=' . $room_max . '&twshomebase=' . $watch->{'homebase'} . ':' . $ENV{PORT_COMS} . '&thomebase=' . $watch->{'homebase'} . ':' . $ENV{PORT_BESTOW};

	my $ua = Mojo::UserAgent->new();

	foreach my $gah ( qw/project person community club team/ ) {
		my $pros = &subs::db_query('select * from settings where setting=? and value=?', 'pos',$gah);
		my $professionals = $pros->hashes;
		$op_d->{'__specs'}->{'chat'}->{$gah} = "";
		foreach my $sc ( keys %{$gb::social_constructs} ) {
			if ($gb::social_constructs->{$sc}->{'sing'} eq $gah) {
				$op_d->{'__specs'}->{'chat'}->{$gah} .= $gb::social_constructs->{$sc}->{'def'} . "\n";				
			}
		}

		foreach my $pro ( @{$professionals} ) {
			$op_d->{'__specs'}->{'chat'}->{$gah} .= &subs::format_name($pro->{'app'}) . "\n";
		}
	}
	my $contacters = &subs::db_query('select * from tickets where status = ?', 'active' );
	my $contacts = $contacters->hashes;
	$op_d->{'__specs'}->{'chat'}->{'contacts'} = "";
	foreach my $conmen ( @{$contacts} ) {
		$op_d->{'__specs'}->{'chat'}->{'contacts'} .= $conmen->{'name'} . "\n";
	}
	my $ip = $watch->{'ip'};
	my $json_op = encode_json $op_d;

	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_op, subsetting => $chip_id });

	my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};
	my $ping_test = `$ping`;
	if ($ping_test =~ /ttl/gi) {
		my $res = $ua->insecure(1)->get($watch_home)->result;
		if ($edt eq 'microcontroller') {
			if (eval { $res->result->body }) {
				if (eval { decode_json $res->result->body }) {
					my $rb = decode_json $res->result->body;
					foreach my $info ( keys %{$rb} ) {
						$op_d->{'__specs'}->{$info} = $res->{$info};
					}
				}
			}
			$json_op = encode_json $op_d;
			&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_op, subsetting => $chip_id });

		}
		return $res;
	}
	return {};
}

get '/manager/watch/set_proxy' => sub ($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $lat_calc = 110.574;
	my $long_calc = (111.320 * cos($lat_calc));
	my $scope = $c->param('scope') || 20;
	my $chip_id = $c->param('chip_id');
	my $q = &subs::db_query('select * from continent where uuid = ? and timestamp=?',$uuid, $timestamp);
	my $locations = $q->hashes;

	&subs::setting_setter({ app => $edt, setting => 'watch_scope', value => $scope, subsetting => $chip_id });
	my $proxies = { near => $locations, far => [], here => {}, scope => $scope };
	foreach my $l ( @{$locations} ) { 
		my $operator_door = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
		my $od = decode_json $operator_door;
		my $operator = $od->{'b1'}->{'app'};
		&subs::db_update('continent', {
			operator => $operator,
			operator_door => $operator_door,
			type => 'proxy_set',
			scope => $scope
		},{ uuid => $l->{'uuid'}, timestamp => $timestamp });
		my $sloop = &subs::db_query('select * from continent where timestamp=? and uuid=?',$timestamp, $l->{'uuid'});
		my $slur = $sloop->hashes;
		my $sl = $slur->[0];
		$proxies->{'here'} = $sl;
	}

	$c->render(json => $proxies);
};

get '/manager/watch/list_proxy' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $q = &subs::db_query('select * from continent where uuid = ? and timestamp=?',$uuid,$timestamp);
	my $locations = $q->hashes;
	my $scope = $c->param('scope') ? $c->param('scope') : 20;
	&subs::setting_setter({ app => $edt, setting => 'watch_scope', value => $scope, subsetting => $chip_id });
	my $proxies = { near => [], far => [], here => {}, scope => $scope };
	my $operator_door = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $od = decode_json $operator_door;
	foreach my $l (@{$locations}) {

		my $operator = $od->{'b1'}->{'app'};
		&subs::db_update('continent',{
			operator => $operator,
			operator_door => $operator_door,
			type => 'proxy_load' 
		}, { 
			uuid => $l->{'uuid'}, timestamp => $l->{'timestamp'}
		});

		my $similar = &subs::db_query('select * from continent where type=?', 'proxy_set');

		foreach my $sl (@{$similar->hashes}) {
			my $lat = ($sl->{'longitude'} - $l->{'longitude'});
			my $long = ($sl->{'longitude'} - $l->{'longitude'});
			my $radius = 6372.8;
			my @BNA = (deg2rad($l->{'longitude'}), deg2rad(90 - $l->{'latitude'}));
			my @LAX = (deg2rad($sl->{'longitude'}), deg2rad(90 - $sl->{'latitude'}));

			my $distance = great_circle_distance(@BNA, @LAX, $radius);
			my $metres = $distance * 1000;

			$sl->{'distance'} = sprintf("%2f", $metres);
			$sl->{'ago'} = &subs::duration_sayer(($timestamp - $sl->{'timestamp'}) / 1000);

			if ($metres <= $scope) {
				push @{$proxies->{'near'}}, $sl;
			}
		}
		push @{$proxies->{'near'}}, $l;
		$proxies->{'here'} = $l;
	}
	$proxies->{'html'} = $c->render_to_string(
		template => 'embedded/proxy',
		proxies => $proxies,
	);

	$c->render(json => $proxies);
};


post '/manager/watch/proxy_load' => sub($c) {
	my $edt = $c->param('edt');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $locations = &subs::db_query('select * from continent where uuid=?', $uuid)->hashes;
	my $location = $locations->[0];

	my $operator_door = decode_json $location->{'operator_door'};
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $location->{'operator_door'}, subsetting => $chip_id });

	$c->render('text' => &embedded_grabber($c,$timestamp));
};

post '/manager/watch/proxy_here' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $locations = &subs::db_query('select * from continent where timestamp=?', $timestamp)->hashes;
	my $location = $locations->[0];
	&subs::db_update('continent', {
		latitude => $location->{'latitude'},
		longitude => $location->{'longitude'},
	}, { 
		uuid => $uuid 
	});
	$locations = &subs::db_query('select * from continent where uuid=?', $uuid)->hashes;
	$location = $locations->[0];
	$c->render(json => $location);
};

post '/manager/watch/proxy_save' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $room_max = &subs::setting_grabber({ app => 'me', setting => 'room_max' });
	my $room_count = &subs::setting_grabber({ app => 'me', setting => 'room_count' });
	my $op = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $watch_settings = eval { return decode_json $op } || {};
	for (my $n = 1; $n <= $room_max * $room_count; $n++) {
		my $app = $watch_settings->{"b" . $n}->{'app'};
		my $colour = $watch_settings->{"b" . $n}->{'colour'};
		my $movement = $watch_settings->{"b" . $n}->{'movement'};
		$colour =~ s/^#//gi;
		my @rgb = map $_ , unpack 'C*', pack 'H*', $colour;
		$watch_settings->{"b" . $n} = {
			'colour' => $colour, 
			rgb => \@rgb, 
			shorthand_name => &subs::shorthand_name(&subs::format_name($app)),
			app => $app,
			movement => $movement,
			numero => $n
		};
	}
	my $json_watch = encode_json $watch_settings;
	my $q = &subs::db_update('continent', { 
		timestamp => $timestamp,
		operator_door => $json_watch,
		operator => $watch_settings->{'b1'}->{'app'}
	}, {
		uuid => $uuid
	});
	$c->render(text => $uuid);
};

post '/manager/watch/delete_proxy' => sub($c) {
	if ($c->param('uuid')) {
		&subs::db_delete('continent', { uuid => $c->param('uuid') });
	}
	$c->render(text => $c->param('uuid') );
};



get '/manager/past_life_recall' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $direction = $c->param('direction');
	my $room_check = $c->param('room_check');
	my $report = {};
	my $query = 'select * from websockets where app= ? and timestamp < ? ORDER BY timestamp DESC LIMIT 1';
	my $results;
	if ($direction eq 'load') { 
		$query = 'select * from websockets where app= ? and timestamp = ?'; 
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	elsif ($direction eq 'forget') { 
		$query = 'delete from websockets where app= ? and timestamp = ?';
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	elsif ($direction eq 'ff') {
		$query = 'select * from websockets where app= ? and timestamp > ? order by timestamp ASC LIMIT 1';
		if ($room_check eq 'true') {
			$query = 'select * from websockets where app= ? and timestamp > ? and room is not null order by timestamp ASC LIMIT 1';
		}
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	elsif ($direction eq 'rew') {
		if ($room_check eq 'true') {
			$query = 'select * from websockets where app= ? and timestamp < ? and room is not null order by timestamp DESC LIMIT 1';
		}
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	my $rooms = $results->hashes;

	foreach my $room  ( @{$rooms} ) {
		my $drawings = &subs::db_query('select * from appointments where browser_tab_id=? and file is not null',$room->{'browser_tab_id'})->hashes;
		my $portfolio = [];
		foreach my $d ( @{$drawings} ) {
			my $files = eval { return decode_json $d->{'file'} } || [];
			foreach my $f ( grep { $_->{'type'} eq 'image' || $_->{'type'} eq 'video' } @{$files} ) {
				push @{$portfolio}, $f;
			}
		}

		my $lifetime = localtime( $room->{'timestamp'} / 1000 )->strftime('%a %B %d %Y %I:%M:%S%P');
		my $windows = eval { return decode_json $room->{'windows'} } || {};
		my $appt_count = scalar %{$windows};
		my $playbook = ($room->{'room'} || $room->{'browser_tab_id'} ) . "<br>$lifetime<br><br>";
	#	next unless scalar keys %{$windows} > 0;
		foreach my $w ( keys %{$windows} ) {
			$playbook .= '<span class="room_appt" app="' . $windows->{$w}->{'app'} . '">' . &subs::format_name($windows->{$w}->{'app'}) . '</span><br>';
		}
		$report = {
			room => $room->{'room'},
			timestamp => $room->{'timestamp'},
			user_agent => $room->{'user_agent'},
			lifetime => $lifetime,
			json_windows => $room->{'windows'},
			windows => $windows,
			appt_count => $appt_count,
			playbook => $playbook,
			browser_tab_id => $room->{'browser_tab_id'},
			portfolio => $portfolio
		};
	}

	$c->render(json => $report);
};

get '/manager/marker' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app') || 'marker';
	my $browser_tab_id = $c->param('browser_tab_id');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $q = &subs::db_query('select * from appointments where app = ? and type= ?', $app, 'image' );
	my $drawings = $q->hashes;

	my $contents = $c->render_to_string(
		template => 'marker',
		window_maker => 'yes',
		drawings => $drawings
	);

	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'marker', contents => $contents }, $timestamp);
	$c->render(text => $website);
};

post '/manager/snapshot_save' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $snapshot = $c->param('snapshot');
	my @snapshot = split ',', $snapshot;
	shift @snapshot;
	$snapshot = join ',', @snapshot;
	$snapshot = decode_base64($snapshot);
	my $folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
	my $location = &subs::home($folder) . '/' . $app;
	my $filename = $location . '/' . $timestamp . '.png';
	write_file($filename,$snapshot);
	my $jfile = encode_json [{ server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(8), type => 'image' }];
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		type => 'image',
		file => $jfile,
		uuid => &subs::random_string_creator(20),
		duration => '1'
	};
	&appointment_writer($c,$write);
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });

	$c->render(json => $write);
};

post '/manager/marker/save' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $marker = $c->param('marker');
	my $image = $c->param('img');
	my $paper = $c->param('paper');
	my $app = &subs::unformat_name($c->param('app'));
	my $browser_tab_id = $c->param('browser_tab_id');
	my ($db,$database,$sql) = &subs::database_grabber();

	my @image = split ',', $image;
	shift @image;
	$image = join ',', @image;
	$image = decode_base64($image);
	my $folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
	my $location = &subs::home($folder) . '/' . $app;
	my $filename = $location . '/' . $timestamp . '.png';
	write_file($filename,$image);

	my $jfile = encode_json [{ server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(8), type => 'image' }];
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		type => 'image',
		file => $jfile,
		uuid => &subs::random_string_creator(20),
		duration => '1',
		browser_tab_id => $browser_tab_id
	};
	&appointment_writer($c,$write);
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => $c->session('suds') });

	my $q = &subs::db_query('select * from appointments where app = ? and type=?',$app,'image');
	my $drawings = $q->hashes;
	my $json = encode_json $drawings || [];
	$c->render(json => $json);
};

post '/manager/marker/delete' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $server_time = $c->param('server_time');

	&delete_file({ app => $app, app_uuid => $app_uuid, file_uuid => $file_uuid });

	$c->render(text => 'ok');
};

get '/manager/marker/gallery' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $drawings;
	if ($app) {
		$drawings = &subs::db_select('drawings', undef, { app => $app })->hashes;
	}
	else {
		$drawings = &subs::db_select('drawings')->hashes;
	}
	my $returner = { app => $app, timestamp => $timestamp, drawings => $drawings };
	$returner->{'html'} = '<h2>' . &subs::format_name($app || 'All') . '<img src="/images/make believe/cancel_button.png" id="alert_cancel"  class="medium_thumb"><div id="marker_exhibition">';
	foreach my $drawing ( @{$drawings} ) {
		$returner->{'html'} .= '<img id="' . $drawing->{'paper'} . '" timestamp="' . $drawing->{'timestamp'} . '" class="paper huge_thumb ' . $drawing->{'paper'} . '" src="' . $drawing->{'image'} . '">';
		$returner->{'html'} .= '<button class="marker_delete ' . $drawing->{'paper'} . '_delete" server_time="' . $drawing->{'server_time'} . '" uuid="' . $drawing->{'uuid'} . '" timestamp="' . $drawing->{'timestamp'} . '" paper="' . $drawing->{'paper'} . '" id="' . $drawing->{'paper'} . '_delete">D</button>';
	}
	$returner->{'html'} .= '</div>';
	$c->render(json => $returner);
};

post '/manager/room_namer' => sub ($c) {
	my $timestamp = $c->param('timestamp');
	my $room_name = $c->param('room_name');
	my $app = $c->param('app');
	my $browser_tab_id = $c->param('browser_tab_id');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $ug    = Data::UUID->new;
	my $uuid = $ug->create_str();
	my $up = &subs::db_update('websockets', { room => $room_name }, { app => 'tab', browser_tab_id => $browser_tab_id });
	my $room = { browser_tab_id => $uuid, formatted_name => &subs::format_name($room_name), room_name => $room_name, timestamp => $timestamp };
	$c->render(json => $room);
};

post '/manager/new_room' => sub ($c) {
	my $ug    = Data::UUID->new;
	my $uuid = $ug->create_str();

	my $room = { 
		timestamp => $c->param('timestamp'),
		room_name => $c->param('room_name'),
		app => $c->param('app'),
		browser_tab_id => $uuid
	};
	$c->render(json => $room);
};

get '/manager/update_database' => sub ($c) {
	$c->render('text' => 'no updates');
	&update_database($c);
};


sub update_database($c) {
	&subs::cache_delete({ app => 'me', context => 'pseudonyms' });
	my $commands = [
		'CREATE INDEX idx1_settings on settings (setting)',
		'CREATE INDEX idx2_settings on settings (setting,device)',
		'CREATE INDEX idx3_settings on settings (setting,value)',
		'CREATE INDEX idx4_settings on settings (setting,device,value)',
		'CREATE INDEX idx1_appts on appointments (app)',
		'CREATE INDEX idx2_appts on appointments (app,timestamp)',
		'CREATE INDEX idx3_appts on appointments (app,uuid)',
		'CREATE INDEX idx4_appts on appointments (uuid)',
		'CREATE INDEX idx5_appts on appointments (app,timestamp)',
		'CREATE INDEX idx6_appts on appointments (app,server_time)',
		'CREATE INDEX idx7_appts on appointments (timestamp,seen)',
		'CREATE INDEX idx8_appts on appointments (timestamp, stop_timestamp, seen, stop_seen)',
		'CREATE INDEX idx9_appts on appointments (stop_timestamp,stop_seen)',
		'CREATE INDEX idx10_appts on appointments (duties,next_duty)',
		'CREATE INDEX idx1_ws on websockets (app,browser_tab_id)',
		'CREATE INDEX idx2_ws on websockets (browser_tab_id)',
		'CREATE INDEX idx1_continent on continent (app)',
		'CREATE INDEX idx2_continent on continent (app,uuid)',
		'CREATE INDEX idx1_security on security (level)',
		'CREATE INDEX idx2_security on security (level,server_time)',
		'CREATE INDEX idx1_cache on cache (app,device,context,subcontext)',
		'CREATE INDEX idx1_backups on backups (signatorial,recipient)',
		'CREATE INDEX idx1_mailbox on mailbox (contact)',
		'CREATE INDEX idx2_mailbox on mailbox (community,club,team,project,account,person)',
		'alter table appointments add column subtype VARCHAR(255)'
	];
	foreach my $t ( qw/model option option_category subcategory/) {

	}
	my ($db,$database,$sql) = &subs::database_grabber();
	foreach my $command (@{$commands}) {
		eval { &subs::db_query($command) };
	}
	if (1 == 0) {
		my $settings = &subs::db_query('select distinct(app) from settings')->hashes;
		foreach my $s ( @{$settings}) { 

			my $permanent = &subs::db_query('select * from settings where app = ? and device = ? and setting=?', $s->{'app'}, $device,'permanent')->hashes;
			if (scalar @{$permanent} == 0) {

				&subs::setting_setter({ app => $s->{'app'}, setting => 'permanent', value => 'checked' });
			}
		}
	}

}

post '/manager/setting_setter' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $subsetting = $c->param('subsetting');
	my $timestamp = $c->param('timestamp');
	my $s = &subs::setting_setter({ app => $app, setting => $setting, value => $value, timestamp => $timestamp, subsetting => $subsetting });
	$c->render(json => $s);
};

get '/manager/setting_grabber' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $s = &subs::setting_grabber({ app => $app, setting => $c->param('setting'), subsetting => $c->param('subsetting') });
	$c->render(json => $s);
};

post '/manager/setting_deleter' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $s = &subs::setting_deleter({ app => $app, setting => $c->param('setting'), device => $c->param('device') });
	$c->render(json => $s);
};

get '/manager/settings_grabber' => sub($c) {
	my $app = &subs::unformat_name($c->param('app'));
	my $device = &subs::unformat_name($c->param('device'));
	my $s = &subs::settings::grabber({ app => $app, device => $device });
	$c->render(json => $s);
};

get '/manager/ago' => sub ($c) {
	my $ago = $c->param('ago');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	$timestamp = &subs::ago_calc($ago,$timestamp);
	$c->render(text => $timestamp);
};


websocket '/observer/ws' => sub ($c) {
	my $browser_tab_id = $c->param('browser_tab_id');
	$gb::paperboy->{$browser_tab_id} = $c->tx;
	$c->on(message => sub ($ows, $msg) {
		my $m = decode_json $msg;
		if ($m->{'type'} eq 'heartbeat') {
			$ows->send($msg);
		}
		elsif ($m->{'type'} eq 'refresher') {
			my ($db,$database,$sql) = &subs::database_grabber();
			my $server_time = &subs::rightNow();
			my $q = &subs::db_query('select * from magazine where timestamp >= ? and timestamp <= ? and status=?', $m->{'last_paper_delivered'},$server_time,'publish');
			my $papers = $q->hashes;
			foreach my $p ( @{$papers} ) {
				my $papes = encode_json $p;
				$ows->send($papes);
			}
		}
	});
	$c->on(close => sub ($ows, $msg) {
		$gb::paperboy->{$browser_tab_id} = undef;
	});
};

websocket '/mail/ws' => sub ($c) {
	my $me = &manager_file_maker($c->session('name'));
	my $browser_tab_id = $c->param('browser_tab_id');
	my $picker = eval { return decode_json $c->param('picker') } || {};
	if ($c->param('phone') && $c->param('phone') ne 'null' && $c->param('phone') ne 'undefined') {
		$gb::mailws->{$c->param('phone')}->{$browser_tab_id} = $c->tx;
	}
	elsif ($c->param('email') && $c->param('email') ne 'null' && $c->param('email') ne 'undefined') {
		$gb::mailws->{$c->param('email')}->{$browser_tab_id} = $c->tx;
	}
	elsif ($c->param('mail_contact') && $c->param('mail_contact') ne 'null') {
		$gb::mailws->{$c->param('mail_contact')}->{$browser_tab_id} = $c->tx;
	}
	elsif ($c->session('privilege') eq 'guest') {
		$gb::mailws->{$c->session('ticket_uuid')}->{$browser_tab_id} = $c->tx;
	}
	else {
		$gb::mailws->{$picker->{'people'}}->{$picker->{'accounts'}}->{$picker->{'projects'}}->{$picker->{'teams'}}->{$picker->{'clubs'}}->{$picker->{'communities'}}->{$browser_tab_id} = $c->tx;
	}
	my $name = $c->session('name');
	$c->on(message => sub ($mws, $msg) {
		my $m = decode_json $msg;
		$m->{'uuid'} = &subs::random_string_creator(35);

		if ($m->{'type'} eq 'heartbeat') {
			if ($c->session('privilege') eq 'citizen') {
				my ($db,$database,$sql) = &subs::database_grabber();
				my $publics = &subs::db_query('select * from mailbox where status=?', 'public');
				my $public = $publics->hashes;
				foreach my $p ( @{$public} ) {
					&subs::db_query('update mailbox set status=?, body =? where uuid =?', 'sent', &subs::note_encrypter($c->session('suds'), $p->{'body'}, $p->{'timestamp'}), $p->{'uuid'});
					my $messenger = { 
						msg => $p->{'body'},
						timestamp => $p->{'timestamp'}, 
						type => 'message', 
						mail_contact => $p->{'contact'}, 
						picker => {
							projects => $p->{'project'},
							accounts => $p->{'account'},
							clubs => $p->{'club'},
							teams => $p->{'team'},
							communities => $p->{'community'},
							people => $p->{'person'}
						},
						manager_file => $p->{'manager_file'}
					};
					my $message = encode_json $messenger;

					foreach my $bti ( keys %{$gb::mailws->{$p->{'person'}}->{$p->{'account'}}->{$p->{'project'}}->{$p->{'team'}}->{$p->{'club'}}->{$p->{'community'}}} ) {
						$gb::mailws->{$p->{'person'}}->{$p->{'account'}}->{$p->{'project'}}->{$p->{'team'}}->{$p->{'club'}}->{$p->{'community'}}->{$bti}->send($message);
					}
				}
			}
			if (scalar @{$m->{'decrypteds'}} > 0) {

				foreach my $d ( @{$m->{'decrypteds'}} ) {
					my $dm = &subs::db_query('select * from mailbox where uuid = ?', $d)->hashes->[0];
					$dm->{'body'} = &subs::note_decrypter($c->session('suds'),$dm->{'body'},$dm->{'ost'});
			
					$dm->{'decrypted'} = 'yes';
					my $content = $c->render_to_string(
						template => 'mail/message',
						'm' => $dm,
						me => $me
					);
					&Websocket::send('mailbox', {  type => 'mailbox_message', selector => '.mailbox_message[uuid="' . $dm->{'uuid'} . '"]', content => $content, browser_tab_id => $c->param('browser_tab_id') });
				}
			}
			$mws->send($msg);
		}
		elsif ($m->{'type'} eq 'compose') {
			my $message = $m->{'msg'};
			$message->{'subject'} = &subs::note_encrypter($c->session('suds'), $message->{'subject'});
			$message->{'body'} = &subs::note_encrypter($c->session('suds'), $message->{'body'});
			if ($message->{'uuid'}) {
				&subs::db_update('mailbox', {
					email => $message->{'to'},
					subject => $message->{'subject'},
					body => $message->{'body'},
					status => 'draft'
				},
				{
					uuid => $message->{'uuid'}
				});
			}
			else {
				$message->{'uuid'} = &subs::random_string_creator(23);
				&subs::db_insert('mailbox', {
					email => $message->{'to'},
					subject => $message->{'subject'},
					body => $message->{'body'},
					uuid => $message->{'uuid'},
					status => 'draft'
				});

			}
			&Websocket::send('tab', { console => '$(\'.wind[app="' . $message->{'app'} . '"]\').find(\'.email_compose_form\').attr(\'uuid\', \'' . $message->{'uuid'} . '\')' });
		}
		elsif ($m->{'type'} eq 'delete') {
			if ($m->{'msg'}->{'uuid'}) {
				&subs::db_delete('mailbox', { uuid => $m->{'msg'}->{'uuid'} });
				my $message = &subs::db_select('mailbox', undef, { uuid => $m->{'msg'}->{'uuid'} })->hashes->[0];
				&deletion_registration({ table => 'mailbox', uuid => $message->{'uuid'}, scope => 'single', server_time => $message->{'server_time'} });
				&Websocket::send('tab', { console => '$(\'.mailbox_message[uuid="' . $m->{'msg'}->{'uuid'} . '\').remove();' });
			}
		}
		elsif ($m->{'type'} eq 'message') {
			$m->{'decrypted'} = 'yes';
			foreach my $strip ( qw/msg manager_file/ ) {
				my $hs = HTML::Strip->new();
				$m->{$strip} = $hs->parse( $m->{$strip} );
				$hs->eof;
			}
			my $manager_file = &manager_file_maker($name);
			$m->{'manager_file'} = $manager_file; 
			if ($c->session('privilege') eq 'guest') {
				$m->{'mail_contact'} = $c->session('ticket_uuid');
			}
			my $e_msg = &subs::note_encrypter($c->session('suds'),$m->{'msg'});
			$m->{'body'} = $m->{'msg'};
			my $picker = eval { return decode_json $m->{'picker'} } || {};
			if ($m->{'mail_contact'}) { $picker = {} };
			my ($db,$database,$sql) = &subs::database_grabber();
			&subs::db_insert('mailbox', {
				uuid => $m->{'uuid'},
				timestamp => $m->{'timestamp'},
				server_time => &subs::rightNow(),
				body => $e_msg,
				project => $picker->{'projects'},
				account => $picker->{'accounts'},
				club => $picker->{'clubs'},
				team => $picker->{'teams'},
				community => $picker->{'communities'},
				manager_file => $m->{'manager_file'},
				status => 'sent',
				contact => $m->{'mail_contact'},
				phone => $m->{'phone'},
				email => $m->{'email'},
				person => $picker->{'people'}
			});
			$m->{'envelope'} = $c->render_to_string(
				template => 'mail/message',
				'm' => $m,
				'me' => $me
			);
			$msg = encode_json $m;
			if ($m->{'phone'}) {
				foreach my $bti ( keys %{$gb::mailws->{$m->{'phone'}}} ) {
					$gb::mailws->{$m->{'phone'}}->{$bti}->send($msg);
				}
				&sms_message_send($m->{'phone'},$m->{'msg'});
			}
			elsif ($m->{'email'}) {
				foreach my $bti ( keys %{$gb::mailws->{$m->{'email'}}} ) {
					$gb::mailws->{$m->{'email'}}->{$bti}->send($msg);
				}
			}
			elsif ($m->{'mail_contact'}) {
				foreach my $bti ( keys %{$gb::mailws->{$m->{'mail_contact'}}} ) {
					$gb::mailws->{$m->{'mail_contact'}}->{$bti}->send($msg);
				}
				if ($m->{'mail_contact'} eq 'pen') {

						my $mesg = &subs::pen_message($m);
						$mesg->{'envelope'} = $c->render_to_string(
							template => 'mail/message',
							'm' => $mesg,
							'me' => $me
						);
						$mesg->{'type'} = 'message';
						my $pmsg = encode_json $mesg;
						foreach my $bti ( keys %{$gb::mailws->{$m->{'mail_contact'}}} ) {
							$gb::mailws->{$m->{'mail_contact'}}->{$bti}->send($pmsg);
						}

				}
			}
			elsif ($c->session('privilege') eq 'guest') {
				my $t_uuid = $c->session('ticket_uuid');
				foreach my $bti ( keys %{$gb::mailws->{$t_uuid}} ) {
					$gb::mailws->{$m->{'mail_contact'}}->{$bti}->send($msg);
				}
			}
			else {
				foreach my $bti ( keys %{$gb::mailws->{$picker->{'people'}}->{$picker->{'accounts'}}->{$picker->{'projects'}}->{$picker->{'teams'}}->{$picker->{'clubs'}}->{$picker->{'communities'}}} ) {
					$gb::mailws->{$picker->{'people'}}->{$picker->{'accounts'}}->{$picker->{'projects'}}->{$picker->{'teams'}}->{$picker->{'clubs'}}->{$picker->{'communities'}}->{$bti}->send($msg);
				}
			}
			if (&subs::setting_grabber({ app => 'mail', setting => 'lora_toggle' }) eq 'on') {
				foreach my $device_type ( qw/watch teletype microcontroller/ ) {
					my $chips = &subs::device_lister(&subs::rightNow(), $device_type, undef, 'all');
					foreach my $watch ( @{$chips} ) {
						if (eval {$watch->{'ip'} }) {
							my $watch_port = $ENV{PORT_BELL};
							my $ws_port = $ENV{PORT_MSG};
							my $od = &subs::setting_grabber({ app => 'watch', setting => 'operator_door' });
							my $op_d = eval { decode_json $od } || {};
							my $secret = &subs::note_encrypter($op_d->{'__shutup'}->{'patience'}, $c->session('suds'));
							$secret = `echo "$secret" | base64 -w 0`;
							my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/chat_received?s=' . $secret . '&timestamp=' . $m->{'timestamp'} . '&uuid=' . $m->{'uuid'};

							my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};
							my $ping_test = `$ping`;
							if ($ping_test =~ /ttl/gi) {
								Mojo::IOLoop->subprocess->run_p(sub {
									my $ua = Mojo::UserAgent->new();
									my $res = $ua->insecure(1)->get($watch_home)->result;
								});
							}
						}
					}
				}
			}
		}
		elsif ($m->{'type'} eq 'refresher') {
			my ($db,$database,$sql) = &subs::database_grabber();
			my $picker = eval { return decode_json $m->{'picker'} } || {};

			my $q;
			if ($m->{'phone'}) { 
				$q = &subs::db_query('select * from mailbox where timestamp > ? and phone = ? order by timestamp desc LIMIT 20', $m->{'last_message'}, $m->{'phone'});
			}
			elsif ($m->{'mail_contact'}) {
				$q = &subs::db_query('select * from mailbox where timestamp > ? and contact = ? order by timestamp desc LIMIT 20', $m->{'last_message'}, $m->{'mail_contact'});
			}
			else {
				$q = &subs::db_query('select * from mailbox where timestamp > ? and  project=? and account =? and community = ? and club = ? and team = ? and person = ? order by timestamp desc LIMIT 20', 
					$m->{'last_message'}, $picker->{'projects'}, $picker->{'accounts'}, $picker->{'community'}, $picker->{'club'}, $picker->{'team'}, $picker->{'person'}
				);
			}
			my $messaging = $q->hashes;
			foreach my $mess ( @{$messaging} ) {
				$mess->{'body'} = &subs::note_decrypter($c->session('suds'), $mess->{'body'}, $mess->{'ost'});
			}
			$messaging = encode_json { messages => $messaging, 'type' => 'refresher' };
			$mws->send($messaging);
		}
	});
	$c->on(finish => sub ($c, $code, $reason) {
		$gb::mailws->{$browser_tab_id} = undef;
		if ($c->param('phone') && $c->param('phone') ne 'null') {
			$gb::mailws->{$c->param('phone')}->{$browser_tab_id} = undef;
		}
		elsif ($c->param('mail_contact') && $c->param('mail_contact') ne 'null') {
			$gb::mailws->{$c->param('mail_contact')}->{$browser_tab_id} = undef;
		}
		elsif ($c->session('privilege') eq 'guest') {
			$gb::mailws->{$c->session('ticket_uuid')}->{$browser_tab_id} = undef;
		}
		else {
			$gb::mailws->{$picker->{'people'}}->{$picker->{'accounts'}}->{$picker->{'projects'}}->{$picker->{'teams'}}->{$picker->{'clubs'}}->{$picker->{'communities'}}->{$browser_tab_id} = undef;
		}
	});
};

get '/manager/remote_auth_test' => sub($c) {
	my $appt = &subs::db_query('select server_time,app from appointments order by server_time DESC LIMIT 1')->hashes->[0];
	my $ip = $c->tx->remote_address;
	my $home_ip = $c->tx->local_address;
	my $remote_domain = $c->param('domain') || $ip;

	my $signatorial = $c->param('signatorial');

	my $rm = &subs::db_select('remote_machines', ['ip','deletions','signatorial'], { ip => $remote_domain, signatorial => $signatorial })->hashes;
		if (scalar @{$rm} > 0) {
		if ($rm->[-1]->{'signatorial'}) {
			my @domain = split '\.', $config->{'domain'};
			shift @domain;
			my $domain = join '.', @domain;
			my $now = &subs::rightNow();
			my $my_signatorial = &subs::signatorial_designer();

			my @ws_auth = (
				$ip, $my_signatorial
			);
			my $ws_joiner = join $universal_splitter, @ws_auth;
			my $pa = &subs::random_string_creator(25);
			my $ws_auth = &subs::encrypter($pa, $ws_joiner);
			&subs::setting_setter({ app => '__president', setting => 'ws_pa', value => $pa});
			my $json = {
				server_time => $appt->{'server_time'},
				app => $appt->{'app'},
				port => $ENV{PORT_AHOY},
				ws_port => $ENV{PORT_MSG},
				signatorial => $my_signatorial,
				now => $now,
				me => $c->tx->local_address,
				you => $c->tx->remote_address,
				deletions => $rm->[-1]->{'deletions'},
				fqdn => $config->{'domain'},
				domain => $domain,
				ws_auth => $ws_auth,
				env => $ENV{PORT_ENV}
			};
			$c->render(json => $json);
			
			my $deletions = eval { return decode_json $rm->[-1]->{'deletions'} } || [];
			@{$deletions} = grep { $_->{'initialization'} + 60000 > &subs::rightNow() } @{$deletions};
			$deletions = eval { return encode_json $deletions };

			&subs::db_update('remote_machines', { deletions => $deletions }, { signatorial => $rm->[-1]->{'signatorial'} }) if eval { decode_json $rm->[-1]->{'deletions'} };


		}
	}
	else {
		$c->render(json => {});
	}
};


sub remote_machine_reconnector($c) {

	&subs::setting_setter({ app => '__president', setting => 'remote_connect_timer', value => &subs::rightNow() });
	my $timestamp = &subs::rightNow();
	my $browser_tab_id = $c->param('browser_tab_id');
	my $browser_tab = $c->param('browser_tab');
	my $ws_auth;
	eval {
		my $remote_machines = &subs::db_select('remote_machines', undef, { })->hashes;
		foreach my $rm ( @{$remote_machines} ) {
			my $ip = $rm->{'ip'};
			my $ping = `timeout 1 ping -c 1 $ip`;
			my $ping_test;
			if ($ping !~ /ttl/) { $ping_test = 'no'; }
			my $auuid = &subs::random_string_creator();

			if ($ping =~ /ttl/) {
				$rm = &remote_useragent_maker({ ip => $ip, signatorial => $rm->{'signatorial'}, rm => $rm });
				my $manager = $rm->{'manager'};
				my $port = $rm->{'port'};
				$manager =~ s/:$port/:3000/gi;
				if (!$rm->{'res'}) {
					$ping_test = 'no';
				}

				if (!eval { return decode_json $rm->{'res'}->body }) {
					$ping_test = 'no';
					if ($rm->{'data'}->{'database'}) {
						my $auuid = &subs::random_string_creator();
						my $manager_file = &manager_file_maker($c->session('name'));
						my $html = '<h2>Reconnecting to ' . $ip . '</h2>';
						&Websocket::send('tab', { green => $html, uuid => $auuid });
						my $password = $c->session('suds');

						my $port = $rm->{'port'};
						my $manager = $rm->{'manager'};
						my $rdc = {
							manager => $manager,
							filename => $rm->{'data'}->{'database'},
							timestamp => $timestamp,
							ip => $ip,
							password => $password,
							name => $c->session('name'),
							browser_tab_id => $browser_tab_id,
							browser_tab => $browser_tab,
							port => $rm->{'port'},
							signatorial => $rm->{'signatorial'},
							nic => $rm->{'nic'}
						};
						$rm->{'cookie'} = undef;
						my $returner = &remote_device_connect($rdc);		
						if ($returner->{'body'}->{'signatorial'}) {
							$ping_test = 'ok';
						}
						else {
							$ping_test = 'no';
						}
					}
					else { $ping_test = 'ok'; }
				}
				else { 
					my $rj = $rm->{'res'}->json;
					my $appt = &subs::db_query('select server_time,app from appointments order by server_time DESC LIMIT 1')->hashes->[0];
					if ($rj->{'fqdn'}) {
						my @domain = split '\.', $rj->{'fqdn'};
						my $subdomain = $domain[0];

						if ($rj->{'ws_auth'}) {
							$ws_auth = url_escape $rj->{'ws_auth'};
						}

					}
					$rm->{'port'} = $rj->{'port'};
					$rm->{'ws_port'} = $rj->{'ws_port'};
					$ping_test = 'ok';
					my $backup = &subs::db_query('select * from backups where reason=? and signatorial=? and recipient=? order by server_time DESC LIMIT 1',
						'remote_upgraded',$rj->{'signatorial'},&subs::signatorial_designer())->hashes->[0];
					if ($rj->{'deletions'}) {
						&deletion_performer($rj->{'deletions'});
					}	
					if ($device eq 'computer') {
						my $diff = ($rj->{'now'} - &subs::rightNow());
						if (abs $diff > 500) {
							my $uc = 'sudo date -s @' . $rj->{'now'} / 1000;
							my $update = `$uc`;
						}
					}

					if ($rj->{'server_time'} > $backup->{'server_time'}) {
						my $whoami = `whoami`;
						chomp $whoami;
						my $hostname = `hostname`;
						chomp $hostname;
						my $gimme = $c->session('gimme') || $c->param('gimme');
						my $params = {
							timestamp => $rj->{'now'},
							ip => $rm->{'ip'},
							ssh_port => $rm->{'data'}->{'ssh_port'} || $config->{'ssh_port'},
							database => $rm->{'data'}->{'database'},
							remote_signatorial => $rj->{'signatorial'},
							remote_device => $rm->{'data'}->{'device'},
							gimme => $gimme
						};
						if ($ENV{PORT_ENV} eq 'production' && $rj->{'env'} eq 'production') {
						#	Mojo::IOLoop->subprocess->run_p(sub {
								&remote_upgrade($c,$params);
						#	});
						}
					}
					else {
					}
				}
			}
			else {
				my $dev_info = &device_network_updater($rm);
			}
			&Websocket::send('tab', { green => ' ', 'close' => 'yes' });
			if ($ping_test eq 'no') {
				if ($rm->{'connection'} eq 'active') {
					my $appts = &subs::db_select('appointments', undef, { app => &subs::unformat_name($rm->{'hostname'}), type => 'start' })->hashes;
					foreach my $appt ( @{$appts} ) { 
						&appointment_writer($c, { 
							type => 'stop', 
							uuid => $appt->{'uuid'},
							app => $appt->{'app'}
						}); 
						&subs::appt_header_printer({ app => $appt->{'app'} });
						&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $appt->{'app'} . '\',\'' . $appt->{'uuid'} .'\');'});
					}
				}
				$rm->{'connection'} = 'inactive';
			}
			else {
				$rm->{'connection'} = 'active';
			}
			&subs::db_update('remote_machines', { ws_auth => $ws_auth, ws_port => $rm->{'ws_port'}, port => $rm->{'port'}, connection => $rm->{'connection'} }, { ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'} });
		}
	}
}


sub device_network_updater($data) {
	my $nic = $data->{'nic'};
	my $ifconfig = `ifconfig`;
	my @ifconfig = grep { $_ =~ /$nic/ } split "\n\n", $ifconfig;

	foreach my $if (@ifconfig) {
		my @ifconfig_list = split "\n", $if;

		my @ifconfig_inet = grep { $_ =~ /inet/ } @ifconfig_list;
	}
}

websocket '/manager/ws' => sub ($c) {
	my $ug    = Data::UUID->new;
	my $uuid = $ug->create_str();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = $c->param('app');
	my $remote_address = $c->tx->remote_address;
#	$c->render(template => 'guest_layouts/denial') unless $app eq 'music' || $app eq 'server' || $app eq 'tab';
	my $timestamp = $c->param('timestamp');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $browser_tab = $c->param('browser_tab');
	my $me_settings = &subs::settings_grabber({ app => 'me', settings => [ 'computer_name', 'log_me' ] });
	my $computer_name = $me_settings->{'computer_name'};
	my $log_me = $me_settings->{'log_me'};
	if ($c->param('browser_tab_id') eq '') {
		$c->render('text' => 'no');
		return;
	}

	my $browser_tab = $c->param('browser_tab');
	my $user_agent = $c->param('user_agent') || $gb::user_agent;

	my $server_time = &subs::rightNow();
	my $hostname = `hostname`;
	chomp($hostname);
	my $connection_id = $c->tx;
	$connection_id = $connection_id->connection;
	my $init_data = { 
		browser_tab_id => $browser_tab_id,
		browser_tab => $browser_tab,
		db => $database,
		'uuid' => $uuid,
		timestamp => $timestamp,
		connected => $timestamp,
		server_time => $server_time,
		type => 'connect',
		app => $app,
		hostname => $hostname,
		connection_id => $connection_id,
		user_agent => $user_agent,
		random_string => &subs::random_string_creator(25),
		href => $c->param('href'),
		pathname => $c->param('pathname'),
		ticket_uuid => $c->session('ticket_uuid')
	};
	if ($c->param('remote') eq 'yes') {
		my @app = split /\@/, $app;
		my $sapp = $app[0];
		$gb::remote_ws->{$sapp}->{$browser_tab_id} = $c->tx;
	}
	else {

	}
	$gb::ws->{$app}->{$browser_tab_id} = $c->tx;
	$gb::ws->{$app}->{$browser_tab_id}->{'privilege'} = $c->session('privilege');
	my $tab_check = &subs::db_query('select * from websockets where browser_tab_id = ? and remote_address = ? and app = ?',$browser_tab_id, $remote_address, $app );
	my $existing_websockets = $tab_check->hashes;

	unless (scalar @{$existing_websockets} > 0) {
		my $app = $c->session('app');
		my $app_warranty = &subs::setting_grabber({ app => $app, setting => 'warranty' });
		my $warranty = &subs::ago_calc($app_warranty || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time);
		$init_data->{'warranty'} = $warranty;
		&subs::db_insert('websockets', $init_data);

	}
	else {



	}



	&Websocket::send($app, $init_data);
	if ($c->param('app') eq 'music') {
		if ($log_me eq 'on') {
			my $appts = &subs::db_query('select * from appointments where source_uuid = ? and app = ? order by timestamp desc limit 30', $browser_tab, $computer_name)->hashes;
			my $resolved = 0;
			if (scalar @{$appts} > 0) {
				foreach my $appt ( @{$appts } ) {
					if ($appt->{'type'} eq 'stop') {
						if (($appt->{'timestamp'} - $appt->{'duration'}) > &subs::rightNow() - 120000) {
							$resolved = 1;
							&subs::db_update('appointments', { server_time => &subs::rightNow(), type => 'start' }, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });
							&subs::intelligent_automation_toggle({ appt_uuid => $appt->{'uuid'}, app => $appt->{'app'}, 'state' => 'on', timestamp => $timestamp });
							&subs::appt_header_printer({ app => $appt->{'app'} });
							&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $appt->{'app'} . '\',\'' . $appt->{'uuid'} .'\');'});
							my $sources = &subs::db_select('appointments', undef, { source_uuid => $appt->{'uuid'} })->hashes;
							foreach my $so ( @{$sources} ) {
								push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
								if ( $so->{'type'} eq 'stop' ) {
									my $dur = $so->{'timestamp'} - $timestamp;
									&subs::db_update('appointments', { stop_seen => 'yes', type => 'start', duration => $dur, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'} });
									&budget_runner($so->{'app'});
									&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'on', timestamp => $timestamp });
									&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
								}
							}
						}
					}
					elsif ($appt->{'type'} eq 'start') {
						$resolved = 1;
					}
				}
			}
			
			if ($resolved == 0) {
				my $jdata = encode_json { duty_time => $gb::duty_time };
				my $data = {
					app => $computer_name,
					type => 'start',
					data => $jdata,
					timestamp => $timestamp,
					source_uuid => $browser_tab
				};
				&appointment_writer($c,$data);
			}
		}
	}
#	$c->send({json => $init_data});
	if ($app eq 'server') {
		&Websocket::send('server', { magic_wand => $browser_tab_id, action => 'open', timestamp => $timestamp });
	}

	$c->on(message => sub ($ws, $msg) {
		my $data = eval { return decode_json $msg };
		my $app = $data->{'app'};
		my $apper = $data->{'app'};
		if ($app =~ /@/gi) {
			my @app = split /\@/, $app;
			$apper = $app[0];

		}
		my $remote_machines;
		if ($data->{'type'} eq 'stayingAlive') {
			my $server_time = &subs::rightNow();
			$timestamp = $data->{'timestamp'};
			my $connection = $ws->tx;
			my $connection_id = $connection->connection;
			my $local_address = $ws->tx->local_address;
			my $remote_address = $ws->tx->remote_address;
			if ($app eq 'music') {
				$data->{'music_data'} = encode_json $data->{'music_data'} if $data->{'music_data'};
			}
			if ($app eq 'server') {
				$data->{'jp_data'} = encode_json $data->{'jp_data'} if $data->{'jp_data'};
			#	my $remote_upgrade = &subs::setting_grabber({ app => '__president', setting => 'remote_upgrade' });
			#	my $remote_connect_timer =  &subs::setting_grabber({ app => '__president', setting => 'remote_connect_timer' });
			#	if ($remote_connect_timer + (60 * 7 * 1000) < $timestamp) {
			#		&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
			#	}
			#	if ($remote_upgrade ne 'running' && $remote_connect_timer + 30000 < $timestamp) {
			#		&remote_machine_reconnector($c);
			#	}
				if ($data->{'controller_visible'} eq 'yes') {
					my $remote_machine_query = &subs::db_query('select * from remote_machines' );
					$remote_machines = $remote_machine_query->hashes;

					foreach my $rm ( @{$remote_machines} ) {
						$rm->{'data'} = decode_json $rm->{'data'} if eval { decode_json $rm->{'data'} };
					}
				}
			}
			if ($app eq 'tab') {
				if ($data->{'windows'}) {
					my $windows = eval { return decode_json $data->{'windows'} } || [];

					foreach my $w ( keys %{$windows} ) {
						foreach my $set ( qw/scrollTop jopen/ ) {
							if ($set eq 'jopen') {
								$windows->{$w}->{$set} = encode_json $windows->{$w}->{$set};
							}
							&subs::setting_setter({ app => $windows->{$w}->{'app'}, setting => $set, value => $windows->{$w}->{$set} });
						}
						if ($windows->{$w}->{'headerUpdate'}) {
							my $header = &subs::db_query('select * from cache where app = ? and context = ? and timestamp > ?', $windows->{$w}->{'app'}, 'header', $windows->{$w}->{'headerUpdate'})->hashes;

							foreach my $head ( @{$header} ) {
								my $data = decode_json $head->{'data'};
								&Websocket::send($app, { type => 'header', app => $windows->{$w}->{'app'}, timestamp => $head->{'timestamp'}, header => $data->{'header'} });
							}
						}
					}
				}
			}
			&subs::db_update('websockets', { 
				timestamp => $timestamp,
				server_time => $server_time,
				type => $data->{'type'},
				connection_id => $connection_id,
				local_address => $local_address,
				remote_address => $remote_address,
				windows => $data->{'windows'},
				music_data => $data->{'music_data'},
				jp_data => $data->{'jp_data'},
				href => $data->{'href'},
				pathname => $data->{'pathname'}
			}, {
				browser_tab_id => $browser_tab_id,
				app => $data->{'app'}
			});
			if ($data->{'debriefer'}) {
				if ($c->session('ticket_uuid')) {
					&subs::db_query('update tickets set debriefer = ? where uuid = ?', $data->{'debriefer'}, $c->session('ticket_uuid'));
				}
				else {
					my $hostname = `hostname`;
					chomp($hostname);
					&subs::setting_setter({ app => '__DEBRIEFING__', setting => $hostname, value => $data->{'debriefer'} });
				}
			}
			my $community = &subs::db_query('select * from websockets where ( app = ? or app like ? ) and type = ? and server_time >= ? order by server_time DESC',$app, $app . '@%', 'stayingAlive',$server_time - 5000);
			my $neighbours = $community->hashes;
			foreach my $n ( @{$neighbours} ) { 
				my $neighbour_windows = $n->{'windows'};
				my $neighbourhood = eval { return decode_json $n->{'windows'} } || {};
				$n->{'user_agent'} = &subs::abbreviate_name($n->{'user_agent'});
				foreach my $nw ( keys %{$neighbourhood} ) {
					$neighbourhood->{$nw}->{'formatted_name'} = &subs::format_name($neighbourhood->{$nw}->{'app'});
					$neighbourhood->{$nw}->{'shorthand_name'} = &subs::shorthand_name($neighbourhood->{$nw}->{'formatted_name'});
				}
				$n->{'windows'} = encode_json $neighbourhood;
			}

			my $return_data = { 
				browser_tab_id => $browser_tab_id,
				browser_tab => $browser_tab,
				'uuid' => $uuid,
				timestamp => $timestamp,
				app => $data->{'app'},
				neighbours => $neighbours,
				from => $hostname,
				connection_id => $connection_id,
				user_agent => $user_agent,
				type => $data->{'type'},
				local_address => $local_address,
				remote_address => $remote_address,
				input => $data->{'input'},
				remote => $remote_machines
			};
			
		
			$return_data->{'template'} = $c->render_to_string(
				template => 'websockets/' . $app,
				ws => $return_data
			) if -e './templates/websockets/' . $apper . '.html.ep';

			&Websocket::send($app,$return_data);


		}
		elsif ($data->{'type'} eq 'synth' && $app eq 'music') {
			my $freq = $data->{'freq'};
			my $waveform = $data->{'waveform'};
			my $length = $data->{'length'};
      Mojo::IOLoop->subprocess->run_p(sub {
				`play "|sox -n -p synth $length $waveform $freq " &`;
			});

		}
		elsif ($data->{'method'} eq 'playerCache') {
			&subs::cache_set({ app => 'music', context => 'player' }, $data);

		}
		elsif ($data->{'method'} eq 'transmitter') {
			$data->{'browser_tab_id'} = $browser_tab_id;

			&subs::music_transmitter($c, $data);
		}
		else {
			$data->{'not_me'} = 1;
			$data->{'browser_tab_id'} = $browser_tab_id;

			&Websocket::send($app, $data);
		}
	});
	$c->on(finish => sub ($c,$code,$reason) {
		&subs::db_update('websockets', { 'type' => 'closed'}, { app => $app, browser_tab_id => $browser_tab_id });
		delete $gb::ws->{$app}->{$browser_tab_id};
		&Websocket::send('server', { magic_wand => $browser_tab_id, action => 'closed', timestamp => $timestamp });
		if ($app eq 'music') {
			if ($log_me eq 'on') {
				my $appts = &subs::db_query('select * from appointments where source_uuid = ? and app = ? and type = ? order by timestamp desc limit 30', $browser_tab, $computer_name,'start')->hashes;
				foreach my $appt ( @{$appts} ) { 
					&appointment_writer($c, { 
						type => 'stop', 
						uuid => $appt->{'uuid'},
						app => $appt->{'app'}
					}); 
					&subs::appt_header_printer({ app => $appt->{'app'} });
					&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $appt->{'app'} . '\',\'' . $appt->{'uuid'} .'\');'});
				}
			}
		}
	});

	unless (1 == 0 && $c->param('remote') eq 'yes') {
		my $remote_machine_query = &subs::db_query('select * from remote_machines where connection=?','active' );
		my $remote_machines = $remote_machine_query->hashes;
		foreach my $rm ( @{$remote_machines} ) {
			my $id = '';
			my @ip = split /\./, $rm->{'ip'};
			if ($rm->{'ip'} =~ /[A-Za-z]/gi) {
				$id = $ip[0];
			}
			else {
				$id = $ip[-1];
			}
			my $command = { console => 'websocketStart(\''. $app . '@' . $id . '\',\'wss://' . $rm->{'ip'} . ':' . $rm->{'ws_port'} . '/manager/ws?remote=yes&app=' . $app . '@' . $id . '&browser_tab_id=' . $rm->{'signatorial'} . '&timestamp=' . &subs::rightNow() . '&ws_auth=' . $rm->{'ws_auth'} . '\');' };
			#&Websocket::send('server', $command);# if !grep { $_ eq $app } qw/music server tab/;
		}
	}
};

post 'manager/ws/remote_control' => sub($c) {
	my $destination = $c->param('destination');
	my $value = $c->param('value');
	my $app = &subs::unformat_name($c->param('app'));
	my $control = $c->param('control');
	&Websocket::send($app, {
		value => $value,
		app => $app,
		control => $control,
		destination => $destination,
		type => 'remote_control'
	});
	$c->render(text => 'ok');

};

get '/manager/remote_refresh' => sub ($c) {
	my $bti = $c->param('bti');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $timestamp = $c->param('timestamp');
	&Websocket::send('server', { console => 'location.reload()', origin => $browser_tab_id, destination => $bti, timestamp => $timestamp });
};


sub paperRoute($msg) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $original_msg = $msg;
	if ( eval { encode_json $msg }) {
		my $m = encode_json $msg;
		if (eval { $sql->db } && $sql->dsn !~ /:$/) {
			my $server_time = &subs::rightNow();
			my $uuid = &subs::random_string_creator(20);
			&subs::db_insert('websocket_messages', {
				timestamp => $original_msg->{'timestamp'},
				message => $m,
				server_time => $server_time,
				uuid => $uuid,
				sent_count => 0,
				environment => 'papers'
			});
		}
	}
}

if ($ENV{PURPOSE} && ($ENV{PURPOSE} eq 'alarm' || ($ENV{PORT_ENV} eq 'development' && $ENV{PURPOSE} eq 'main'))) {

	#require './Alarm.pl';
	#&Alarm::alarm_clock();;
}

if ($ENV{PURPOSE} && ($ENV{PURPOSE} eq 'websocket' || ($ENV{PORT_ENV} eq 'development' && $ENV{PURPOSE} eq 'main'))) {


	my $message_count = &websocket_message_checker([]);

	sub websocket_message_checker($last_message) {

		my $db_running = 0;
		my $message_count = 0;
		if ($db_running == 0) {

			$db_running = 1;
			my $returner;
			my ($db,$database,$sql) = &subs::database_grabber();
			if ($db) {

				my $wm = &subs::db_query('select * from websocket_messages');
				my $ws_messages = $wm->hashes;

				$message_count = scalar @{$ws_messages};

				foreach my $wsm ( @{$ws_messages} ) {
					my $return_msg = &websocket_sender($wsm);	
					if ($wsm->{'uuid'}) {
						if (!grep { $_->{'uuid'} ne $wsm->{'uuid'} } @{$return_msg->{'save'}}) {
							&subs::db_query('delete from websocket_messages where uuid=?',$wsm->{'uuid'});
						}
					}
					else {
						&subs::db_query('delete from websocket_messages where timestamp = ?', $wsm->{'timestamp'});
					}
				}
			}
			$db_running = 0;
		}
		unshift @{$last_message}, $message_count;
		pop @{$last_message} if scalar @{$last_message} > 100;
		my $sum = 0;
		map { $sum += $_ } @{$last_message};
		my $next_time = 2;
		if ($sum > 20) {
			$next_time = .1;
		} elsif ($sum > 10) {
			$next_time = .3;
		} elsif ($sum > 5) {
			$next_time = .6;
		}
		Mojo::IOLoop->timer($next_time => sub { &websocket_message_checker($last_message); });
	}


}

sub websocket_sender($wsm) {
	my $returner;
	my $return_msg = { save => [] };
	if ($wsm->{'environment'} eq 'papers') {
		foreach my $subscriber ( keys %{$gb::paperboy} ) {
			$gb::paperboy->{$subscriber}->send($wsm->{'message'});
		}
	}
	else {
		my $original_msg = eval { return decode_json $wsm->{'message'} } || {};
		#return unless $original_msg->{'app'};

		my $msg = $original_msg;
		my $app = $wsm->{'app'};
		my $server_time = $wsm->{'server_time'};
		my $timestamp = $wsm->{'timestamp'};
		my $count = 0;

		foreach my $ws ( $gb::ws, $gb::remote_ws ) {
			if ($count != 0) {
				my @app = split /\@/, $app;
				$app = $app[0];
			}
			else {
				
			}
			if ($original_msg->{'remote_only'}) {
				if ($original_msg->{'remote_only'} eq 'yes' && $count == 0) {
					next;
				}
			}
			if ( $original_msg->{'destination'}) {
				if ($ws->{$app}->{$wsm->{'destination'}}) {
					$ws->{$app}->{$wsm->{'destination'}}->send($wsm->{'message'});
				}
				elsif ($wsm->{'server_time'} > &subs::rightNow() - 10000) {
					push @{$return_msg->{'save'}}, $wsm;
				}
			}
			elsif ($original_msg->{'not_me'}) {
				foreach my $w ( keys %{$ws->{$app}} ) {
					if ($ws->{$app}->{$w} && $w ne $original_msg->{'browser_tab_id'}) {
						if ($msg->{'role'} && $msg->{'role'} ne 'all') {
							if ($msg->{'role'} ne $ws->{$app}->{$w}->{'privilege'}) {
								next;
							}
						}
						$returner = $ws->{$app}->{$w}->send($wsm->{'message'});
					}
				}
			}
			else {
				foreach my $w ( keys %{$ws->{$app}}) {
					if ($ws->{$app}->{$w}) {
						if ($msg->{'role'} && $msg->{'role'} ne 'all') {
							if ($msg->{'role'} ne $ws->{$app}->{$w}->{'privilege'}) {
								next;
							}
						}
						$returner = $ws->{$app}->{$w}->send($wsm->{'message'});
					}
				}
			}
		}
		$count++;
	}
	return $return_msg;
}

get '/manager/ws_close' => sub($c) {
	my $websocket = &subs::db_select('websockets', undef, { app => $c->param('app'), browser_tab_id => $c->param('browser_tab_id') })->hash;
	unless ($websocket->{'room'}) {
		&subs::db_delete('websockets', { app => $c->param('app'), browser_tab_id => $c->param('browser_tab_id') });
	}
	$c->render('text' => 'ok');
};
sub websocketClose($app) {
	#soon
}

if ($ENV{PURPOSE} && ($ENV{PURPOSE} ne "alarm" && $ENV{PURPOSE} ne "watch" && $ENV{PURPOSE} ne "teletype")) {

	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
#	app->sessions->encrypted(1);
	app->secrets($gb::secret_maker);
	app->sessions->cookie_name($ENV{'cookie_name'});
	app->start;
}
else {
	1;
}

