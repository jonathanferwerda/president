var campusProxy = {};
var locationWatchers = {};
var mapData = {};
$(document).on('click', '#travel_toggle', function() {
	travelToggle();
});

function travelToggle() {
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = timestamp; 
	}
	var url = '/manager/travel';
	var travel_scope = localStorage.getItem('travel_scope');
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: ts },
		success: function(response) {
			windowMaker(response);

			travelViewer(ts);
			//continent_record({'app':'travel','timestamp':ts,'purpose':'travel_viewer','scope':travel_scope});
		}, error: function (response) {  }
	});
}


function mapCampus(timestamp,response,campus) {

	var canvas = document.getElementById(campus);
	var win = $('#' + campus).closest('.wind');
	canvas.height = win.width();
	canvas.width = win.width();

	var ctx = canvas.getContext('2d');
	var h = response['here'];
	ctx.arc(canvas.width / 2, canvas.height /2, 7, 0, (Math.PI * 2), true);
	var zoom = numeral($('#travel_distance_range').val()).value();
	var map_file = $('.travel_map_selector').find('option[selected]').attr('file');

	var image = new Image();
	var image_drawn = 0;
	image.onload=function(){

		canvas.width = image.width;
		canvas.height = image.height;
		ctx.drawImage(image,0,0,image.width, image.height);

		image_drawn = 1;
	};
	image.src = map_file;
	var tries = 0;
	var map_loaded = setInterval(function() {
		tries++;
		if (tries > 5) { clearInterval(map_loaded); tries = 0; }
		if (!map_file || ( map_file && image_drawn == 1 ) ) {
			clearInterval(map_loaded);
			var home_x = response['current_map']['home_plate']['x'] * (canvas.width / response['current_map']['home_plate']['width']);
			var home_y = response['current_map']['home_plate']['y'] * (canvas.height / response['current_map']['home_plate']['height'] );
			
			var original_scale = (response['current_map']['scale']['last']['x'] - response['current_map']['scale']['first']['x']);
			var original_width = (response['current_map']['home_plate']['width']);
			var legend = response['current_map']['scale']['legend'];

			var scale_legend = legend / original_scale;
			
			console.log(original_scale + ' ' + original_width + ' ' + scale_legend);
			console.log(response['current_map']);
			var dist = (legend /  original_scale) * (canvas.width / original_width);

			ctx.font = "400 " + ( 28 / zoom ) + "px Arial";

			ctx.arc(home_x, home_y, 10, 0, (Math.PI * 2), true);
			ctx.fillText(response['current_map']['home_plate']['formatted_legend'], home_x + 10, home_y + 10);		
			ctx.stroke();
			ctx.fill();

			ctx.strokeStyle = 'black';
			var count = 0;
			ctx.translate(home_x, home_y);
			$.each(response['near'], function(i,v) {
				var point = response['near'][i];
			//	console.log(point);
				if (point['direction']) {
					var lat = Math.abs((v['latitude'] + 180) / 360);
					var long = Math.abs((v['longitude'] + 180) / 360);
					ctx.fillStyle = point['settings']['colour'];
					lat = (lat * canvas.height);
					long = (long * canvas.width);
					ctx.closePath();
					ctx.beginPath();

					ctx.save('ok');
 					var deg = (point['direction']);//* ((Math.PI / 2) * -1) * (180 / Math.PI) - 90));

					ctx.rotate(deg);

					var new_dist = ((numeral(point['distance']).value() / scale_legend) ) ;
					console.log(v['app'] + ' ' + deg + ' '  + new_dist);
					console.log(point['distance'] + ' ' + new_dist + ' ' + (canvas.height - new_dist) + ' ' + deg);
					//console.log(canvas.height);
					ctx.translate(0, new_dist);

					ctx.rotate(-deg);
					ctx.fillText(v['app'], 0 + 15, new_dist);
					ctx.arc(0, new_dist, 7, 0, (Math.PI * 2), true);

					ctx.stroke();
					ctx.fill();

					ctx.restore('ok');
				}
				count++;
			}); 
			ctx.stroke();
			ctx.fill();
		}
	},200);
	appointment_chron();
}

function travelViewer(timestamp,uuid) {
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = timestamp; 
	}
	var travel_scope = $('#travel_scope').val();
	var time_scope = localStorage.getItem('scope');
	var sel = $('.travel_map_selector').find('option[selected]');
	var map = sel.val();
	$.ajax({
		url: '/manager/travel/viewer',
		type: 'GET',
		data: { map: map, travel_scope: travel_scope, uuid: uuid, time_scope: time_scope, timestamp: ts },
		success: function(response) {

			mapData = response;
			$('#travel_campus').show();
			$('#travel_proxy_view').html(response['html']);
			mapCampus(ts, response, 'travel_campus');
		}
	});
}

$(document).on('click', '#travel_update', function() {
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = timestamp; 
	}

	var travel_scope = localStorage.getItem('travel_scope');
	if ($('#travel_home_plate').attr('status') == 'disabled') {
	//	continent_record({'app':'travel','timestamp':ts,'purpose':'travel_viewer','scope':travel_scope,'navigation':'once'});
	}
	else {
		travelViewer(ts);
	}
});

$(document).on('change', '#travel_scope', function() {
	var scope = $(this).val();
	localStorage.setItem('travel_scope', scope);
	settingSetter({ 'app': 'travel', 'setting': 'travel_scope' });
});

$(document).on('click', '#travel_home_plate', function() {
	var t = $(this);
	var status = 'enabled';
	if (t.attr('status') == 'enabled') {
		status = 'disabled';
	}
	else {
		status = 'enabled';
	}
	t.attr('status',status);
	settingSetter({ 'app': 'travel', 'setting': 'home_plate_enabled', 'value': t.attr('status') });
});


