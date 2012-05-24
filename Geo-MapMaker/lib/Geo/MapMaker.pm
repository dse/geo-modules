package Geo::MapMaker;
use warnings;
use strict;
use Carp qw(croak);

# NOTE: "ground" and "background" are apparently treated as the same
# classname in SVG, or some shit.

=head1 NAME
	
Geo::MapMaker - Create semi-usable transit maps from GTFS and OSM data.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';
	
=head1 SYNOPSIS

    use Geo::MapMaker;

    # TBD

=head1 DESCRIPTION

If you want to create and edit your own to-scale map of your favorite
transit system, this module performs some of the work for you.  It
takes care of the following:

=over 4

=item *

Download and render data from OpenStreetMap.org, including streets and
highways, parks, golf courses, lakes, rivers, streams, educational
institutions, industrial areas, and other forms of land use.

=item *

Download and render transit routes (and stops!) from GTFS data.

=back

On first run this module creates an SVG file with a bunch of layers
containing the necessary data.  On each subsequent run this module
will update the appropriate layers in the SVG file as needed without
affecting manually-edited layers.

=cut


our @_FIELDS;
BEGIN {
	@_FIELDS = qw(filename
		      _read_filename
		      north south east west
		      map_data_north
		      map_data_south
		      map_data_east
		      map_data_west
		      paper_width paper_height paper_margin
		      vertical_align
		      horizontal_align
		      classes
		      layers
		      route_colors
		      route_overrides
		      grid
		      osm_layers
		      inset_maps
		      _map_areas
		      _gtfs_list
		      _parser
		      _svg_doc
		      _svg_doc_elt
		      _xpc
		      _map_xml_filenames
		      _nodes
		      _ways
		      _scale
		      _south_y _north_y _east_x _west_x
		      _svg_west _svg_east _svg_north _svg_south
		      _cache
		      include
		      transit_route_overrides
		      transit_route_defaults
		      transit_route_groups
		      orig_transit_route_color_mapping
		      transit_trip_exceptions
		      transit_route_fix_overlaps
		    );
}
use fields @_FIELDS;

our $verbose = 0;

sub new {
	my ($class, %options) = @_;
	my $self = fields::new($class);
	$self->{_cache} = {};
	$self->{paper_width}  = 90 * 8.5;
	$self->{paper_height} = 90 * 11;
	$self->{paper_margin} = 90 * 0.25;
	$self->{vertical_align} = "top";
	$self->{horizontal_align} = "left";
	$self->{_gtfs_list} = [];
	while (my ($k, $v) = each(%options)) {
		if ($self->can($k)) {
			$self->$k($v);
		}
		else {
			$self->{$k} = $v;
		}
	}
	foreach my $include (@{$self->{include}}) {
		while (my ($k, $v) = each(%$include)) {
			if ($self->can($k)) {
				$self->$k($v);
			}
			else {
				$self->{$k} = $v;
			}
		}
	}
	return $self;
}
sub north {
	my ($self, $lat) = @_;
	$self->{north} = $lat;
}
sub south {
	my ($self, $lat) = @_;
	$self->{south} = $lat;
}
sub east {
	my ($self, $lon) = @_;
	$self->{east} = $lon;
}
sub west {
	my ($self, $lon) = @_;
	$self->{west} = $lon;
}
sub map_data_north {
	my ($self, $lat) = @_;
	$self->{map_data_north} = $lat;
}
sub map_data_south {
	my ($self, $lat) = @_;
	$self->{map_data_south} = $lat;
}
sub map_data_east {
	my ($self, $lon) = @_;
	$self->{map_data_east} = $lon;
}
sub map_data_west {
	my ($self, $lon) = @_;
	$self->{map_data_west} = $lon;
}
sub paper_margin {
	my ($self, $margin) = @_;
	$self->{paper_margin} = $margin;
}
sub paper_width {
	my ($self, $width) = @_;
	$self->{paper_width} = $width;
}
sub paper_height {
	my ($self, $height) = @_;
	$self->{paper_height} = $height;
}

sub DESTROY {
	my ($self) = @_;
	$self->finish_xml();
}

use XML::LibXML qw(:all);
use LWP::Simple;
use URI;
use Carp qw(croak);
use File::Path qw(mkpath);
use File::Basename;
use List::MoreUtils qw(all firstidx uniq);
use Geo::MapMaker::Util;

sub update_openstreetmap {
	my ($self, $force) = @_;
	$self->{_map_xml_filenames} = [];
	$self->_update_openstreetmap($force);
}

sub _update_openstreetmap {
	my ($self, $force, $west, $south, $east, $north) = @_;

	$west  //= ($self->{map_data_west}  // $self->{west});
	$south //= ($self->{map_data_south} // $self->{south});
	$east  //= ($self->{map_data_east}  // $self->{east});
	$north //= ($self->{map_data_north} // $self->{north});

	my $center_lat = ($north + $south) / 2;
	my $center_lon = ($west + $east) / 2;

	my $url = sprintf("http://api.openstreetmap.org/api/0.6/map?bbox=%.8f,%.8f,%.8f,%.8f",
			  $west, $south, $east, $north);
	my $txt_filename = sprintf("%s/.transit-mapmaker/map_%.8f_%.8f_%.8f_%.8f_bbox.txt",
				   $ENV{HOME}, $west, $south, $east, $north);
	my $xml_filename = sprintf("%s/.transit-mapmaker/map_%.8f_%.8f_%.8f_%.8f_bbox.xml",
				   $ENV{HOME}, $west, $south, $east, $north);

	mkpath(dirname($xml_filename));
	my $status = eval { file_get_contents($txt_filename); };

	if ($status && $status eq "split-up") {
		$self->_update_openstreetmap($force, $west,       $south,      $center_lon, $center_lat);
		$self->_update_openstreetmap($force, $center_lon, $south,      $east,       $center_lat);
		$self->_update_openstreetmap($force, $west,       $center_lat, $center_lon, $north);
		$self->_update_openstreetmap($force, $center_lon, $center_lat, $east,       $north);
	}
	elsif (-e $xml_filename && !$force) {
		warn("Not updating $xml_filename\n");
		push(@{$self->{_map_xml_filenames}}, $xml_filename);
	}
	else {
		my $ua = LWP::UserAgent->new();
		print STDERR ("Downloading $url ... ");
		my $response = $ua->mirror($url, $xml_filename);
		printf STDERR ("%s\n", $response->status_line());
		my $rc = $response->code();
		if ($rc == RC_NOT_MODIFIED) {
			push(@{$self->{_map_xml_filenames}}, $xml_filename);
			# ok then
		}
		elsif ($rc == 400) {
			file_put_contents($txt_filename, "split-up");
			my $center_lat = ($north + $south) / 2;
			my $center_lon = ($west + $east) / 2;
			$self->_update_openstreetmap($force, $west,       $south,      $center_lon, $center_lat);
			$self->_update_openstreetmap($force, $center_lon, $south,      $east,       $center_lat);
			$self->_update_openstreetmap($force, $west,       $center_lat, $center_lon, $north);
			$self->_update_openstreetmap($force, $center_lon, $center_lat, $east,       $north);
		}
		elsif (is_success($rc)) {
			push(@{$self->{_map_xml_filenames}}, $xml_filename);
			# ok then
		}
		else {
			croak(sprintf("Failure: %s => %s\n",
				      $response->base(),
				      $response->status_line()));
		}
	}
}

sub force_update_openstreetmap {
	my ($self) = @_;
	$self->update_openstreetmap(1);
}

