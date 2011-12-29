package Transit::MapMaker;

use warnings;
use strict;


=head1 NAME
	
Transit::MapMaker - Generate SVG layers from GTFS and OSM data.

=head1 VERSION

Version 0.01

=cut


our $VERSION = '0.01';
	

=head1 SYNOPSIS

    use Transit::MapMaker;

    my $mm = Transit::MapMaker->new(
	filename => "map.svg"
    );

    $mm->north(38.24);
    $mm->south(38.21);
    $mm->west(-85.78);
    $mm->east(-85.74);
    $mm->paper_size(1980, 1530);	# width, height in units of 1/90 inch
    $mm->paper_margin(22.5);		# in units of 1/90 inch

    $mm->plot_osm_layers();
    $mm->transit_feed("http://developer.trimet.org/schedule/gtfs.zip");
    $mm->plot_transit_stops();

=cut


use fields qw(filename

	      north
	      south
	      east
	      west

	      map_data_north
	      map_data_south
	      map_data_east
	      map_data_west

	      paper_width
	      paper_height
	      paper_margin

	      gtfs

	      _parser
	      _svg_doc
	      _map_xml_filenames
	      _nodes
	      _ways
	      _scale
	      _south_y
	      _north_y
	      _east_x
	      _west_x
	      _rad_width
	      _rad_height

	      _svg_west
	      _svg_east
	      _svg_north
	      _svg_south

	    );

