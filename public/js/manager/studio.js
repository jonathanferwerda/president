var mixer = {};
var studio;

$(document).on('click', '#studio_new', function() {
	$('#studio').attr('uuid','').attr('name','');
	studioInit();
	$('#studio_song_select').val('none');
});

$(document).on('click', '#pedalboard_hamburger', function() {
	var pd = $('#pedalboard');
	var z = $('#studio_viewer').closest('.wind').css('z-index');

	if (pd.is(':visible')) {
		pd.hide();
	}
	else {
		pd.show();
		pd.css({ 'z-index': (z + 10) });
	}
});

function studioInit() {
	mixer = {
		time: { duration: 0, status: 'stop', position: 0, marks: [], interval: 0, startTime: 0 },
		buttons: { record: { obg: '', bg: 'red', interval: '' }, stop: { obg: '', bg: 'lightgreen', interval: '' }, play: { obg: '', bg: 'yellow', interval: '' } }
	};
	$('#studio_track_container').html('');

	var pd = $('#pedalboard');
	if (!$('#soundroom_sidebar_container').is(':visible')) {

		var width = $('#soundroom_sidebar_container').width();
		width = (width + 30) + 'px';
		$('#studio').find('.to_sound').each(function(i,v) {
			var channel = $(v).attr('channel') + 1;
			$('#browser').append($(v).html());


			$(v).remove();
			$('.cord[channel="' + channel + '"]').draggable({
				start: function(p,ui) {
					$('.jack').show();
					
				},
				drag: function(p,ui) {

				},
				stop: function(p,ui) {
					$('.jack').hide();
				}
			});
		});
	}
	studioRetriever();
	if ($('#studio').attr('uuid')) {
		var uuid = $('#studio').attr('uuid');
		studioLoad(uuid);
	}
}

$(document).on('click', '.studio_close_button', function() {
	$('#soundroom_sidebar_container').html('').hide();
	$('.cord').remove();
});



$(document).on('click','.knob',function() {
	var knob = $(this);
	var control = knob.attr('control');
	var channel = knob.attr('channel');
	var input = $('.knob_control[control="' + control + '"][channel="' + channel + '"]');
	var current_value = input.val();
	var vis = input.is(':visible');
	if (vis) {
		input.hide();
		$('.knob[channel="' + channel + '"]').show();
	}
	else {
		input.show();
		$('.knob[channel="' + channel + '"]').hide();
		$('.knob[control="' + control + '"][channel="' + channel + '"]').show();
	}
	studioSaver();
});

$(document).on('mousewheel', '.knob', function(e) {
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	mvmt = numeral(mvmt / 30).value() ;

	var knob = $(this);
	var control = knob.attr('control');
	var channel = knob.attr('channel');
	var input = $('.knob_control[control="' + control + '"][channel="' + channel + '"]');
	var current_value = input.val();
	input.val((numeral(current_value).value() + mvmt) );
	input.trigger('change');
	studioSaver();
});

$(document).on('change mousemove touchmove','.knob_control',function() {
	var input = $(this);
	var channel = input.attr('channel');

	var current_value = input.val();
	var control = input.attr('control');
	var knob = $('.knob[control="' + control + '"][channel="' + channel + '"]');
	var direction = knob.attr('direction');
	var flip = numeral(knob.attr('flip')).value() || 0;
	var range = numeral(knob.attr('range')).value() || .85;
	var step = numeral(input.attr('step')).value();

	var transform_value = (flip + numeral((360 / 100) * (current_value * range)).value());
	if (direction == 'counter') {
		transform_value = (flip - numeral((360 / 100) * (current_value * range)).value());
	}
	knob.css({ 'transform': 'rotate(' + transform_value + 'deg)' });
	studioSaver();
});