sub init_xml {
	my ($self) = @_;
	if (defined($self->{_read_filename}) and
	    defined($self->{filename}) and
	    ($self->{_read_filename} eq $self->{filename})) {
		return;
	}
	my $parser = XML::LibXML->new();
	$parser->keep_blanks(0);
	my $doc = eval {
		$self->diag("Parsing $self->{filename} ... ");
		my $d = $parser->parse_file($self->{filename});
		$self->diag("Done.\n");
		return $d;
	};
	my $doc_is_new = 0;
	if (!$doc) {
		$doc_is_new = 1;
		$doc = $parser->parse_string(<<'END');
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!-- Not created with Inkscape (http://www.inkscape.org/) -->
<!-- (However, a very early version of this template was.) -->
<svg
   xmlns:dc="http://purl.org/dc/elements/1.1/"
   xmlns:cc="http://creativecommons.org/ns#"
   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
   xmlns:svg="http://www.w3.org/2000/svg"
   xmlns="http://www.w3.org/2000/svg"
   xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd"
   xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
   xmlns:mapmaker="http://webonastick.com/namespaces/transit-mapmaker"
   width="765"
   height="990"
   id="svg2"
   version="1.1"
   inkscape:version="0.48.1 "
   sodipodi:docname="Map">
  <sodipodi:namedview
     id="base"
     pagecolor="#ffffff"
     bordercolor="#666666"
     borderopacity="1.0"
     inkscape:pageopacity="0.0"
     inkscape:pageshadow="2"
     inkscape:zoom="1"
     inkscape:cx="0" inkscape:cy="0"
     inkscape:document-units="px"
     inkscape:current-layer="layer1"
     showgrid="false"
     inkscape:not-window-width="600" inkscape:not-window-height="600"
     inkscape:not-window-x="0" inkscape:not-window-y="0"
     inkscape:window-maximized="1" />
  <metadata>
    <rdf:RDF>
      <cc:Work rdf:about="">
        <dc:format>image/svg+xml</dc:format>
        <dc:type rdf:resource="http://purl.org/dc/dcmitype/StillImage" />
        <dc:title></dc:title>
      </cc:Work>
    </rdf:RDF>
  </metadata>
</svg>
END
	}

	my $doc_elt = $doc->documentElement();

	$self->{_parser} = $parser;
	$self->{_svg_doc} = $doc;
	$self->{_svg_doc_elt} = $doc_elt;

	$doc_elt->setAttribute("width", $self->{paper_width});
	$doc_elt->setAttribute("height", $self->{paper_height});
	$doc_elt->setNamespace($NS{"svg"}, "svg", 0);

	my $xpc = XML::LibXML::XPathContext->new($doc);
	$xpc->registerNs("svg"      => $NS{"svg"});
	$xpc->registerNs("inkscape" => $NS{"inkscape"});
	$xpc->registerNs("sodipodi" => $NS{"sodipodi"});
	$xpc->registerNs("mapmaker" => $NS{"mapmaker"});
	$self->{_xpc} = $xpc;

	if ($doc_is_new) {
		my ($view) = $doc->findnodes("//sodipodi:namedview[\@id='base']");
		if ($view) {
			$view->setAttributeNS($NS{"inkscape"}, "inkscape:cx",
					      $self->{paper_width} / 2);
			$view->setAttributeNS($NS{"inkscape"}, "inkscape:cy",
					      $self->{paper_height} / 2);
		}
	}

	$self->{_map_areas} = [ { is_main => 1, name => "Main Map" }, 
				eval { @{$self->{inset_maps}} } ];

	$self->add_indexes_to_array($self->{_map_areas});
	$self->add_indexes_to_array($self->{transit_route_groups});

	foreach my $map_area (@{$self->{_map_areas}}) {
		my $id = $map_area->{id};
		my $index = $map_area->{index};
		if ($index == 0) {
			$map_area->{clip_path_id} = "main_area_clip_path";
		}
		elsif (defined $id) {
			$map_area->{clip_path_id} = "inset_${id}_clip_path";
		}
		else {
			$map_area->{clip_path_id} = "inset__${index}__clip_path";
		}
	}

	$self->{_read_filename} = $self->{filename};
}

sub findnodes {
	my ($self, @args) = @_;
	return $self->{_xpc}->findnodes(@args);
}

sub add_indexes_to_array {
	my ($self, $array_ref) = @_;
	my $index = 0;
	foreach my $o (@{$array_ref}) {
		$o->{index} = $index;
		$index += 1;
	}
}

BEGIN {
	my $d2r = atan2(1, 1) / 45;
	my $r2d = 45 / atan2(1, 1);
	sub update_scale {
		my ($self, $map_area) = @_;
		my $w = $self->{west};			 # in degrees
		my $e = $self->{east};			 # in degrees
		my $n = $self->{north};			 # in degrees
		my $s = $self->{south};			 # in degrees
		my $wx = $self->{_west_x} = _lon2x($w);	 # units
		my $ex = $self->{_east_x} = _lon2x($e);	 # units
		my $ny = $self->{_north_y} = _lat2y($n); # units
		my $sy = $self->{_south_y} = _lat2y($s); # units
		my $width  = $ex - $wx;			 # units
		my $height = $ny - $sy;			 # units
		my $pww = $self->{paper_width}  - 2 * $self->{paper_margin}; # in px
		my $phh = $self->{paper_height} - 2 * $self->{paper_margin}; # in px
		if ($width / $height <= $pww / $phh) {
			$self->{_scale} = $phh / $height; # px/unit
		} else {
			$self->{_scale} = $pww / $width; # px/unit
		}

		# assuming top left
		$self->{_svg_north} = $self->{paper_margin}; # $self->lat2y($self->{north});
		$self->{_svg_south} = $self->lat2y($self->{south});
		$self->{_svg_west}  = $self->{paper_margin};
		$self->{_svg_east}  = $self->lon2x($self->{east});

		my $extra_horizontal_room = $self->{paper_width}  - $self->{paper_margin} - $self->{_svg_east};
		my $extra_vertical_room   = $self->{paper_height} - $self->{paper_margin} - $self->{_svg_south};

		if ($self->{vertical_align} eq "bottom") {
			$self->{_svg_north} += $extra_vertical_room;
			$self->{_svg_south} += $extra_vertical_room;
		} elsif ($self->{vertical_align} eq "center") {
			$self->{_svg_north} += $extra_vertical_room / 2;
			$self->{_svg_south} += $extra_vertical_room / 2;
		}
		if ($self->{horizontal_align} eq "right") {
			$self->{_svg_east} += $extra_horizontal_room;
			$self->{_svg_west} += $extra_horizontal_room;
		} elsif ($self->{horizontal_align} eq "center") {
			$self->{_svg_east} += $extra_horizontal_room / 2;
			$self->{_svg_west} += $extra_horizontal_room / 2;
		}
		
		if (!$map_area->{is_main}) {
			# recalculate
			$w = $map_area->{west};
			$e = $map_area->{east};
			$n = $map_area->{north};
			$s = $map_area->{south};
			$wx = $self->{_west_x}  = _lon2x($w); # units
			$ex = $self->{_east_x}  = _lon2x($e); # units
			$ny = $self->{_north_y} = _lat2y($n); # units
			$sy = $self->{_south_y} = _lat2y($s); # units
			$width  = $ex - $wx;		      # units
			$height = $ny - $sy;		      # units
			if (exists $map_area->{zoom}) {
				$self->{_scale} *= $map_area->{zoom};
			}
			if (exists $map_area->{left}) {
				$self->{_svg_west} += $map_area->{left};
				$self->{_svg_east} = $self->{_svg_west} + $self->{_scale} * $width;
			}
			elsif (exists $map_area->{right}) {
				$self->{_svg_east} -= $map_area->{right};
				$self->{_svg_west} = $self->{_svg_east} - $self->{_scale} * $width;
			}
			if (exists $map_area->{top}) {
				$self->{_svg_north} += $map_area->{top};
				$self->{_svg_south} = $self->{_svg_north} + $self->{_scale} * $height;
			}
			elsif (exists $map_area->{bottom}) {
				$self->{_svg_south} -= $map_area->{bottom};
				$self->{_svg_north} = $self->{_svg_south} - $self->{_scale} * $height;
			}
		}
	}
	sub _lon2x {
		my ($lon) = @_;
		return $lon * $d2r;
	}
	sub _lat2y {
		my ($lat) = @_;
		my $latr = $lat * $d2r;
		return log(abs((1 + sin($latr)) / cos($latr)));
	}
	sub lon2x {
		my ($self, $lon) = @_;
		return $self->{_svg_west} + $self->{_scale} * (_lon2x($lon) - $self->{_west_x});
	}
	sub lat2y {
		my ($self, $lat) = @_;
		return $self->{_svg_north} + $self->{_scale} * ($self->{_north_y} - _lat2y($lat));
	}
}

sub clip_path_d {
	my ($self) = @_;
	my $left   = $self->{_svg_west};
	my $right  = $self->{_svg_east};
	my $top    = $self->{_svg_north};
	my $bottom = $self->{_svg_south};
	my $d = sprintf("M %f %f H %f V %f H %f Z",
			$left, $top, $right, $bottom, $left);
	return $d;
}

sub erase_autogenerated_clip_paths {
	my ($self) = @_;
	my $defs = $self->defs_node();
	my $doc = $self->{_svg_doc};
	my @cpnodes = $doc->findnodes("/svg:defs/svg:clipPath[\@mapmaker:autogenerated]");
	foreach my $cpnode (@cpnodes) {
		$cpnode->unbindNode();
	}
}

sub defs_node {
	my ($self) = @_;
	my $doc = $self->{_svg_doc};
	my $doc_elt = $doc->documentElement();
	my ($defs) = $doc->findnodes("/*/svg:defs");
	if (!$defs) {
		$defs = $doc->createElementNS($NS{"svg"}, "defs");
		$doc_elt->insertBefore($defs, $doc_elt->firstChild());
	}
	return $defs;
}

sub remove_style_node {
	my ($self) = @_;
	my $doc = $self->{_svg_doc};
	my $defs = $self->defs_node();
	my @style = $defs->findnodes("svg:style[\@mapmaker:autogenerated]");
	foreach my $style (@style) {
		$style->unbindNode();
	}
}

sub style_node {
	my ($self) = @_;
	my $doc = $self->{_svg_doc};
	my $defs = $self->defs_node();
	my ($style) = $defs->findnodes("svg:style");
	if (!$style) {
		$style = $doc->createElementNS($NS{svg}, "style");
		$style->setAttribute("type", "text/css");
		$style->setAttributeNS($NS{mapmaker}, "mapmaker:autogenerated", "true");
		$defs->appendChild($style);
	}

	my $contents = "\n";
	
	$contents .= <<'END';
        .WHITE      { fill: #fff; }
        .MAP_BORDER { fill: none !important; stroke-linejoin: square !important; }
        .OPEN       { fill: none !important; stroke-linecap: round; stroke-linejoin: round; }
        .GRID_TEXT  {
		font-size: 6px;
		font-style: normal;
		font-variant: normal;
		font-weight: normal;
		font-stretch: normal;
		text-align: center;
		line-height: 100%;
		writing-mode: lr-tb;
		text-anchor: middle;
		fill: #000000;
		fill-opacity: 1;
		stroke: none;
		font-family: Arial;
        }
END

	foreach my $class (sort keys %{$self->{classes}}) {
		my $css   = $self->compose_style_string(class => $class);
		my $css_2 = $self->compose_style_string(class => $class, style_attr_name => "style_2");
		$contents .= "        .${class}   { $css }\n";
		$contents .= "        .${class}_2 { $css_2 }\n" if $self->has_style_2(class => $class);
	}

	$style->removeChildNodes();
	my $cdata = $doc->createCDATASection($contents);
	$style->appendChild($cdata);
}

sub clip_path {
	my ($self, $map_area) = @_;
	my $defs = $self->defs_node();
	my $doc = $self->{_svg_doc};

	my $clip_path_id      = $map_area->{clip_path_id};
	my $clip_path_path_id = $clip_path_id . "_path";

	my ($cp_node) = $defs->findnodes("svg:clipPath[\@mapmaker:autogenerated and \@id='$clip_path_id']");
	return $cp_node if $cp_node;

	my $cpnode = $doc->createElementNS($NS{"svg"}, "clipPath");
	$cpnode->setAttributeNS($NS{mapmaker}, "mapmaker:autogenerated", "true");
	$cpnode->setAttribute("id", $clip_path_id);
	$defs->appendChild($cpnode);

	my $path = $doc->createElementNS($NS{"svg"}, "path");
	$path->setAttribute("id" => $clip_path_path_id);
	$path->setAttributeNS($NS{mapmaker}, "mapmaker:autogenerated" => "true");
	$path->setAttribute("d" => $self->clip_path_d());
	$path->setAttributeNS($NS{"inkscape"}, "inkscape:connector-curvature" => 0);
	$cpnode->appendChild($path);

	return $cpnode;
}

use constant POINT_X => 0;
use constant POINT_Y => 1;
use constant POINT_X_ZONE => 2;
use constant POINT_Y_ZONE => 3;

sub erase_autogenerated_map_layers {
	my ($self) = @_;
	my $doc = $self->{_svg_doc};
	foreach my $layer ($doc->findnodes("/svg:svg/svg:g[\@inkscape:groupmode=\"layer\" and \@mapmaker:autogenerated]")) {
		$layer->unbindNode();
	}
	foreach my $layer ($doc->findnodes("/svg:svg/svg:g[\@inkscape:groupmode=\"layer\" and \@mapmaker:inset-map]")) {
		$layer->unbindNode();
	}
	foreach my $layer ($doc->findnodes("/svg:svg/svg:g[\@inkscape:groupmode=\"layer\" and \@mapmaker:main-map]")) {
		$layer->unbindNode();
	}
}

sub layer_insertion_point {
	my ($self) = @_;
	my $doc = $self->{_svg_doc};
	my ($insertion_point) = $doc->findnodes(<<'END');
		/svg:svg/svg:g
			[@inkscape:groupmode="layer"]
			[not(@mapmaker:autogenerated) and
			 not(@mapmaker:inset-map) and
			 not(@mapmaker:main-map)]
END
	return $insertion_point;
}

sub map_area_layer {
	my ($self, $map_area) = @_;
	my $doc = $self->{_svg_doc};
	my $doc_elt = $doc->documentElement();
	my $insertion_point = $self->layer_insertion_point();
	my $layer_name = $map_area->{name} // ("Inset " . $map_area->{index});
	my $map_area_layer = $self->layer(name            => $layer_name,
					  writable        => 1,
					  parent          => $doc_elt,
					  insertion_point => $insertion_point);
	if ($map_area->{is_main}) {
		$map_area_layer->setAttributeNS($NS{mapmaker}, "mapmaker:main-map", "true");
	}
	else {
		$map_area_layer->setAttributeNS($NS{mapmaker}, "mapmaker:inset-map", "true");
	}
	$map_area_layer->setAttributeNS($NS{mapmaker}, "mapmaker:autogenerated", "true");
	return $map_area_layer;
}

sub background_layer {
	my ($self, $map_layer) = @_;
	my $background = $self->layer(name => "Background Color",
				      z_index => 1,
				      parent => $map_layer);
	$background->removeChildNodes();
	my $rect = $self->rectangle(x      => $self->{_svg_west},
				    y      => $self->{_svg_north},
				    width  => $self->{_svg_east} - $self->{_svg_west},
				    height => $self->{_svg_south} - $self->{_svg_north},
				    class  => "map-background");
	$background->appendChild($rect);
	return $background;
}

sub white_layer {
	my ($self, $map_layer) = @_;
	my $background = $self->layer(name => "White Background",
				      z_index => 0,
				      parent => $map_layer);
	$background->removeChildNodes();
	my $rect = $self->rectangle(x      => $self->{_svg_west},
				    y      => $self->{_svg_north},
				    width  => $self->{_svg_east} - $self->{_svg_west},
				    height => $self->{_svg_south} - $self->{_svg_north},
				    class  => "WHITE");
	$background->appendChild($rect);
	return $background;
}

sub border_layer {
	my ($self, $map_layer) = @_;
	my $border = $self->layer(name => "Border",
				  z_index => 9999,
				  parent => $map_layer);
	$border->removeChildNodes();
	my $rect = $self->rectangle(x      => $self->{_svg_west},
				    y      => $self->{_svg_north},
				    width  => $self->{_svg_east} - $self->{_svg_west},
				    height => $self->{_svg_south} - $self->{_svg_north},
				    class  => "map-border MAP_BORDER");
	$border->appendChild($rect);
	return $border;
}

sub openstreetmap_layer {
	my ($self, $map_area_layer) = @_;
	my $layer = $self->layer(name => "OpenStreetMap",
				 z_index => 100,
				 parent => $map_area_layer);
	return $layer;
}

sub transit_map_layer {
	my ($self, $map_area_layer) = @_;
	my $layer = $self->layer(name => "Transit",
				 z_index => 200,
				 parent => $map_area_layer);
	return $layer;
}

sub transit_stops_layer {
	my ($self, $map_area_layer) = @_;
	my $layer = $self->layer(name => "Transit Stops",
				 z_index => 300,
				 parent => $map_area_layer);
	return $layer;
}

# FIXME: use new gtfs structure
sub get_transit_routes {
	my ($self, $gtfs) = @_;
	my @result;
	my $dbh = $gtfs->dbh();
	my $sth;
	my $data = $gtfs->{data};
	if ($data->{routes}) {
		my $q = join(", ", map { "?" } @{$data->{routes}});
		$sth = $dbh->prepare_cached("select * from routes where route_short_name in ($q)");
		$sth->execute(@{$data->{routes}});
	} elsif ($data->{routes_except}) {
		my $q = join(", ", map { "?" } @{$data->{routes_except}});
		$sth = $dbh->prepare_cached("select * from routes where route_short_name not in ($q)");
		$sth->execute(@{$data->{routes_except}});
	} else {
		$sth = $dbh->prepare_cached("select * from routes");
		$sth->execute();
	}
	while (my $row = $sth->fetchrow_hashref()) {
		push(@result, { %$row });
	}
	$sth->finish();
	return @result;
}

sub get_transit_stops {
	my ($self, $gtfs) = @_;
	my @result;
	my $dbh = $gtfs->dbh();
	my $sth;
	my $data = $gtfs->{data};
	if ($data->{routes}) {
		my $q = join(", ", map { "?" } @{$data->{routes}});
		$sth = $dbh->prepare_cached(<<"END");
				select	distinct stops.*
				from	stops
				join	stop_times on stops.stop_id = stop_times.stop_id
				join	trips on stop_times.trip_id = trips.trip_id
				join	routes on trips.route_id = routes.route_id
				where	routes.route_short_name in ($q);
END
		$sth->execute(@{$data->{routes}});
	} elsif ($data->{routes_except}) {
		my $q = join(", ", map { "?" } @{$data->{routes_except}});
		$sth = $dbh->prepare_cached(<<"END");
				select	distinct stops.*
				from	stops
				join	stop_times on stops.stop_id = stop_times.stop_id
				join	trips on stop_times.trip_id = trips.trip_id
				join	routes on trips.route_id = routes.route_id
				where	routes.route_short_name not in ($q);
END
		$sth->execute(@{$data->{routes_except}});
	} else {
		$sth = $dbh->prepare_cached(<<"END");
				select * from stops;
END
		$sth->execute();
	}
	while (my $row = $sth->fetchrow_hashref()) {
		push(@result, { %$row });
	}
	$sth->finish();
	return @result;
}

sub get_excepted_transit_trips {
	my ($self, %args) = @_;
	my $gtfs                  = $args{gtfs};
	my $route_short_name      = $args{route};
	my $return_excluded_trips = $args{return_excluded_trips};

	my $dbh = $gtfs->dbh();

	my @exceptions;
	eval { @exceptions = @{$self->{transit_trip_exceptions}->{exceptions}}; };
	return unless scalar(@exceptions);

	if (defined $route_short_name) {
		@exceptions = grep { $_->{route} eq $route_short_name } @exceptions;
	}
	my @all_trips = ();

	my $sth = $dbh->prepare_cached(<<"END");
		select	 trips.trip_id,
			 trips.service_id,
			 trips.direction_id,
			 trips.trip_headsign,
			 trips.block_id,
		       	 trips.shape_id
		from	 routes
			 join trips on routes.route_id = trips.route_id
		where	 routes.route_short_name = ?
			 and trips.trip_headsign = ?
END
	my $sth2 = $dbh->prepare_cached(<<"END");
		-- find last stop on this trip
		select	 stop_times.arrival_time,
		         stop_times.departure_time,
                         stops.stop_id,
                         stops.stop_code,
                         stops.stop_name,
                         stops.stop_desc
		from	 stop_times
			 join stops on stop_times.stop_id = stops.stop_id
		where	 trip_id = ?
		order by stop_sequence desc
		limit	 1
END
	my $sth3 = $dbh->prepare_cached(<<"END");
		select	 trips.trip_id,
                         trips.direction_id,
                         min(stop_times.departure_time) as time,
                         trips.shape_id
		from	 trips
			 join stop_times on trips.trip_id = stop_times.trip_id
		where	 trips.block_id = ?
			 and not (trips.direction_id = ?)
			 and not (trips.trip_id = ?)
			 and trips.service_id = ?
		group by trips.trip_id
		having	 time >= ?
		order by time asc
		limit	 1
END
	my $sth4 = $dbh->prepare_cached(<<"END");
		select	 trips.trip_id,
			 trips.service_id,
			 trips.direction_id,
			 trips.trip_headsign,
			 trips.block_id,
		       	 trips.shape_id
		from	 trips join stop_times on trips.trip_id = stop_times.trip_id
                               join stops on stop_times.stop_id = stops.stop_id
			       join routes on trips.route_id = routes.route_id
		where	 routes.route_short_name = ?
                         and stops.stop_name = ?
END
	my $sth5 = $dbh->prepare_cached(<<"END");
		select	 trips.trip_id,
			 trips.service_id,
			 trips.direction_id,
			 trips.trip_headsign,
			 trips.block_id,
		       	 trips.shape_id
		from	 trips join stop_times on trips.trip_id = stop_times.trip_id
                               join stops on stop_times.stop_id = stops.stop_id
			       join routes on trips.route_id = routes.route_id
		where	 routes.route_short_name = ?
                         and stops.stop_code = ?
END
	my $sth6 = $dbh->prepare_cached(<<"END");
		select	 trips.trip_id,
			 trips.service_id,
			 trips.direction_id,
			 trips.trip_headsign,
			 trips.block_id,
		       	 trips.shape_id
		from	 trips join stop_times on trips.trip_id = stop_times.trip_id
			       join routes on trips.route_id = routes.route_id
		where	 routes.route_short_name = ?
                         and stop_times.stop_id = ?
END
	
	foreach my $exception (@exceptions) {
		if ($return_excluded_trips) {
			next unless $exception->{exclude};
		}
		else {
			next if $exception->{exclude};
		}
		my @trips;
		my $route_short_name = $exception->{route};
		my $trip_headsign    = $exception->{trip_headsign};
		my $return_trip      = $exception->{return_trip} ? 1 : 0;
		my $stop_name        = $exception->{stop_name};
		my $stop_code        = $exception->{stop_code};
		my $stop_id          = $exception->{stop_id};

		if ($route_short_name && $trip_headsign) {
			$sth->execute($route_short_name, $trip_headsign);
			while (my $hash = $sth->fetchrow_hashref()) {
				my $trip_id = $hash->{trip_id};
				my @hash = %$hash;
				push(@trips, { %$hash });
				if ($return_trip) {
					$sth2->execute($trip_id);
					my $hash2 = $sth2->fetchrow_hashref();
					$sth2->finish();
					if ($hash2) {
						my @hash2 = %$hash2;
						$sth3->execute($hash->{block_id},
							       $hash->{direction_id},
							       $hash->{trip_id},
							       $hash->{service_id},
							       $hash2->{departure_time});
						my $hash3 = $sth3->fetchrow_hashref();
						if ($hash3) {
							my @hash3 = %$hash3;
							push(@trips, { %$hash3 });
						}
						$sth3->finish();
					}
				}
			}
			$sth->finish();
		}
		elsif ($stop_name) {
			$sth4->execute($route_short_name, $stop_name);
			while (my $hash = $sth4->fetchrow_hashref()) {
				my @hash = %$hash;
				push(@trips, { %$hash });
			}
		}
		elsif ($stop_code) {
			$sth5->execute($route_short_name, $stop_code);
			while (my $hash = $sth5->fetchrow_hashref()) {
				my @hash = %$hash;
				push(@trips, { %$hash });
			}
		}
		elsif ($stop_id) {
			$sth6->execute($route_short_name, $stop_id);
			while (my $hash = $sth6->fetchrow_hashref()) {
				my @hash = %$hash;
				push(@trips, { %$hash });
			}
			$sth6->finish();
		}
		push(@all_trips, @trips);
	}

	return @all_trips;
}

sub get_shape_id_to_direction_id_map {
	my ($self, %args) = @_;
	my $gtfs  = $args{gtfs};
	my $route_short_name = $args{route};
	my $dbh = $gtfs->dbh();
	my $sth = $dbh->prepare_cached(<<"END");
		select	trips.shape_id,
			trips.direction_id
		from	routes
			join trips on routes.route_id = trips.route_id
		where	routes.route_short_name = ?
END
	$sth->execute($route_short_name);
	my %result;
	while (my ($shape_id, $direction_id) = $sth->fetchrow_array()) {
		if (exists($result{$shape_id}) && $result{$shape_id} != $direction_id) {
			warn("  shape id to direction id mapping not possible!\n");
			$sth->finish();
			return ();
		}
		else {
			$result{$shape_id} = $direction_id;
		}
	}
	$sth->finish();
	return %result;
}

sub get_transit_shape_ids_from_trip_ids {
	my ($self, %args) = @_;
	my $gtfs  = $args{gtfs};
	my @trips = @{$args{trips}};

	my $dbh = $gtfs->dbh();

	my @trip_ids  = sort { $a <=> $b } uniq map { $_->{trip_id} } @trips;
	my @shape_ids = sort { $a <=> $b } uniq map { $_->{shape_id} } @trips;
	return () unless scalar(@trip_ids) and scalar(@shape_ids);

	my $sql = <<"END";
		select	count(*)
		from	trips
		where	trips.shape_id = ?
			and not (trips.trip_id in (???));
END
	my $q = join(", ", (("?") x scalar(@trip_ids)));
	$sql =~ s{\?\?\?}{$q}g;
	my $sth = $dbh->prepare_cached($sql);

	my @result;

	foreach my $shape_id (@shape_ids) {
		$sth->execute($shape_id, @trip_ids);
		my ($count) = $sth->fetchrow_array();
		if ($count) {
			# do nothing
		}
		else {
			push(@result, $shape_id);
		}
		$sth->finish();
	}

	return @result;
}

sub get_transit_route_shape_ids {
	my ($self, $gtfs, $route_short_name) = @_;
	my $dbh = $gtfs->dbh();
	my $sth = $dbh->prepare_cached(<<"END");
		select distinct shape_id
		from trips
		join routes on trips.route_id = routes.route_id
		where route_short_name = ?
END
	$sth->execute($route_short_name);
	my @result;
	while (my ($shape_id) = $sth->fetchrow_array()) {
		push(@result, $shape_id);
	}
	$sth->finish();
	return @result;
}

sub get_transit_route_shape_points {
	my ($self, $gtfs, $shape_id) = @_;
	my $dbh = $gtfs->dbh();
	
	my $sth = $dbh->prepare_cached(<<"END");
		select shape_pt_lon, shape_pt_lat
		from shapes
		where shape_id = ?
		order by shape_pt_sequence asc
END
	$sth->execute($shape_id);
	my @result;
	while (my ($lon, $lat) = $sth->fetchrow_array()) {
		push(@result, [$lon, $lat]);
	}
	$sth->finish();
	return @result;
}

sub clear_transit_map_layers {
	my ($self) = @_;
	foreach my $map_area (@{$self->{_map_areas}}) {
		$self->update_scale($map_area);
		my $map_area_layer = $self->map_area_layer($map_area);
		my $transit_map_layer = $self->transit_map_layer($map_area_layer);
		$transit_map_layer->removeChildNodes();
	}
}

sub clear_transit_stops_layers {
	my ($self) = @_;
	foreach my $map_area (@{$self->{_map_areas}}) {
		$self->update_scale($map_area);
		my $map_area_layer = $self->map_area_layer($map_area);
		my $transit_stops_layer = $self->transit_stops_layer($map_area_layer);
		$transit_stops_layer->removeChildNodes();
	}
}

sub draw_transit_stops {
	my ($self) = @_;

	my @gtfs = $self->gtfs();
	if (!scalar(@gtfs)) { return; }

	$self->init_xml();
	$self->clear_transit_stops_layers();
	$self->stuff_all_layers_need();

       	foreach my $gtfs (@gtfs) {
		$self->diagf("Drawing transit stops for %s ... ", $gtfs->{data}->{name});

		my @stops = $self->get_transit_stops($gtfs);
		
		my $class        = "transit-stop";
		my $class_2      = "transit-stop_2";
		my $has_style_2  = $self->has_style_2(class => $class);
		my $r   = $self->get_style_property(class => $class,
						    property => "r") // 1.0;
		my $r_2 = $self->get_style_property(class => $class,
						    style_attr_name => "style_2",
						    property => "r") // 0.5;
	
		foreach my $map_area (@{$self->{_map_areas}}) {
			$self->update_scale($map_area);
			my $svg_west  = $self->{_svg_west};
			my $svg_east  = $self->{_svg_east};
			my $svg_north = $self->{_svg_north};
			my $svg_south = $self->{_svg_south};
		
			my $map_area_layer = $self->map_area_layer($map_area);
			my $transit_stops_layer = $self->transit_stops_layer($map_area_layer);
			my $clipped_group = $self->clipped_group(parent => $transit_stops_layer,
								 clip_path_id => $map_area->{clip_path_id});

			my $plot = sub {
				my ($stop, $class, $r) = @_;
				my $stop_id   = $stop->{stop_id};
				my $stop_code = $stop->{stop_code};
				my $stop_name = $stop->{stop_name};
				my $stop_desc = $stop->{stop_desc};
				my $lat       = $stop->{stop_lat};
				my $lon       = $stop->{stop_lon};
				my $title = join(" - ", grep { $_ } ($stop_code, $stop_name, $stop_desc));
				my $x = $self->lon2x($lon);
				my $y = $self->lat2y($lat);
				return if $x < $svg_west  || $x > $svg_east;
				return if $y < $svg_north || $y > $svg_south;
				my $circle = $self->{_svg_doc}->createElementNS($NS{"svg"}, "circle");
				$circle->setAttribute("cx", $x);
				$circle->setAttribute("cy", $y);
				$circle->setAttribute("class", $class);
				$circle->setAttribute("r", $r);
				$circle->setAttribute("title", $title) if $title;
				$clipped_group->appendChild($circle);
			};
		
			foreach my $stop ($self->get_transit_stops($gtfs)) {
				$plot->($stop, $class, $r);
			}
			if ($has_style_2) {
				foreach my $stop ($self->get_transit_stops($gtfs)) {
					$plot->($stop, $class_2, $r_2);
				}
			}
		}
		$self->diag("done.\n");
	}
}

sub draw_transit_routes {
	my ($self, @routes) = @_;

	my @gtfs = $self->gtfs();
	if (!scalar(@gtfs)) { return; }

	$self->init_xml();
	$self->clear_transit_map_layers();
	$self->stuff_all_layers_need();

	my %route_group_by_name;
	foreach my $group (@{$self->{transit_route_groups}}) {
		$route_group_by_name{$group->{name}} = $group if defined $group->{name};
		$route_group_by_name{$group->{id}}   = $group if defined $group->{id};
	}
	
	my $exceptions_group_name = eval { $self->{transit_trip_exceptions}->{group} };
	my $exceptions_group;
	my $exceptions_class;  
	my $exceptions_class_2;
	if (defined $exceptions_group_name) {
		$exceptions_group = $route_group_by_name{$exceptions_group_name};
	}
	if (defined $exceptions_group) {
		$exceptions_class   = $exceptions_group->{class};
		$exceptions_class_2 = $exceptions_group->{class} . "_2";
	}

	my %shape_direction_id;	
	my %shape_excepted;	
	my %shape_excluded;	
	my %route_shape_id;	
	my %shape_coords;       
	my %shape_svg_coords;   
	my %route_group;        

	$self->diag("Gathering and converting route coordinates...\n");
	foreach my $gtfs (@gtfs) {
		my $agency_id = $gtfs->{data}{agency_id};
		foreach my $route ($self->get_transit_routes($gtfs)) {
			my $route_short_name = $route->{route_short_name};
			my $agency_route = $agency_id . "/" . $route_short_name;
			my $route_long_name = $route->{route_long_name};
			my $route_desc = $route->{route_desc};
			my $route_name = $route->{name} = join(" - ", grep { $_ } ($route_short_name, $route_long_name));
			my $route_title = $route->{title} = join(" - ", grep { $_ } ($route_short_name, $route_long_name, $route_desc));
			my $route_color = $route->{route_color};
			if ($route_color) {
				$route_color = "#" . lc($route_color);
			}

			next if scalar(@routes) && !grep { $_ eq $route_short_name } @routes;

			$self->diagf("  Route $agency_id $route_short_name - $route_title ...\n");
			
			my %s2d = $self->get_shape_id_to_direction_id_map(gtfs => $gtfs, route => $route_short_name);
			while (my ($shape_id, $direction_id) = each(%s2d)) {
				$shape_direction_id{$agency_route}{$shape_id} = $direction_id;
			}
			
			my @shape_id = $self->get_transit_route_shape_ids($gtfs, $route_short_name);
			$route_shape_id{$agency_route} = [@shape_id];

			my @excepted_trips = $self->get_excepted_transit_trips(gtfs => $gtfs, route => $route_short_name);
			my @excluded_trips = $self->get_excepted_transit_trips(gtfs => $gtfs, route => $route_short_name, return_excluded_trips => 1);
			my @excepted_shape_id = $self->get_transit_shape_ids_from_trip_ids(gtfs => $gtfs, trips => \@excepted_trips);
			my @excluded_shape_id = $self->get_transit_shape_ids_from_trip_ids(gtfs => $gtfs, trips => \@excluded_trips);
			$shape_excepted{$agency_route}{$_} = 1 foreach @excepted_shape_id;
			$shape_excluded{$agency_route}{$_} = 1 foreach @excluded_shape_id;

			my $route_group_name_source = ($self->{transit_route_overrides}->{$route_short_name} //
						       $self->{orig_transit_route_color_mapping}->{$route_color} //
						       $self->{transit_route_defaults});
			my $route_group_name        = $route_group_name_source->{group};
			my $route_group             = $route_group_by_name{$route_group_name};
			next unless $route_group;
			$route_group{$agency_route} = $route_group;

			foreach my $map_area (@{$self->{_map_areas}}) {
				my $map_area_index = $map_area->{index};
				$self->update_scale($map_area);
				my $svg_west  = $self->{_svg_west};
				my $svg_east  = $self->{_svg_east};
				my $svg_north = $self->{_svg_north};
				my $svg_south = $self->{_svg_south};
				foreach my $shape_id (@shape_id) {
					my @coords = $self->get_transit_route_shape_points($gtfs, $shape_id);
					$shape_coords{$agency_route}{$shape_id} = [@coords];
					my @svg_coords = map {
						my $svgx = $self->lon2x($_->[0]);
						my $svgy = $self->lat2y($_->[1]);
						my $xzone = ($svgx <= $svg_west)  ? -1 : ($svgx >= $svg_east)  ? 1 : 0;
						my $yzone = ($svgy <= $svg_north) ? -1 : ($svgy >= $svg_south) ? 1 : 0;
						[ $svgx, $svgy, $xzone, $yzone ];
					} @coords;
					if (all { $_->[POINT_X_ZONE] == -1 } @svg_coords) { next; }
					if (all { $_->[POINT_X_ZONE] ==  1 } @svg_coords) { next; }
					if (all { $_->[POINT_Y_ZONE] == -1 } @svg_coords) { next; }
					if (all { $_->[POINT_Y_ZONE] ==  1 } @svg_coords) { next; }
					foreach (@svg_coords) { splice(@$_, 2); }
					$shape_svg_coords{$map_area_index}{$agency_route}{$shape_id} = \@svg_coords;
				}
			}
		}
	}

	$self->diag("Handling user-defined overlaps...\n");
	foreach my $overlap (@{$self->{transit_route_fix_overlaps}}) {
		my $separation = $overlap->{separation} // 1.0;
		my $direction   = $overlap->{direction}   // 0;
		my $direction_2 = $direction;
		if ($direction eq "left") {
			$direction_2 = "right";
		}
		elsif ($direction eq "right") {
			$direction_2 = "left";
		}
		my $agency_route_A = $overlap->{route_A}; # this route stays
		my $agency_route_B = $overlap->{route_B}; # this route gets moved over
		next unless defined $agency_route_A;
		next unless defined $agency_route_B;
		$self->diag("  overlap $agency_route_A $agency_route_B...");
		my $north = $overlap->{north};
		my $south = $overlap->{south};
		my $east  = $overlap->{east};
		my $west  = $overlap->{west};
		foreach my $map_area (@{$self->{_map_areas}}) {
			my $map_area_index = $map_area->{index};
			$self->update_scale($map_area);
			my $svg_north = defined $north ? $self->lat2y($north) : undef;
			my $svg_south = defined $south ? $self->lat2y($south) : undef;
			my $svg_east  = defined $east  ? $self->lon2x($east)  : undef;
			my $svg_west  = defined $west  ? $self->lon2x($west)  : undef;
			foreach my $shape_id_B (keys(%{$shape_svg_coords{$map_area_index}{$agency_route_B}})) {
				foreach my $shape_id_A (keys(%{$shape_svg_coords{$map_area_index}{$agency_route_A}})) {
					move_line_away($svg_north, $svg_south, $svg_east, $svg_west,
						       $separation,
						       $direction,
						       $shape_svg_coords{$map_area_index}{$agency_route_B}{$shape_id_B},
						       $shape_svg_coords{$map_area_index}{$agency_route_A}{$shape_id_A});
				}
			}
		}
		$self->diag("done.\n");
	}
	$self->diag("Done with overlaps.\n");

	$self->diag("Drawing routes...\n");
	foreach my $gtfs (@gtfs) {
		my $agency_id = $gtfs->{data}{agency_id};
		foreach my $route ($self->get_transit_routes($gtfs)) {
			my $route_short_name = $route->{route_short_name};
			my $agency_route = $agency_id . "/" . $route_short_name;
			my $route_name = $route->{route_name};
			my @shape_id = @{$route_shape_id{$agency_route}};
			foreach my $map_area (@{$self->{_map_areas}}) {
				my $map_area_index = $map_area->{index};
				$self->update_scale($map_area);

				my $map_area_layer = $self->map_area_layer($map_area);
				my $transit_map_layer = $self->transit_map_layer($map_area_layer);

				foreach my $shape_id (@shape_id) {

					my @svg_coords = @{$shape_svg_coords{$map_area_index}{$agency_route}{$shape_id}};
					my $route_group;
					if ($shape_excluded{$agency_route}{$shape_id}) {
						next;
					}
					elsif ($shape_excepted{$agency_route}{$shape_id}) {
						$route_group = $exceptions_group;
					}
					else {
						$route_group = $route_group{$agency_route};
					}
					next unless $route_group;
					my $route_group_class = $route_group->{class};

					my $class   = "${route_group_class} route_${agency_id} route_${route_short_name}";
					my $class_2 = "${route_group_class}_2 route_${agency_id}_2 route_${route_short_name}_2";
					
					my $route_group_layer = $self->layer(name    => $route_group->{name},
									     z_index => $route_group->{index},
									     parent  => $transit_map_layer);
					my $route_layer = $self->layer(name => $route_name,
								       parent => $route_group_layer);
					my $clipped_group = $self->clipped_group(parent => $route_layer,
										 clip_path_id => $map_area->{clip_path_id});
					my $polyline = $self->polyline(points => \@svg_coords, class => $class);
					$clipped_group->appendChild($polyline);
					if ($self->has_style_2(class => $class)) {
						my $polyline_2 = $self->polyline(points => \@svg_coords, class => $class_2);
						$clipped_group->appendChild($polyline_2);
					}
				}
			}
		}
	}
	$self->diag("Done.\n");
}

sub update_styles {
	my ($self) = @_;
	$self->init_xml();
	foreach my $map_area (@{$self->{_map_areas}}) {
		$self->update_scale($map_area); # don't think this is necessary, but . . .
		$self->style_node();
	}
}

sub stuff_all_layers_need {
	my ($self) = @_;
	
	foreach my $map_area (@{$self->{_map_areas}}) {
		$self->update_scale($map_area);
		my $map_area_layer = $self->map_area_layer($map_area);
		$self->clip_path($map_area);
		$self->white_layer($map_area_layer);
		$self->background_layer($map_area_layer);
		$self->style_node();
		$self->border_layer($map_area_layer);
	}
}

sub draw_openstreetmap_maps {
	my ($self, $some) = @_;

	$self->init_xml();

	my %index_tag;
	foreach my $info (@{$self->{osm_layers}}) {
		$info->{tags} = $self->normalize_tags($info->{tags});
		foreach my $tag (@{$info->{tags}}) {
			$index_tag{$tag->{k}} = 1;
		}
	}

	$self->stuff_all_layers_need();
	
	foreach my $map_area (@{$self->{_map_areas}}) {
		$self->update_scale($map_area);
		my $map_area_layer = $self->map_area_layer($map_area);
		my $clip_path_id = $map_area->{clip_path_id};
		my $osm_layer = $self->openstreetmap_layer($map_area_layer);
		foreach my $info (@{$self->{osm_layers}}) {
			my $layer = $self->layer(name => $info->{name},
						 parent => $osm_layer);
			my $group = $self->clipped_group(parent => $layer, clip_path_id => $clip_path_id);
			$group->removeChildNodes();
			$info->{_map_area_layer} //= [];
			$info->{_map_area_group} //= [];
			push(@{$info->{_map_area_layer}}, $layer);
			push(@{$info->{_map_area_group}}, $group);
		}
	}

	my %unused;
	my $num_maps = scalar(@{$self->{_map_xml_filenames}});
	my $map_number = 0;
	
	foreach my $filename (@{$self->{_map_xml_filenames}}) {
		$map_number += 1;

		$self->diag("($map_number/$num_maps) Parsing $filename ... ");
		my $doc = $self->{_parser}->parse_file($filename);
		$self->diag("done.\n");

		$self->diag("  Finding <node> elements ... ");
		my @nodes = $doc->findnodes("/osm/node");
		my %nodes;
		$self->diag(scalar(@nodes) . " elements found.\n");
		foreach my $map_area (@{$self->{_map_areas}}) {
			$self->update_scale($map_area);
			my $index = $map_area->{index};
			my $area_name = $map_area->{name};
			$self->diag("    Indexing for map area $area_name ... ");
			my $svg_west  = $self->{_svg_west};
			my $svg_east  = $self->{_svg_east};
			my $svg_north = $self->{_svg_north};
			my $svg_south = $self->{_svg_south};
			foreach my $node (@nodes) {
				my $id  = $node->getAttribute("id");
				my $lat = 0 + $node->getAttribute("lat");
				my $lon = 0 + $node->getAttribute("lon");
				my $svgx = $self->lon2x($lon);
				my $svgy = $self->lat2y($lat);
				my $xzone = ($svgx <= $svg_west)  ? -1 : ($svgx >= $svg_east)  ? 1 : 0;
				my $yzone = ($svgy <= $svg_north) ? -1 : ($svgy >= $svg_south) ? 1 : 0;
				my $result = [$svgx, $svgy, $xzone, $yzone];
				$nodes{$id}[$index] = $result;
			}
			$self->diag("done.\n");
		}
		$self->diag("done.\n");

		$self->diag("  Finding <way> elements ... ");
		my @ways;


		if ($some) {
			my %exclude = (railway => 1,
				       highway => [qw(residential living_street path)]);
			my @exclude;
			while (my ($k, $v) = each(%exclude)) {
				if ($v && !ref($v)) {
					push(@exclude, "\@k='$k'");
				}
				elsif (ref($v) eq "ARRAY") {
					my $or = join(" or ", map { "\@v='$_'" } @$v);
					push(@exclude, "\@k='$k' and ($or)");
				}
			}
			my $not = join(" and ", map { "not(tag[$_])" } @exclude);
			my $xpath = "/osm/way[$not]";
			print STDERR "$xpath\n";
			@ways = $doc->findnodes($xpath);
		}
		else {
			@ways = $doc->findnodes("/osm/way");
		}
		my %ways;
		my %ways_index_k;
		my %ways_index_kv;
		$self->diag(scalar(@ways) . " elements found; indexing ... ");
		foreach my $way (@ways) {
			my $id = $way->getAttribute("id");
			my @nodeid = map { $_->getAttribute("ref"); } $way->findnodes("nd");
			my $closed = (scalar(@nodeid)) > 2 && ($nodeid[0] == $nodeid[-1]);
			pop(@nodeid) if $closed;

			my $result = { id     => $id,
				       nodeid => \@nodeid,
				       closed => $closed,
				       points => [],
				       tags   => {}
				     };
			$ways{$id} = $result;
			
			my @tag = $way->findnodes("tag");
			foreach my $tag (@tag) {
				my $k = $tag->getAttribute("k");
				my $v = $tag->getAttribute("v");
				next unless $index_tag{$k};
				push(@{$ways_index_k{$k}}, $result);
				push(@{$ways_index_kv{$k, $v}}, $result);
				$result->{tags}->{$k} = $v;
			}
		}
		$self->diag("done.\n");

		foreach my $map_area (@{$self->{_map_areas}}) {
			$self->update_scale($map_area);
			my $index = $map_area->{index};
			my $area_name = $map_area->{name};
			$self->diag("    Indexing for map area $area_name ... ");
			foreach my $way (@ways) {
				my $id = $way->getAttribute("id");
				my @nodeid = @{$ways{$id}{nodeid}};
				my @points = map { $nodes{$_}[$index] } @nodeid;
				$ways{$id}{points}[$index] = \@points;
			}
			$self->diag("done.\n");
		}
		
		foreach my $map_area (@{$self->{_map_areas}}) {
			$self->update_scale($map_area);
			my $index = $map_area->{index};
			my $area_name = $map_area->{name};
			$self->diag("Adding objects for map area $area_name ...\n");

			foreach my $info (@{$self->{osm_layers}}) {
				my $name = $info->{name};
				my $tags = $info->{tags};
				my $class = $info->{class};
				my $group = $info->{_map_area_group}[$index];

				my @ways;
				foreach my $tag (@$tags) {
					my $k = $tag->{k};
					my $v = $tag->{v};
					if (defined $v) {
						eval { push(@ways, @{$ways_index_kv{$k, $v}}); };
					} else {
						eval { push(@ways, @{$ways_index_k{$k}}); };
					}
				}
				@ways = uniq @ways;
				$self->diagf("\r  %-77.77s", 
					     sprintf("%s (%s objects) ...",
						     $name, scalar(@ways)));

				my $options = {};
				if ($map_area->{scale_stroke_width} && exists $map_area->{zoom}) {
					$options->{scale} = $map_area->{zoom};
				}

				my $open_class     = "OPEN " . $info->{class};
				my $closed_class   =           $info->{class};
				my $open_class_2   = "OPEN " . $info->{class} . "_2";
				my $closed_class_2 =           $info->{class} . "_2";
				
				foreach my $way (@ways) {
					$way->{used} = 1;
					my $points = $way->{points}[$index];

					if (all { $_->[POINT_X_ZONE] == -1 } @$points) { next; }
					if (all { $_->[POINT_X_ZONE] ==  1 } @$points) { next; }
					if (all { $_->[POINT_Y_ZONE] == -1 } @$points) { next; }
					if (all { $_->[POINT_Y_ZONE] ==  1 } @$points) { next; }

					if ($way->{closed}) {
						my $polygon = $self->polygon(points => $points,
									     class => $closed_class);
						$group->appendChild($polygon);
						if ($self->has_style_2(class => $class)) {
							my $polygon_2 = $self->polygon(points => $points,
										       class => $closed_class_2);
							$group->appendChild($polygon_2);
						}
					} else {
						my $polyline = $self->polyline(points => $points,
									       class => $open_class);
						$group->appendChild($polyline);
						if ($self->has_style_2(class => $class)) {
							my $polyline_2 = $self->polyline(points => $points,
											 class => $open_class_2);
							$group->appendChild($polyline_2);
						}
					}
				}
			}

			$self->diag("\ndone.\n");
		}

		foreach my $k (keys(%ways_index_k)) {
			my @unused = grep { !$_->{used} } @{$ways_index_k{$k}};
			foreach my $v (map { $_->{tags}->{$k} } @unused) {
				$unused{$k,$v} += 1;
			}
		}
	}

	print("You may also want to include...\n");
	foreach my $kv (sort keys %unused) {
		my ($k, $v) = split($;, $kv);
		my $n = $unused{$kv};
		printf("  { %-25s %-25s } # %6d objects\n",
		       "k: '$k',",
		       "v: '$v'",
		       $n);
	}
}

sub polygon {
	my ($self, %args) = @_;
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	$path->setAttribute("d", $self->points_to_path(1, @{$args{points}}));
	$path->setAttribute("class", $args{class});
	return $path;
}

sub polyline {
	my ($self, %args) = @_;
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	$path->setAttribute("d", $self->points_to_path(0, @{$args{points}}));
	$path->setAttribute("class", $args{class});
	return $path;
}

sub points_to_path {
	my ($self, $closed, @points) = @_;
	my @coords = map { [ int($_->[POINT_X] * 100 + 0.5) / 100,
			     int($_->[POINT_Y] * 100 + 0.5) / 100 ] } @points;
	my $result = sprintf("m %.2f,%.2f", @{$coords[0]});
	for (my $i = 1; $i < scalar(@coords); $i += 1) {
		$result .= sprintf(" %.2f,%.2f", 
				   $coords[$i][POINT_X] - $coords[$i - 1][POINT_X],
				   $coords[$i][POINT_Y] - $coords[$i - 1][POINT_Y]);
	}
	$result .= " z" if $closed;
	return $result;
}

sub normalize_tags {
	my ($self, $tags) = @_;
	$tags ||= [];
	if (ref($tags) ne "ARRAY") {
		$tags = [$tags];
	}
	my $limit = "";
	if (scalar(@$tags)) {
		my $tag;
		foreach $tag (@$tags) {
			if (ref($tag) ne "HASH") {
				$tag = { k => $tag };
			}
		}
	}
	return $tags;
}

sub clipped_group {
	my ($self, %args) = @_;
	my $clip_path_id = $args{clip_path_id};
	my $parent = $args{parent};

	if ($parent) {
		my ($group) = $parent->findnodes("svg:g[\@clip-path='url(#${clip_path_id})' and \@clip-rule='nonzero']");
		return $group if $group;
	}

	my $group = $self->{_svg_doc}->createElementNS($NS{"svg"}, "g");
	$group->setAttribute("clip-path" => "url(#${clip_path_id})");
	$group->setAttribute("clip-rule" => "nonzero");
	if ($parent) {
		$parent->appendChild($group);
	}
	return $group;
}

sub layer {
	my ($self, %args) = @_;
	my $insertion_point = $args{insertion_point};
	my $name = $args{name};
	my $parent = $args{parent};
	my $z_index = $args{z_index};
	my $writable = $args{writable};
	my $id = $args{id};
	my $no_create = $args{no_create};
	
	if (defined $parent) {
		if (defined $id) {
			my ($existing) = $parent->findnodes("svg:g[\@id='$id']");
			return $existing if $existing;
		}
		if (defined $name) {
			my ($existing) = $parent->findnodes("svg:g[\@inkscape:label='$name']");
			return $existing if $existing;
		}
	}

	return if $args{no_create};

	my $layer = $self->{_svg_doc}->createElementNS($NS{"svg"}, "g");
	$layer->setAttributeNS($NS{"inkscape"}, "inkscape:groupmode", "layer");
	$layer->setAttributeNS($NS{"inkscape"}, "inkscape:label", $name) if defined $name;
	$layer->setAttributeNS($NS{"mapmaker"}, "mapmaker:z-index", $z_index) if defined $z_index;
	$layer->setAttributeNS($NS{"sodipodi"}, "sodipodi:insensitive", $writable ? "true" : "false");

	if (defined $parent) {
		if ($insertion_point) {
			$parent->insertBefore($layer, $insertion_point);
			return $layer;
		}
		if (defined $z_index) {
			my @below = $parent->findnodes("svg:g[\@inkscape:groupmode='layer' and \@mapmaker:z-index and \@mapmaker:z-index < $z_index]");
			if (scalar(@below)) {
				$parent->insertAfter($layer, $below[-1]);
				return $layer;
			}
			my @above = $parent->findnodes("svg:g[\@inkscape:groupmode='layer' and \@mapmaker:z-index and \@mapmaker:z-index > $z_index]");
			if (scalar(@above)) {
				$parent->insertBefore($layer, $above[0]);
				return $layer;
			}
		}
		$parent->appendChild($layer);
		return $layer;
	}

	return $layer;
}

sub rectangle {
	my ($self, %args) = @_;
	my $left   = $args{x};
	my $right  = $args{x} + $args{width};
	my $top    = $args{y};
	my $bottom = $args{y} + $args{height};
	my $d = sprintf("M %f %f H %f V %f H %f Z",
			$left, $top, $right, $bottom, $left);
	my $path = $self->{_svg_doc}->createElementNS($NS{svg}, "path");
	$path->setAttribute("d", $d);
	$path->setAttribute("class",  $args{class});
	return $path;
	
	my $rect = $self->{_svg_doc}->createElementNS($NS{"svg"}, "rect");
	$rect->setAttribute("x",      $args{x});
	$rect->setAttribute("y",      $args{y});
	$rect->setAttribute("width",  $args{width});
	$rect->setAttribute("height", $args{height});
	$rect->setAttribute("class",  $args{class});
	return $rect;
}

###############################################################################

sub get_style_hashes {
	my ($self, %args) = @_;
	my $class           = $args{class};
	my $style_attr_name = $args{style_attr_name} // "style";

	my @class = (ref($class) eq "ARRAY") ? @$class : ($class);
	@class = grep { /\S/ } map { split(/\s+/, $_) } @class;

	my @style;
	foreach my $class (@class) {
		my $hash;
		eval { $hash = $self->{classes}->{$class}->{$style_attr_name}; };
		if ($hash) {
			if (wantarray) {
				push(@style, $hash);
			}
			else {
				return $hash;
			}
		}
	}
	if (wantarray) {
		return @style;
	}
	else {
		return;
	}
}

sub compose_style_hash {
	my ($self, %args) = @_;
	my $style_attr_name = $args{style_attr_name} // "style";
	my $class           = $args{class};
	my %style           = $args{style} ? %{$args{style}} : ();
	
	my @class = (ref($class) eq "ARRAY") ? @$class : ($class);
	@class = grep { /\S/ } map { split(/\s+/, $_) } @class;

	my @hash = $self->get_style_hashes(class => $class,
					   style_attr_name => $style_attr_name);
	foreach my $hash (@hash) {
		if ($hash) {
			%style = (%style, %$hash);
		}
	}

	if (scalar(keys(%style))) {
		if ($args{open}) {
			$style{"fill"}              = "none";
			$style{"stroke-linecap"}  //= "round";
			$style{"stroke-linejoin"} //= "round";
		}
		if ($args{scale} && exists $style{"stroke-width"}) {
			$style{"stroke-width"} *= $args{scale};
		}
	}
	return \%style;
}

sub get_style_property {
	my ($self, %args) = @_;
	my $hash = $self->compose_style_hash(%args);
	return $hash->{$args{property}};
}

sub has_style_2 {
	my ($self, %args) = @_;
	my $class = $args{class};
	return scalar($self->get_style_hashes(class => $class, style_attr_name => "style_2")) ? 1 : 0;
}

sub compose_style_string {
	my ($self, %args) = @_;
	my $style = $self->compose_style_hash(%args);
	return join(";",
		    map { $_ . ":" . $style->{$_} }
		    sort  
		    grep { $_ ne "r" }
		    keys %$style);
}

###############################################################################

sub gtfs {
	my ($self, $hash_list) = @_;
	if ($hash_list) {
		my $gtfs_list = $self->{_gtfs_list} = [];
		my $index = 0;
		foreach my $hash (@$hash_list) {
			my $url = $hash->{url};
			my $gtfs = Geo::GTFS->new($url);
			$hash->{index} = $index;
			$hash->{name} //= $hash->{index};
			$gtfs->{data} = $hash;
			push(@$gtfs_list, $gtfs);
			$index += 1;
		}
		return @{$self->{_gtfs_list}};
	}
	else {
		return @{$self->{_gtfs_list}};
	}
}

###############################################################################

sub remove_grid {
	my ($self) = @_;
	foreach my $map_area (@{$self->{map_areas}}) {
		my $map_area_layer = $self->map_area_layer($map_area);
		my $grid_layer = $self->layer(name => "Grid",
					      z_index => 9998,
					      parent => $map_area_layer,
					      no_create => 1);
		if ($grid_layer) {
			$grid_layer->unbindNode();
		}
	}
}

sub draw_grid {
	my ($self) = @_;
	my $grid = $self->{grid};
	if (!$grid) { return; }

	$self->init_xml();

	my $increment = $grid->{increment} // 0.01;
	my $format = $grid->{format};
	my $doc = $self->{_svg_doc};

	$self->stuff_all_layers_need();

	my $class = $grid->{class};
	my $text_class   = "GRID_TEXT " . $grid->{"text-class"};
	my $text_2_class = "GRID_TEXT " . $grid->{"text-2-class"};

	foreach my $map_area (@{$self->{_map_areas}}) {
		$self->update_scale($map_area);
		my $map_area_layer = $self->map_area_layer($map_area);
		my $grid_layer = $self->layer(name => "Grid",
					      z_index => 9998,
					      parent => $map_area_layer);
		$grid_layer->removeChildNodes();
		my $clipped_group = $self->clipped_group(parent => $grid_layer,
							 clip_path_id => $map_area->{clip_path_id});

		my $south = $self->{south}; my $ys = $self->lat2y($south);
		my $north = $self->{north}; my $yn = $self->lat2y($north);
		my $east = $self->{east};   my $xe = $self->lon2x($east);
		my $west = $self->{west};   my $xw = $self->lon2x($west);

		for (my $lat = int($south / $increment) * $increment; $lat <= $north; $lat += $increment) {
			my $lat_text = sprintf($format, $lat);
			my $y = $self->lat2y($lat);

			my $path = $doc->createElementNS($NS{"svg"}, "path");
			$path->setAttribute("d", "M $xw,$y $xe,$y");
			$path->setAttribute("class", $class);
			$clipped_group->appendChild($path);

			for (my $lon = (int($west / $increment) + 0.5) * $increment; $lon <= $east; $lon += $increment) {
				my $x = $self->lon2x($lon);
				my $text_node = $self->text_node(x => $x, y => $y, class => $text_2_class, text => $lat_text);
				$clipped_group->appendChild($text_node);
			}
			# foreach my $x ($xw + 18, $xe - 18) {
			# 	my $text_node = $self->text_node(x => $x, y => $y, class => $text_class, text => $lat_text);
			# 	$clipped_group->appendChild($text_node);
			# }
		}

		for (my $lon = int($west / $increment) * $increment; $lon <= $east; $lon += $increment) {
			my $lon_text = sprintf($format, $lon);
			my $x = $self->lon2x($lon);

			my $path = $doc->createElementNS($NS{"svg"}, "path");
			$path->setAttribute("d", "M $x,$ys $x,$yn");
			$path->setAttribute("class", $class);
			$clipped_group->appendChild($path);

			for (my $lat = (int($south / $increment) + 0.5) * $increment; $lat <= $north; $lat += $increment) {
				my $y = $self->lat2y($lat);
				my $text_node = $self->text_node(x => $x, y => $y, class => $text_2_class, text => $lon_text);
				$clipped_group->appendChild($text_node);
			}
			# foreach my $y ($ys - 2, $yn + 8) {
			# 	my $text_node = $self->text_node(x => $x, y => $y, class => $text_class, text => $lon_text);
			# 	$clipped_group->appendChild($text_node);
			# }
		}
	}
}

sub text_node {
	print STDERR (".");
	my ($self, %args) = @_;
	my $x = $args{x};
	my $y = $args{y};
	my $text = $args{text};
	my $class = $args{class};
	my $doc = $self->{_svg_doc};
	my $text_node = $doc->createElementNS($NS{"svg"}, "text");
	$text_node->setAttribute("x", $x);
	$text_node->setAttribute("y", $y);
	$text_node->setAttribute("class", $class);
	my $tspan_node = $doc->createElementNS($NS{"svg"}, "tspan");
	$tspan_node->setAttribute("x", $x);
	$tspan_node->setAttribute("y", $y);
	$tspan_node->appendText($text);
	$text_node->appendChild($tspan_node);
	return $text_node;
}

###############################################################################

sub find_chunks {
	my @paths = @_;

	my @chunks = ();
	my $chunk_id_counter = -1;

	my %which_chunk_id = ();
	# {A, B} => [id, 1]
	# {B, A} => [id, -1]

	my $working_chunk_id;
	my $working_chunk;

	local $" = ", ";

	my $work_on_new_chunk = sub {
		my @points = @_;
		$chunk_id_counter += 1;
		$working_chunk_id = $chunk_id_counter;
		$working_chunk = $chunks[$working_chunk_id] = [@points];
		for (my $i = 0; $i < scalar(@points) - 1; $i += 1) {
			my $A = $points[$i];
			my $B = $points[$i + 1];
			$which_chunk_id{$A, $B} = [$working_chunk_id, 1];
			$which_chunk_id{$B, $A} = [$working_chunk_id, -1];
		}
	};
	my $work_on_existing_chunk = sub {
		my ($chunk_id, $direction) = @_;
		$direction //= 1;
		if ($direction == 1) {
			$working_chunk_id = $chunk_id;
			$working_chunk = $chunks[$chunk_id];
		}
		elsif ($direction == -1) {
			$working_chunk_id = $chunk_id;
			$working_chunk = $chunks[$chunk_id];
			@{$chunks[$chunk_id]} = reverse @{$chunks[$chunk_id]};
			my @k = keys(%which_chunk_id);
			foreach my $k (@k) {
				if ($which_chunk_id{$k}[0] == $chunk_id) {
					$which_chunk_id{$k}[1] *= -1;
				}
			}
		}
	};
	my $append_to_working_chunk = sub {
		my @points = @_;
		my $A;
		foreach my $B (@points) {
			$A //= $working_chunk->[-1];
			push(@{$working_chunk}, $B);
			$which_chunk_id{$A, $B} = [$working_chunk_id, 1];
			$which_chunk_id{$B, $A} = [$working_chunk_id, -1];
			$A = $B;
		}
	};

	for (my $i = 0; $i < scalar(@paths); $i += 1) {
		my $path = $paths[$i];
		$working_chunk_id = undef;
		$working_chunk = undef;
		for (my $j = 0; $j < scalar(@$path) - 1; $j += 1) {
			my $A = $path->[$j];
			my $B = $path->[$j + 1];
			if (!defined $working_chunk_id) {
				# start of path is segment A-B
				my ($chunk_id, $direction) = eval { @{$which_chunk_id{$A, $B}} };
				my $chunk = defined($chunk_id) ? $chunks[$chunk_id] : undef;
				if (!defined $chunk_id) {
					$work_on_new_chunk->($A, $B);
				} elsif ($direction == 1) {
					# existing chunk contains A-B segment
					my $A_index = firstidx { $_ == $A } @$chunk;
					if ($A_index == 0) {
						# existing chunk starts with A-B
						$work_on_existing_chunk->($chunk_id);
					} else {
						# existing chunk has segments before A-B
						# split it into      ...-A and A-B-...
						#               (existing)     (new chunk)
						my @new_chunk = ($A, splice(@{$chunks[$chunk_id]}, $A_index + 1));
						$work_on_new_chunk->(@new_chunk);
						# working chunk is now A-B-...
					}
				} elsif ($direction == -1) {
					# existing chunk contains B-A segment
					my $B_index = firstidx { $_ == $B } @$chunk;
					if ($B_index == scalar(@{$chunks[$chunk_id]}) - 2) {
						# existing chunk ends at B-A
						$work_on_existing_chunk->($chunk_id, -1);
						# working chunk is now A-B-...
					}
					else {
						# existing chunk has segments after B-A
						# split it into ...-B-A and A-...
						#                 (new)     (existing)
						my @new_chunk = (splice(@{$chunks[$chunk_id]}, 0, $B_index + 1), $A);
						$work_on_new_chunk->(reverse @new_chunk);
						# working chunk is now A-B-...
					}
				}
			} else {
				# path: ...-Z-A-B-...
				# working chunk has ...-Z-A-...
				my ($chunk_id, $direction) = eval { @{$which_chunk_id{$A, $B}} };
				if (!defined $chunk_id) {
					# no existing chunk has A-B (or B-A) segment
					if ($working_chunk->[-1] == $A) {
						# working chunk ends with A
						$append_to_working_chunk->($B);
					} else {
						my $A_index = firstidx { $_ == $A } @$working_chunk;
						# working chunk has stuff after A.
						# split it into      ...-A and A-...
						#               (existing)     (new)
						my @new_chunk = ($A, splice(@$working_chunk, $A_index + 1));
						$work_on_new_chunk->(@new_chunk);
						$work_on_new_chunk->($A, $B);
					}
				} elsif ($direction == 1) {
					# an existing chunk has A-B segment
					if ($working_chunk_id == $chunk_id) {
						# current working chunk is existing chunk so it has ...-Z-A-B-...
						$work_on_existing_chunk->($chunk_id);
					} else {
						# working chunk has ...-Z-A-...
						# existing chunk has ...-A-B-...
						$work_on_existing_chunk->($chunk_id);
					}
				} else {
					# an existing chunk has B-A segment
					if ($working_chunk_id == $chunk_id) {
						# current working chunk with ...-Z-A-...
						# is same as existing chunk with ...-B-A-Z-...
						$work_on_existing_chunk->($chunk_id, -1);
					} else {
						# working chunk has ...-Z-A-...
						# existing chunk has ...-B-A-...
						$work_on_existing_chunk->($chunk_id, -1);
					}
				}
			}
		}
	}
	return @chunks;
}

sub finish_xml {
	my ($self) = @_;

	if (!(defined($self->{_read_filename}) and
	      defined($self->{filename}) and
	      ($self->{_read_filename} eq $self->{filename}))) {
		return;
	}

	open(my $fh, ">", $self->{filename}) or die("cannot write $self->{filename}: $!\n");
	$self->diag("Writing $self->{filename} ... ");
	my $string = $self->{_svg_doc}->toString(1);

	# we're fine with indentation everywhere else, but inserting
	# whitespace within a <text> node, before the first <tspan>
	# node or after the last <tspan> node, screws things up.  and
	# yes this is quick-and-dirty, :dealwithit:
	$string =~ s{(<text[^>]*>)[\s\r\n]*}{$1}gs;
	$string =~ s{[\s\r\n]*(?=</text>)}{}gs;
	$string =~ s{(</tspan>)\s*(<tspan\b)}{$1$2}gs;

	# minimize diffs with netscape-output XML
	$string =~ s{\s*/>}{ />}gs;

	print $fh $string;
	close($fh);
	$self->diag("done.\n");
}

use constant PI => 4 * atan2(1, 1);

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

	my $dx;
	my $dy;
	my $theta;

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
			$dx = $dx[$i] / $l[$i] + $dx[$i + 1] / $l[$i + 1];
			$dy = $dy[$i] / $l[$i] + $dy[$i + 1] / $l[$i + 1];
			$theta = atan2($dy, $dx);
			if (sin($theta - $gd) < 0) {
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
			$dx = $x[$i + 1] - $x[$i];
			$dy = $y[$i + 1] - $y[$i];
			$theta = atan2($dy, $dx);
			if (sin($theta - $gd) < 0) {
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
		$theta = $theta[0];
		if (sin($theta - $gd) < 0) {
			$x = $x[0] - $md * sin($theta);
			$y = $y[0] + $md * cos($theta);
		}
		else {
			$x = $x[0] + $md * sin($theta);
			$y = $y[0] - $md * cos($theta);
		}
	}
	elsif ($dp[$n - 1] < $md) {
		$theta = $theta[$n - 2];
		if (sin($theta - $gd) < 0) {
			$x = $x[$n - 1] - $md * sin($theta);
			$y = $y[$n - 1] + $md * cos($theta);
		}
		else {
			$x = $x[$n - 1] + $md * sin($theta);
			$y = $y[$n - 1] - $md * cos($theta);
		}
	}
	return ($x, $y);
}

sub uniq_coord_pairs {
	my @result = ();
	my $px;
	my $py;
	foreach my $pair (@_) {
		next if (defined $px && $pair->[0] == $px && defined $py && $pair->[1] == $py);
		push(@result, $pair);
		$px = $pair->[0];
		$py = $pair->[1];
	}
	return @result;
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

sub diag {
	my ($self, @args) = @_;
	return unless $verbose;
	print STDERR (@args);
}
sub diagf {
	my ($self, $format, @args) = @_;
	return unless $verbose;
	printf STDERR ($format, @args);
}

1;