sub new {
	my ($class, %options) = @_;
	my $self = fields::new($class);
	$self->{paper_width}  = 90 * 8.5;
	$self->{paper_height} = 90 * 11;
	$self->{paper_margin} = 90 * 0.25;
	while (my ($k, $v) = each(%options)) {
		$self->{$k} = $v;
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
sub paper_size {
	my ($self, $width, $height) = @_;
	$self->{paper_width} = $width;
	$self->{paper_height} = $height;
}
sub paper_margin {
	my ($self, $margin) = @_;
	$self->{paper_margin} = $margin;
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
use List::MoreUtils qw(all);
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

sub init_xml {
	my ($self) = @_;
	my $parser = XML::LibXML->new();
	my $doc = eval {
		warn("Loading $self->{filename}...\n");
		my $d = $parser->parse_file($self->{filename});
		warn("Done.\n");
		return $d;
	};
	if (!$doc) {
		$doc = $parser->parse_string(<<"END");
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
   width="765"
   height="990"
   id="svg2"
   version="1.1"
   inkscape:version="0.48.1 "
   sodipodi:docname="Map">
  <defs id="defs4" />
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
	$self->{_parser} = $parser;
	$self->{_svg_doc} = $doc;
	$doc->documentElement()->setAttribute("width", $self->{paper_width});
	$doc->documentElement()->setAttribute("height", $self->{paper_height});
	my ($view) = $doc->findnodes("//sodipodi:namedview[\@id='base']");
	if ($view) {
		$view->setAttribute("inkscape:cx", $self->{paper_width} / 2);
		$view->setAttribute("inkscape:cy", $self->{paper_height} / 2);
	}
}

BEGIN {
	my $d2r = atan2(1, 1) / 45;
	my $r2d = 45 / atan2(1, 1);
	sub update_scale {
		my ($self) = @_;
		my $w = $self->{west};
		my $e = $self->{east};
		my $n = $self->{north};
		my $s = $self->{south};
		my $wx = $self->{_west_x} = _lon2x($w);
		my $ex = $self->{_east_x} = _lon2x($e);
		my $ny = $self->{_north_y} = _lat2y($n);
		my $sy = $self->{_south_y} = _lat2y($s);
		my $width  = $self->{_rad_width}  = $ex - $wx;
		my $height = $self->{_rad_height} = $ny - $sy;
		my $pww = $self->{paper_width}  - 2 * $self->{paper_margin};
		my $phh = $self->{paper_height} - 2 * $self->{paper_margin};
		if ($width / $height <= $pww / $phh) {
			$self->{_scale} = $phh;
		}
		else {
			$self->{_scale} = $pww;
		}
		$self->{_svg_west}  = $self->lon2x($self->{west});
		$self->{_svg_east}  = $self->lon2x($self->{east});
		$self->{_svg_north} = $self->lat2y($self->{north});
		$self->{_svg_south} = $self->lat2y($self->{south});
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
		return $self->{paper_margin} + $self->{_scale} * (_lon2x($lon) - $self->{_west_x}) / $self->{_rad_width};
	}
	sub lat2y {
		my ($self, $lat) = @_;
		return $self->{paper_margin} + $self->{_scale} * ($self->{_north_y} - _lat2y($lat)) / $self->{_rad_height};
	}
}

<<"END";
END

our $LAYER_INFO;
BEGIN {
	$LAYER_INFO = {
		       "osm:natural=water"            => { z_index => 1010, style => { fill => '#bbd', stroke => '#bbd', stroke_width => 0.25 } },
		       "osm:waterway=river"           => { z_index => 1020, style => { fill => '#bbd', stroke => '#bbd', stroke_width => 0.25 } },
		       "osm:waterway=stream"          => { z_index => 1030, style => { fill => '#bbd', stroke => '#bbd', stroke_width => 0.25 } },
		       "osm:amenity=park"             => { z_index => 1040, style => { fill => '#cfc' } },
		       "osm:leisure=park"             => { z_index => 1050, style => { fill => '#cfc' } },
		       "osm:landuse=forest"           => { z_index => 1060, style => { fill => '#cfc' } },
		       "osm:amenity=parking"          => { z_index => 1070, style => { fill => '#f7f7f7' } },
		       "osm:building=yes"             => { z_index => 1080, style => { fill => '#e6e6e6' } },
		       "osm:building=office"          => { z_index => 1081, style => { fill => '#e6e6e6' } },
		       "osm:landuse=industrial"       => { z_index => 1090, style => { fill => '#eee' } },
		       "osm:landuse=commercial"       => { z_index => 1091, style => { fill => '#eee' } },
		       "osm:amenity=university"       => { z_index => 1100, style => { fill => '#ddf' } },
		       "osm:amenity=college"          => { z_index => 1101, style => { fill => '#ddf' } },
		       "osm:amenity=school"           => { z_index => 1102, style => { fill => '#ddf' } },
		       "osm:leisure=golf_course"      => { z_index => 1110, style => { fill => '#ffc' } },
		       "osm:landuse=cemetery"         => { z_index => 1120, style => { fill => '#cfc' } },
		       "osm:highway=track"            => { z_index => 2010, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.25 } },
		       "osm:highway=footway"          => { z_index => 2020, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.25 } },
		       "osm:highway=service"          => { z_index => 2030, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.25 } },
		       "osm:highway=living_street"    => { z_index => 2040, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.25 } },
		       "osm:highway=residential"      => { z_index => 2050, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.50 } },
		       "osm:highway=unclassified"     => { z_index => 2060, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=tertiary_link"    => { z_index => 2070, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=tertiary"         => { z_index => 2075, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=secondary_link"   => { z_index => 2080, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=secondary"        => { z_index => 2090, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=primary_link"     => { z_index => 2100, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=primary"          => { z_index => 2110, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=motorway_link"    => { z_index => 2120, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=motorway"         => { z_index => 2130, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=road"             => { z_index => 2140, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:highway=trunk"            => { z_index => 2150, style => { fill => 'none', stroke => '#ddd', stroke_width => 0.70 } },
		       "osm:railway=rail"             => { z_index => 3000, style => { fill => 'none', stroke => '#999', stroke_width => 0.25 } },
		       "osm:aeroway=apron"            => { z_index => 4000, style => { fill => '#ddd', stroke => '#ddd', stroke_width => 0.25 } },
		       "osm:aeroway=terminal"         => { z_index => 4003, style => { fill => '#ccc', stroke => '#ccc', stroke_width => 0.25 } },
		       "osm:aeroway=runway"           => { z_index => 4001, style => { fill => 'none', stroke => '#ddd', stroke_width => 2 } },
		       "osm:aeroway=taxiway"          => { z_index => 4002, style => { fill => 'none', stroke => '#ddd', stroke_width => 2 } },

		       "highway-route-markers"        => { z_index => 5000 },

		       # transit routes, 6000 => 6999

		       "gtfs:transit-stops"           => { z_index => 7000 },
		       "transit-route-numbers"        => { z_index => 7010 },
		       "park-and-ride-lots"           => { z_index => 7020 },
		       "one-way-indicators"           => { z_index => 7030 },

		       "points-of-interest"           => { z_index => 9040 },
		       "street-names"                 => { z_index => 9050 },
		       "place-names"                  => { z_index => 9060 },
		       "test-layer"                   => { z_index => 9500, unclipped => 1 },
		       "legend"                       => { z_index => 10000, unclipped => 1 }
		      };
}

sub add_clipping_path {
	my ($self) = @_;
	my $svg = $self->{_svg_doc};
	my ($defs) = $svg->findnodes("//svg:defs");
	if (!$defs) {
		warn("no defs section found\n");
		return;
	}
	my $clipPath = $defs->findnodes("clipPath[\@id='documentClipPath']");
	if ($clipPath) {
		$clipPath->parentNode()->remoteChild($clipPath);
	}
	$clipPath = $svg->createElement("clipPath");
	$clipPath->setAttribute("id", "documentClipPath");
	$defs->appendChild($clipPath);

	my $left   = $self->lon2x($self->{west});
	my $right  = $self->lon2x($self->{east});
	my $top    = $self->lat2y($self->{north});
	my $bottom = $self->lat2y($self->{south});

	my $d = sprintf("M %f %f H %f V %f H %f Z",
			$left, $top, $right, $bottom, $left);
			
	my $path = $svg->createElement("path");
	$path->setAttribute("id" => "documentClipPathPath");
	$path->setAttribute("d" => $d);
	$path->setAttribute("inkscape:connector-curvature" => 0);
	$clipPath->appendChild($path);
}

sub refresh_osm_styles {
	my ($self) = @_;
	$self->update_scale();
	warn("Refreshing styles...\n");
	foreach my $layer_name (grep { m{^osm:} } keys(%$LAYER_INFO)) {
		warn("  $layer_name...\n");
		my $layer = $self->svg_layer($layer_name, 1);
		my $style = $LAYER_INFO->{$layer_name}->{style};
		foreach my $polyline ($layer->findnodes("svg:polyline")) {
			# TODO: delete attributes unless it's something like points
			$self->apply_styles($polyline, $style) if $style;
			$polyline->setAttribute("fill" => "none"); # override
			$polyline->setAttribute("stroke-linecap" => "round");
			$polyline->setAttribute("stroke-linejoin" => "round");
		}
		foreach my $polygon ($layer->findnodes("svg:polygon")) {
			# TODO: delete attributes unless it's something like points
			$self->apply_styles($polygon, $style) if $style;
		}
	}
	warn("Done updating styles.\n");
}

sub plot_osm_layers {
	my ($self) = @_;

	$self->update_scale();
	$self->add_clipping_path();

	$self->{_nodes} = {};
	$self->{_ways} = {};

	my %skipped;

	foreach my $layer_name (grep { m{^osm:} } keys(%$LAYER_INFO)) {
		$self->svg_layer($layer_name)->removeChildNodes();
	}
	
	foreach my $filename (@{$self->{_map_xml_filenames}}) {
		warn("Working through $filename ... \n");
		my $doc = $self->{_parser}->parse_file($filename);
		warn("  Nodes...\n");
		foreach my $node ($doc->findnodes("/osm/node")) {
			my $lat = 0 + $node->getAttribute("lat");
			my $lon = 0 + $node->getAttribute("lon");
			my $id = $node->getAttribute("id");
			my $svgx = $self->lon2x($lon);
			my $svgy = $self->lat2y($lat);
			$self->{_nodes}->{$id} = { svgx => $svgx, svgy => $svgy };
		}
		warn("  Ways...\n");
		foreach my $way ($doc->findnodes("/osm/way")) {
			my $id = $way->getAttribute("id");
			next if defined $self->{_ways}->{$id};
			$self->{_ways}->{$id} = 1;

			my $layer_name;
			my @class;
			foreach my $type (qw(railway highway building
					     landuse amenity leisure
					     natural waterway boundary
					     power man_made aeroway
					     sport barrier parking
					     tourism bridge)) {
				my $value = $way->findnodes("tag[\@k='$type']/\@v");
				next if !defined $value || $value eq "";
				$layer_name = "osm:$type=$value" unless defined $layer_name;
				push(@class, $type, $value);
			}
			if (!defined $layer_name) {
				my @stuff = (grep { ($_->nodeType() ne XML_TEXT_NODE &&
						     $_->nodeName() ne "nd" &&
						     !($_->nodeName() eq "tag" && $_->getAttribute("k") eq "admin_level") &&
						     !($_->nodeName() eq "tag" && $_->getAttribute("k") =~ /^tiger:/)
						    ) }
					     $way->childNodes());
				if (@stuff) {
					warn("We found a 'way' node that we don't know how to deal with yet:");
					foreach my $node (@stuff) {
						warn("\t", $node->toString(), "\n");
					}
				}
				next;
			}

			my $layer = $self->svg_layer($layer_name);
			if (!defined $layer) {
				$skipped{$layer_name} += 1;
				next;
			}

			my @nd = $way->findnodes("nd");
			my $closed = (scalar(@nd) > 2 &&
				      $nd[0]->getAttribute("ref") eq $nd[-1]->getAttribute("ref"));
			my $is_polygon = $closed;

			if ($is_polygon) {
				pop(@nd);
			}
			my @points = map { $self->{_nodes}->{$_->getAttribute("ref")} } @nd;
			my $points = join(" ",
					  map { sprintf("%.2f,%.2f", $_->{svgx}, $_->{svgy}) }
					  # %.2f is accurate/precise enough to within
					  # 1/9000'th of an inch
					  @points);

			if (all { $_->{svgx} <= $self->{_svg_west}  } @points) {
				next;
			}
			if (all { $_->{svgx} >= $self->{_svg_east}  } @points) {
				next;
			}
			if (all { $_->{svgy} <= $self->{_svg_north} } @points) {
				next;
			}
			if (all { $_->{svgy} >= $self->{_svg_south} } @points) {
				next;
			}

			my $style = $LAYER_INFO->{$layer_name}->{style};
			
			if ($is_polygon) {
				my $polygon = $self->{_svg_doc}->createElement("polygon");
				$polygon->setAttribute("points", $points);
				$self->apply_styles($polygon, $style) if $style;
				$layer->appendChild($polygon);
				$layer->appendText("\n");
			}
			else {
				my $polyline = $self->{_svg_doc}->createElement("polyline");
				$polyline->setAttribute("points", $points);
				$self->apply_styles($polyline, $style) if $style;
				$polyline->setAttribute("fill" => "none"); # override
				$polyline->setAttribute("stroke-linecap" => "round");
				$polyline->setAttribute("stroke-linejoin" => "round");
				$layer->appendChild($polyline);
				$layer->appendText("\n");
			}
		}
		foreach my $relation ($doc->findnodes("/osm/relation")) {
		}
	}

	my $test_layer = $self->svg_layer("test-layer");
	$test_layer->removeChildNodes();
	{
		my $rect = $self->{_svg_doc}->createElement("rect");
		$rect->setAttribute("x",       $self->lon2x($self->{west}));
		$rect->setAttribute("y",       $self->lat2y($self->{north}));
		$rect->setAttribute("width",   $self->lon2x($self->{east}) - $self->lon2x($self->{west}));
		$rect->setAttribute("height",  $self->lat2y($self->{south}) - $self->lat2y($self->{north}));
		$rect->setAttribute("style", "fill:none;stroke:blue;stroke-width:4;");
		$test_layer->appendChild($rect);
	}

	foreach my $skipped (sort keys(%skipped)) {
		warn(sprintf("Skipped %d %s ways\n", $skipped{$skipped}, $skipped));
	}
}

our %layer;
sub svg_layer {
	my ($self, $arg, $justfind) = @_;

	my $z_index;
	my $unclipped;
	my $name;

	if (ref($arg) eq "HASH") {
		$name = $arg->{name};
		$z_index = $arg->{z_index};
		$unclipped = $arg->{unclipped};
	}
	else {
		$name = $arg;
		$z_index = $LAYER_INFO->{$name}->{z_index};
		$unclipped = $LAYER_INFO->{$name}->{unclipped};
	}
	if (defined $layer{$name}) { return $layer{$name}; }
	if (!defined $z_index) { return undef; }
	$z_index += 0;
	my $id = "layer$z_index";
	my ($layer) = $self->{_svg_doc}->findnodes("//svg:g[\@inkscape:label='$name']");
	if ($justfind && !$layer) { return undef; }
	if (!$layer) {
		$layer = $self->{_svg_doc}->createElement("g");
		$layer->setAttribute("inkscape:label", $name);
		$layer->setAttribute("id", $id);
		$layer->setAttribute("inkscape:groupmode", "layer");
		$layer->appendText("\n");

		my ($svg)  = $self->{_svg_doc}->documentElement();
		my @layers = (grep { my $id = $_->getAttribute("id");
				     $id && $id =~ m{^layer(\d+)$} } 
			      $self->{_svg_doc}->findnodes("//svg:g"));

		my $i;
		for ($i = 0; $i < scalar(@layers); $i += 1) {
			next unless $layers[$i]->getAttribute("id") =~ m{^layer(\d+)$};
			my $checkid = $1 + 0;
			last unless $checkid <= $z_index;
		}
		if ($i >= scalar(@layers)) {
			$svg->appendText("\n");
			$svg->appendChild($layer);
			$svg->appendText("\n");
		}
		else {
			$svg->insertBefore($self->{_svg_doc}->createTextNode("\n"), $layers[$i]);
			$svg->insertBefore($layer, $layers[$i]);
			$svg->insertBefore($self->{_svg_doc}->createTextNode("\n"), $layers[$i]);
		}
	}
	if ($unclipped) {
		$layer->removeAttribute("clip-path");
		$layer->removeAttribute("clip-rule");
	}
	else {
		$layer->setAttribute("clip-path" => "url(#documentClipPath)");
		$layer->setAttribute("clip-rule" => "nonzero");
	}
	$layer{$name} = $layer;
	return $layer;
}

sub transit_feed {
	my ($self, $gtfs) = @_;
	if (!$gtfs->isa("Transit::GTFS")) {
		$gtfs = Transit::GTFS->new($gtfs);
	}
	$self->{gtfs} = $gtfs;
}

sub update_transit_stops {
	my ($self) = @_;
	my $gtfs = $self->{gtfs};
	if (!$gtfs) { return; }

	warn("Updating transit stops...\n");

	$self->update_scale();

	{
		my @existing_layers = (grep { my $label = $_->getAttribute("inkscape:label");
					      $label && $label =~ m{^gtfs:transit-stops$} }
				       $self->{_svg_doc}->findnodes("//svg:g"));
		foreach my $layer (@existing_layers) {
			$layer->parentNode()->removeChild($layer);
		}
	}

	my $dbh = $gtfs->dbh();
	
	my $bus_stops_layer = $self->svg_layer("gtfs:transit-stops");
	$bus_stops_layer->appendText("\n");

	my $sth = $dbh->prepare("select * from stops");
	$sth->execute();
	while (my $hash = $sth->fetchrow_hashref()) {
		my $stop_id = $hash->{stop_id};
		my $stop_code = $hash->{stop_code};
		my $lat = $hash->{stop_lat};
		my $lon = $hash->{stop_lon};

		my $g = $self->{_svg_doc}->createElement("g");
		$g->appendText("\n");
		
		my $circle1 = $self->{_svg_doc}->createElement("circle");
		$circle1->setAttribute("cx", $self->lon2x($lon));
		$circle1->setAttribute("cy", $self->lat2y($lat));
		$circle1->setAttribute("r", 0.5);
		$circle1->setAttribute("style", "fill:#666;stroke-width:0;stroke:none;");
		$g->appendChild($circle1);
		$g->appendText("\n");

		my $circle2 = $self->{_svg_doc}->createElement("circle");
		$circle2->setAttribute("cx", $self->lon2x($lon));
		$circle2->setAttribute("cy", $self->lat2y($lat));
		$circle2->setAttribute("r", 0.3);
		$circle2->setAttribute("style", "fill:white;stroke-width:0;stroke:none;");
		$g->appendChild($circle2);
		$g->appendText("\n");

		my $circle3 = $self->{_svg_doc}->createElement("circle");
		$circle3->setAttribute("cx", $self->lon2x($lon));
		$circle3->setAttribute("cy", $self->lat2y($lat));
		$circle3->setAttribute("r", 0.1);
		$circle3->setAttribute("style", "fill:black;stroke-width:0;stroke:none;");
		$g->appendChild($circle3);
		$g->appendText("\n");

		$bus_stops_layer->appendChild($g);
		$bus_stops_layer->appendText("\n");

	}
	warn("Done.\n");
}

sub update_transit_routes {
	my ($self) = @_;
	my $gtfs = $self->{gtfs};
	if (!$gtfs) { return; }

	$self->update_scale();

	{
		my @existing_layers = (grep { my $label = $_->getAttribute("inkscape:label");
					      $label && $label =~ m{^gtfs:route:} }
				       $self->{_svg_doc}->findnodes("/svg:svg/svg:g"));
		foreach my $layer (@existing_layers) {
			$layer->removeChildNodes();
		}
	}

	my $z_index = 6000;

	my @routes = ();

	my $dbh = $gtfs->dbh();

	my $routes_sth = $dbh->prepare("select * from routes");
	my $trips_sth = $dbh->prepare(qq{select distinct shape_id from trips where route_id = ?});
	my $shapes_sth = $dbh->prepare(qq{select shape_pt_lon, shape_pt_lat
                                          from shapes
                                          where shape_id = ?
                                          order by shape_pt_sequence asc});

	$routes_sth->execute();
	while (my $route = $routes_sth->fetchrow_hashref()) {
		printf("  Route %s - %s\n", $route->{route_short_name}, $route->{route_long_name});
		push(@routes, $route);
		my $name = sprintf("gtfs:route:%s:%s",
				   $route->{route_short_name},
				   $route->{route_long_name});
		my $layer = $self->svg_layer({ name => $name, z_index => $z_index++ });
		$layer->appendText("\n");

		my $style1 = "fill:none;stroke:white;stroke-width:1.1;";
		my $style2 = "fill:none;stroke:red;stroke-width:0.7;";

		my @shapes = ();

		$trips_sth->execute($route->{route_id});
		while (my ($shape_id) = $trips_sth->fetchrow_array()) {
			printf("    Shape %s\n", $shape_id);

			$shapes_sth->execute($shape_id);
			my @points = ();
			while (my ($lon, $lat) = $shapes_sth->fetchrow_array()) {
				push(@points, [$self->lon2x($lon),
					       $self->lat2y($lat)]);
			}
			$shapes_sth->finish();

			my $points = join(" ",
					  map { sprintf("%.2f,%.2f", @$_) }
					  # %.2f is accurate/precise enough to within
					  # 1/9000'th of an inch
					  @points);
			push(@shapes, $points);
		}
		$trips_sth->finish();

		foreach my $points (@shapes) {
			my $polyline1 = $self->{_svg_doc}->createElement("polyline");
			$polyline1->setAttribute("style", $style1);
			$polyline1->setAttribute("points", $points);
			$polyline1->setAttribute("stroke-linecap" => "round");
			$polyline1->setAttribute("stroke-linejoin" => "round");
			$layer->appendChild($polyline1);
			$layer->appendText("\n");
		}

		foreach my $points (@shapes) {
			my $polyline2 = $self->{_svg_doc}->createElement("polyline");
			$polyline2->setAttribute("style", $style2);
			$polyline2->setAttribute("points", $points);
			$polyline2->setAttribute("stroke-linecap" => "round");
			$polyline2->setAttribute("stroke-linejoin" => "round");
			$layer->appendChild($polyline2);
			$layer->appendText("\n");
		}
	}
	$routes_sth->finish();
}

sub apply_styles {
	my ($self, $object, $style) = @_;
	while (my ($k, $v) = each(%$style)) {
		$k =~ s{_}{-}g;
		$object->setAttribute($k, $v);
	}
}

sub create_all_layers {
	my ($self) = @_;
	foreach my $layer_name (keys %{$LAYER_INFO}) {
		$self->svg_layer($layer_name);
	}
}

sub finish_xml {
	my ($self) = @_;
	open(my $fh, ">", $self->{filename}) or
		die("cannot write $self->{filename}: $!\n");
	warn("Writing $self->{filename} ...\n");
	$self->{_svg_doc}->toFH($fh, 2);
	warn("Done.\n");
}

1;