$(document).on('click', '.button_control', function() {
	var b = $(this);
	var control = b.attr('control');
	var colour = b.attr('colour');
	var status = b.attr('status');
	if (status == 'depressed') {
		b.attr('status', 'pressed');
		b.attr('src', '/images/studio/button_pressed_' + colour + '.png');
	}
	else {
		b.attr('status', 'depressed');
		b.attr('src', '/images/studio/button_depressed_' + colour + '.png');
	}
	studioSaver();
});

$(document).on('mousewheel', '.channel_volume', function(e) {
	var vol = $(this);
	var mvmt = numeral(e.originalEvent.wheelDelta).value() / 30;
	var newVol = (numeral(vol.val()).value() + mvmt);
	vol.val(newVol);
	studioSaver();
});

$(document).on('change', '.channel_volume', function() {
	studioSaver();
});

$(document).on('click', '#studio_loop', function() {
	var sl = $(this);
	if (sl.attr('enabled') == 'on') {
		sl.attr('enabled', 'off');
		sl.css({'background-color': sl.attr('obg') });
	}
	else {
		sl.attr('obg', sl.css('background-color'));
		sl.attr('enabled', 'on');
		sl.css({'background-color': 'red' });
	}
	studioSaver();
});

function studioSaver() {
	var studio = {};
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');
	$('.knob_control, .channel_volume').each(function(i,v) {

		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		var value = $(v).val();

		if (control == 'pan') {
			value = (value - 0) / (100 - 0) * ( 1 - -1) + -1;
		}

		if (studio[channel] == undefined) {
			studio[channel] = {};
		}
		studio[channel][control] = value;
		if (mixer[channel]) {
			mixer[channel][control] = value;
		}
	});
	$('.armed').each(function(i,v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		var state = $(v).attr('state');
		var text = $(v).text();
		studio[channel][control] = { state: state, text: text };
	});
	var sl = $('#studio_loop').attr('enabled');
	var video_toggle = $('#studio_video_toggle').attr('toggled');
	studio['admin'] = { time: mixer['time'], name: name, uuid: uuid, loop: sl, video_toggle: video_toggle };
	studio = JSON.stringify(studio);
	localStorage.setItem('studio', studio);
}

function studioRetriever() {
	var studio = localStorage.getItem('studio') || "{}";
	studio = JSON.parse(studio);
	$.each(studio, function(i,v) {
		if (!mixer[i]) { mixer[i] = {}; }
		$.each(studio[i], function(n,w) {
			mixer[i][n] = w;
			$.each(mixer[i], function(ir,vr) {
				studio[i]['mixer'] = vr;
			});
			if (n == 'armed') {
				$('[channel="' + i + '"][control="' + n + '"]').attr('state', w.state);
				$('[channel="' + i + '"][control="' + n + '"]').text(w.text);
			}
			else {

				if (n == 'pan') {
					w = (w - -1) / (1 - -1) * ( 100 - 0) + 0;
				}
				$('[channel="' + i + '"][control="' + n + '"]').val(w).trigger('change');
			}
		});
	});
	mixer['time']['loop'] = studio['admin']['loop'];
	return studio;
}

var studio_jw_deg =  0;
var studio_last = 'out';
$(document).on('touchmove mousemove', '#studio_jog_wheel', function(e) {
	e.preventDefault();			e.preventDefault();
	var j = $(this);
	var jc = j.closest('.jog_wheel_frame').find('.jog_wheel_centre');
	if (e.which === 1 || e.originalEvent.type == 'touchmove') {
		var x = e.originalEvent.clientX;
		var y = e.originalEvent.clientY;
		if (e.originalEvent.targetTouches) {
			x = e.originalEvent.targetTouches[0].clientX;
			y = e.originalEvent.targetTouches[0].clientY;
		}
		var middle_x = numeral(jc.offset().left + (jc.width() / 2)).value();
		var middle_y = numeral(jc.offset().top + (jc.height() / 2)).value();
		var deltaX = middle_x - x;
		var deltaY = middle_y - y;
		var rad = Math.atan2(deltaY, deltaX); 
		var deg = rad * (180 / Math.PI) - 90;
		var diff = 0;
		if (studio_last == 'in') {
			diff = (deg - studio_jw_deg);
		}
		studio_jw_deg = (studio_jw_deg + diff);
		j.css({'rotate': studio_jw_deg + 'deg' });
		studio_last = 'in';
		mixer['time']['position'] = mixer['time']['position'] + diff / 10;
		studioTime();
	}
});
$(document).on('mouseout touchend mouseup', '#studio_jog_wheel', function() {
	studio_last = 'out';
});

