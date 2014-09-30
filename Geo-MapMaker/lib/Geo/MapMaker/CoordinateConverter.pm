package Geo::MapMaker::CoordinateConverter;
use warnings;
use strict;

use Math::Trig;
use Math::Trig qw(:pi);
use constant D2R => atan2(1, 1) / 45;
use constant WGS84_EQUATORIAL_RADIUS_KILOMETERS => 6378.1370; # WGS84
use constant KM_PER_ER => WGS84_EQUATORIAL_RADIUS_KILOMETERS;
use constant PX_PER_IN => 90;
use constant MM_PER_IN => 25.4;
use constant MM_PER_KM => 1_000_000;

use fields qw(
		 paper_width_px
		 paper_height_px
		 paper_margin_x_px
		 paper_margin_y_px
		 fudge_factor_x_px
		 fudge_factor_y_px
		 horizontal_alignment
		 vertical_alignment
		 horizontal_fill
		 vertical_fill

		 reset_A
		 reset_B
		 reset_C

		 orientation

		 center_lon_deg
		 center_lat_deg

		 center_lon_er
		 center_lat_er

		 map_area_width_px
		 map_area_height_px
		 map_width_px
		 map_height_px

		 center_x_px
		 center_y_px

		 left_x_px
		 right_x_px
		 top_y_px
		 bottom_y_px

		 scale_px_per_er

		 west_lon_deg
		 east_lon_deg
		 north_lat_deg
		 south_lat_deg
	    );

use constant DEFAULTS => (
    paper_width_px       => 8.5 * PX_PER_IN,
    paper_height_px      => 11 * PX_PER_IN,
    paper_margin_x_px    => 0.25 * PX_PER_IN,
    paper_margin_y_px    => 0.25 * PX_PER_IN,
    fudge_factor_x_px    => 0.25 * PX_PER_IN,
    fudge_factor_y_px    => 0.25 * PX_PER_IN,

    orientation          => 0,
    horizontal_alignment => "center",
    vertical_alignment   => "center",
    horizontal_fill      => 0,
    vertical_fill        => 0,
   );

sub new {
    my ($class, %args) = @_;
    my $self = fields::new($class);

    my %defaults = (DEFAULTS);
    while (my ($k, $v) = each(%defaults)) {
	$self->{$k} = $v;
    }

    return $self;
}

#------------------------------------------------------------------------------

sub set_paper_size_px {
    my ($self, $width_px, $height_px) = @_;
    $self->{paper_width_px}  = $width_px  if defined $width_px;
    $self->{paper_height_px} = $height_px if defined $height_px;
}

sub set_paper_margin_px {
    my ($self, $width_px, $height_px) = @_;
    $height_px //= $width_px;
    $self->{paper_margin_x_px} = $width_px  if defined $width_px;
    $self->{paper_margin_y_px} = $height_px if defined $height_px;
}

sub set_fudge_factor_px {
    my ($self, $width_px, $height_px) = @_;
    $height_px //= $width_px;
    $self->{fudge_factor_x_px} = $width_px  if defined $width_px;
    $self->{fudge_factor_y_px} = $height_px if defined $height_px;
}

#------------------------------------------------------------------------------

# These don't *really* matter unless you set west/east/north/south
# boundaries.

sub set_horizontal_alignment {
    my ($self, $alignment) = @_;
    $self->{horizontal_alignment} = $alignment;
}

sub set_vertical_alignment {
    my ($self, $alignment) = @_;
    $self->{horizontal_alignment} = $alignment;
}

sub set_horizontal_fill {
    my ($self, $fill) = @_;
    $self->{horizontal_fill} = $fill;
}

sub set_vertical_fill {
    my ($self, $fill) = @_;
    $self->{horizontal_fill} = $fill;
}

###############################################################################

# Using A, B, and C

# A
sub set_center_lon_lat_deg {
    my ($self, $lon_deg, $lat_deg) = @_;

    die("must specify longitude AND latitude.\n") if !defined $lon_deg || !defined $lat_deg;

    #$self->{reset_A} = _sub_to_call_this_sub(@_);

    $self->{center_lon_deg} = $lon_deg;
    $self->{center_lat_deg} = $lat_deg;

    $self->{center_lon_er} = $self->lon_deg_to_er($self->{center_lon_deg});
    $self->{center_lat_er} = $self->lon_deg_to_er($self->{center_lat_deg});

    $self->{map_area_width_px}  = $self->{paper_width_px} - $self->{paper_margin_x_px} - $self->{fudge_factor_x_px};
    $self->{map_area_height_px} = $self->{paper_height_px} - $self->{paper_margin_y_px} - $self->{fudge_factor_y_px};
    $self->{map_width_px}  = $self->{paper_width_px} - $self->{paper_margin_x_px};
    $self->{map_height_px} = $self->{paper_height_px} - $self->{paper_margin_y_px};

    $self->{center_x_px} = $self->{paper_width_px} / 2;
    $self->{center_y_px} = $self->{paper_height_px} / 2;

    $self->{left_x_px}   = $self->{paper_margin_x_px};
    $self->{right_x_px}  = $self->{paper_width_px} - $self->{paper_margin_x_px};
    $self->{top_y_px}    = $self->{paper_margin_y_px};
    $self->{bottom_y_px} = $self->{paper_height_px} - $self->{paper_margin_y_px};

    $self->set_real_lat_lon_boundaries();
}

