
var budgetConfigTimeout;

$(document).on('click', '#budget, #budget_refresh', function() {
	budgetInit()
});

function budgetInit(data) {
	if (typeof data == 'undefined') { data = {}; }
	var new_settings = data['new_settings'] || {};
	var jnew_settings = JSON.stringify(new_settings);
	var adata = deloreanBringer();
	adata['new_settings'] = jnew_settings;
	var settingsVisibility = $('#budget_settings').is(':visible');
	$.ajax({
		url: '/manager/budget',
		type: 'GET',
		data: adata,
		success: function(response) {
			windowMaker(response);
			if (settingsVisibility) {
				$('#budget_settings').show();
			}
		}
	});
}

$(document).on('click', '#budget_settings_toggle', function() {
	var bs = $('#budget_settings');
	var visible = bs.is(':visible');
	if ( visible ) {
		bs.hide();
	}
	else {
		bs.show();
	}
});

$(document).on('change', '.budget_config', function() {
	clearTimeout(budgetConfigTimeout);
	var setting = $(this).val();
	var wait_time = 1000;
	var config = $(this).attr('config');
	if ($(this).attr('multiple') == "multiple") {
		setting = JSON.stringify(setting);
	}
	var delorean = deloreanBringer();
	delorean[config] = setting;
	console.log(delorean);
	var new_settings = {};
	$('#budget_display').val('');
	if ($(this).attr('id') != 'budget_display') {
		var display = $('#budget_display').attr('budget_display');
		display = display + '_display';
		console.log(display);
		new_settings[display] = '';
	}

	new_settings[config] = setting;
	if (config == 'scope') {
		new_settings['start_time'] = '';
		new_settings['end_time'] = '';
		wait_time += 200;
	}
	console.log(new_settings);
	budgetInit({ 'new_settings': new_settings });

});

$(document).on('change', '.budget_time', function() {
	var setting = $(this).attr('setting');


	var value = $('.budget_time[setting="' + setting + '"]').val();
//	settingSetter({ 'app': 'budget', 'setting': setting, 'value': value });
	var new_settings = {};
	new_settings[setting] = value;	
	console.log(new_settings);

	budgetInit({ 'new_settings': new_settings });


});


$(document).on('click', '.budget_row', function() {
	var row = $(this);
	var app = row.attr('app');
	var movement = row.attr('movement');
	var status = row.attr('status');
	var rows = $('.budget_detail_row[movement="' + movement + '"][app="' + app + '"]');
	if (status == 'closed') {
		rows.show();
		row.attr('status','open');
	}
	else {
		rows.hide();
		row.attr('status','closed');
	}
});

$(document).on('click', '.budget_app', function() {
	var dr = $(this).closest('.budget_detail_row');
	var timestamp = dr.attr('timestamp');
	var server_time = dr.attr('server_time');
	var app = $(this).attr('app');
	var filter = dr.attr('filter');
	var sorts = localStorage.getItem('sorts');
	var scope = localStorage.getItem('scope');
	appointmentGrabber(app,timestamp);
	var variables = { app: app, filter: filter, sorts: sorts, timeshift: '0d', time_machine: '', timestamp: timestamp, scope: scope };
	var budgetAppInterval = setInterval(function() {
		var parent = $('.wind[app="' + app + '"]');
		if (parent.length > 0) {
			var container = parent.find('.re_details');
		
			$.ajax({ 
				url: '/manager/appointment_details',
				type: 'GET',
				data: variables,
				success: function(response) {
					clearInterval(budgetAppInterval);
					container.html(response);
					container.show();
					appointment_chron();
				}
			});
		}
	},200);
});