$(document).on('mousewheel', '#studio_jog_wheel', function(e) {
	var j = $(this);
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	var diff = numeral(mvmt / 30).value() ;
	studio_jw_deg = (studio_jw_deg + diff);
	j.css({'rotate': studio_jw_deg + 'deg' });
	mixer['time']['position'] = mixer['time']['position'] + diff / 10;
	studioTime();
});

$(document).on('click', '#studio_video_toggle', function() {
	var toggle = $(this).attr('toggled');

	if (toggle == 'on') {
		toggle = 'off';
	}
	else {
		toggle = 'on';
	}
	$(this).attr('toggled', toggle);
	studioSaver();
});

$(document).on('click', '#studio_record', function() {
	if (mixer['time']['status'] != 'record' && mixer['time']['status'] != 'play') {
		studioRecord();
		mixer['time']['status'] = 'record';
	}
});

$(document).on('click', '.armed',function() {
	var armed = $(this);
	var state = armed.attr('state');
	if (state == 'off') {
		armed.attr('state', 'rec');
		armed.text('R');
	}
	else if (state == 'rec') {
		armed.attr('state', 'play');
		armed.text('P');
	}
	else if (state == 'play') {
		armed.attr('state', 'loop');
		armed.text('L');
	}
	else {
		armed.attr('state', 'off');
		armed.text('O');
	}
	studioSaver();
});

