package Transit::MapMaker;
use warnings;
use strict;
use Carp qw(croak);

=head1 NAME
	
Transit::MapMaker - Create semi-usable transit maps from GTFS and OSM data.

=head1 VERSION

Version 0.01

=cut


our $VERSION = '0.01';
	

=head1 SYNOPSIS

    use Transit::MapMaker;

    my $mm = Transit::MapMaker->new(
	filename => "map.svg"
    );

    $mm->north(38.24);		# degrees
    $mm->south(38.21);
    $mm->west(-85.78);
    $mm->east(-85.74);
    $mm->paper_width(1980);	# in units of 1/90 inch
    $mm->paper_height(1530);	# in units of 1/90 inch
    $mm->paper_margin(22.5);	# in units of 1/90 inch
    $mm->plot_osm_layers();
    $mm->gtfs("http://developer.trimet.org/schedule/gtfs.zip");
    $mm->plot_transit_stops();

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
		      north south east west
		      map_data_north map_data_south map_data_east map_data_west
		      paper_width paper_height paper_margin
		      classes
		      layers
		      route_colors
		      route_overrides
		      grid
		      grid_sprintf
		      osm_layers
		      selected_trips_only
		      inset_maps
		      _map_areas
		      _gtfs_url
		      _gtfs
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
		    );
}
use fields @_FIELDS;

