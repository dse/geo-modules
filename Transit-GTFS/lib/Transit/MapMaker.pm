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
	      transit_feed

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
		$parser->parse_file($self->{filename});
	};
	if (!$doc) {
		$doc = $parser->parse_string(<<"END");
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<?xml-stylesheet href="map.css" type="text/css"?>

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

our $layers;
BEGIN {
	$layers = {
		   "osm:natural=water"            => { z => 1010 },
		   "osm:waterway=river"           => { z => 1020 },
		   "osm:waterway=stream"          => { z => 1030 },
		   "osm:amenity=park"             => { z => 1040 },
		   "osm:leisure=park"             => { z => 1050 },
		   "osm:landuse=forest"           => { z => 1060 },
		   "osm:amenity=parking"          => { z => 1070 },
		   "osm:building=yes"             => { z => 1080 },
		   "osm:building=office"          => { z => 1081 },
		   "osm:landuse=industrial"       => { z => 1090 },
		   "osm:landuse=commercial"       => { z => 1091 },
		   "osm:amenity=university"       => { z => 1100 },
		   "osm:amenity=college"          => { z => 1101 },
		   "osm:amenity=school"           => { z => 1102 },
		   "osm:leisure=golf_course"      => { z => 1110 },
		   "osm:landuse=cemetery"         => { z => 1120 },
		   "osm:highway=unrecognized"     => { z => 2000 },
		   "osm:highway=track"            => { z => 2010 },
		   "osm:highway=footway"          => { z => 2020 },
		   "osm:highway=service"          => { z => 2030 },
		   "osm:highway=living_street"    => { z => 2040 },
		   "osm:highway=residential"      => { z => 2050 },
		   "osm:highway=unclassified"     => { z => 2060 },
		   "osm:highway=tertiary_link"    => { z => 2070 },
		   "osm:highway=tertiary"         => { z => 2075 },
		   "osm:highway=secondary_link"   => { z => 2080 },
		   "osm:highway=secondary"        => { z => 2090 },
		   "osm:highway=primary_link"     => { z => 2100 },
		   "osm:highway=primary"          => { z => 2110 },
		   "osm:highway=motorway_link"    => { z => 2120 },
		   "osm:highway=motorway"         => { z => 2130 },
		   "osm:highway=road"             => { z => 2140 },
		   "osm:highway=trunk"            => { z => 2150 },
		   "osm:railway=rail"             => { z => 3000 },
		   "osm:aeroway=apron"    => { z => 4000 },
		   "osm:aeroway=runway"   => { z => 4001 },
		   "osm:aeroway=taxiway"  => { z => 4002 },
		   "osm:aeroway=terminal" => { z => 4003 },

		   "highway-route-markers"    => { z => 5000 },

		   # bus routes, 6000 => 6999

		   "bus-stops"          => { z => 9000 },
		   "bus-route-numbers"  => { z => 9010 },
		   "park-and-ride-lots" => { z => 9020 },
		   "one-way-indicators" => { z => 9030 },
		   "points-of-interest" => { z => 9040 },
		   "street-names"       => { z => 9050 },
		   "place-names"        => { z => 9060 },
		   "test-layer"         => { z => 9500, unclipped => 1 },
		   "legend"             => { z => 10000, unclipped => 1 }
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

sub plot_osm_layers {
	my ($self) = @_;

	$self->update_scale();
	$self->add_clipping_path();

	$self->{_nodes} = {};
	$self->{_ways} = {};

	my %skipped;

	foreach my $layer_name (grep { m{^osm:} } keys(%$layers)) {
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
			my $circle = $self->{_svg_doc}->createElement("circle");
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
			
			if ($is_polygon) {
				my $polygon = $self->{_svg_doc}->createElement("polygon");
				$polygon->setAttribute("points", $points);
				$polygon->setAttribute("class", join(" ", @class)) if @class;
				$layer->appendChild($polygon);
				$layer->appendText("\n");
			}
			else {
				my $polyline = $self->{_svg_doc}->createElement("polyline");
				$polyline->setAttribute("points", $points);
				$polyline->setAttribute("class", join(" ", @class)) if @class;
				$layer->appendChild($polyline);
				$layer->appendText("\n");
			}
		}
		foreach my $relation ($doc->findnodes("/osm/relation")) {
			# eh?
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
		$rect->setAttribute("fill", "none");
		$rect->setAttribute("stroke", "black");
		$rect->setAttribute("stroke-width", "2");
		$test_layer->appendChild($rect);
	}

	foreach my $skipped (sort keys(%skipped)) {
		warn(sprintf("Skipped %d %s ways\n", $skipped{$skipped}, $skipped));
	}
}

our %layer;
sub svg_layer {
	my ($self, $name) = @_;
	if (defined $layer{$name}) {
		return $layer{$name};
	}
	my $zindex = $layers->{$name}->{z};
	my $unclipped = $layers->{$name}->{unclipped};
	if (!defined $zindex) {
		return undef;
	}
	$zindex += 0;
	my $id = "layer$zindex";
	my ($layer) = $self->{_svg_doc}->findnodes("//svg:g[\@inkscape:label='$name']");
	if (!$layer) {
		$layer = $self->{_svg_doc}->createElement("g");
		$layer->setAttribute("inkscape:label", $name);
		$layer->setAttribute("id", $id);
		$layer->setAttribute("inkscape:groupmode", "layer");
		$layer->appendText("\n");

		my ($svg)  = $self->{_svg_doc}->documentElement();
		my @layers = $self->{_svg_doc}->findnodes("//g");

		my $i;
		for ($i = 0; $i < scalar(@layers); $i += 1) {
			last unless $layers[$i]->getAttribute("id") =~ m{^layer(\d+)$};
			my $checkid = $1 + 0;
			last unless $checkid <= $zindex;
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

sub finish_xml {
	my ($self) = @_;
	open(my $fh, ">", $self->{filename}) or
		die("cannot write $self->{filename}: $!\n");
	$self->{_svg_doc}->toFH($fh, 2);
}

1;