async function studioRecord() {
	var studio = studioRetriever();
	mixer['time']['status'] = 'record';
	var constraints = { 'audio': true };
	if (mixer['admin']['video_toggle'] == 'on') {
		constraints['video'] = true;
	}
	var inputStream = await navigator.mediaDevices.getUserMedia(constraints);

	studioTime('start');
	$.each(studio, function(i,v) {
		if (v.armed) {
			if (v.armed.state == 'rec') {
				if (!mixer[i]['media']) { mixer[i]['media'] = {}; }
				var rec = { startTime: mixer['time']['position'] };

				mixer[i]['media']['in'] = inputStream;
				rec['track'] = new MediaRecorder(mixer[i]['media']['in']);


				if (!mixer[i]['media']['rec']) {
					mixer[i]['media']['rec'] = [];
					mixer[i]['media']['rec'][0] = rec;
				}
				else {
					mixer[i]['media']['rec'][mixer[i]['media']['rec'].length] = rec;
				}
				var count = mixer[i]['media']['rec'].length - 1;
				if (!mixer[i]['media']['out']) { mixer[i]['media']['out'] = []; }
				if (!mixer[i]['media']['out'][count]) { mixer[i]['media']['out'][count] = {}; }
				if (!mixer[i]['media']['actx']) { mixer[i]['media']['actx'] = []; }
				if (!mixer[i]['media']['actx'][count]) { mixer[i]['media']['actx'][count] = {}; }
				if (!mixer[i]['media']['actx'][count]['ctx']) { mixer[i]['media']['actx'][count]['ctx'] = { 'state': 'uninitialized', pcmData: [] }; }
				mixer[i]['media']['actx'][count]['ctx'] = new AudioContext();
				var c = mixer[i]['media']['actx'][count]['ctx'];
				mixer[i]['media']['actx'][count]['track'] = c.createMediaStreamSource(inputStream);
		//		mixer[i]['media']['actx'][ir]['track'].connect(c.destination);
				mixer[i]['media']['actx'][count]['panner'] = new StereoPannerNode(c, { pan: mixer[i]['pan']});
				mixer[i]['media']['actx'][count]['analyser'] = c.createAnalyser();
				mixer[i]['media']['actx'][count]['track'].connect(mixer[i]['media']['actx'][count]['analyser']);//.connect(mixer[i]['media']['actx'][count]['panner']);
				const pcmData = new Float32Array(mixer[i]['media']['actx'][count]['analyser'].fftSize);
				//	console.log(pcmData);
				mixer[i]['media']['actx'][count]['pcmData'] = pcmData;

				var trackContainer = $('#studio_track_container');
				trackContainer.append('<video class="studio_video" startTime="' + mixer['time']['position'] + '" channel="' + i + '" id="studio_channel_' + i + '_' + count + '"></video>');
				if (mixer['admin']['video_toggle'] == 'on') {
					var v = document.getElementById('studio_video_monitor');
					v.srcObject = rec['track'].stream;
					v.muted = true;
				}

				mixer[i]['media']['out'][count]['track'] = document.getElementById('studio_channel_' + i + '_' + count);
				mixer[i]['media']['out'][count]['startTime'] = mixer['time']['position'];
				rec['track'].audioBitsPerSecond = 192000
				mixer[i]['media']['rec'][count]['track'].ondataavailable = (event) => { 
					var data = event.data;
					if (!mixer[i]['media']['aud']) { mixer[i]['media']['aud'] = []; }
					if (!mixer[i]['media']['aud'][count]) { mixer[i]['media']['aud'][count] = {}; }
					mixer[i]['media']['out'][count]['data'] = data;
					mixer[i]['media']['out'][count]['encoding'] = data['type'];
					mixer[i]['media']['out'][count]['size'] = data['size'];
					mixer[i]['media']['aud'][count]['track'] = new Audio;
					var audioUrl = URL.createObjectURL(data);
					mixer[i]['media']['out'][count]['track'].src = audioUrl;
					mixer[i]['media']['out'][count]['status'] = 'stop';
				};
				mixer[i]['media']['rec'][count]['track'].start();
			}
		}
	});
	studioPlay('rec');
}

$(document).on('click', '#studio_play', function() {
	if (mixer['time']['status'] != 'record' && mixer['time']['status'] != 'play') {
		studioPlay('play');
		mixer['time']['status'] = 'play';
	}
});

async function studioPlay(mode) {
	var playTracks = [];

	if (mode != 'rec') {
		studioTime('start');
	}
	var studio = studioRetriever();
	$.each(studio, function(i,v) {
		if (v.armed) {
			if ((v.armed.state == 'rec' && mode == 'play') || v.armed.state == 'play') {

				if (mixer[i]['media']) { 
					if (mixer[i]['media']['out']) {
						$.each(mixer[i]['media']['out'],function(ir,vr) {
							vr['track'].currentTime = mixer['time']['position'];
							//vr['track'].play();
							vr['track'].volume = (studio[i]['volume'] / 100);
						});
					}
				}
			}
		}
	});
}

$(document).on('click', '#studio_stop', function() {
	studioStop();
	mixer['time']['status'] = 'stop';
});

async function studioStop() {
	var playTracks = [];

	if (mixer['time']['status'] == 'stop') {
		mixer['time']['position'] = 0;
	}

	studioTime('stop');

	var studio = studioRetriever();
	$.each(studio, function(i,v) {

		if (v.armed) {
			if (mixer[i]['media']) {
				if (mixer[i]['media']['rec'] && mixer['time']['status'] == 'record') {
					$.each(mixer[i]['media']['rec'], function(ir,vr) {
						console.log(vr['track']);
						if (vr['track'].state == 'recording') {
							vr['track'].stop();
							mixer[i]['media']['in'].getTracks().forEach(function(track) { console.log(track); track.stop(); });
						}
						vr['status'] = 'stop';
						mixer[i]['media']['out'][ir]['status'] = 'stop';
						mixer[i]['media']['out'][ir]['duration'] = mixer['time']['position'] - mixer[i]['media']['out'][ir]['startTime'] ;
					});

				}
				if (mixer[i]['media']['out']) {
					$.each(mixer[i]['media']['out'], function(ir,vr) {

						vr['status'] = 'stop';
						vr['track'].pause();
					//	vr['track'].play();
						if (mixer[i]['media']['actx'][ir]) {
						//	mixer[i]['media']['actx'][ir] = null;
						}
					});
				}

			}
		}
	});
	mixer['time']['status'] = 'stop';
}