# B
sub set_orientation {
    my ($self, $orientation) = @_;

    #$self->{reset_B} = _sub_to_call_this_sub(@_);

    $self->{orientation} = $orientation if defined $orientation;
}

# C
sub set_absolute_scale {
    my ($self, $scale) = @_;

    #$self->{reset_C} = _sub_to_call_this_sub(@_);

    $self->{scale_px_per_er} = $scale # in px per px
      * PX_PER_IN		       # in px per in
	/ MM_PER_IN		       # in px per mm
	  * MM_PER_KM		       # in px per km
	    * KM_PER_ER;	       # in px per er
}

#------------------------------------------------------------------------------

sub set_lon_lat_boundaries {
    my ($self, $west_lon_deg, $east_lon_deg, $north_lat_deg, $south_lat_deg) = @_;

    #$self->{reset_A} = _sub_to_call_this_sub(@_);
    #$self->{reset_B} = undef;
    #$self->{reset_C} = undef;

    $self->{orientation} = 0;

    my $west_lon_er = $self->lon_deg_to_er($west_lon_deg);
    my $east_lon_er = $self->lon_deg_to_er($east_lon_deg);
    my $north_lat_er = $self->lat_deg_to_er($north_lat_deg);
    my $south_lat_er = $self->lat_deg_to_er($south_lat_deg);

    my $center_lon_er = ($west_lon_er + $east_lon_er) / 2;
    my $center_lat_er = ($north_lat_er + $south_lat_er) / 2;
    my $center_lon_deg = $self->lon_er_to_deg($center_lon_er);
    my $center_lat_deg = $self->lat_er_to_deg($center_lat_er);

    $self->{center_lon_er} = $center_lon_er;
    $self->{center_lat_er} = $center_lat_er;
    $self->{center_lon_deg} = $center_lon_deg;
    $self->{center_lat_deg} = $center_lat_deg;

    my $width_er = $east_lon_er - $west_lon_er;
    my $height_er = $north_lat_er - $south_lat_er;

    my $map_area_aspect = $width_er / $height_er;
    # >1 landscape
    # =1 square
    # <1 portrait

    my $paper_map_area_width  = $self->{paper_width_px}  - $self->{paper_margin_x_px} * 2 - $self->{fudge_factor_x_px} * 2;
    my $paper_map_area_height = $self->{paper_height_px} - $self->{paper_margin_y_px} * 2 - $self->{fudge_factor_y_px} * 2;

    my $paper_map_area_aspect = $paper_map_area_width / $paper_map_area_height;
    # >1 landscape
    # =1 square
    # <1 portrait

    if ($map_area_aspect <= $paper_map_area_aspect) {
	# e.g., portrait map area on landscape paper
	# any extra space will be on left and right sides
	# y coordinates dictate scale
	$self->{scale_px_per_er} = $paper_map_area_height / $height_er;
    } else {
	# e.g., landscape map area on portrait paper
	# any extra space will be on top and bottom
	# x coordinates dictate scale
	$self->{scale_px_per_er} = $paper_map_area_width / $width_er;
    }

    $self->{map_area_width_px}  = $self->{scale_px_per_er} * $width_er;
    $self->{map_area_height_px} = $self->{scale_px_per_er} * $height_er;
    $self->{map_width_px}       = $self->{map_area_width_px}  + $self->{fudge_factor_x_px} * 2;
    $self->{map_height_px}      = $self->{map_area_height_px} + $self->{fudge_factor_y_px} * 2;

    # in er, 0 = bottom left
    # in svg, 0 = top left

    if ($self->{horizontal_alignment} eq "left") {
	$self->{center_x_px} = $self->{paper_margin_x_px} + $self->{fudge_factor_x_px} + $self->{map_width_px} / 2;
    } elsif ($self->{horizontal_alignment} eq "right") {
	$self->{center_x_px} = $self->{paper_width_px} - $self->{paper_margin_x_px} - $self->{fudge_factor_x_px} - $self->{map_width_px} / 2;
    } else {
	$self->{center_x_px} = $self->{paper_width_px} / 2;
    }

    if ($self->{vertical_alignment} eq "top") {
	$self->{center_y_px} = $self->{paper_margin_y_px} + $self->{fudge_factor_y_px} + $self->{map_height_px} / 2;
    } elsif ($self->{vertical_alignment} eq "bottom") {
	$self->{center_y_px} = $self->{paper_height_px} - $self->{paper_margin_y_px} - $self->{fudge_factor_y_px} - $self->{map_height_px} / 2;
    } else {
	$self->{center_y_px} = $self->{paper_height_px} / 2;
    }

    $self->{left_x_px}   = $self->{paper_margin_x_px};
    $self->{right_x_px}  = $self->{paper_width_px} - $self->{paper_margin_x_px};
    if (!$self->{horizontal_fill}) {
	if ($self->{horizontal_alignment} eq "left") {
	    $self->{right_x_px} = $self->{left_x_px} + $self->{map_width_px};
	} elsif ($self->{horizontal_alignment} eq "right") {
	    $self->{left_x_px} = $self->{right_x_px} - $self->{map_width_px};
	} else {
	    $self->{right_x_px} = $self->{center_x_px} + $self->{map_width_px} / 2;
	    $self->{left_x_px} = $self->{center_x_px} - $self->{map_width_px} / 2;
	}
    }

    $self->{top_y_px}    = $self->{paper_margin_y_px};
    $self->{bottom_y_px} = $self->{paper_height_px} - $self->{paper_margin_y_px};
    if (!$self->{vertical_fill}) {
	if ($self->{vertical_alignment} eq "top") {
	    $self->{bottom_y_px} = $self->{top_y_px} + $self->{map_height_px};
	} elsif ($self->{vertical_alignment} eq "bottom") {
	    $self->{top_y_px} = $self->{bottom_y_px} - $self->{map_height_px};
	} else {
	    $self->{bottom_y_px} = $self->{center_y_px} + $self->{map_height_px} / 2;
	    $self->{top_y_px} = $self->{center_y_px} - $self->{map_height_px} / 2;
	}
    }

    $self->set_real_lat_lon_boundaries();
}