$(document).on('click', '.budget_autocalc', function() {
	var button = $(this);
	var app = button.attr('app');
	var circumstance = $(this).attr('circumstance');
	var timestamp = Date.now();
	button.addClass('active');
	var autoCalcInterval;
	var autoCalcTimeout;
	button.addClass('medium_thumb').removeClass('little_thumb');
	autoCalcInterval = setInterval(function() {
		button.addClass('little_thumb').removeClass('medium_thumb');
		clearTimeout(autoCalcTimeout);
		autoCalcTimeout = setTimeout(function() {
			button.addClass('medium_thumb').removeClass('little_thumb');
		},500);
	}, 1000);

	$.ajax({
		url: '/manager/budget/autocalc',
		type: 'GET',
		data: { timestamp: timestamp, app: app, circumstance: circumstance },
		success: function(response) {
			console.log(response);
			button.addClass('medium_thumb').removeClass('little_thumb');
			clearInterval(autoCalcInterval);

		//	if ($('.wind[app="budget"').is(':visible')) {
				var message = 'These are the autocalcs for ' + response.data.formatted_app + '<br><br>';
				$.each(response, function(i,v) {
					if (i != 'data') {
						message += '<button app="' + response.data.app + '" circumstance="' + response.data.circumstance + '" result="' + v.formatted_result + '" class="budget_autocalc_accept">' + v.formatted_result +'</button><br>';
					}
				});
				message += '<br><button id="alert_cancel">Cancel</button>'
				$('#alert').html(message);
				$('#alert').show();
				$(this).removeClass('active');
		//	}
			if ($('.wind[app="' + app + '"]').is(':visible')) {
				inventoryDetails(app);
			}
		}
	});
});

$(document).on('click', '.budget_autocalc_accept', function() {
	var app = $(this).attr('app');
	var circumstance = $(this).attr('circumstance');
	var result = $(this).attr('result');
	var b = $('.budget_edit_input[app="' + app + '"][circumstance="' + circumstance + '"]');
	b.val(result);
	b.trigger('focusout');
	$('#alert').hide();
	if ($('.wind[app="' + app + '"]').is(':visible')) {
		inventoryDetails(app);
	}
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: result, circumstance: circumstance },
		success: function(response) {
			console.log(response);
		}
	});
});



$(document).on('change, focusout', '.budget_edit_input', function() {
	var input = $(this);
	var app = input.attr('app');
	var value = input.val();
	var circumstance = input.attr('circumstance');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: value, circumstance: circumstance },
		success: function(response) {
			console.log(response);
		}
	});
});

$(document).on('click', '.budget_light', function() {
	var bl = $(this);
	var circumstance = bl.attr('circumstance');
	var app = bl.attr('app');
	budgetLight(app,circumstance);

});

function budgetLight(app,circumstance,status) {
	console.log(app + ' ' + circumstance + ' ' + status);
	var blci = $('.budget_current_information[app="' + app + '"]');
	var wind = blci.closest('.wind');
	var header;
	if ((blci.is(':visible') && status != 'open') && blci.attr('circumstance') == circumstance) {
		blci.hide();
		blci.attr('status', 'closed');
		circumstance = undefined;
		blci.attr('circumstance', undefined);
		header = blci.html();

//		cacheSet({ 'app': app, 'context': 'header' }, { 'timestamp': timestamp, 'header': header });
	}
	else {
		$.ajax({
			url: '/manager/budget/current_information',
			type: 'GET',
			data: { timestamp: timestamp, app: app, circumstance: circumstance },
			success: function(response) {
				blci.html(response).show();
				blci.attr('circumstance', circumstance);
				blci.attr('status', 'open');
				appointment_chron();
				header = blci.html();
//				cacheSet({ 'app': app, 'context': 'header' }, { 'timestamp': timestamp, 'header': header });
			}
		});
	}

	settingSetter({ 'app': app, 'setting': 'ci', 'value': circumstance });

	wind.attr('current_information', circumstance);
}

$(document).on('click', '#budget_display_save', function() {
	var name = $('#budget_display_name').val();
	var type = $('#budget_display_name').attr('display_type');
	console.log(name);
	if (!name) {
		
//		return;
	}

	var data = [ 'start_time', 'end_time' ];
	$('.budget_config').each(function(i,v) {
		data.push($(v).attr('config'));
	});
	console.log(data);
	data = JSON.stringify(data);
	$.ajax({
		url: '/manager/budget/display/save',
		type: 'POST',
		data: { name: name, timestamp: timestamp, data: data, type: type },
		success: function(response) {
			console.log(response);
		}
	});
});

$(document).on('click', '#budget_display_delete', function() {
	var name = $('#budget_display_name').val();
	var display = $('#budget_display_name').attr('display_type');
	$.ajax({
		url: '/manager/budget/display/delete',
		type: 'POST',
		data: { name: name, display: display },
		success: function(response) {
			console.log(response);
		}
	
	});

});