sub new {
	my ($class, %options) = @_;
	my $self = fields::new($class);
	$self->{_cache} = {};
	$self->{paper_width}  = 90 * 8.5;
	$self->{paper_height} = 90 * 11;
	$self->{paper_margin} = 90 * 0.25;
	while (my ($k, $v) = each(%options)) {
		if ($self->can($k)) {
			$self->$k($v);
		}
		else {
			$self->{$k} = $v;
		}
	}
	$self->init_xml();
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
use YAML;

sub file_get_contents {		# php-like lol
	my ($filename) = @_;
	open(my $fh, "<", $filename) or die("Cannot read $filename: $!\n");
	return join("", <$fh>);
}

sub file_put_contents {		# php-like lol
	my ($filename, $contents) = @_;
	open(my $fh, ">", $filename) or die("Cannot write $filename: $!\n");
	print $fh $contents;
}

sub download_map_data {
	my ($self, $force) = @_;
	$self->{_map_xml_filenames} = [];
	$self->_download_map_data($force);
}

sub _download_map_data {
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
		$self->_download_map_data($force, $west,       $south,      $center_lon, $center_lat);
		$self->_download_map_data($force, $center_lon, $south,      $east,       $center_lat);
		$self->_download_map_data($force, $west,       $center_lat, $center_lon, $north);
		$self->_download_map_data($force, $center_lon, $center_lat, $east,       $north);
	}
	elsif (-e $xml_filename && !$force) {
		warn("Not updating $xml_filename\n");
		push(@{$self->{_map_xml_filenames}}, $xml_filename);
	}
	else {
		my $ua = LWP::UserAgent->new();
		warn("Downloading $url ...\n");
		my $response = $ua->mirror($url, $xml_filename);
		warn(sprintf("  => %s\n", $response->status_line()));
		my $rc = $response->code();
		if ($rc == RC_NOT_MODIFIED) {
			push(@{$self->{_map_xml_filenames}}, $xml_filename);
			# ok then
		}
		elsif ($rc == 400) {
			file_put_contents($txt_filename, "split-up");
			my $center_lat = ($north + $south) / 2;
			my $center_lon = ($west + $east) / 2;
			$self->_download_map_data($force, $west,       $south,      $center_lon, $center_lat);
			$self->_download_map_data($force, $center_lon, $south,      $east,       $center_lat);
			$self->_download_map_data($force, $west,       $center_lat, $center_lon, $north);
			$self->_download_map_data($force, $center_lon, $center_lat, $east,       $north);
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

sub update_map_data {
	my ($self) = @_;
	$self->download_map_data(1);
}

our %NS;
BEGIN {
	$NS{"svg"}      = "http://www.w3.org/2000/svg";
	$NS{"inkscape"} = "http://www.inkscape.org/namespaces/inkscape";
	$NS{"sodipodi"} = "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd";
	$NS{"mapmaker"} = "http://webonastick.com/namespaces/transit-mapmaker";
}

sub init_xml {
	my ($self) = @_;
	my $parser = XML::LibXML->new();
	$parser->keep_blanks(0);
	my $doc = eval {
		print STDERR ("Parsing $self->{filename} ... ");
		my $d = $parser->parse_file($self->{filename});
		print STDERR ("Done.\n");
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
  <metadata id="metadata7">
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
			$view->setAttributeNS($NS{"inkscape"}, "inkscape:cx", $self->{paper_width} / 2);
			$view->setAttributeNS($NS{"inkscape"}, "inkscape:cy", $self->{paper_height} / 2);
		}
	}

	$self->{_map_areas} = [ { is_main => 1, name => "Main Map" }, @{$self->{inset_maps}} ];
	my $map_area_idx = 0;
	foreach my $map_area (@{$self->{_map_areas}}) {
		$map_area->{idx} = $map_area_idx++;
	}
}

sub findnodes {
	my ($self, @args) = @_;
	return $self->{_xpc}->findnodes(@args);
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
		$self->{_svg_west}  = $self->{paper_margin}; # $self->lon2x($self->{west});
		$self->{_svg_north} = $self->{paper_margin}; # $self->lat2y($self->{north});
		$self->{_svg_east}  = $self->lon2x($self->{east});
		$self->{_svg_south} = $self->lat2y($self->{south});
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
	my @cpnodes = $doc->findnodes("svg:clipPath[\@mapmaker:autogenerated]");
	foreach my $cpnode (@cpnodes) {
		$cpnode->unbindNode();
	}
}

sub defs_node {
	my ($self) = @_;
	my ($defs) = $self->findnodes("//svg:defs");
	my $doc = $self->{_svg_doc};
	my $doc_elt = $doc->documentElement();
	if (!$defs) {
		$defs = $doc->createElementNS($NS{"svg"}, "defs");
		$doc_elt->insertBefore($defs, $doc_elt->firstChild());
	}
	return $defs;
}

sub create_clip_path {
	my ($self, $map_area) = @_;
	my $defs = $self->defs_node();
	my $doc = $self->{_svg_doc};

	my $idx       = $map_area ? $map_area->{idx}          : 0;
	my $cpnode_id = $map_area ? "map_area_${idx}_cp"      : "main_map_cp";
	my $path_id   = $map_area ? "map_area_${idx}_cp_path" : "main_map_cp_path";
	
	my $cpnode = $doc->createElementNS($NS{"svg"}, "clipPath");
	$cpnode->setAttribute("id", $cpnode_id);
	$defs->appendChild($cpnode);

	my $path = $doc->createElementNS($NS{"svg"}, "path");
	$path->setAttribute("id" => $path_id);
	$path->setAttributeNS($NS{mapmaker}, "mapmaker:autogenerated" => "true");
	$path->setAttribute("d" => $self->clip_path_d());
	$path->setAttributeNS($NS{"inkscape"}, "inkscape:connector-curvature" => 0);
	$cpnode->appendChild($path);

	return $cpnode_id;
}

use constant POINT_X => 0;
use constant POINT_Y => 1;
use constant POINT_X_ZONE => 2;
use constant POINT_Y_ZONE => 3;

sub erase_autogenerated_map_layers {
	my ($self) = @_;
	my $doc = $self->{_svg_doc};
	foreach my $layer ($doc->findnodes("/svg:svg/svg:g[\@inkscape:groupmode=\"layer\"][\@mapmaker:autogenerated]")) {
		$layer->unbindNode();
	}
	foreach my $layer ($doc->findnodes("/svg:svg/svg:g[\@inkscape:groupmode=\"layer\"][\@mapmaker:inset-map]")) {
		$layer->unbindNode();
	}
	foreach my $layer ($doc->findnodes("/svg:svg/svg:g[\@inkscape:groupmode=\"layer\"][\@mapmaker:main-map]")) {
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

sub create_map_area_layer {
	my ($self, $map_area) = @_;
	my $doc = $self->{_svg_doc};
	my $insertion_point = $self->layer_insertion_point();
	my $map_area_layer = $self->create_layer(name => ($map_area->{name} // 
							  ("Inset " . $map_area->{idx})),
						 writable => 1);
	if ($map_area->{is_main}) {
		$map_area_layer->setAttributeNS($NS{mapmaker}, "mapmaker:main-map", "true");
	}
	else {
		$map_area_layer->setAttributeNS($NS{mapmaker}, "mapmaker:inset-map", "true");
	}
	$map_area_layer->setAttributeNS($NS{mapmaker}, "mapmaker:autogenerated", "true");
	if ($insertion_point) {
		$doc->documentElement()->insertBefore($map_area_layer, $insertion_point);
	}
	else {
		$doc->documentElement()->appendChild($map_area_layer);
	}
	return $map_area_layer;
}

sub create_background_layer {
	my ($self, $map_layer) = @_;
	my $background = $self->create_layer(name => "Background Color");
	my $rect = $self->create_rectangle(x      => $self->{_svg_west},
					   y      => $self->{_svg_north},
					   width  => $self->{_svg_east} - $self->{_svg_west},
					   height => $self->{_svg_south} - $self->{_svg_north},
					   style  => $self->compose_style_string({}, "background"));
	$background->appendChild($rect);
	$map_layer->appendChild($background);
}

sub create_border_layer {
	my ($self, $map_layer) = @_;
	my $border = $self->create_layer(name => "Border");
	my $rect = $self->create_rectangle(x      => $self->{_svg_west},
					   y      => $self->{_svg_north},
					   width  => $self->{_svg_east} - $self->{_svg_west},
					   height => $self->{_svg_south} - $self->{_svg_north},
					   style  => $self->compose_style_string({}, "map-border", { fill => "none", stroke_linejoin => "square" }));
	$border->appendChild($rect);
	$map_layer->appendChild($border);
}

sub create_openstreetmap_layer {
	my ($self, $map_layer) = @_;
	my $osm_layer = $self->create_layer(name => "OpenStreetMap");
	$map_layer->appendChild($osm_layer);
	return $osm_layer;
}

sub plot_osm_maps {
	my ($self) = @_;
	my $doc = $self->{_svg_doc};

	my %index_tag;
	foreach my $info (@{$self->{osm_layers}}) {
		$info->{tags} = $self->normalize_tags($info->{tags});
		foreach my $tag (@{$info->{tags}}) {
			$index_tag{$tag->{k}} = 1;
		}
	}

	$self->erase_autogenerated_map_layers();
	$self->erase_autogenerated_clip_paths();

	foreach my $map_area (@{$self->{_map_areas}}) {
		$self->update_scale($map_area);
		my $map_area_layer = $self->create_map_area_layer($map_area);
		my $cpnode_id = $self->create_clip_path($map_area);
		$self->create_background_layer($map_area_layer);
		my $osm_layer = $self->create_openstreetmap_layer($map_area_layer);
		foreach my $info (@{$self->{osm_layers}}) {
			my $layer = $self->create_layer(name => $info->{name});
			my $group = $self->create_clipped_group($cpnode_id);
			$layer->appendChild($group);
			$osm_layer->appendChild($layer);
			$info->{_map_area_layer} //= [];
			$info->{_map_area_group} //= [];
			push(@{$info->{_map_area_layer}}, $layer);
			push(@{$info->{_map_area_group}}, $group);
		}
		$self->create_border_layer($map_area_layer);
	}

	foreach my $filename (@{$self->{_map_xml_filenames}}) {
		print STDERR ("Parsing $filename ... ");
		my $doc = $self->{_parser}->parse_file($filename);
		print STDERR ("done.\n");

		print STDERR ("  Finding <node> elements ... ");
		my @nodes = $doc->findnodes("/osm/node");
		my %nodes;
		print STDERR (scalar(@nodes) . " elements found.\n");
		foreach my $map_area (@{$self->{_map_areas}}) {
			$self->update_scale($map_area);
			my $idx = $map_area->{idx};
			my $area_name = $map_area->{name};
			print STDERR ("    Indexing for map area $area_name ... ");
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
				$nodes{$id}[$idx] = $result;
			}
			print STDERR ("done.\n");
		}
		print STDERR ("done.\n");

		print STDERR ("  Finding <way> elements ... ");
		my @ways = $doc->findnodes("/osm/way");
		my %ways;
		my %ways_index;
		print STDERR (scalar(@ways) . " elements found; indexing ... ");
		foreach my $way (@ways) {
			my $id = $way->getAttribute("id");
			my @nodeid = map { $_->getAttribute("ref"); } $way->findnodes("nd");
			my $closed = (scalar(@nodeid)) > 2 && ($nodeid[0] == $nodeid[-1]);
			pop(@nodeid) if $closed;

			my $result = { id     => $id,
				       nodeid => \@nodeid,
				       closed => $closed,
				       points => []
				     };
			$ways{$id} = $result;
			
			my @tag = $way->findnodes("tag");
			foreach my $tag (@tag) {
				my $k = $tag->getAttribute("k");
				my $v = $tag->getAttribute("v");
				next unless $index_tag{$k};
				push(@{$ways_index{$k}}, $result);
				push(@{$ways_index{$k, $v}}, $result);
			}
		}
		print STDERR ("done.\n");

		foreach my $map_area (@{$self->{_map_areas}}) {
			$self->update_scale($map_area);
			my $idx = $map_area->{idx};
			my $area_name = $map_area->{name};
			print STDERR ("    Indexing for map area $area_name ... ");
			foreach my $way (@ways) {
				my $id = $way->getAttribute("id");
				my @nodeid = @{$ways{$id}{nodeid}};
				my @points = map { $nodes{$_}[$idx] } @nodeid;
				$ways{$id}{points}[$idx] = \@points;
			}
			print STDERR ("done.\n");
		}

		foreach my $map_area (@{$self->{_map_areas}}) {
			$self->update_scale($map_area);
			my $idx = $map_area->{idx};
			my $area_name = $map_area->{name};
			print STDERR ("Adding objects for map area $area_name ...\n");

			foreach my $info (@{$self->{osm_layers}}) {
				my $name = $info->{name};
				my $tags = $info->{tags};
				my $class = $info->{class};
				my $group = $info->{_map_area_group}[$idx];

				print STDERR ("  Layer $name\n");

				my @ways;
				foreach my $tag (@$tags) {
					my $k = $tag->{k};
					my $v = $tag->{v};
					if (defined $v) {
						eval { push(@ways, @{$ways_index{$k, $v}}); };
					} else {
						eval { push(@ways, @{$ways_index{$k}}); };
					}
				}
				@ways = uniq @ways;
				print STDERR (scalar(@ways), " objects found; processing ... ");

				my $options = {};
				if ($map_area->{scale_stroke_width} && exists $map_area->{zoom}) {
					$options->{scale} = $map_area->{zoom};
				}

				my $open_style   = $self->compose_style_string({ %$options, open => 1 }, $info->{class});
				my $closed_style = $self->compose_style_string({ %$options, open => 0 }, $info->{class});

				foreach my $way (@ways) {
					my $points = $way->{points}[$idx];

					if (all { $_->[POINT_X_ZONE] == -1 } @$points) { next; }
					if (all { $_->[POINT_X_ZONE] ==  1 } @$points) { next; }
					if (all { $_->[POINT_Y_ZONE] == -1 } @$points) { next; }
					if (all { $_->[POINT_Y_ZONE] ==  1 } @$points) { next; }

					if ($way->{closed}) {
						my $polygon = $self->create_polygon(points => $points, style => $closed_style);
						$group->appendChild($polygon);
					} else {
						my $polyline = $self->create_polyline(points => $points, style => $open_style);
						$group->appendChild($polyline);
					}
				}
				print STDERR ("done.\n");
			}

			print STDERR ("Done.\n");
		}
	}
}
sub create_polygon {
	my ($self, %args) = @_;
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	$path->setAttribute("d", $self->points_to_path(1, @{$args{points}}));
	$path->setAttribute("style", $args{style});
	return $path;
}
sub create_polyline {
	my ($self, %args) = @_;
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	$path->setAttribute("d", $self->points_to_path(0, @{$args{points}}));
	$path->setAttribute("style", $args{style});
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
sub create_clipped_group {
	my ($self, $id) = @_;
	my $group = $self->{_svg_doc}->createElementNS($NS{"svg"}, "g");
	$group->setAttribute("clip-path" => "url(#${id})");
	$group->setAttribute("clip-rule" => "nonzero");
	return $group;
}
sub create_layer {
	my ($self, %args) = @_;
	my $layer = $self->{_svg_doc}->createElementNS($NS{"svg"}, "g");
	$layer->setAttributeNS($NS{"inkscape"}, "inkscape:groupmode", "layer");
	$layer->setAttributeNS($NS{"inkscape"}, "inkscape:label", $args{name}) if defined $args{name};
	$layer->setAttributeNS($NS{"sodipodi"}, "sodipodi:insensitive", $args{writable} ? "true" : "false");
	return $layer;
}
sub create_rectangle {
	my ($self, %args) = @_;
	my $rect = $self->{_svg_doc}->createElementNS($NS{"svg"}, "rect");
	$rect->setAttribute("x",      $args{x});
	$rect->setAttribute("y",      $args{y});
	$rect->setAttribute("width",  $args{width});
	$rect->setAttribute("height", $args{height});
	$rect->setAttribute("style",  $args{style});
	return $rect;
}
sub compose_style_string {
	my ($self, $options, @classes) = @_;
	return $self->_compose_style_string($options, "style", @classes);
}
sub _compose_style_string {
	my ($self, $options, $style_attr_name, @classes) = @_;
	@classes = (grep { /\S/ }
		    map { ref($_) eq "HASH" ? $_ : split(/\s+/, $_) }
		    map { ref($_) eq "ARRAY" ? @$_ : $_ }
		    @classes);
	my %style = ();
	foreach my $class (@classes) {
		my $add = (ref($class) eq "HASH") ? $class : $self->{classes}->{$class}->{$style_attr_name};
		if ($add) {
			%style = (%style, %$add);
		}
	}
	if ($options && $options->{open} && scalar(keys(%style))) {
		$style{"fill"}              = "none";
		$style{"stroke-linecap"}  //= "round";
		$style{"stroke-linejoin"} //= "round";
	}
	if ($options && exists $options->{scale} && exists $style{"stroke-width"}) {
		$style{"stroke-width"} *= $options->{scale};
	}
	return join(";",
		    map { $_ . ":" . $style{$_} }
		    sort  
		    grep { $_ ne "r" }
		    keys %style);
}

sub gtfs_url {
	my $self = shift();
	return $self->{_gtfs_url} unless @_;
	
	my $gtfs_url = shift();
	$self->{_gtfs_url} = $gtfs_url;
	$self->{_gtfs} = Transit::GTFS->new($gtfs_url);
	return $self->{_gtfs_url};
}

sub gtfs {
	my $self = shift();
	return $self->{_gtfs} unless @_;

	my $gtfs = shift();
	$self->{_gtfs} = $gtfs;
	$self->{_gtfs_url} = $gtfs->{url};
	return $self->{_gtfs};
}

sub update_transit_stops {
	my ($self) = @_;
	$self->update_scale();

	my $gtfs = $self->{_gtfs};
	if (!$gtfs) { return; }

	warn("Updating transit stops...\n");

	my $dbh = $gtfs->dbh();
	
	my ($layer, $group, $group_2) = $self->svg_layer_node("gtfs:transit-stops", { clear => 1 });

	my $sth = $dbh->prepare("select * from stops");
	$sth->execute();

	my $style = $self->layer_style("gtfs:transit-stops");
	my $r = $style->{r} // 0.5;
	my $style_string = $style->as_string();
	
	my $style_2 = $self->layer_style("gtfs:transit-stops", style_attr_name => "style_2");
	my $r_2 = $style_2->{r} // 0.5;
	my $style_2_string = $style_2->as_string();
	
	while (my $hash = $sth->fetchrow_hashref()) {
		my $stop_id = $hash->{stop_id};
		my $stop_code = $hash->{stop_code};
		my $lat = $hash->{stop_lat};
		my $lon = $hash->{stop_lon};

		my $title = join(" - ", grep { $_ }
				 $hash->{stop_code},
				 $hash->{stop_name},
				 $hash->{stop_desc});

		my $circle = $self->{_svg_doc}->createElementNS($NS{"svg"}, "circle");
		$circle->setAttribute("cx", $self->lon2x($lon));
		$circle->setAttribute("cy", $self->lat2y($lat));
		$circle->setAttribute("r", $r);
		$circle->setAttribute("style", $style_string);
		$circle->setAttribute("title", $title) if $title;
		$circle->setAttributeNS($NS{"mapmaker"}, "mapmaker:group", "1");
		$group->appendChild($circle);

		if (!($style_2->is_empty())) {
			my $circle_2 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "circle");
			$circle_2->setAttribute("cx", $self->lon2x($lon));
			$circle_2->setAttribute("cy", $self->lat2y($lat));
			$circle_2->setAttribute("r", $r_2);
			$circle_2->setAttribute("style", $style_2_string);
			$circle_2->setAttribute("title", $title) if $title;
			$circle_2->setAttributeNS($NS{"mapmaker"}, "mapmaker:group", "2");
			if ($style_2->{group}) {
				$group_2->appendChild($circle_2);
			}
			else {
				$group->appendChild($circle_2);
			}
		}
	}
	warn("Done.\n");
}

sub transit_route_color {
	my ($self, $route_short_name) = @_;
	my $gtfs = $self->{_gtfs};
	if (!$gtfs) { return; }
	my $dbh = $gtfs->dbh();

	my $sth = $dbh->prepare(qq(select route_color from routes where route_short_name = ?));
	$sth->execute($route_short_name);
	if (my ($color) = $sth->fetchrow_array()) {
		warn("$route_short_name => $color\n") if $ENV{DEBUG};
		return "#" . lc($color);
	}
	return undef;
}

sub transit_route_paint_order {
	my ($self, $route_short_name) = @_;
	my $gtfs = $self->{_gtfs};
	if (!$gtfs) { return; }
	
	my $paint_order = eval { $self->{route_overrides}->{$route_short_name}->{paint_order} };
	return $paint_order if defined $paint_order;

	my $route_color = $self->transit_route_color($route_short_name);
	return unless defined $route_color;
	
	$paint_order = eval { $self->{route_colors}->{$route_color}->{paint_order} };
	return $paint_order if defined $paint_order;

	return undef;
}

our $LAYER_INFO = {};
sub update_transit_routes {
	my ($self, @routes) = @_;
	$self->update_scale();

	my $gtfs = $self->{_gtfs};
	if (!$gtfs) { return; }

	warn("Updating transit route layers...\n");

	my $z_index = $LAYER_INFO->{"gtfs:transit-routes"}->{z_index};

	my $dbh = $gtfs->dbh();

	my $routes_sth = $dbh->prepare("select * from routes");
	my $trips_sth = $dbh->prepare(qq{select distinct shape_id from trips where route_id = ?});
	my $shapes_sth = $dbh->prepare(qq{select shape_pt_lon, shape_pt_lat
                                          from shapes
                                          where shape_id = ?
                                          order by shape_pt_sequence asc});

	$routes_sth->execute();
	while (my $route = $routes_sth->fetchrow_hashref()) {
		my $route_short_name = $route->{route_short_name};
		my $route_long_name = $route->{route_long_name};
		my $route_desc = $route->{route_desc};

		next if scalar(@routes) && !grep { $_ eq $route_short_name } @routes;
		
		my @existing_layers = $self->findnodes('/svg:svg/svg:g[@mapmaker:class="gtfs:transit-route"]' .
						       '[@mapmaker:route-short-name="' . $route_short_name . '"]');
		foreach my $layer (@existing_layers) {
			warn("  Deleting existing route layer for $route_short_name\n");
			$layer->parentNode()->removeChild($layer);
		}

		my $route_title = join(" - ", grep { $_ } ($route_short_name, $route_long_name, $route_desc));
		my $google_route_color = $route->{route_color};
		if ($google_route_color) {
			$google_route_color = "#" . lc($google_route_color);
		}

		warn(sprintf("  Creating layer for Route %s - %s\n", $route_short_name, $route_long_name));
		my $name = sprintf("gtfs:route:%s:%s", $route_short_name, $route_long_name);
		my ($layer, $group, $group_2) = $self->svg_layer_node({ name => $name, z_index => $z_index++ });
		my $paint_order = (
				   eval { $self->{route_overrides}->{$route_short_name}->{paint_order} } //
				   eval { $self->{route_colors}->{$google_route_color}->{paint_order} }
				  );
		if (defined $paint_order) {
			$layer->setAttributeNS($NS{"mapmaker"},
					       "mapmaker:paint-order", $paint_order);
		}
		$layer->setAttributeNS($NS{"mapmaker"}, "mapmaker:class", "gtfs:transit-route");
		$layer->setAttributeNS($NS{"mapmaker"}, "mapmaker:route-short-name", $route_short_name) if defined $route_short_name;
		$layer->setAttributeNS($NS{"mapmaker"}, "mapmaker:route-long-name", $route_long_name)   if defined $route_long_name;
		$layer->setAttributeNS($NS{"mapmaker"}, "mapmaker:route-desc", $route_desc)             if defined $route_desc;

		my $node_id_counter = 0;
		my %xy_to_node_id = ();
		my %node = ();	# map id to [x,y]
		my @paths = ();	# each member an arrayref containing node_ids

		$trips_sth->execute($route->{route_id});
		while (my ($shape_id) = $trips_sth->fetchrow_array()) {
			my $path = [];
			$shapes_sth->execute($shape_id);
			while (my ($lon, $lat) = $shapes_sth->fetchrow_array()) {
				my $x = $self->lon2x($lon);
				my $y = $self->lat2y($lat);
				if (exists $xy_to_node_id{$x,$y}) {
					push(@$path, $xy_to_node_id{$x,$y});
				}
				else {
					$xy_to_node_id{$x,$y} = ++$node_id_counter;
					$node{$node_id_counter} = [$x,$y];
					push(@$path, $node_id_counter);
				}
			}
			push(@paths, $path);
			$shapes_sth->finish();
		}
		$trips_sth->finish();

		my $route_override_style = eval { My::MapMaker::Style->new($self->{route_overrides}->{$route_short_name}->{style}) };
		my $route_color_style    = eval { My::MapMaker::Style->new($self->{route_colors}->{$google_route_color}->{style}) };

		my $style = $self->layer_style("gtfs:transit-routes");
		$style->set($route_color_style)    if $route_color_style;
		$style->set($route_override_style) if $route_override_style;
		$style->default("stroke", $google_route_color // "#000000");
		my $style_string = $style->as_string();

		my $route_override_style_2 = eval { My::MapMaker::Style->new($self->{route_overrides}->{$route_short_name}->{style_2}) };
		my $route_color_style_2    = eval { My::MapMaker::Style->new($self->{route_colors}->{$google_route_color}->{style_2}) };
		my $style_2 = $self->layer_style("gtfs:transit-routes", style_attr_name => "style_2");
		$style_2->set($route_color_style_2)    if $route_color_style_2;
		$style_2->set($route_override_style_2) if $route_override_style_2;
		$style_2->default("stroke", $google_route_color // "#000000") if !$style_2->is_empty();
		my $style_2_string = $style_2->as_string();

		# warn($style->as_string_full());
		# warn($style_2->as_string_full());

		print STDERR ("  Consolidating chunks ... ");
		my @chunks = find_chunks(@paths);
		print STDERR ("done.\n");
		foreach my $path (@chunks) {
			my $path_obj = My::MapMaker::Path->new({ points => [ map { $node{$_} } @$path ],
								 closed => 0 });
			my $path_string = $path_obj->as_string();

			my $path_node = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
			$path_node->setAttribute("d", $path_string);
			$path_node->setAttribute("style", $style_string);
			$path_node->setAttribute("title", $route_title);
			$path_node->setAttributeNS($NS{"mapmaker"}, "mapmaker:group", "1");
			$group->appendChild($path_node);

			if (!$style_2->is_empty()) {
				my $path_node_2 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
				$path_node_2->setAttribute("d", $path_string);
				$path_node_2->setAttribute("style", $style_2_string);
				$path_node_2->setAttribute("title", $route_title);
				$path_node_2->setAttributeNS($NS{"mapmaker"}, "mapmaker:group", "2");
				if ($style_2->{group}) {
					$group_2->appendChild($path_node_2);
				}
				else {
					$group->appendChild($path_node_2);
				}
			}
		}
	}
	$routes_sth->finish();
}

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
					my $A_idx = firstidx { $_ == $A } @$chunk;
					if ($A_idx == 0) {
						# existing chunk starts with A-B
						$work_on_existing_chunk->($chunk_id);
					} else {
						# existing chunk has segments before A-B
						# split it into      ...-A and A-B-...
						#               (existing)     (new chunk)
						my @new_chunk = ($A, splice(@{$chunks[$chunk_id]}, $A_idx + 1));
						$work_on_new_chunk->(@new_chunk);
						# working chunk is now A-B-...
					}
				} elsif ($direction == -1) {
					# existing chunk contains B-A segment
					my $B_idx = firstidx { $_ == $B } @$chunk;
					if ($B_idx == scalar(@{$chunks[$chunk_id]}) - 2) {
						# existing chunk ends at B-A
						$work_on_existing_chunk->($chunk_id, -1);
						# working chunk is now A-B-...
					}
					else {
						# existing chunk has segments after B-A
						# split it into ...-B-A and A-...
						#                 (new)     (existing)
						my @new_chunk = (splice(@{$chunks[$chunk_id]}, 0, $B_idx + 1), $A);
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
						my $A_idx = firstidx { $_ == $A } @$working_chunk;
						# working chunk has stuff after A.
						# split it into      ...-A and A-...
						#               (existing)     (new)
						my @new_chunk = ($A, splice(@$working_chunk, $A_idx + 1));
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

	open(my $fh, ">", $self->{filename}) or die("cannot write $self->{filename}: $!\n");
	print STDERR ("Writing $self->{filename} ... ");
	my $string = $self->{_svg_doc}->toString(1);

	# we're fine with indentation everywhere else, but inserting
	# whitespace within a <text> node, before and after <tspan>
	# nodes, screws things up.  and yes this is quick-and-dirty,
	# :dealwithit:
	$string =~ s{[\s\r\n]*(?=<tspan)}{}gs;
	$string =~ s{(<tspan[^>]*>.*?</tspan>)[\s\r\n]*}{$1}gs;

	# minimize diffs with netscape-output XML
	$string =~ s{\s*/>}{ />}gs;

	print $fh $string;
	close($fh);
	print STDERR ("done.\n");
}

1;