function studioTime(command) {

	if (command == 'start') {
		mixer['time']['startTime'] = Date.now();
		mixer['time']['startTime'] = (mixer['time']['startTime'] - (mixer['time']['position'] * 1000));
		var svm = document.getElementById('studio_video_monitor');
		mixer['time']['interval'] = setInterval(function() {
			var now = Date.now();
			mixer['time']['position'] = ((now - mixer['time']['startTime']) / 1000);
			
			$('#studio_time_display').html(numeral(mixer['time']['position']).format('00.000'));
			if (mixer['time']['status'] == 'record' && mixer['time']['position'] > mixer['time']['duration']) {
				mixer['time']['duration'] = mixer['time']['position'];
				$('#studio_time_duration').html(numeral(mixer['time']['duration']).format('00.000'));
			}
			else if (mixer['time']['status'] == 'play' && mixer['time']['position'] > mixer['time']['duration']) {
				studioStop();
				clearInterval(mixer['time']['interval']);
				console.log(mixer['time']['loop']);
				if (mixer['time']['loop'] == 'on') {
					mixer['time']['position'] = 0;
					studioPlay();
					mixer['time']['status'] = 'play';
				}
				else {
					clearInterval(mixer['time']['interval']);
					mixer['time']['status'] = 'stop';
					studioStop();
					return;
				}
			}
			$.each(mixer, function(i,v) {

				if (mixer[i]['media'] && mixer[i]['armed']['state'] != 'off') {
					var canvas = document.getElementById('track_view_' + i);
					var metreCanvas = document.getElementById('channel_volume_metre_' + i);
					var mctx = metreCanvas.getContext('2d');
					var ctx = canvas.getContext('2d');
					$.each(mixer[i]['media']['out'], function(ir,vr) {

						if (mixer[i]['media']['in'].active == true) {
							let sum = 0.0;
							if (eval(typeof mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData == 'function')) {
								mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData(mixer[i]['media']['actx'][ir]['pcmData']);
								for (const amplitude of mixer[i]['media']['actx'][ir]['pcmData']) {
									sum += amplitude * amplitude;
								}
								var metreValue = Math.sqrt(sum / mixer[i]['media']['actx'][ir]['pcmData'].length) * 3;
							//	console.log(metreValue + ' '  + ((metreValue * metreCanvas.height) - metreCanvas.height));
								mctx.beginPath();
							//	if (mixer[i]['media']['actx'][ir]['lastClear'] + 500 <= now) {
									mctx.clearRect(0,0,metreCanvas.width,metreCanvas.height);
									mctx.fill();
									mixer[i]['media']['actx'][ir]['lastClear'] = now;
							//	}
								mctx.fillStyle = "green";
								mctx.fillRect(0, Math.abs((metreValue * metreCanvas.height) - metreCanvas.height), metreCanvas.width,  metreCanvas.height);
								mctx.fill();
								if (mixer[i]['media']['actx'][ir]['panner']['pan']) {
									mixer[i]['media']['actx'][ir]['panner'].pan.value = mixer[i]['pan'];
								}
							}

						}
						else if (vr['startTime'] <= mixer['time']['position'] && (vr['status'] != 'record' && vr['status'] != 'play')) {
							

							if (!mixer[i]['media']['actx'] && vr['status']) { mixer[i]['media']['actx'] = []; console.log('new track'); }
							if (!mixer[i]['media']['actx'][ir]) { mixer[i]['media']['actx'][ir] = {}; console.log('new take'); }
							if (!mixer[i]['media']['actx'][ir]['ctx']) { mixer[i]['media']['actx'][ir]['ctx'] = { state: 'uninitialized' }; console.log('new take'); }
							if (mixer[i]['media']['actx'][ir]['ctx'].state == 'uninitialized') { console.log('new state');
								vr['init'] = true;
								mixer[i]['media']['actx'][ir]['ctx'] = new AudioContext();
								var c = mixer[i]['media']['actx'][ir]['ctx'];
								mixer[i]['media']['actx'][ir]['track'] = c.createMediaElementSource(vr['track']);
								mixer[i]['media']['actx'][ir]['track'].connect(c.destination);
								mixer[i]['media']['actx'][ir]['panner'] = new StereoPannerNode(c, { pan: mixer[i]['pan']});
								mixer[i]['media']['actx'][ir]['analyser'] = c.createAnalyser();
							//	console.log(mixer[i]['media']['actx'][ir]['analyser']);
								const pcmData = new Float32Array(mixer[i]['media']['actx'][ir]['analyser'].fftSize);
							//	console.log(pcmData);
								mixer[i]['media']['actx'][ir]['pcmData'] = pcmData;
								mixer[i]['media']['actx'][ir]['track'].connect(mixer[i]['media']['actx'][ir]['panner']).connect(mixer[i]['media']['actx'][ir]['analyser']).connect(c.destination);
								var now = Date.now();
								mixer['time']['position'] = ((now - mixer['time']['startTime']) / 1000);
								console.log('added the panning and whatnot');
								mixer[i]['media']['actx'][ir]['lastClear'] = now;
							}

							vr['track'].currentTime = mixer['time']['position'] - vr['startTime'];
							vr['track'].play();
							vr['status'] = 'play';
							svm.src = vr['track'].src;
							svm.play();
						}
					//	else { vr['init'] = false; }

						if (mixer[i]['media']['actx'][ir] && vr['status'] != 'record') {
							if (vr['init'] == true) {
								//console.log(vr['track']);
								if (vr['track']) {
									vr['track'].volume = (mixer[i]['volume'] / 100);
									
									if (mixer[i]['media']['actx'][ir]['panner']['pan']) {
										mixer[i]['media']['actx'][ir]['panner'].pan.value = mixer[i]['pan'];
									}
									let sum = 0.0;
									if (typeof mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData == 'function') {
										mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData(mixer[i]['media']['actx'][ir]['pcmData']);
										for (const amplitude of mixer[i]['media']['actx'][ir]['pcmData']) {
											sum += amplitude * amplitude;
										}
										var metreValue = Math.sqrt(sum / mixer[i]['media']['actx'][ir]['pcmData'].length) * 3;
									//	console.log(metreValue + ' '  + ((metreValue * metreCanvas.height) - metreCanvas.height));
										mctx.beginPath();
									//	if (mixer[i]['media']['actx'][ir]['lastClear'] + 500 <= now) {
											mctx.clearRect(0,0,metreCanvas.width,metreCanvas.height);
											mctx.fill();
											mixer[i]['media']['actx'][ir]['lastClear'] = now;
									//	}
										mctx.fillStyle = "green";
										mctx.fillRect(0, Math.abs((metreValue * metreCanvas.height) - metreCanvas.height), metreCanvas.width,  metreCanvas.height);
										mctx.fill();
									}
								}
						
							}


						}



						ctx.beginPath();

						ctx.fillStyle = 'red';
						ctx.fillRect((vr['startTime'] / mixer['time']['duration'] * canvas.width), 0, ((vr['duration'] / mixer['time']['duration'] * canvas.width )), canvas.height);
						ctx.lineWidth = 10;
						var positionLine = (mixer['time']['position'] / mixer['time']['duration'] * canvas.width);
						ctx.moveTo(positionLine, 0);
						ctx.lineTo(positionLine, canvas.height);
						ctx.strokeStyle = 'black';
						ctx.stroke();
						ctx.fill();
					});

					
				}

			});
		},10);

	}
	else if (command == 'stop') {

		clearInterval(mixer['time']['interval']);
		$('#studio_time_display').html(numeral(mixer['time']['position']).format('00.000'));
	}
	else {
		$('#studio_time_display').html(numeral(mixer['time']['position']).format('00.000'));
	}
	if (!mixer['time']['status']) { mixer['time']['status'] = 'stop'; }
	var button = $('#studio_' + mixer['time']['status'] );

	$.each(mixer['buttons'], function(i,v) {
		clearInterval(v['interval']);
		$('#studio_' + i).css({'background-color': v.obg });
	});
	mixer['buttons'][mixer['time']['status']]['interval'] = setInterval(function() {
		button.css({'background-color': mixer['buttons'][mixer['time']['status']]['bg'] });
		var obg = mixer['buttons'][mixer['time']['status']]['obg'];

		setTimeout(function() {
			button.css({'background-color': obg });

		},500);
	},1000);
}