#------------------------------------------------------------------------------

sub set_real_lat_lon_boundaries {
    my ($self) = @_;
    $self->{west_lon_deg}  = $self->x_px_to_lon_deg($self->{left_x_px});
    $self->{east_lon_deg}  = $self->x_px_to_lon_deg($self->{right_x_px});
    $self->{north_lat_deg} = $self->y_px_to_lat_deg($self->{top_y_px});
    $self->{south_lat_deg} = $self->y_px_to_lat_deg($self->{bottom_y_px});
}

#------------------------------------------------------------------------------

sub lon_deg_to_er {
    my ($self, $lon_deg) = @_;
    return $lon_deg * D2R;
}

sub lat_deg_to_er {
    my ($self, $lat_deg) = @_;
    my $lat_rad = $lat_deg * D2R;
    return log(abs((1 + sin($lat_rad)) / cos($lat_rad)));
}

sub lon_er_to_deg {
    my ($self, $lon_er) = @_;
    return $lon_er / D2R;
}

sub lat_er_to_deg {
    my ($self, $lat_er) = @_;
    return (2 * atan(exp($lat_er)) - pip2) / D2R;
}

sub lon_er_to_x_px {
    my ($self, $lon_er) = @_;
    return $self->{center_x_px} + $self->{scale_px_per_er} * ($lon_er - $self->{center_lon_er});
}

sub lat_er_to_y_px {
    my ($self, $lat_er) = @_;
    return $self->{center_y_px} + $self->{scale_px_per_er} * ($self->{center_lat_er} - $lat_er);
}

sub x_px_to_lon_er {
    my ($self, $x_px) = @_;
    return ($x_px - $self->{center_x_px}) / $self->{scale_px_per_er} + $self->{center_lon_er};
}

sub y_px_to_lat_er {
    my ($self, $y_px) = @_;
    return $self->{center_lat_er} - ($y_px - $self->{center_y_px}) / $self->{scale_px_per_er};
}

sub lon_deg_to_x_px {
    my ($self, $lon_deg) = @_;
    return $self->lon_er_to_x_px($self->lon_deg_to_er($lon_deg));
}

sub lat_deg_to_y_px {
    my ($self, $lat_deg) = @_;
    return $self->lat_er_to_y_px($self->lat_deg_to_er($lat_deg));
}

sub x_px_to_lon_deg {
    my ($self, $x_px) = @_;
    return $self->lon_er_to_deg($self->x_px_to_lon_er($x_px));
}

sub y_px_to_lat_deg {
    my ($self, $y_px) = @_;
    return $self->lat_er_to_deg($self->y_px_to_lat_er($y_px));
}

sub _sub_to_call_this_sub {
    my @args = @_;
    my @caller = caller(1);
    for (my $i = 0; $i <= $#caller; $i += 1) {
	print("$i: $caller[$i]\n");
    }
}

1;

