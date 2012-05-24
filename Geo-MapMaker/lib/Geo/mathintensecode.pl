# used for taking a path that overlaps another path and moving the
# offending points on that path slightly away from it
sub move_point_away {
	my $x = shift();
	my $y = shift();
	my $md = shift();	# minimum distance to move away
	my $gd = shift();	# left,right,north,south,east,west,<radians>
	# rest of args are [x,y],[x,y],...

	if    ($gd eq "south"     || $gd eq "s" ) { $gd = atan2( 1,  0); }
	elsif ($gd eq "north"     || $gd eq "n" ) { $gd = atan2(-1,  0); }
	elsif ($gd eq "east"      || $gd eq "e" ) { $gd = atan2( 0,  1); }
	elsif ($gd eq "west"      || $gd eq "w" ) { $gd = atan2( 0, -1); }
	elsif ($gd eq "southwest" || $gd eq "sw") { $gd = atan2( 1, -1); }
	elsif ($gd eq "northwest" || $gd eq "nw") { $gd = atan2(-1, -1); }
	elsif ($gd eq "southeast" || $gd eq "se") { $gd = atan2( 1,  1); }
	elsif ($gd eq "northeast" || $gd eq "ne") { $gd = atan2(-1,  1); }

	my $i;
	my @x;  my @y;
	my @dp;			# distance of (x, y) from each point
	                        # (x[i], y[i])	       
	my @dl;			# distance of (x, y) from each line segment
	                        # from (x[i], y[i]) to (x[i+1], y[i+1])
	my @rl;			# position r of (x, y) along each line segment
	my @px;	my @py;		# P, the perpendicular projection of (x, y)
	                        # on each line segment
	my @sl;			# is (x, y) to the right (> 0) or left (< 0)
	                        # of each line segment?
	my @l;                  # length of each line segment
	my @dx;
	my @dy;
	my @theta;

	my @pairs = uniq_coord_pairs(@_);
	foreach my $pair (@pairs) {
		push(@x, $pair->[0]);
		push(@y, $pair->[1]);
	}

	my $n = scalar(@x);
	if ($n < 1) {
		return ($x, $y);
	}
	if ($n == 1) {
		my $theta = atan2($y[0] - $y, $x[0] - $x);
		if (point_distance($x, $y, $x[0], $y[0]) < $md) {
			$x = $x[0] + $md * cos($theta);
			$y = $y[0] + $md * sin($theta);
		}
		return ($x, $y);
	}

	for ($i = 0; $i < $n; $i += 1) {
		$dp[$i] = point_distance($x, $y, $x[$i], $y[$i]);
	}
	for ($i = 0; $i < ($n - 1); $i += 1) {
		($rl[$i], $px[$i], $py[$i], $sl[$i], $dl[$i]) =
			segment_distance($x, $y,
					 $x[$i], $y[$i],
					 $x[$i + 1], $y[$i + 1]);
		$l[$i] = point_distance($x[$i], $y[$i],
					$x[$i + 1], $y[$i + 1]);
		$dx[$i] = $x[$i + 1] - $x[$i];
		$dy[$i] = $y[$i + 1] - $y[$i];
		$theta[$i] = atan2($dy[$i], $dx[$i]);
	}
	for ($i = 0; $i < ($n - 2); $i += 1) {
		if (($dl[$i]     < $md &&
		     $dl[$i + 1] < $md &&
		     $rl[$i]     >= 0 && $rl[$i]     <= 1 &&
		     $rl[$i + 1] >= 0 && $rl[$i + 1] <= 1) ||
		    ($dp[$i + 1] < $md)) {
			my $dx = $dx[$i] / $l[$i] + $dx[$i + 1] / $l[$i + 1];
			my $dy = $dy[$i] / $l[$i] + $dy[$i + 1] / $l[$i + 1];

			my $theta = atan2($dy, $dx);
			if ($gd eq "left") {
				$x = $x[$i + 1] - $md * sin($theta);
				$y = $y[$i + 1] + $md * cos($theta);
			} 
			elsif ($gd eq "right") {
				$x = $x[$i + 1] + $md * sin($theta);
				$y = $y[$i + 1] - $md * cos($theta);
			}
			elsif (sin($theta - $gd) < 0) {
				$x = $x[$i + 1] - $md * sin($theta);
				$y = $y[$i + 1] + $md * cos($theta);
			}
			else {
				$x = $x[$i + 1] + $md * sin($theta);
				$y = $y[$i + 1] - $md * cos($theta);
			}
		}
	}
	for ($i = 0; $i < ($n - 1); $i += 1) {
		if ($dl[$i] < $md && $rl[$i] >= 0 && $rl[$i] <= 1) {
			my $dx = $x[$i + 1] - $x[$i];
			my $dy = $y[$i + 1] - $y[$i];

			my $theta = atan2($dy, $dx);
			if ($gd eq "left") {
				$x = $px[$i] - $md * sin($theta);
				$y = $py[$i] + $md * cos($theta);
			}
			elsif ($gd eq "right") {
				$x = $px[$i] + $md * sin($theta);
				$y = $py[$i] - $md * cos($theta);
			}
			elsif (sin($theta - $gd) < 0) {
				$x = $px[$i] - $md * sin($theta);
				$y = $py[$i] + $md * cos($theta);
			}
			else {
				$x = $px[$i] + $md * sin($theta);
				$y = $py[$i] - $md * cos($theta);
			}
		}
	}
	if ($dp[0] < $md) {
		my $theta = $theta[0];
		if ($gd eq "left") {
			$x = $px[0] - $md * sin($theta);
			$y = $py[0] + $md * cos($theta);
		}
		elsif ($gd eq "right") {
			$x = $px[0] + $md * sin($theta);
			$y = $py[0] - $md * cos($theta);
		}
		elsif (sin($theta - $gd) < 0) {
			$x = $px[0] - $md * sin($theta);
			$y = $py[0] + $md * cos($theta);
		}
		else {
			$x = $px[0] + $md * sin($theta);
			$y = $py[0] - $md * cos($theta);
		}
	}
	elsif ($dp[$n - 1] < $md) {
		my $theta = $theta[$n - 1];
		if ($gd eq "left") {
			$x = $px[$n - 1] - $md * sin($theta);
			$y = $py[$n - 1] + $md * cos($theta);
		}
		elsif ($gd eq "right") {
			$x = $px[$n - 1] + $md * sin($theta);
			$y = $py[$n - 1] - $md * cos($theta);
		}
		elsif (sin($theta - $gd) < 0) {
			$x = $px[$n - 1] - $md * sin($theta);
			$y = $py[$n - 1] + $md * cos($theta);
		}
		else {
			$x = $px[$n - 1] + $md * sin($theta);
			$y = $py[$n - 1] - $md * cos($theta);
		}
	}
	return ($x, $y);
}

sub point_distance {
	my ($x, $y, $x0, $y0) = @_;
	return sqrt(($x0 - $x) ** 2 + ($y0 - $y) ** 2);
}

sub segment_distance {
	# http://forums.codeguru.com/showthread.php?t=194400

	# points C, A, B
	my ($cx, $cy, $ax, $ay, $bx, $by) = @_;

	# $l is length of the line segment; $l2 is its square
	my $l2 = ($bx - $ax) ** 2 + ($by - $ay) ** 2;
	my $l = sqrt($l2);

	# $r is P's position along AB
	my $r = (($cx - $ax) * ($bx - $ax) + ($cy - $ay) * ($by - $ay)) / $l2;

	# ($px, $py) is P, the point of perpendicular projection of C on AB
	my $px = $ax + $r * ($bx - $ax);
	my $py = $ay + $r * ($by - $ay);

	my $s = (($ay - $cy) * ($bx - $ax) - ($ax - $cx) * ($by - $ay)) / $l2;
	# if $s < 0  then C is left of AB
	# if $s > 0  then C is right of AB
	# if $s == 0 then C is on AB

	# distance from C to P
	my $d = abs($s) * $l;
	
	return ($r, $px, $py, $s, $d);
}

