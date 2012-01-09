package Transit::MapMaker;
use warnings;
use strict;


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

=cut


our @_FIELDS;
BEGIN {
	@_FIELDS = qw(filename
		      north south east west
		      map_data_north map_data_south map_data_east map_data_west
		      paper_width paper_height paper_margin
		      grid
		      grid_sprintf
		      _gtfs_url
		      _gtfs
		      _parser
		      _svg_doc
		      _map_xml_filenames
		      _nodes
		      _ways
		      _scale
		      _south_y _north_y _east_x _west_x
		      _rad_width _rad_height
		      _svg_west _svg_east _svg_north _svg_south
		      _updated_clip_path_node
		    );
}
use fields @_FIELDS;

sub new {
	my ($class, %options) = @_;
	my $self = fields::new($class);
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
		my ($view) = $doc->findnodes("//sodipodi:namedview[\@id='base']");
		if ($view) {
			$view->setAttribute("inkscape:cx", $self->{paper_width} / 2);
			$view->setAttribute("inkscape:cy", $self->{paper_height} / 2);
		}
	}
	$self->{_parser} = $parser;
	$self->{_svg_doc} = $doc;
	$doc->documentElement()->setAttribute("width", $self->{paper_width});
	$doc->documentElement()->setAttribute("height", $self->{paper_height});
}

BEGIN {
	my $d2r = atan2(1, 1) / 45;
	my $r2d = 45 / atan2(1, 1);
	sub update_scale {
		my ($self) = @_;
		my $w = $self->{west};			 # in degrees
		my $e = $self->{east};			 # in degrees
		my $n = $self->{north};			 # in degrees
		my $s = $self->{south};			 # in degrees
		my $wx = $self->{_west_x} = _lon2x($w);	 # units
		my $ex = $self->{_east_x} = _lon2x($e);	 # units
		my $ny = $self->{_north_y} = _lat2y($n); # units
		my $sy = $self->{_south_y} = _lat2y($s); # units
		my $width  = $self->{_rad_width}  = $ex - $wx; # units
		my $height = $self->{_rad_height} = $ny - $sy; # units
		my $pww = $self->{paper_width}  - 2 * $self->{paper_margin}; # in px
		my $phh = $self->{paper_height} - 2 * $self->{paper_margin}; # in px
		if ($width / $height <= $pww / $phh) {
			$self->{_scale} = $phh / $height; # px/unit
		}
		else {
			$self->{_scale} = $pww / $width; # px/unit
		}
		$self->{_svg_west}  = $self->lon2x($self->{west});
		$self->{_svg_east}  = $self->lon2x($self->{east});
		$self->{_svg_north} = $self->lat2y($self->{north});
		$self->{_svg_south} = $self->lat2y($self->{south});
		$self->{_updated_clip_path_node} = 0;
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
		return $self->{paper_margin} + $self->{_scale} * (_lon2x($lon) - $self->{_west_x});
	}
	sub lat2y {
		my ($self, $lat) = @_;
		return $self->{paper_margin} + $self->{_scale} * ($self->{_north_y} - _lat2y($lat));
	}
}

