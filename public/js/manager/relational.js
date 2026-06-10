$(document).on('click', '#relational_toggle', function() {
	twirlRunning = false;
	var url = '/manager/relational';
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			relationalInit(response);
		}, error: function (response) {  }
	});
});


$(document).on('click', '#relational_contents_select', function() {
	var construct = $(this).val();
	console.log(construct);
	$.ajax({
		url: '/manager/relational/select',
		type: 'GET',
		data: { construct: construct, setting: 'construct' },
		success: function(response) {
			console.log(response);
			relationalInit(response);
		}
	});
});

$(document).on('click', '#relational_category_select', function() {
	var construct = $(this).val();
	console.log(construct);
	$.ajax({
		url: '/manager/relational/select',
		type: 'GET',
		data: { construct: construct, setting: 'category' },
		success: function(response) {
			console.log(response);
			relationalInit(response);
		}
	});
});


$(document).on('change', '.relational_adder', function() {
	var construct = $(this).attr('construct');
	var addition = $(this).val();
	var input = selectorMaker(this);
	$.ajax({
		url: '/manager/relational/adder',
		type: 'POST',
		data: { construct: construct, addition: addition },
		success: function(response) {


			relationalInit(response);
			$(input).focus();
		}
	});
});

function relationalInit(response) {
	var scrollCon = $('#relational_contents').scrollTop();
	var scrollCat = $('#relational_categories').scrollTop();
	var openTable = [];
	$('#relational_contents').find('table:visible').each(function(i,v) { console.log(v); openTable.push($(v).attr('uuid')); });

	if (typeof response != 'object') {
		$('#relational').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		windowMaker(response);
	}
	else if (response['contents']) {
		$('#relational_contents').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		$('#relational_contents').replaceWith(response.contents);
	}
	else if (response['bucket']) {
//		$('.bucket[uuid="' + response.bucket_uuid + '"]').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		$('.bucket[uuid="' + response.bucket_uuid + '"]').replaceWith(response['bucket']);
	}
	else if (response['category']) {
		$('.relational_space[construct="' + response.sc.sing + '"]').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		$('.relational_space[construct="' + response.sc.sing + '"]').html(response['category']);
	}
	else if (response.relationalizer.contents) {
		$('#relational').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); } });
		$('#relational').replaceWith(response.relationalizer.contents);
	}

	$('#relational_contents').scrollTop(scrollCon);
	$('#relational_categories').scrollTop(scrollCat);
	$.each(openTable, function(i,v) {
		$('table[uuid="' + v + '"]').show();
	});

	$('#relational').find('.draggable').each(function(i,v) {
		var k = $(this);
		k.draggable({
	//		appendTo: 'body',
	//		containment: 'window',
			scroll: false,
			revert: true,
			helper: 'clone',
			start: function(p) {
				var b = $('#' + p.target.id);
				b.show();
				var z = numeral(b.closest('.wind').css('z-index') + 1000).value();
			//	b.css({'z-index': z});

				console.log(p.target.id + ' ' + z);
			},
			drag: function(p) {
			},
			stop: function(p,b) {
				var b = $('#' + p.target.id);
				b.css({'position': 'relative', 'z-index': 'auto'});
				var mouse = mouse_position();
				var elements = [];//document.elementsFromPoint(mouse.x, mouse.y);
				console.log(b);
				$.each(elements, function(i,v) {
					var bu = $(v);
					if (bu.hasClass('bucket') || bu.hasClass('garbage')) {

					}

				});

			}
		});
	});
	$('#relational').find('.droppable').each(function(i,v) {
		var k = $(v);
		k.droppable({
			drop: function(bu,b) {
				var drag = b.draggable[0];


				b = $(drag);
				bu = k;
				console.log(b);
				console.log(bu);
				var movement = 'add';
				$('.relational_bucket_table[uuid="' + bu.attr('uuid') + '"]').show();
				var timestamp = Date.now();
				var construct = b.attr('construct');
				var uuid = b.attr('uuid');
				var b_uuid = bu.attr('uuid');
				var b_construct = bu.attr('construct');
				if (bu.hasClass('garbage')) { 
					movement = 'delete';
					b_uuid = b.closest('.bucket').attr('uuid');
					b_construct = b.closest('.bucket').attr('construct');
					console.log(b.closest('.bucket'));
					console.log(b_construct + ' ' + b_uuid);
				}
				$.ajax({
					url: '/manager/relational/sorter',
					type: 'POST',
					data: { 
						timestamp: timestamp,
						uuid: uuid,
						construct: construct,
						b_uuid: b_uuid,
						b_construct: b_construct,
						movement: movement
					},
					success: function(response) {
						relationalInit(response);
					}
				});
			}
		});
	});
}

$(document).on('click', '.relational_bucket_header', function() {
	var uuid = $(this).attr('uuid');
	console.log(uuid);
	var table = $('.relational_bucket_table[uuid="' + uuid + '"]');
	if (table.is(':visible')) {
		table.hide();
	}
	else {
		table.show();
	}
});


$(document).on('change keyup', '.relational_search', function(e) {
	var ss = $(this);
	console.log(e);
	var search_tool = $(this).attr('search_tool');
	var search = $(this).val();
	if (e.keyCode == 13 || e.type == 'change') {
		$.ajax({ 
			url: '/manager/relational/search',
			type: 'GET',
			data: { search: search, search_tool: search_tool },
			success: function(response) {
				relationalInit(response);
				ss.focus();
			}
		});
	}

});