$(document).on('click', '#studio_metronome', function() {
	var met = $(this);
	if (met.attr('armed') == 'yes') {
		met.attr('armed','no');
		met.css({'background-color': met.attr('obg')});
	}
	else {
		met.attr('armed', 'yes');
		met.attr('obg', met.css('background-color'));
		met.css({'background-color': 'red'});
	}
});


$(document).on('click', '#studio_save', function() {
	studioSave();
});


function studioSave() {
var app = 'studio';
	var now = Date.now();
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');
	if (name) {

		var formData = new FormData();
		var studio = studioRetriever();
		formData.append('app', name);
		formData.append('name', name);
		formData.append('duration', mixer['time']['duration']);
		formData.append('timestamp', now);
		formData.append('type', 'studio');
		formData.append('uuid', uuid );

		$.each(mixer, function(i,v) {

			if (mixer[i]['media']) {
				$.each(mixer[i]['media']['out'], function(ir,vr) {
					var filename = app + '_' + now + '_' + i + '_' + ir + '.webm';

					if (vr.data && vr.data.size && vr.data.type) {
						formData.append('blob', vr.data, filename);
					}

				});
			}
		});
		var jStudio = JSON.stringify(studio);
		formData.append('studio', jStudio);
		$.ajax({
			url: '/manager/studio/save',
			type: 'POST',
			data: formData,
			success: function (response) {
				$('#studio').attr('uuid', response.uuid);
				$('#studio').attr('name', response.app);
				var studio = JSON.stringify(response.studio);
				localStorage.setItem('studio', studio);
				continent_record({'uuid':response['uuid'], 'app':response['app'],'timestamp':response['timestamp']});
				studioRetriever();
			},
			cache: false,
			contentType: false,
			processData: false
		});
	}
	else {
		$('#studio_name').attr('type','text').focus();
	}
}

