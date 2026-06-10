$(document).on('keyup', '#terminal_console', function(e) {
	var timestamp = Date.now();
	var command = $('#terminal_console').val();
	if (e.keyCode == 13) {
		$('#terminal_view').append('<span style="color:green"><b>' + my_name + ':</b></span> ' + command + '<br>');

		$('#terminal_console').val('');
		$.ajax({
			url: '/manager/terminal',
			type: 'POST',
			data: { timestamp: timestamp, command: command },
			success: function(response) {
				console.log(response);
			}
		});
	}
	else {
		ws['server'].send(JSON.stringify({ 'app': 'server', 'type': 'input', input: command }));
	}
});

$(document).on('click', '.terminal_view_select', function() {
	var selection = $(this).attr('view');
	$('.terminal_view').hide();
	$('.terminal_view_select').removeAttr('selected');
	$('.terminal_view_select[view="' + selection + '"]').attr('selected', true);
	$('.terminal_view[view="' + selection + '"]').show();
	settingSetter({ 'app': 'terminal', 'setting': 'view', 'value': selection });
	setTimeout(function() {
		terminalOpener({'window_maker': 'no'});
	},300);
});

$(document).on('click', '.terminal_clear', function() {
	var view = $('#terminal').find('.terminal_view:visible').attr('view');
	console.log(view);
	settingDeleter({ 'app': 'terminal', 'setting': view });
	$('.terminal_' + view).remove();
});

function terminalOpener(data) {
	var timestamp = Date.now();
	var url = '/manager/terminal';
	if ($('#terminal_toolbox').length > 0) {
		var tid = $('#terminal_toolbox').closest('.wind').attr('id');
		$('#' + tid).show();
		topLevelNow($('#' + tid));
	}
	else {
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: data['window_maker'], timestamp: timestamp },
			success: function(response) {
				if (data['window_maker'] == 'yes') {
					var window_id = windowMaker(response);
				}
				else {
					$('#terminal').replaceWith(response);
				}
				var tv = $('#terminal_input');
				tv.focus();
			}
		});
	}
}