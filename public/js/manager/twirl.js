var twirlRunning = false;
function twirlGame() {
	var twirl_dimensions = { 'height': 20, 'width': 10 };
	var canvas = document.getElementById('twirl');
	if (!canvas || !$('#twirl').is(':visible') || twirlRunning == true) {
		return;
	}
	twirlRunning = true;
	var tPieces = [];
	var dropper;
	var win = $('#twirl').closest('.wind');
	var tn = win.find('.top_navbar');
	canvas.height = win.height();
	canvas.width = win.width();
	var twirlctx = canvas.getContext('2d');

	twirlctx.beginPath;
	twirlctx.font = "1 26px arial";


	var twirlPieces = [
		{ 
			'name': 'straight', 
			'colour': 'red', 
			'offset': 3, 
			'piece': [ 
				[ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 3, 0 ] 
			],
			'rotations': [
				[ [ 0, 0 ], [ 0, 0 ], [ 0, 0 ], [ 0, 0 ] ],
				[ [ 1, -1 ], [ 0, 0 ], [ -1, -2 ], [ -2, -3 ] ]

			]
		},
		{ 
			'name': 'cube', 
			'colour': 'blue', 
			'offset': 4, 
			'piece': [ 
				[ 0, 0 ], [ 1, 0 ], [ 0, 1 ], [ 1, 1 ]
			],
			'rotations': [
				[ [ 0, 0 ], [ 0, 0 ], [ 0, 0 ], [ 0, 0 ] ],
			]
		},
		{ 
			'name': 'left_curl', 
			'colour': 'green', 
			'offset': 3, 
			'piece': [ 
				[ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 0, 1 ]
			],
			'rotations': [
				[ [ 0, 0 ], [ 0, 0 ], [ 0, 0 ], [ 0, 0 ] ],
				[ [ 0, -1 ], [ 0, -1 ], [ -1, 0 ], [ 1, 0 ] ],
				[ [ 0, 1 ], [ 0, 1 ], [ 0, 0 ], [ 2, 0 ] ],
				[ [ 1, 1 ], [ 1, 1 ], [ -1, -1 ], [ 1, -1 ] ],
			]
		},
		{ 
			'name': 'right_curl', 
			'colour': 'yellow', 
			'offset': 3, 
			'piece': [ 
				[ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 2, 1 ],
			],
			'rotations': [
				[ [ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 2, 1 ] ],
				[ [ 2, -1 ], [ 2, 0 ], [ 2, 1 ], [ 1, 1 ] ],
				[ [ 1, 0 ], [ 2, 1 ], [ 3, 1 ], [ 1, 1 ] ],
				[ [ 1, -1 ], [ 1, 0 ], [ 1, 1 ], [ 2, -1 ] ]
			]
		},
		{ 
			'name': 'crown', 
			'colour': 'orange', 
			'offset': 3, 
			'piece': [ 
				[ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 1, 1 ]
			],
			'rotations': [
				[ [ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 1, 1 ] ],
				[ [ 1, -1 ], [ 0, 0 ], [ 1, 0 ], [ 1, 1 ] ],
				[ [ 1, -1 ], [ 2, 0 ], [ 1, 0 ], [ 0, 0 ] ],
				[ [ 1, -1 ], [ 2, 0 ], [ 1, 0 ], [ 1, 1 ] ],
			]
		},
		{ 
			'name': 'lstep', 
			'colour': 'lightgreen', 
			'offset': 3, 
			'piece': [ 
				[ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 2, 1 ]
			],
			'rotations': [
				[ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 2, 1 ] ],
				[ [ 1, -1 ], [ 0, 0 ], [ 1, 0 ], [ 0, 1 ] ],	
			]
		},
		{ 
			'name': 'rstep', 
			'colour': 'lightblue', 
			'offset': 3, 
			'piece': [ 
				[ 0, 1 ], [ 1, 1 ], [ 1, 0 ], [ 2, 0 ]
			],
			'rotations': [
				[ [ 0, 1 ], [ 1, 1 ], [ 1, 0 ], [ 2, 0 ] ],
				[ [ 0, -1 ], [ 1, 1 ], [ 1, 0 ], [ 0, 0 ] ]
			]
		}
	];
	var twirlSpace = { 
		'columns': 10, 
		'rows': 18, 
		'top': 35, 
		'bottom': (canvas.height - 90), 
		'left': 10, 
		'right': (canvas.width * .7128),
		'nextPiece': randomPiece(),
		'speed': 1000,
		'originalSpeed': 1000,
		'drop': 'no',
		'fallingPieces': 0,
		'status': 'ok',
		'nextPl': [],
		'score': 0,
		'highScore': twirlHighScore,
		'paused': false
	};
	$.each(twirlPieces, function(i,v) {
		v.blockHeight = ((twirlSpace.bottom - twirlSpace.top) / twirlSpace.rows);
		v.blockWidth = ((twirlSpace.right - twirlSpace.left) / twirlSpace.columns);
		twirlSpace['blockHeight'] = v.blockHeight;
		twirlSpace['blockWidth'] = v.blockWidth;
	});

	function randomPiece() {
		var random_number = numeral(Math.random() * 10).format('0');
		while (random_number >= twirlPieces.length) {
			random_number = numeral(Math.random() * 10).format('0');
		}
		return random_number;
	}

	function drawPiece(n,next) {

		var p = twirlPieces[ n || 0 ];
		var pls = [];
		twirlctx.fillStyle = p.colour;
		twirlctx.strokeStyle = 'black';

		var status = 'falling';
		var delete_it = 'no';
		$.each(p.piece, function(i,v) {
			var l = twirlSpace.left + (p.blockWidth * v[0]) + (p.blockWidth * p.offset);
			var t = twirlSpace.top + (p.blockHeight * v[1]);
			var r = Date.now();
			if (next == 'next') {
				$.each(tPieces, function(i,v) {
					$.each(v, function(ir,pl) {

					});
				});
				l = (canvas.width * .66) + (p.blockWidth * v[0]) + (p.blockWidth);
				t = 80 + (p.blockHeight * v[1]);
				status = 'next';
			}
			var pl = [ 
				l,
				t, 
				p.blockWidth, 
				p.blockHeight,
				status,
				0,
				p,
				r,
				0,
				i,
				n
			];
			pls.push(pl);
		});
		twirlctx.fillStyle = 'beige';
		return pls;
	}
	function drawTwirl() {
		clearInterval(dropper);
		twirlSpace.initiated = Date.now();

		twirlctx.strokeRect(5, 30, canvas.width - 10, canvas.height - 80);
		twirlctx.strokeRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);


		twirlctx.fillText('Next', ( (canvas.width * .7128) + ( twirlctx.measureText('text').width / 2)), 50);
		twirlctx.strokeRect(canvas.width * .7128 + 10, 50, (canvas.width * .7128 * .3), 100);
		tPieces.push(drawPiece(twirlSpace.nextPiece));
		twirlSpace.nextPiece = randomPiece();
		twirlSpace.nextPl = drawPiece(twirlSpace.nextPiece,'next');
		twirlctx.stroke();

		twirlctx.fillStyle = 'beige';

		twirlctx.fillRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);
		twirlctx.fill();

		twirlDropper();
	}

	function twirlDropper() {

		dropper = setInterval(function() {
			twirlctx.fillStyle = 'white';
			twirlctx.fillRect(canvas.width * .7128 + 10, 50, (canvas.width * .7128 * .3), 100);
			twirlctx.fill();
			pieceDropper(twirlSpace.nextPl);
			twirlSpace.fallingPieces = 0;
			twirlSpace.nextPl = drawPiece(twirlSpace.nextPiece,'next');
			twirlctx.fillStyle = 'beige';

			twirlctx.fillRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);
			twirlctx.fill();
			if (twirlSpace.status == 'ok') {
				$.each(tPieces, function(i,v) {
					pieceDropper(v)
				});
				if (twirlSpace.fallingPieces == 0) {

					tPieces.push(drawPiece(twirlSpace.nextPiece));
					if (twirlSpace.speed != twirlSpace.originalSpeed) {
						clearInterval(dropper);
						twirlSpace.speed = twirlSpace.originalSpeed;
						twirlDropper()
					}

					twirlSpace.nextPiece = randomPiece();
					twirlctx.fillStyle = 'white';
					twirlctx.fillRect(canvas.width * .7128 + 10, 50, (canvas.width * .7128 * .3), 100);

					twirlctx.fill();
					twirlSpace.nextPl = drawPiece(twirlSpace.nextPiece,'next');
					pieceDropper(twirlSpace.nextPl);
					twirlctx.fillStyle = 'beige';

				}
			}
			else if (status == 'game over') {
				gameOver();
			}
			twirlSpace.status = boundaryPiece();
			twirlSpace.nextPl = drawPiece(twirlSpace.nextPiece,'next');
		},twirlSpace.speed);
	}

	function pieceDropper(v) {
		pieceEliminator();
		$.each(v, function(ir,pl) {
			if (pl && pl[4] == 'falling') {
				twirlSpace.fallingPieces += 1;
				pl[1] = (pl[1] + (twirlSpace.blockHeight));
				pl[5] += 1;

			}

			if (pl) {
				twirlctx.fillStyle = pl[6]['colour'];
				twirlctx.fillRect(pl[0],pl[1],pl[2],pl[3]);
				twirlctx.strokeRect(pl[0],pl[1],pl[2],pl[3]);
				twirlctx.stroke();
				if (ir == v.length) {
					twirlSpace.status = boundaryPiece();
				}
			}
			

		});

	}

	if (!twirlSpaceInitiated) {
		$(document).on('keydown', function(e) {
			if (topWindow() == 'twirl') {
				e.preventDefault();
				if (e.keyCode == 27) {
					pauseGame();
				}
				if (e.keyCode == 32) {
					movePiece('drop');
				}
				if (e.keyCode == 37) {
					movePiece('left');
				}
				else if (e.keyCode == 39) {
					movePiece('right');
				}
				else if (e.keyCode == 40) {
					movePiece('down');
				}
				else if (e.keyCode == 38) {
					movePiece('rotate');
				}
			}
		});
	}

	function pauseGame() {
		if (twirlSpace.paused == true) {
			twirlSpace.paused = false;
			twirlctx.fillStyle = 'beige';
			var text = 'Resuming';
			if (tPieces.length == 0) {
				text = 'Beginning';
			}
			twirlctx.fillRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);
			twirlctx.fillStyle = 'black';
			twirlctx.fillText(text, (twirlSpace.left + (twirlSpace.right / 2) - (twirlctx.measureText(text).width / 2)), (twirlSpace.top + (twirlSpace.bottom / 2)));
			twirlctx.fill();

			var count = 3;
			var countdown = 3000 / count;
			var remaining = 3000;
			var i = setInterval(function() {
				if (count == 0) { clearInterval(i); }
				else {
					remaining = countdown * (count - 1);
					if (remaining < twirlSpace.speed) {
						twirlDropper(); 
					}
					twirlctx.fillStyle = 'beige';

					twirlctx.fillRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);
					twirlctx.fillStyle = 'black';
					twirlctx.fillText(text, (twirlSpace.left + (twirlSpace.right / 2) - (twirlctx.measureText(text).width / 2)), (twirlSpace.top + (twirlSpace.bottom / 2)));
					twirlctx.fill();
					twirlctx.fillStyle = 'black';
					twirlctx.fillText(count, (twirlSpace.left + (twirlSpace.right / 2) - (twirlctx.measureText(count).width / 2)), (twirlSpace.top + (twirlSpace.bottom / 2) + 30));
					twirlctx.fill();
					count--;
				}
			}, countdown);

		}
		else {
			twirlSpace.paused = true;
			clearInterval(dropper);
			twirlctx.fillStyle = 'beige';

			twirlctx.fillRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);
			twirlctx.fillStyle = 'black';
			twirlctx.fillText('Paused', (twirlSpace.left + (twirlSpace.right / 2) - (twirlctx.measureText('Paused').width / 2)), (twirlSpace.top + (twirlSpace.bottom / 2)));
			twirlctx.fill();
		}
	}

	function pieceEliminator() {
		var rows = {};
		var eliminate = [];
		var eliminated = [];
		var eliminator = Date.now();
		$.each(tPieces, function(i,v) {
			$.each(v, function(ir,pl) {
				if (rows[pl[1]] == undefined) { rows[pl[1]] = []; }
				if (pl[4] == 'laid') {
					rows[pl[1]].push(pl[0]);
				}
				
				if (rows[pl[1]].length == twirlSpace.columns) {
					console.log('elminating ' + pl[1]);
					if (pl[4] == 'laid') {
						rows[pl[1]].push(pl[0]);
						eliminate.push(pl[1]);
					}
				}
			});
		});
		var pushDown = [];
		$.each(eliminate, function(e,el) {
			$.each(tPieces, function(i,v) {
				$.each(v, function(ir,pl) {
					var gone = 0;
					if (pl[1] < el) {
						pushDown.push(pl);
					}
					if (pl[1] == el) {
						eliminated.push(ir);
						gone = 1;
					}

				});
				twirlSpace.score = (twirlSpace.score + (eliminated.length));
				$.each(eliminated, function(ip,vp) {
					v.splice(vp)
				});
				eliminated = [];
			});
		});
		$.each(pushDown.reverse(), function(i,pl) {
			pl[1] = pl[1] + twirlSpace.blockHeight;
		});
		twirlctx.fillStyle = 'white';

		twirlctx.fillRect((canvas.width * .7128 + 10), 200, 100, 60);
		twirlctx.fillRect((canvas.width * .7128 + 12),  250, 100, 60);
		twirlctx.fill();


		if (twirlSpace.score > twirlSpace.highScore) {
			twirlSpace.highScore = twirlSpace.score;
			settingSetter({ 'app': 'twirl', 'setting': 'high_score', 'value': twirlSpace.highScore });
		}
		twirlctx.fillStyle = 'black';
		twirlctx.fillText(twirlSpace.score, (canvas.width * .7128 + 12),  220);
		twirlctx.fillStyle = 'blue';
		twirlctx.fillText(twirlSpace.highScore, (canvas.width * .7128 + 12),  250);
		twirlctx.fill();
		twirlctx.stroke();
	}

	var twirlSpaceInitiated = Date.now();

	function movePiece(direction) {
		if (twirlSpace.paused == true) { return; }
		twirlctx.fillStyle = 'beige';

		var fallingPieces = 0;
		var status = boundaryPiece(direction);
		if (status == 'ok') { 
			twirlctx.fillRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);
			twirlctx.fill();
			$.each(tPieces, function(i,v) {
				$.each(v, function(ir,pl) {
					var transformed;
					if (pl[4] == 'falling') {
						fallingPieces += 1;
						twirlctx.fillStyle = pl[6]['colour'];
						if (direction == 'right') {
							pl[0] = (pl[0] + (twirlSpace.blockWidth));
						}
						else if (direction == 'left') {
							pl[0] = (pl[0] - (twirlSpace.blockWidth));
						}
						else if (direction == 'down') {
							pl[1] = (pl[1] + (twirlSpace.blockHeight));
							pl[5] += 1;
						}
						else if (direction == 'drop') {
							twirlSpace.speed = 1;
							clearInterval(dropper);
							twirlDropper();
							if (!$('#twirl').is(':visible')) {
								clearInterval(dropper);
							}
							//clearInterval(dropper);
							//twirlSpace.speed = twirlSpace.originalSpeed;
							//twirlDropper();
						}
						else if (direction == 'rotate') {
							transformed = pl[8];
							if (pl[8] >= pl[6]['rotations'].length - 1) {
								pl[8] = 0;
							}
							else {
								pl[8]++;
							}
						}

					}

					if ((transformed || transformed == 0) && pl[8] != transformed) {
						var block = pl[9];
						var new_block = twirlPieces[pl[10]]['rotations'][pl[8]][pl[9]];
						var old_block = twirlPieces[pl[10]]['rotations'][transformed][pl[9]];

						var xdiff = (new_block[0] - old_block[0]) * twirlSpace.blockWidth;
						var ydiff = (new_block[1] - old_block[1]) * twirlSpace.blockHeight;
						pl[0] = pl[0] + xdiff;
						pl[1] = pl[1] + ydiff;
					}

					twirlctx.fillStyle = pl[6]['colour'];
					twirlctx.fillRect(pl[0],pl[1],pl[2],pl[3]);
					twirlctx.strokeRect(pl[0],pl[1],pl[2],pl[3]);
					twirlctx.stroke(); 
				});
			});
		}
		else if (status == 'game over') {
			gameOver();
		}
		twirlctx.save('a');
		twirlSpace.nextPl = drawPiece(twirlSpace.nextPiece,'next');
		twirlctx.restore('a');
	}

	function boundaryPiece(direction) {
		var laid = 0;
		var status = 'ok';

		$.each(tPieces.reverse(), function(i,v) {
			$.each(v, function(ir,pl) {
				if (pl[4] == 'falling') {
					if ((pl[1] + pl[3]) >= twirlSpace.bottom) {
						laid = 1;
					}

					$.each(tPieces, function(ip,vp) {
						$.each(vp, function(irp, vrp) {

							if (pl[7] != vrp[7]) {
								if ((pl[1] + pl[3]) == vrp[1] && (pl[0] == vrp[0])) {
									laid = 1;
								}
							}

							if (direction == 'right') {
								if (((pl[0] + pl[3] + pl[3]) == vrp[0] && (pl[1] == vrp[1]) && (pl[7] != vrp[7])) || (pl[0] + pl[3] + pl[3] ) >= twirlSpace.right) {
									status = 'no';
								}
							}
							else if (direction == 'left') {
								if ((pl[0] - pl[3]) <= twirlSpace.left || ((pl[7] != vrp[7]) && (pl[1] == vrp[1]) && (pl[0] + pl[3]) == (vrp[0] + vrp[2]))) {
									status = 'no';
								}
							}
						});
					});
				}
			});
			if (laid == 1) {
				$.each(v, function(ir,pl) {

					if (pl[1] <= twirlSpace.top && pl[4] != 'falling') {
						status = 'game over';
						gameOver();
					}
					pl[4] = 'laid';
				});

			}
		});
		return status;
	}

	function gameOver() {
		twirlctx.fillStyle = 'beige';

		twirlctx.fillRect(twirlSpace.left, twirlSpace.top, twirlSpace.right, twirlSpace.bottom);
		twirlctx.fillStyle = 'black';
		twirlctx.fillText('Game Over!', (twirlSpace.left + (twirlSpace.right / 2) - (twirlctx.measureText('Game Over!').width / 2)), (twirlSpace.top + (twirlSpace.bottom / 2)));
		twirlctx.fill();
		clearInterval(dropper);
		twirlSpace.paused = true;
		twirlSpace.score = 0;
		tPieces = [];
	}
	document.addEventListener("visibilitychange", function(e) {

		if (e.returnValue == true) {
			twirlSpace.paused = true;
			pauseGame();
		}
	});
	drawTwirl();
}

twirlGame();