$(document).on('click', '#song_delete', function() {
	var uuid = $('#studio').attr('uuid');
	var app = $('#studio').attr('name');
	var a = $(this);

	if (a.armed == 'yes') {
		$.ajax({
			url: '/manager/studio/delete',
			type: 'POST',
			data: { uuid: uuid, app: app },
			success: function(response) {
				
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '#studio_song_select', function() {
	var uuid = $(this).val();
	if (uuid != 'none') {
		studioLoad(uuid);
	}
});
function studioLoad(uuid) {
	var buttons = mixer['buttons'];
	studioStop();
	$.ajax({ 
		url: '/manager/studio/load',
		type: 'GET',
		data: { uuid: uuid },
		success: function(response) {
			console.log(response);
			$('#studio_song_select').val(response['uuid']);
			mixer['time'] = response.studio['admin']['time'];
			console.log(response.studio);
			console.log(mixer['time']['loop']);
			mixer['time']['status'] = 'stop';
			$('#studio_video_toggle').attr('toggled', mixer['admin']['video_toggle']);
			if (mixer['time']['loop'] == 'on') {
				$('#studio_loop').attr('enabled','on').attr('obg', 'rgb(211, 211, 211)').css({'background-color':'red'});
			}
			else {
				$('#studio_loop').attr('enabled', 'off').css({'background-color':'rgb(211, 211, 211)'});
			}
			$('#studio').attr('name', response['app']);
			$('#studio').attr('uuid', response['uuid']);
			$('#studio_time_display').html(numeral(mixer['time']['position']).format('00.000'));
			$.each(response.studio, function(i,v) {
				if (v['mixer']) {
					$('#studio_channel_container_' + i ).html('');
					if (!i.match('[a-zA-Z]')) {
						mixer[i]['media'] = v['mixer'];
					}
					$.each(v['mixer']['out'], function(ir, vr) {
						var trackContainer = $('#studio_track_container');

						trackContainer.append('<video class="studio_video" startTime="' + vr['startTime'] + '" type="' + vr['encoding'] + '" channel="' + i + '" id="studio_channel_' + i + '_' + ir + '"></video>');
						$('#studio_channel_' + i + '_' + ir).attr('src', vr['src']);
						if (!mixer[i]['media']['aud']) { mixer[i]['media']['aud'] = []; }
						if (!mixer[i]['media']['aud'][ir]) { mixer[i]['media']['aud'][ir] = {}; }
						mixer[i]['media']['actx'][ir]['ctx'] = { 'state': 'uninitialized', pcmData: [] } ; 
						mixer[i]['media']['aud'][ir]['track'] = new Audio;

						mixer[i]['media']['out'][ir]['track'] = document.getElementById('studio_channel_' + i + '_' + ir);
					});
				}
			});
			var studio = JSON.stringify(response.studio);
			localStorage.setItem('studio', studio);
			studioRetriever();
			mixer['buttons'] = buttons;
		}
	});


}

$(document).on('change', '#studio_name', function() {
	$('#studio').attr('name', $(this).val());
	$('#studio_name').hide();
});

$(document).on('blur', '#studio_name', function() {
	$('#studio_name').hide();
});

$(document).on('click', '#studio_mark', function() {
	var seen = undefined;
	for (n = 0; n <= mixer['time']['marks'].length; n++) {
		if (mixer['time']['position'] == mixer['time']['marks'][n]) {
			seen = n;
		}
	}
	if (seen == undefined) {
		mixer['time']['marks'].push(mixer['time']['position']);
		mixer['time']['marks'] = mixer['time']['marks'].sort(function(a,b) {
			return a - b;
		});
	}
	else {
		mixer['time']['marks'].splice(seen,1);
		console.log(seen);
		console.log(mixer['time']['marks']);
	}
});

$(document).on('click', '#studio_prev, #studio_next', function() {
	console.log('moving');
	var potentialPosition = 0;
	if ($(this).hasClass('prev')) {
		console.log('previous');
		for (var n = 0; n <= mixer['time']['marks'].length; n++) {
			if (mixer['time']['position'] > mixer['time']['marks'][n]) {
				potentialPosition = mixer['time']['marks'][n];
			}
		}
	}
	else {
		potentialPosition = mixer['time']['duration'];
		for (var n = mixer['time']['marks'].length; n >= 0; n--) {
			if (mixer['time']['position'] < mixer['time']['marks'][n]) {
				potentialPosition = mixer['time']['marks'][n];
			}
		}
	}
	mixer['time']['position'] = potentialPosition;
	$('#studio_time_display').html(numeral(mixer['time']['position']).format('00.000'));
});
