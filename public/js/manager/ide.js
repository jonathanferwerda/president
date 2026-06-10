var ide = {};

var ideSearchTimeout;



$(document).on('click', '#ide_toggle', function() {
	ideFolderSelector();
});

$(document).on('click', '#ide_hamburger', function() {
	var il = $('#ide_list');
	var imw = $('#ide_main_window');
	if (il.is(':visible')) {
		il.hide();
		imw.show();
	}
	else {
		il.show();
		imw.hide();
	}
});

$(document).on('click', '.ide_file', function(e) {
	console.log(e.target);
	if (!$(e.target).hasClass('ide_file_delete')) { 
		console.log('allowed');
		var sel = $(this);
		var file = sel.attr('file');
		var status = sel.attr('status');
		var location = sel.attr('location');
		if (sel.attr('type') == 'folder') {
			if (status == 'closed') {
				console.log('opening');
				$('.ide_file[location="' + sel.attr('file') + '"]').show();
				sel.attr('status','open');
				idecwd = ideocwd + '/' + file;
			}
			else {
				console.log('closing');
				$('.ide_file[location="' + sel.attr('file') + '"]').hide();
				sel.attr('status','closed');
				idecwd = ideocwd;
			}
		}
		else {
			$('.ide_sidebar[status="active"]').attr('status', 'closed');
			$.ajax({
				url: '/manager/ide/file_open',
				type: 'GET',
				data: { location: location, timestamp: timestamp, file: file },
				success: function(response) {
					if (response['open_app']) {
						if (response['files'] && response['open_app'] == 'gallery') {
							imageViewer({ 'files': response['files'] });
						}
					}
					else {
						$('.ide_tab.active').removeClass('active');
						if ($('.ide_tab[file="' + file + '"]').length >= 1) {
							$('.ide_tab[file="' + file + '"]').addClass('active');
						}
						else {
							$('#ide_navbar').append(response['tab']);
						}
						$('#ide_main_window');
						$('#ide_content').val(response.content).trigger('change');
						$('#ide_content').attr('file', response['file']);

						sel.attr('status', 'active');
						ide[response['file']] = response;
						settingSetter({ 'app': 'ide', 'setting': 'active_tab', 'value': file });
						$('#ide_list').hide();
						$('#ide_main_window').show();
					}
				}
			});
		}
	}
});

$(document).on('change', '#ide_folder_selector', function() {
	var folder = $(this).val();
	ideFolderSelector(folder);
});

function ideFolderSelector(folder,search) {
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/ide/folder_selector',
		type: 'POST',
		data: { folder: folder, timestamp: timestamp, search: search },
		success: function(response) {
			windowMaker(response.html);
			ideTabPopulator(response);
		}
	});
}

function ideTabPopulator(response) {
	console.log(response);
	$.each(response.tabs, function(i,v) {
		if (response.settings.active_tab == i) {
			$('.ide_tab[file="' + v.file + '"]').trigger('click');
		}
	});
}

$(document).on('keyup', '#ide_search', function() {
	var search = $(this).val();
	var folder = $('#ide_folder_selector').val();
	var timestamp = Date.now();
	clearInterval(ideSearchTimeout);
	ideSearchTimeout = setTimeout(function() {

		ideFolderSelector(folder,search);
		$('#ide_search').focus();

	},500);
});

$(document).on('click', '.ide_file_delete', function() {

	var b = $(this);
	var armed = b.attr('armed');
	var file = b.attr('file');
	var type = b.attr('type');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/ide/file_delete',
			type: 'POST',
			data: { file: file, type: type },
			success: function(response) {
				if (response.file) {
					$('.ide_close_tab[file="' + file + '"]').trigger('click');
					$('.ide_file[file="' + file + '"]').remove();
				}
			}
		});
	}
	else {
		b.attr('armed', 'yes');
		var bgcolor = b.css('background-color');
		b.css({'background-color': 'red' });
		setTimeout(function() {
			b.css({'background-color': bgcolor });
			b.attr('armed', 'no');			
		},2000);
	}
});


$(document).on('keyup', '#ide_content', function() {
	var t = $(this).val();
	var file = $(this).attr('file');
	ide[file]["content"] = t;
});

$(document).on('click', '#ide_new', function() {
	$('#alert').html('<h1>Gonna make a new file!</h1><h4>Folder: ' + idecwd + '</h4><input id="ide_new_file_namer"><button id="ide_new_file_create" class="hover">Create</button><button id="alert_cancel" class="hover">Cancel</button>').show();
});

$(document).on('click', '#ide_new_file_create', function() {
	var file = $('#ide_new_file_namer').val();
	var filename = idecwd + '/' + file;
	var timestamp = Date.now();
	$.ajax({ 
		url: '/manager/ide/file_create',
		type: 'POST',
		data: { filename: filename, timestamp: timestamp },
		success: function(response) {
			$('#alert').hide();
			ideFolderSelector(idecwd);
			var opener = setInterval(function() {
				var f = $('.ide_file[location="' + idecwd + '"][file="' + filename + '"]');
				if (f.length > 0) {
					$('.ide_file[location="' + idecwd + '"][file="' + filename + '"]').trigger('click');
					clearInterval(opener);
				}
			},500);
		}
	});
});

$(document).on('click', '#ide_save', function() {
	var save = $(this);
	var c = $('#ide_content');
	var f = c.attr('file');
	var t = c.val();
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/ide/save',
		type: 'POST',
		data: { timestamp, timestamp, file: f, content: t },
		success: function(response) {
			var cbg = save.css('background-color');
			if (response.status == 'success') {
				save.css({ 'background-color': 'green' });
			}
			setTimeout(function() {
				save.css({ 'background-color': cbg });
			},500);
		}
	});

});

$(document).on('click', '.ide_tab', function(e) {

	var file = $(this).attr('file');
	if ($(e.target).hasClass('ide_close_tab')) {
		return;
	}
	if (typeof ide[file] != "undefined") {
		$('#ide_content').val(ide[file]["content"])
		$('#ide_content').attr('file', ide[file]['file']);
	}
	else {
		$('.ide_file[file="' + file + '"]').trigger('click');
	}
	$('.ide_tab.active').removeClass('active');
	$(this).addClass('active');
	settingSetter({ 'app': 'ide', 'setting': 'active_tab', 'value': file });
});

$(document).on('click', '.ide_close_tab', function(e) {
	var timestamp = Date.now();
	var b = $(this);
	var t = b.closest('.ide_tab');
	var closing_file = t.attr('file');
	if (t.hasClass('active')) {
		t.removeClass('active');
		var p = t.prev();
		if (!p.hasClass('ide_tab')) {
			p = t.next();
		}
		if (p.length >= 1) {
			p.addClass('active');
			$('#ide_content').val(ide[p.attr('file')]["content"]);
			$('#ide_content').attr('file', ide[p.attr('file')]['file']);
		}
		else {
			$('#ide_content').val('').attr('file', '').trigger('change');
		}
	}
	t.remove();
	delete ide[b.attr('file')];
	$.ajax({
		url: '/manager/ide/file_close',
		type: 'POST',
		data: { timestamp: timestamp, file: closing_file },
		success: function(response) {}
	});
});