our $LAYER_INFO;
BEGIN {
	$LAYER_INFO = {"osm:natural=water"            => { z_index => 1010, style => "fill:#bbd;stroke:#bbd;stroke-width:0.25;" },
		       "osm:waterway=river"           => { z_index => 1020, style => "fill:#bbd;stroke:#bbd;stroke-width:0.25;" },
		       "osm:waterway=stream"          => { z_index => 1030, style => "fill:#bbd;stroke:#bbd;stroke-width:0.25;" },
		       "osm:amenity=park"             => { z_index => 1040, style => "fill:#cfc;" },
		       "osm:leisure=park"             => { z_index => 1050, style => "fill:#cfc;" },
		       "osm:landuse=forest"           => { z_index => 1060, style => "fill:#cfc;" },
		       "osm:amenity=parking"          => { z_index => 1070, style => "fill:#f7f7f7;" },
		       "osm:building=yes"             => { z_index => 1080, style => "fill:#e6e6e6;" },
		       "osm:building=office"          => { z_index => 1081, style => "fill:#e6e6e6;" },
		       "osm:landuse=industrial"       => { z_index => 1090, style => "fill:#eee;" },
		       "osm:landuse=commercial"       => { z_index => 1091, style => "fill:#eee;" },
		       "osm:amenity=university"       => { z_index => 1100, style => "fill:#ddf;" },
		       "osm:amenity=college"          => { z_index => 1101, style => "fill:#ddf;" },
		       "osm:amenity=school"           => { z_index => 1102, style => "fill:#ddf;" },
		       "osm:leisure=golf_course"      => { z_index => 1110, style => "fill:#ffc;" },
		       "osm:landuse=cemetery"         => { z_index => 1120, style => "fill:#cfc;" },
		       "osm:highway=track"            => { z_index => 2010, style => "fill:none;stroke:#ddd;stroke-width:0.25;" },
		       "osm:highway=footway"          => { z_index => 2020, style => "fill:none;stroke:#ddd;stroke-width:0.25;" },
		       "osm:highway=service"          => { z_index => 2030, style => "fill:none;stroke:#ddd;stroke-width:0.25;" },
		       "osm:highway=living_street"    => { z_index => 2040, style => "fill:none;stroke:#ddd;stroke-width:0.25;" },
		       "osm:highway=residential"      => { z_index => 2050, style => "fill:none;stroke:#ddd;stroke-width:0.50;" },
		       "osm:highway=unclassified"     => { z_index => 2060, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=tertiary_link"    => { z_index => 2070, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=tertiary"         => { z_index => 2075, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=secondary_link"   => { z_index => 2080, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=secondary"        => { z_index => 2090, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=primary_link"     => { z_index => 2100, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=primary"          => { z_index => 2110, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=motorway_link"    => { z_index => 2120, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=motorway"         => { z_index => 2130, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=road"             => { z_index => 2140, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:highway=trunk"            => { z_index => 2150, style => "fill:none;stroke:#ddd;stroke-width:0.70;" },
		       "osm:railway=rail"             => { z_index => 3000, style => "fill:none;stroke:#999;stroke-width:0.25;" },
		       "osm:aeroway=apron"            => { z_index => 4000, style => "fill:#ddd;stroke:#ddd;stroke-width:0.25;" },
		       "osm:aeroway=terminal"         => { z_index => 4003, style => "fill:#ccc;stroke:#ccc;stroke-width:0.25;" },
		       "osm:aeroway=runway"           => { z_index => 4001, style => "fill:none;stroke:#ddd;stroke-width:2;" },
		       "osm:aeroway=taxiway"          => { z_index => 4002, style => "fill:none;stroke:#ddd;stroke-width:2;" },
		       "highway-route-markers"        => { z_index => 5000 }, # user-edited
		       # transit routes are layers 6000 - 6999
		       "gtfs:transit-stops"           => { z_index => 7000 },
		       "transit-route-numbers"        => { z_index => 7010 }, # user-edited
		       "park-and-ride-lots"           => { z_index => 7020 }, # user-edited
		       "one-way-indicators"           => { z_index => 7030 }, # user-edited
		       "points-of-interest"           => { z_index => 9040 }, # user-edited
		       "street-names"                 => { z_index => 9050 }, # user-edited
		       "place-names"                  => { z_index => 9060 }, # user-edited
		       "generated:map-border"         => { z_index => 9500,  unclipped => 1, style => "fill:none;stroke:black;stroke-width:4;" },
		       "legend"                       => { z_index => 10000, unclipped => 1 }, # user-edited
		       "generated:grid"               => { z_index => 11000, unclipped => 1,
							   style => "fill:none;stroke:#ccf;stroke-width:0.25;",
							   text_style => ("font-family:Arial;font-size:6px;font-style:normal;font-variant:normal;font-weight:normal;" .
									  "font-stretch:normal;" .
									  "text-align:center;text-anchor:middle;" .
									  "line-height:100%;" .
									  "writing-mode:lr-tb;" .
									  "fill:black;fill-opacity:1;stroke:none;") },
		      };
}

sub update_clip_path_node {
	my ($self) = @_;
	if ($self->{_updated_clip_path_node}) { return; }
	
	my $svg_doc = $self->{_svg_doc};
	my $svg_doc_element = $svg_doc->documentElement();
	my ($defs) = $svg_doc->findnodes("//svg:defs");
	if (!$defs) {
		$defs = $svg_doc->createElement("defs");
		$svg_doc_element->insertBefore($defs, $svg_doc_element->firstChild());
	}

	my ($clipPath) = $defs->findnodes("clipPath[\@id='documentClipPath']");
	if ($clipPath) {
		$clipPath->parentNode()->removeChild($clipPath);
	}

	$clipPath = $svg_doc->createElement("clipPath");
	$clipPath->setAttribute("id", "documentClipPath");
	$defs->appendChild($clipPath);
	
	my $left   = $self->lon2x($self->{west});
	my $right  = $self->lon2x($self->{east});
	my $top    = $self->lat2y($self->{north});
	my $bottom = $self->lat2y($self->{south});

	my $d = sprintf("M %f %f H %f V %f H %f Z",
			#  #1 #2   #3   #4   #5
			$left, $top, $right, $bottom, $left);
	#               #1     #2    #3      #4       #5
			
	my $path = $svg_doc->createElement("path");
	$path->setAttribute("id" => "documentClipPathPath");
	$path->setAttribute("d" => $d);
	$path->setAttribute("inkscape:connector-curvature" => 0);
	$clipPath->appendChild($path);

	$self->{_updated_clip_path_node} = 1;
}

sub refresh_osm_styles {
	my ($self) = @_;
	$self->update_scale();
	$self->update_clip_path_node();

	warn("Refreshing styles...\n");
	foreach my $layer_name (grep { m{^osm:} } keys(%$LAYER_INFO)) {
		warn("  $layer_name...\n");
		my ($layer, $group) = $self->svg_layer_node($layer_name, { nocreate => 1 });
		next unless $layer;
		my $style = $LAYER_INFO->{$layer_name}->{style};
		foreach my $polyline ($group->findnodes("svg:polyline")) {
			if ($style) {
				$style =~ s{(^|;)(?:fill|stroke-linecap|stroke-linejoin):[^;]*(;|$)}{$1$2}gi;
				$style =~ s{;{2,}}{;}g;
				$style =~ s{^;}{};
				$style .= "fill:none;stroke-linecap:round;stroke-linejoin:round;";
				$polyline->setAttribute("style", $style);
			}
		}
		foreach my $polygon ($group->findnodes("svg:polygon")) {
			if ($style) {
				$polygon->setAttribute("style", $style);
			}
		}
		foreach my $path ($group->findnodes("svg:path")) {
			if ($style) {
				$path->setAttribute("style", $style);
			}
		}
	}
	warn("Done updating styles.\n");
}

sub plot_osm_layers {
	my ($self) = @_;
	$self->update_scale();
	$self->update_clip_path_node();

	$self->{_nodes} = {};
	$self->{_ways} = {};

	my %skipped;

	foreach my $layer_name (grep { m{^osm:} } keys(%$LAYER_INFO)) {
		$self->svg_layer_node($layer_name, { clear => 1 });
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

			my ($layer, $group) = $self->svg_layer_node($layer_name);
			if (!defined $layer) {
				$skipped{$layer_name} += 1;
				next;
			}

			my @nd = $way->findnodes("nd");
			my $closed = (scalar(@nd) > 2 &&
				      $nd[0]->getAttribute("ref") eq $nd[-1]->getAttribute("ref"));
			if ($closed) {
				pop(@nd);
			}
			my @points = map { $self->{_nodes}->{$_->getAttribute("ref")} } @nd;
			my $points = join(" ",
					  map { sprintf("%.2f,%.2f", $_->{svgx}, $_->{svgy}) }
					  # %.2f is accurate/precise enough to within
					  # 1/9000'th of an inch
					  @points);

			# if every point in a polyline/polygon is past
			# one of the borders, you're not going to see
			# it.
			if (all { $_->{svgx} <= $self->{_svg_west}  } @points) { next; }
			if (all { $_->{svgx} >= $self->{_svg_east}  } @points) { next; }
			if (all { $_->{svgy} <= $self->{_svg_north} } @points) { next; }
			if (all { $_->{svgy} >= $self->{_svg_south} } @points) { next; }

			my $style = $LAYER_INFO->{$layer_name}->{style};
			
			if ($closed) {
				my $path = $self->{_svg_doc}->createElement("path");
				$path->setAttribute("d", "M $points Z");
				if ($style) {
					$path->setAttribute("style", $style);
				}
				$group->appendText("      ");
				$group->appendChild($path);
				$group->appendText("\n");
			}
			else {
				my $path = $self->{_svg_doc}->createElement("path");
				$path->setAttribute("d", "M $points");

				if ($style) {
					$style =~ s{(^|;)(?:fill|stroke-linecap|stroke-linejoin):[^;]*(;|$)}{$1$2}gi;
					$style =~ s{;{2,}}{;}g;
					$style =~ s{^;}{};
					$style .= "fill:none;stroke-linecap:round;stroke-linejoin:round;";
					$path->setAttribute("style", $style);
				}

				$group->appendText("      ");
				$group->appendChild($path);
				$group->appendText("\n");
			}
		}
		foreach my $relation ($doc->findnodes("/osm/relation")) {
			# eh?
		}
	}

	foreach my $skipped (sort keys(%skipped)) {
		warn(sprintf("Skipped %d %s ways\n", $skipped{$skipped}, $skipped));
	}

	$self->update_map_border();
}

sub update_map_border {
	my ($self) = @_;
	$self->update_scale();
	$self->update_clip_path_node();
	
	my ($map_border, $map_border_group) = $self->svg_layer_node("generated:map-border", { clear => 1 });
	{
		my $rect = $self->{_svg_doc}->createElement("rect");
		$rect->setAttribute("x",       $self->lon2x($self->{west}));
		$rect->setAttribute("y",       $self->lat2y($self->{north}));
		$rect->setAttribute("width",   $self->lon2x($self->{east}) - $self->lon2x($self->{west}));
		$rect->setAttribute("height",  $self->lat2y($self->{south}) - $self->lat2y($self->{north}));
		$rect->setAttribute("style",   $LAYER_INFO->{"generated:map-border"}->{"style"});
		$map_border_group->appendChild($rect);
	}
}

our %layer;
sub svg_layer_node {
	my ($self, $arg, $opts) = @_;

	$opts //= {};

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

	if (defined $layer{$name}) {
		if ($opts->{clear}) {
			$layer{$name}->{group}->removeChildNodes();
			$layer{$name}->{group}->appendText("\n");
		}
		if (wantarray) {
			return ($layer{$name}->{layer},
				$layer{$name}->{group});
		}
		else {
			return $layer{$name}->{group};
		}
	}
	if (!defined $z_index) {
		return undef;
	}
	$z_index += 0;
	my $id = "layer$z_index";

	my ($layer) = $self->{_svg_doc}->findnodes("//svg:g[\@inkscape:label='$name']");
	if ($opts->{nocreate} && !$layer) {
		return undef;
	}

	my $group;			# whatever is actually returned
	if ($layer) {
		($group) = (grep { ($_->nodeType() == XML_ELEMENT_NODE &&
				    $_->nodeName() eq "g") }
			    $layer->childNodes());
	}
	else {
		$layer = $self->{_svg_doc}->createElement("g");
		$layer->setAttribute("inkscape:label", $name);
		$layer->setAttribute("id", $id);
		$layer->setAttribute("inkscape:groupmode", "layer");
		$layer->appendText("\n");

		$group = $self->{_svg_doc}->createElement("g");
		$group->appendText("\n");

		$layer->appendText("    ");
		$layer->appendChild($group);
		$layer->appendText("\n");

		my ($svg_doc_element) = $self->{_svg_doc}->documentElement();
		my @layers = (grep { eval { ( $_->nodeType() == XML_ELEMENT_NODE &&
					      $_->nodeName() eq "g" &&
					      $_->getAttribute("id") =~ m{^layer(\d+)$} ) } }
			      $svg_doc_element->nonBlankChildNodes());

		my $i;
		my $insertBefore = undef;
		for ($i = 0; $i < scalar(@layers); $i += 1) {
			my $layer__id = $layers[$i]->getAttribute("id");
			next unless defined $layer__id;
			next unless $layer__id =~ m{^layer(\d+)$};
			my $checkid = $1 + 0;
			if ($checkid > $z_index) {
				$insertBefore = $layers[$i];
				last;
			}
		}

		$svg_doc_element->insertBefore($layer, $insertBefore);
	}

	if ($unclipped) {
		$group->removeAttribute("clip-path");
		$group->removeAttribute("clip-rule");
	}
	else {
		$group->setAttribute("clip-path" => "url(#documentClipPath)");
		$group->setAttribute("clip-rule" => "nonzero");
	}

	$layer{$name} = { layer => $layer,
			  group => $group };
	if (wantarray) {
		return ($layer, $group);
	}
	else {
		return $group;
	}
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
	$self->update_clip_path_node();

	my $gtfs = $self->{_gtfs};
	if (!$gtfs) { return; }

	warn("Updating transit stops...\n");

	my $dbh = $gtfs->dbh();
	
	my ($bus_stops_layer, $bus_stops_group) =
		$self->svg_layer_node("gtfs:transit-stops", { clear => 1 });

	my $sth = $dbh->prepare("select * from stops");
	$sth->execute();
	while (my $hash = $sth->fetchrow_hashref()) {
		my $stop_id = $hash->{stop_id};
		my $stop_code = $hash->{stop_code};
		my $lat = $hash->{stop_lat};
		my $lon = $hash->{stop_lon};

		my $circle = $self->{_svg_doc}->createElement("circle");
		$circle->setAttribute("cx", $self->lon2x($lon));
		$circle->setAttribute("cy", $self->lat2y($lat));
		$circle->setAttribute("r", 0.5);
		$circle->setAttribute("style", "fill:#000000;stroke-width:0;stroke:none;");

		$bus_stops_group->appendText("      ");
		$bus_stops_group->appendChild($circle);
		$bus_stops_group->appendText("\n");
	}
	warn("Done.\n");
}

sub update_transit_routes {
	my ($self) = @_;
	$self->update_scale();
	$self->update_clip_path_node();

	my $gtfs = $self->{_gtfs};
	if (!$gtfs) { return; }

	warn("  Deleting existing route layers...\n");
	{
		my @existing_layers = (grep { my $label = $_->getAttribute("inkscape:label");
					      $label && $label =~ m{^gtfs:route:} }
				       $self->{_svg_doc}->findnodes("/svg:svg/svg:g"));
		foreach my $layer (@existing_layers) {
			my ($group) = $layer->nonBlankChildNodes();
			if ($group) {
				$group->removeChildNodes();
				$group->appendText("\n");
			}
		}
	}

	warn("Updating transit route layers...\n");

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
		warn(sprintf("  Creating layer for Route %s - %s\n",
			     $route->{route_short_name},
			     $route->{route_long_name}));
		push(@routes, $route);
		my $name = sprintf("gtfs:route:%s:%s",
				   $route->{route_short_name},
				   $route->{route_long_name});
		my ($layer, $group) =
			$self->svg_layer_node({ name => $name,
						z_index => $z_index++ });

		my @shapes = ();

		$trips_sth->execute($route->{route_id});
		while (my ($shape_id) = $trips_sth->fetchrow_array()) {
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

		my $style = "fill:none;stroke:red;stroke-width:0.7;stroke-linecap:round;stroke-linejoin:round;";
		foreach my $points (@shapes) {
			my $path = $self->{_svg_doc}->createElement("path");
			$path->setAttribute("d", "M $points");
			$path->setAttribute("style", $style);

			$group->appendText("      ");
			$group->appendChild($path);
			$group->appendText("\n");
		}
	}
	$routes_sth->finish();
}

sub update_grid {
	my ($self) = @_;
	$self->update_scale();
	$self->update_clip_path_node();

	my $grid = $self->{grid};
	return unless $grid;

	my $sprintf = $self->{grid_sprintf} // "%.4f";
	my $doc = $self->{_svg_doc};

	my ($grid_layer, $grid_layer_group) = $self->svg_layer_node("generated:grid", { clear => 1 });
	my $south = $self->{south}; my $ys = $self->lat2y($south);
	my $north = $self->{north}; my $yn = $self->lat2y($north);
	my $east = $self->{east};   my $xe = $self->lon2x($east);
	my $west = $self->{west};   my $xw = $self->lon2x($west);
	for (my $lat = int($south / $grid) * $grid; $lat <= $north; $lat += $grid) {

		next if abs($lat - $south) < 0.000001;
		next if abs($lat - $north) < 0.000001;

		my $y = $self->lat2y($lat);

		my $path = $doc->createElement("path");
		$path->setAttribute("d", "M $xw,$y $xe,$y");
		$path->setAttribute("style", $LAYER_INFO->{"generated:grid"}->{style});
		$grid_layer_group->appendText("    ");
		$grid_layer_group->appendChild($path);
		$grid_layer_group->appendText("\n");

		my $text = $doc->createElement("text");
		$text->setAttribute("x", $xw);
		$text->setAttribute("y", $y);
		$text->setAttribute("style", $LAYER_INFO->{"generated:grid"}->{text_style});
		$text->setAttribute("xml:space", "preserve");
		my $tspan = $doc->createElement("tspan");
		$tspan->setAttribute("x", $xw);
		$tspan->setAttribute("y", $y);
		$tspan->appendText(sprintf($sprintf, $lat));
		$text->appendChild($tspan);
		$grid_layer_group->appendText("    ");
		$grid_layer_group->appendChild($text);
		$grid_layer_group->appendText("\n");
	}
	for (my $lon = int($west / $grid) * $grid;
	     $lon <= $east;
	     $lon += $grid) {

		next if abs($lon - $east) < 0.000001;
		next if abs($lon - $west) < 0.000001;

		my $x = $self->lon2x($lon);

		my $path = $doc->createElement("path");
		$path->setAttribute("d", "M $x,$ys $x,$yn");
		$path->setAttribute("style", $LAYER_INFO->{"generated:grid"}->{style});
		$grid_layer_group->appendText("    ");
		$grid_layer_group->appendChild($path);
		$grid_layer_group->appendText("\n");

		my $text = $doc->createElement("text");
		$text->setAttribute("x", $x);
		$text->setAttribute("y", $ys);
		$text->setAttribute("style", $LAYER_INFO->{"generated:grid"}->{text_style});
		$text->setAttribute("xml:space", "preserve");
		my $tspan = $doc->createElement("tspan");
		$tspan->setAttribute("x", $x);
		$tspan->setAttribute("y", $ys);
		$tspan->appendText(sprintf($sprintf, $lon));
		$text->appendChild($tspan);
		$grid_layer_group->appendText("    ");
		$grid_layer_group->appendChild($text);
		$grid_layer_group->appendText("\n");
	}
}

sub create_all_layers {
	my ($self) = @_;
	warn("Making sure all layers are created...\n");
	foreach my $layer_name (keys %{$LAYER_INFO}) {
		warn("  $layer_name...\n");
		$self->svg_layer_node($layer_name);
	}
}

sub finish_xml {
	my ($self) = @_;
	open(my $fh, ">", $self->{filename}) or
		die("cannot write $self->{filename}: $!\n");
	warn("Writing $self->{filename} ...\n");
	$self->{_svg_doc}->toFH($fh, 1);
	warn("Done.\n");
}

1;