function continent_cancel(app) {
	if (eval(navigator.geolocation) && locationWatchers[app]) {
		navigator.geolocation.clearWatch(locationWatchers[app]['watch']);
//		locationWatchers[app]['watch'] = null;
	}
}

function continent_record(setter) {

	var app = setter['app'] || 'me';
	var timestamp = setter['timestamp'];
	var purpose = setter['purpose'];
	var scope = setter['scope'];
	var device = setter['device'];
	timestamp = timestamp || Date.now();
	var hostname = $(location)[0]['hostname'];
	var pathname = $(location)[0]['pathname'];
	var protocol = $(location)[0]['protocol'];
	var uuid = setter['uuid'];
	var navigation = setter['navigation'];
	if (!navigation) {
	//	navigation = $('.appointment[app="' + app + '"]').attr('navigation');
	}
	var now = Date.now();
	if (!locationWatchers[app]) {
		locationWatchers[app] = { watch: undefined, timer: (now - numeral(navigation).value()) };
	}
	else {
		navigator.geolocation.clearWatch(locationWatchers[app]['watch'])
	}
	var returner;
	var gotLocation = 0;
	
	if (navigator.geolocation) { 
		if (navigation == 'once' || navigation == undefined || navigation == 0) {
			navigator.geolocation.getCurrentPosition((position) => {
				gotLocation = 1;
				var data = position.coords;
				$.ajax({
					url: '/manager/continent/record',
					type: 'POST',
					data: { 
						latitude: data.latitude,
						longitude: data.longitude,
						altitude: data.altitude,
						speed: data.speed,
						accuracy: data.accuracy,
						timestamp: timestamp,
						user_agent: navigator.userAgent,
						hostname: hostname,
						pathname: pathname,
						protocol: protocol,
						purpose: purpose,
						scope: scope,
						app: app,
						device: device,
						uuid: uuid,
						navigation: setter['navigation']
					},
					success: function(response) {
						return response;
					},
				});

			}, (error) => {
				$.ajax({
					url: '/manager/continent/record_anyway',
					type: 'POST',
					data: { app: app, uuid:uuid, scope:scope, purpose:purpose, timestamp: timestamp, device: device },
					success: function(response) {

					}
				}); 
			}, { 
				maximumAge:1_000, enableHighAccuracy: true 
			});
		}
		else {

			locationWatchers[app]['watch'] = navigator.geolocation.watchPosition((position) => {
				gotLocation = 1;
				var data = position.coords;

				var now = Date.now();
				if (now > locationWatchers[app]['timer']) {
					locationWatchers[app]['timer'] = (now + numeral(navigation).value());

					$.ajax({
						url: '/manager/continent/record',
						type: 'POST',
						data: { 
							latitude: data.latitude,
							longitude: data.longitude,
							altitude: data.altitude,
							speed: data.speed,
							accuracy: data.accuracy,
							timestamp: timestamp,
							user_agent: navigator.userAgent,
							hostname: hostname,
							pathname: pathname,
							protocol: protocol,
							purpose: purpose,
							scope: scope,
							app: app,
							device: device,
							uuid: uuid,
							navigation: setter['navigation']
						},
						success: function(response) {

							return response;
						},
					});
				}

			}, (error) => {
				$.ajax({
					url: '/manager/continent/record_anyway',
					type: 'POST',
					data: { app: app, scope:scope, uuid:uuid, purpose:purpose, timestamp: timestamp, device: device },
					success: function(response) {

					}
				});
			}, { 
				maximumAge:1_000, enableHighAccuracy: true 
			});
		}
	} 
}

$(document).on('click', '.delete_location', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var server_time = a.attr('server_time');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/continent/delete',
			type: 'POST',
			data: { uuid: uuid, server_time: server_time },
			success:function(response) {

				$('.appointment_distance_container[uuid="' + response.uuid + '"]').remove();
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

$(document).on('change', '.travel_map_selector', function() {
	var uuid = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'current_map', 'value': uuid });

	var s = $('.travel_map_selector').find('option[selected]').removeAttr('selected');

	$('.travel_map_selector').find('option[value="' + uuid + '"]').attr('selected', 'yes');
	
	setTimeout(function() {
		travelViewer(Date.now());
	},200);
});


$(document).on('mousemove touchmove click', '#travel_campus', function(m) {

	if (m.which === 1 || m.originalEvent.type == 'touchmove') {

		var x = m.originalEvent.clientX;
		var y = m.originalEvent.clientY;
		if (m.originalEvent.targetTouches) {
			x = m.originalEvent.targetTouches[0].clientX;
			y = m.originalEvent.targetTouches[0].clientY;
		}
		x = numeral(x - w.offset().left).value();
		y = numeral(y - w.offset().top).value();



	}
});

$(document).on('click', '.delete_travel_map', function() {
	var a = $(this);
	var sel = $('.travel_map_selector').find('option[selected]');
	var uuid = sel.attr('value');
	var app_uuid = sel.attr('app_uuid');
	var app = sel.attr('app');
	if (a.attr('armed') == 'yes') {
		var obg = a.attr('obg');
		a.css({'background-color': obg });

		$.ajax({
			url: '/manager/travel/delete_map',
			type: 'POST',
			data: { file_uuid: uuid, app_uuid: app_uuid, app: app },
			success: function(response) {
				travelToggle();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change mousewheel', '#travel_distance_range', function() {
	var value = $(this).val();

	$('#travel_campus').css({ 'zoom': value });
	settingSetter({ 'app': 'travel', 'setting': 'campus_zoom', 'value': value });
	mapCampus(timestamp, mapData, 'travel_campus');
});







