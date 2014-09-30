package Geo::MapMaker;
use warnings;
use strict;

use Carp qw(croak);
use Carp qw(confess);
use YAML::Syck qw(Dump);

use constant FALSE => 0;
use constant TRUE  => 1;

# NOTE: "ground" and "background" are apparently treated as the same
# classname in SVG, or some shit.

=head1 NAME
	
Geo::MapMaker - Create semi-usable maps from GTFS and OSM data.

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

		  classes
		  layers
		  route_colors
		  route_overrides
		  grid
		  crop_lines
		  crop_marks
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

		  _cache
		  include
		  transit_route_overrides
		  transit_route_defaults
		  transit_route_groups
		  transit_orig_route_color_mapping
		  transit_trip_exceptions
		  transit_route_fix_overlaps
		  _dirty_
		  debug
		  verbose


		  _scale_px_per_er

		  north_deg
		  south_deg
		  east_deg
		  west_deg

		  map_data_north_deg
		  map_data_south_deg
		  map_data_east_deg
		  map_data_west_deg

		  paper_width_px
		  paper_height_px
		  paper_margin_px
		  fudge_factor_px

		  extend_to_full_page

		  vertical_align
		  horizontal_align

		  _west_er
		  _east_er
		  _north_er
		  _south_er

		  _west_er_outer
		  _east_er_outer
		  _north_er_outer
		  _south_er_outer

		  _west_svg
		  _east_svg
		  _north_svg
		  _south_svg

		  _west_svg_outer
		  _east_svg_outer
		  _north_svg_outer
		  _south_svg_outer

		  orientation

		  converter

		);
}
use fields @_FIELDS;

sub new {
    my ($class, %options) = @_;
    my $self = fields::new($class);
    $self->{verbose} = 0;
    $self->{debug} = {};
    $self->{_cache} = {};
    $self->{paper_width_px}  = 90 * 8.5;
    $self->{paper_height_px} = 90 * 11;
    $self->{paper_margin_px} = 90 * 0.25;
    $self->{fudge_factor_px} = 90 * 0.25;
    $self->{extend_to_full_page} = FALSE;
    $self->{vertical_align} = "top";
    $self->{horizontal_align} = "left";
    $self->{_gtfs_list} = [];
    while (my ($k, $v) = each(%options)) {
	if ($self->can($k)) {
	    $self->$k($v);
	} else {
	    $self->{$k} = $v;
	}
    }
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    if ($self->{_dirty_}) {
	$self->save();
    }
}

use XML::LibXML qw(:all);
use LWP::Simple;
use URI;
use Carp qw(croak);
use Carp qw(confess);
use File::Path qw(mkpath);
use File::Basename;
use List::MoreUtils qw(all firstidx uniq);
use Geo::MapMaker::Util qw(file_get_contents file_put_contents move_line_away);
use Geo::MapMaker::CoordinateConverter;

our %NS;
BEGIN {
    $NS{"xmlns"}    = undef;
    $NS{"svg"}      = "http://www.w3.org/2000/svg";
    $NS{"inkscape"} = "http://www.inkscape.org/namespaces/inkscape";
    $NS{"sodipodi"} = "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd";
    $NS{"mapmaker"} = "http://webonastick.com/namespaces/geo-mapmaker";
}

sub update_openstreetmap {
    my ($self, $force) = @_;
    $self->{_map_xml_filenames} = [];
    $self->_update_openstreetmap($force);
}

sub _update_openstreetmap {
    my ($self, $force, $west_deg, $south_deg, $east_deg, $north_deg) = @_;
    
    $west_deg  //= $self->west_map_data_boundary_deg();
    $south_deg //= $self->south_map_data_boundary_deg();
    $east_deg  //= $self->east_map_data_boundary_deg();
    $north_deg //= $self->north_map_data_boundary_deg();
    
    my $center_lat = ($north_deg + $south_deg) / 2;
    my $center_lon = ($west_deg + $east_deg) / 2;
    
    my $url = sprintf("http://api.openstreetmap.org/api/0.6/map?bbox=%.8f,%.8f,%.8f,%.8f",
		      $west_deg, $south_deg, $east_deg, $north_deg);
    my $txt_filename = sprintf("%s/.geo-mapmaker-osm/map_%.8f_%.8f_%.8f_%.8f_bbox.txt",
			       $ENV{HOME}, $west_deg, $south_deg, $east_deg, $north_deg);
    my $xml_filename = sprintf("%s/.geo-mapmaker-osm/map_%.8f_%.8f_%.8f_%.8f_bbox.xml",
			       $ENV{HOME}, $west_deg, $south_deg, $east_deg, $north_deg);
    
    mkpath(dirname($xml_filename));
    my $status = eval { file_get_contents($txt_filename); };
    
    if ($status && $status eq "split-up") {
	$self->_update_openstreetmap($force, $west_deg,   $south_deg,  $center_lon, $center_lat);
	$self->_update_openstreetmap($force, $center_lon, $south_deg,  $east_deg,   $center_lat);
	$self->_update_openstreetmap($force, $west_deg,   $center_lat, $center_lon, $north_deg);
	$self->_update_openstreetmap($force, $center_lon, $center_lat, $east_deg,   $north_deg);
    } elsif (-e $xml_filename && !$force) {
	warn("Not updating $xml_filename\n") if $self->{verbose};
	push(@{$self->{_map_xml_filenames}}, $xml_filename);
    } else {
	my $ua = LWP::UserAgent->new();
	print STDERR ("Downloading $url ... ");
	my $response = $ua->mirror($url, $xml_filename);
	printf STDERR ("%s\n", $response->status_line());
	my $rc = $response->code();
	if ($rc == RC_NOT_MODIFIED) {
	    push(@{$self->{_map_xml_filenames}}, $xml_filename);
	    # ok then
	} elsif ($rc == 400) {
	    file_put_contents($txt_filename, "split-up");
	    my $center_lat = ($north_deg + $south_deg) / 2;
	    my $center_lon = ($west_deg + $east_deg) / 2;
	    $self->_update_openstreetmap($force, $west_deg,   $south_deg,  $center_lon, $center_lat);
	    $self->_update_openstreetmap($force, $center_lon, $south_deg,  $east_deg,   $center_lat);
	    $self->_update_openstreetmap($force, $west_deg,   $center_lat, $center_lon, $north_deg);
	    $self->_update_openstreetmap($force, $center_lon, $center_lat, $east_deg,   $north_deg);
	} elsif (is_success($rc)) {
	    push(@{$self->{_map_xml_filenames}}, $xml_filename);
	    # ok then
	} else {
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
   xmlns:mapmaker="http://webonastick.com/namespaces/geo-mapmaker"
   width="765"
   height="990"
   id="svg2"
   version="1.1"
   inkscape:version="0.48.1 "
   sodipodi:docname="Map"
   mapmaker:version="1">
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
    
    $doc_elt->setAttribute("width", sprintf("%.2f", $self->{paper_width_px}));
    $doc_elt->setAttribute("height", sprintf("%.2f", $self->{paper_height_px}));
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
				  sprintf("%.2f", $self->{paper_width_px} / 2));
	    $view->setAttributeNS($NS{"inkscape"}, "inkscape:cy",
				  sprintf("%.2f", $self->{paper_height_px} / 2));
	}
    }
    
    # keep dox with the old namespace working
    $doc_elt->setAttributeNS("http://www.w3.org/2000/xmlns/", "xmlns:mapmaker", $NS{"mapmaker"});
    
    $self->{_map_areas} = [ { is_main => 1, name => "Main Map" }, 
			    eval { @{$self->{inset_maps}} } ];
    
    $self->add_indexes_to_array($self->{_map_areas});
    $self->add_indexes_to_array($self->{transit_route_groups});
    
    foreach my $map_area (@{$self->{_map_areas}}) {
	my $id = $map_area->{id};
	my $index = $map_area->{index};
	if ($index == 0) {
	    $map_area->{clip_path_id} = "main_area_clip_path";
	} elsif (defined $id) {
	    $map_area->{clip_path_id} = "inset_${id}_clip_path";
	} else {
	    $map_area->{clip_path_id} = "inset${index}_clip_path";
	}
	if ($index == 0) {
	    $map_area->{id_prefix} = "";
	} elsif (defined $id) {
	    $map_area->{id_prefix} = $id . "_";
	} else {
	    $map_area->{id_prefix} = "ma" . $index . "_";
	}
    }
    
    $self->{_read_filename} = $self->{filename};
    
    $self->upgrade_mapmaker_version();
    
    $self->{_dirty_} = 1;
}

sub upgrade_mapmaker_version_from_0_to_1 {
    my ($self) = @_;
    # stub upgrade to add version number
}

sub upgrade_mapmaker_version {
    my ($self) = @_;
    my $doc_elt = $self->{_svg_doc_elt};
    if (!$doc_elt) { return; }
    my $version = $doc_elt->getAttributeNS($NS{"mapmaker"}, "version") // 0;
    my $old_version = $version;
    warn("Document is at mapmaker:version $version.  Checking for upgrades...\n");
    while (TRUE) {
	my $next_version = $version + 1;
	my $sub_name = "upgrade_mapmaker_version_from_${version}_to_${next_version}";
	last if (!(exists &$sub_name));
	warn("  Upgrading from version ${version} to version ${next_version}...\n");
	$self->$sub_name();
	$version = $next_version;
	$doc_elt->setAttributeNS($NS{"mapmaker"}, "version", $version);
	$self->{_dirty_} = 1;
	warn("  Done.\n");
    }
    if ($old_version eq $version) {
	warn("No upgrades necessary.\n");
    } else {
	warn("All upgrades complete.\n");
    }
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

sub clip_path_d {
    my ($self) = @_;
    my $left   = $self->west_outer_map_boundary_svg();
    my $right  = $self->east_outer_map_boundary_svg();
    my $top    = $self->north_outer_map_boundary_svg();
    my $bottom = $self->south_outer_map_boundary_svg();
    my $d = sprintf("M %.2f %.2f H %.2f V %.2f H %.2f Z",
		    $left, $top, $right, $bottom, $left);
    return $d;
}

sub find_or_create_defs_node {
    my ($self) = @_;
    my $doc = $self->{_svg_doc};
    my $doc_elt = $doc->documentElement();
    my ($defs) = $doc->findnodes("/*/svg:defs");
    if (!$defs) {
	$self->{_dirty_} = 1;
	$defs = $doc->createElementNS($NS{"svg"}, "defs");
	$doc_elt->insertBefore($defs, $doc_elt->firstChild());
    }
    $defs->setAttribute("id", "geoMapmakerDefs");
    return $defs;
}

sub update_or_create_style_node {
    my ($self) = @_;
    my $doc = $self->{_svg_doc};
    my $defs = $self->find_or_create_defs_node();
    my ($style) = $defs->findnodes("svg:style[\@mapmaker:autogenerated]");
    if (!$style) {
	$self->{_dirty_} = 1;
	$style = $self->create_element("svg:style",
				       autogenerated => 1,
				       children_autogenerated => 1);
	$style->setAttribute("type", "text/css");
	$defs->appendChild($style);
    }
    $style->setAttribute("id", "geoMapmakerStyles");

    my $contents = "\n";
	
    $contents .= <<'END';
	.WHITE      { fill: #fff; }
	.MAP_BORDER { fill: none !important; stroke-linejoin: square !important; }
	.OPEN       { fill: none !important; stroke-linecap: round; stroke-linejoin: round; }
	.TEXT_NODE_BASE {
		text-align: center;
		text-anchor: middle;
	}
        /*
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
        */
END

    foreach my $class (sort keys %{$self->{classes}}) {
	my $css   = $self->compose_style_string(class => $class);
	my $css_2 = $self->compose_style_string(class => $class, style_attr_name => "style_2");
	$contents .= "\t.${class}    { $css }\n";
	$contents .= "\t.${class}_2 { $css_2 }\n" if $self->has_style_2(class => $class);
    }

    $self->{_dirty_} = 1;
    $style->removeChildNodes(); # OK
    my $cdata = $doc->createCDATASection($contents);
    $style->appendChild($cdata);
}

sub update_or_create_clip_path_node {
    my ($self, $map_area) = @_;
    my $defs = $self->find_or_create_defs_node();
    my $doc = $self->{_svg_doc};

    my $clip_path_id      = $map_area->{clip_path_id};
    my $clip_path_path_id = $clip_path_id . "_path";

    my $cpnode;
    my $path;
    my @others;

    $self->{_dirty_} = 1;
    ($cpnode, @others) = $defs->findnodes("svg:clipPath[\@id='$clip_path_id']");
    if (!$cpnode) {
	$cpnode = $doc->createElementNS($NS{"svg"}, "clipPath");
	$cpnode->setAttribute("id", $clip_path_id);
	$defs->appendChild($cpnode);
    }
    $cpnode->setAttributeNS($NS{"mapmaker"}, "autogenerated", "true");
    foreach my $other (@others) {
	$other->unbindNode();
    }
	
    ($path, @others) = $cpnode->findnodes("svg:path");
    if (!$path) {
	$path = $doc->createElementNS($NS{"svg"}, "path");
	$cpnode->appendChild($path);
    }
    $path->setAttribute("id" => $clip_path_path_id);
    $path->setAttributeNS($NS{"mapmaker"}, "autogenerated" => "true");
    $path->setAttribute("d" => $self->clip_path_d());
    $path->setAttributeNS($NS{"inkscape"}, "connector-curvature" => 0);
    foreach my $other (@others) {
	$other->unbindNode();
    }

    return $cpnode;
}

use constant POINT_X => 0;
use constant POINT_Y => 1;
use constant POINT_X_ZONE => 2;
use constant POINT_Y_ZONE => 3;

sub find_layer_insertion_point {
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

sub update_or_create_map_area_layer {
    my ($self, $map_area, $options) = @_;
	
    my $doc     = $self->{_svg_doc};
    my $doc_elt = $self->{_svg_doc_elt};

    my $under           = $options && $options->{under};
    my $insertion_point = $self->find_layer_insertion_point();
    my $layer_name      = $map_area->{name} // ("Inset " . $map_area->{index});

    my $more_options = {};

    if ($under) {
	$more_options->{but_before} = $layer_name;
	$layer_name .= " (under)";
    } else {
	$more_options->{but_after} = $layer_name . " (under)";
    }
	
    $self->{_dirty_} = 1;
	
    my $class = $options->{class};
    if (defined $class) {
	$class .= " mapAreaLayer";
    } else {
	$class = "mapAreaLayer";
    }
    if ($map_area->{is_main}) {
	$class .= " mainMapAreaLayer";
    } else {
	$class .= " insetMapAreaLayer";
    }

    my $id;
    if ($map_area->{is_main}) {
	$id = $options->{id} // "mapAreaLayer_main";
    } else {
	$id = $options->{id} // "mapAreaLayer_" . $map_area->{id};
    }

    my $map_area_layer = $self->update_or_create_layer(%$options,
						       %$more_options,
						       class           => $class,
						       id              => $id,
						       name            => $layer_name,
						       parent          => $doc_elt,
						       insertion_point => $insertion_point,
						       autogenerated   => 1);
    if ($map_area->{is_main}) {
	$map_area_layer->setAttributeNS($NS{"mapmaker"}, "main-map", "true");
    } else {
	$map_area_layer->setAttributeNS($NS{"mapmaker"}, "inset-map", "true");
    }
    return $map_area_layer;
}

sub update_or_create_background_layer {
    my ($self, $map_area, $map_layer) = @_;
    $self->{_dirty_} = 1;
    my $background = $self->update_or_create_layer(name => "Background Color",
						   class => "backgroundColorLayer",
						   id => $map_area->{id_prefix} . "backgroundColorLayer",
						   z_index => 1,
						   parent => $map_layer,
						   insensitive => 1,
						   autogenerated => 1,
						   children_autogenerated => 1);
    $background->removeChildNodes(); # OK
    my $rect = $self->rectangle(x      => $self->west_outer_map_boundary_svg,
				y      => $self->north_outer_map_boundary_svg,
				width  => $self->east_outer_map_boundary_svg - $self->west_outer_map_boundary_svg,
				height => $self->south_outer_map_boundary_svg - $self->north_outer_map_boundary_svg,
				class  => "map-background BACKGROUND",
				id     => $map_area->{id_prefix} . "map-background"
			       );
    $background->appendChild($rect);
    return $background;
}

sub update_or_create_white_layer {
    my ($self, $map_area, $map_layer) = @_;
    $self->{_dirty_} = 1;
    my $background = $self->update_or_create_layer(name => "White Background",
						   class => "whiteBackgroundLayer",
						   id => $map_area->{id_prefix} . "whiteBackgroundLayer",
						   z_index => 0,
						   parent => $map_layer,
						   insensitive => 1,
						   autogenerated => 1,
						   children_autogenerated => 1);
    $background->removeChildNodes(); # OK
    my $rect = $self->rectangle(x      => $self->west_outer_map_boundary_svg,
				y      => $self->north_outer_map_boundary_svg,
				width  => $self->east_outer_map_boundary_svg - $self->west_outer_map_boundary_svg,
				height => $self->south_outer_map_boundary_svg - $self->north_outer_map_boundary_svg,
				class  => "map-white WHITE",
				id     => $map_area->{id_prefix} . "whiteRect"
			       );
    $background->appendChild($rect);
    return $background;
}

sub update_or_create_border_layer {
    my ($self, $map_area, $map_layer) = @_;
    $self->{_dirty_} = 1;
    my $border = $self->update_or_create_layer(name => "Border",
					       class => "borderLayer",
					       id => $map_area->{id_prefix} . "borderLayer",
					       z_index => 9999,
					       parent => $map_layer,
					       insensitive => 1,
					       autogenerated => 1,
					       children_autogenerated => 1);
    $border->removeChildNodes(); # OK
    my $rect = $self->rectangle(x      => $self->west_outer_map_boundary_svg,
				y      => $self->north_outer_map_boundary_svg,
				width  => $self->east_outer_map_boundary_svg - $self->west_outer_map_boundary_svg,
				height => $self->south_outer_map_boundary_svg - $self->north_outer_map_boundary_svg,
				class  => "map-border MAP_BORDER",
				id     => $map_area->{id_prefix} . "map-border"
			       );
    $border->appendChild($rect);
    return $border;
}

sub update_or_create_openstreetmap_layer {
    my ($self, $map_area, $map_area_layer) = @_;
    $self->{_dirty_} = 1;
    my $layer = $self->update_or_create_layer(name => "OpenStreetMap",
					      class => "openStreetMapLayer",
					      id => $map_area->{id_prefix} . "openStreetMapLayer",
					      z_index => 100,
					      parent => $map_area_layer,
					      autogenerated => 1);
    return $layer;
}

sub update_or_create_transit_map_layer {
    my ($self, $map_area, $map_area_layer) = @_;
    $self->{_dirty_} = 1;
    my $layer = $self->update_or_create_layer(name => "Transit",
					      class => "transitMapLayer",
					      id => $map_area->{id_prefix} . "transitMapLayer",
					      z_index => 200,
					      parent => $map_area_layer,
					      autogenerated => 1);
    return $layer;
}

sub update_or_create_transit_stops_layer {
    my ($self, $map_area, $map_area_layer) = @_;
    $self->{_dirty_} = 1;
    my $layer = $self->update_or_create_layer(name => "Transit Stops",
					      class => "transitStopsLayer",
					      id => $map_area->{id_prefix} . "transitStopsLayer",
					      z_index => 300,
					      parent => $map_area_layer,
					      insensitive => 1,
					      autogenerated => 1,
					      children_autogenerated => 1);
    return $layer;
}

sub get_transit_routes {
    my ($self, $gtfs) = @_;
    my $data = $gtfs->{data};
    if ($data->{routes}) {
	return $gtfs->selectall("select * from routes where route_short_name in (??)",
				{}, @{$data->{routes}});
    } elsif ($data->{routes_except}) {
	return $gtfs->selectall("select * from routes where route_short_name not in (??)",
				{}, @{$data->{routes_except}});
    } else {
	return $gtfs->selectall("select * from routes");
    }
}

sub get_transit_stops {
    my ($self, $gtfs) = @_;
    my $data = $gtfs->{data};
    if ($data->{routes}) {
	my $sql = <<"END";
			select	distinct stops.*
			from	stops
			join	stop_times on stops.stop_id = stop_times.stop_id
			join	trips on stop_times.trip_id = trips.trip_id
			join	routes on trips.route_id = routes.route_id
       			where	routes.route_short_name in (??);
END
	return $gtfs->selectall($sql, {}, @{$data->{routes}});
    } elsif ($data->{routes_except}) {
	my $sql = <<"END";
			select	distinct stops.*
			from	stops
			join	stop_times on stops.stop_id = stop_times.stop_id
			join	trips on stop_times.trip_id = trips.trip_id
			join	routes on trips.route_id = routes.route_id
			where	routes.route_short_name not in (??);
END
	return $gtfs->selectall($sql, {}, @{$data->{routes_except}});
    } else {
	my $sql = <<"END";
			select * from stops;
END
	return $gtfs->selectall($sql, {});
    }
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
	} else {
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
	} elsif ($stop_name) {
	    $sth4->execute($route_short_name, $stop_name);
	    while (my $hash = $sth4->fetchrow_hashref()) {
		my @hash = %$hash;
		push(@trips, { %$hash });
	    }
	} elsif ($stop_code) {
	    $sth5->execute($route_short_name, $stop_code);
	    while (my $hash = $sth5->fetchrow_hashref()) {
		my @hash = %$hash;
		push(@trips, { %$hash });
	    }
	} elsif ($stop_id) {
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
	} else {
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
	} else {
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
    while (my ($lon_deg, $lat_deg) = $sth->fetchrow_array()) {
	push(@result, [$lon_deg, $lat_deg]);
    }
    $sth->finish();
    return @result;
}

sub clear_transit_map_layers {
    my ($self) = @_;
    $self->{_dirty_} = 1;
    foreach my $map_area (@{$self->{_map_areas}}) {
	$self->update_scale($map_area);
	my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
	my $transit_map_layer = $self->update_or_create_transit_map_layer($map_area, $map_area_layer);
	$self->erase_autogenerated_content_within($transit_map_layer);
    }
}

sub clear_transit_stops_layers {
    my ($self) = @_;
    $self->{_dirty_} = 1;
    foreach my $map_area (@{$self->{_map_areas}}) {
	$self->update_scale($map_area);
	my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
	my $transit_stops_layer = $self->update_or_create_transit_stops_layer($map_area, $map_area_layer);
	$self->erase_autogenerated_content_within($transit_stops_layer);
    }
}

sub draw_transit_stops {
    my ($self) = @_;

    my @gtfs = $self->gtfs();
    if (!scalar(@gtfs)) { return; }

    $self->init_xml();

    $self->{_dirty_} = 1;
    $self->clear_transit_stops_layers();
    $self->stuff_all_layers_need();

    foreach my $gtfs (@gtfs) {
	$self->diagf("Fetching transit stops for %s ... ", $gtfs->{data}->{name});
	my @stops = $self->get_transit_stops($gtfs, { });
	$self->diag("Done.\n");
		
	$self->diagf("Drawing transit stops for %s ... ", $gtfs->{data}->{name});
		
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
	    my $west_svg  = $self->west_outer_map_boundary_svg;
	    my $east_svg  = $self->east_outer_map_boundary_svg;
	    my $north_svg = $self->north_outer_map_boundary_svg;
	    my $south_svg = $self->south_outer_map_boundary_svg;
		
	    my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
	    my $transit_stops_layer = $self->update_or_create_transit_stops_layer($map_area, $map_area_layer);
	    $self->erase_autogenerated_content_within($transit_stops_layer);
	    my $clipped_group = $self->find_or_create_clipped_group(parent => $transit_stops_layer,
								    clip_path_id => $map_area->{clip_path_id});

	    my $plot = sub {
		my ($stop, $class, $r, $suffix) = @_;
		$suffix //= "";
		my $stop_id   = $stop->{stop_id};
		my $stop_code = $stop->{stop_code};
		my $stop_name = $stop->{stop_name};
		my $stop_desc = $stop->{stop_desc};
		my $lat_deg       = $stop->{stop_lat};
		my $lon_deg       = $stop->{stop_lon};
		my $title = join(" - ", grep { $_ } ($stop_code, $stop_name, $stop_desc));

		my ($x, $y) = $self->{converter}->lon_lat_deg_to_x_y_px($lon_deg, $lat_deg);
		
		return if $x < $west_svg  || $x > $east_svg;
		return if $y < $north_svg || $y > $south_svg;
		my $circle = $self->circle_node(x => $x, y => $y, r => $r,
						class => $class,
						title => $title,
						id => "ts_" . $stop_code . $suffix);
		$clipped_group->appendChild($circle);
	    };
		
	    foreach my $stop ($self->get_transit_stops($gtfs)) {
		$plot->($stop, $class, $r);
	    }
	    if ($has_style_2) {
		foreach my $stop ($self->get_transit_stops($gtfs)) {
		    $plot->($stop, $class_2, $r_2, "_2");
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

    $self->{_dirty_} = 1;
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

	    next if scalar(@routes) && !grep { $_ eq $route_short_name || $_ eq $agency_route } @routes;
			
	    my $route_long_name = $route->{route_long_name};
	    my $route_desc  = $route->{route_desc};
	    my $route_name  = $route->{name}  = join(" - ", grep { $_ } ($route_short_name, $route_long_name));
	    my $route_title = $route->{title} = join(" - ", grep { $_ } ($route_short_name, $route_long_name, $route_desc));
	    my $route_color = $route->{route_color};
	    if ($route_color) {
		$route_color = "#" . lc($route_color);
	    }

	    $self->diagf("  Route $agency_route - $route_title ...\n");
			
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

	    my $route_group_name;
	    if (defined($route_group_name = $self->{transit_route_overrides}->{$route_short_name}->{group})) {
		$self->warnf("  route $route_short_name => $route_group_name [by route override]\n")
		  if $self->{debug}->{routegroup} or $self->{verbose} >= 2;
	    } elsif (defined($route_group_name = $self->{transit_route_overrides}->{$agency_route}->{group})) {
		$self->warnf("  route $route_short_name => $route_group_name [by agency/route override]\n")
		  if $self->{debug}->{routegroup} or $self->{verbose} >= 2;
	    } elsif (defined($route_group_name = $self->{transit_orig_route_color_mapping}->{$route_color}->{group})) {
		$self->warnf("  route $route_short_name => $route_group_name [by route color $route_color]\n")
		  if $self->{debug}->{routegroup} or $self->{verbose} >= 2;
	    } elsif (defined($route_group_name = $self->{transit_route_defaults}->{group})) {
		$self->warnf("  route $route_short_name => $route_group_name [by default]\n")
		  if $self->{debug}->{routegroup} or $self->{verbose} >= 2;
	    }

	    my $route_group = $route_group_by_name{$route_group_name};
	    next unless $route_group;
	    $route_group{$agency_route} = $route_group;

	    foreach my $map_area (@{$self->{_map_areas}}) {
		my $map_area_index = $map_area->{index};
		$self->update_scale($map_area);
		my $west_svg  = $self->west_outer_map_boundary_svg;
		my $east_svg  = $self->east_outer_map_boundary_svg;
		my $north_svg = $self->north_outer_map_boundary_svg;
		my $south_svg = $self->south_outer_map_boundary_svg;
		foreach my $shape_id (@shape_id) {
		    my @coords = $self->get_transit_route_shape_points($gtfs, $shape_id);
		    $shape_coords{$agency_route}{$shape_id} = [@coords];
		    my @svg_coords = map {

			my ($svgx, $svgy) = $self->{converter}->lon_lat_deg_to_x_y_px($_->[0], $_->[1]);

			my $xzone = ($svgx <= $west_svg)  ? -1 : ($svgx >= $east_svg)  ? 1 : 0;
			my $yzone = ($svgy <= $north_svg) ? -1 : ($svgy >= $south_svg) ? 1 : 0;
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

    if ($self->{transit_route_fix_overlaps}) {
	# FIXME
	if (scalar(@{$self->{transit_route_fix_overlaps}})) {
	    $self->diag("Handling user-defined overlaps...\n");
	}
	foreach my $overlap (@{$self->{transit_route_fix_overlaps}}) {
	    my $separation = $overlap->{separation} // 1.0;
	    my $direction   = $overlap->{direction}   // 0;
	    my $direction_2 = $direction;
	    if ($direction eq "left") {
		$direction_2 = "right";
	    } elsif ($direction eq "right") {
		$direction_2 = "left";
	    }
	    my $agency_route_A = $overlap->{route_A}; # this route stays
	    my $agency_route_B = $overlap->{route_B}; # this route gets moved over
	    next unless defined $agency_route_A;
	    next unless defined $agency_route_B;
	    $self->diag("  overlap $agency_route_A $agency_route_B...");
	    my $north_deg = $overlap->{north_deg};
	    my $south_deg = $overlap->{south_deg};
	    my $east_deg  = $overlap->{east_deg};
	    my $west_deg  = $overlap->{west_deg};
	    foreach my $map_area (@{$self->{_map_areas}}) {
		my $map_area_index = $map_area->{index};
		$self->update_scale($map_area);
		my $north_svg = defined $north_deg ? $self->{converter}->lat_deg_to_y_px($north_deg) : undef;
		my $south_svg = defined $south_deg ? $self->{converter}->lat_deg_to_y_px($south_deg) : undef;
		my $east_svg  = defined $east_deg  ? $self->{converter}->lon_deg_to_x_px($east_deg)  : undef;
		my $west_svg  = defined $west_deg  ? $self->{converter}->lon_deg_to_x_px($west_deg)  : undef;
		foreach my $shape_id_B (keys(%{$shape_svg_coords{$map_area_index}{$agency_route_B}})) {
		    foreach my $shape_id_A (keys(%{$shape_svg_coords{$map_area_index}{$agency_route_A}})) {
			move_line_away($north_svg, $south_svg, $east_svg, $west_svg,
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
    }

    $self->diag("Drawing routes...\n");

    foreach my $gtfs (@gtfs) {
	$self->warnf(" gtfs agency_id %s name %s\n",
		     $gtfs->{data}{agency_id},
		     $gtfs->{data}{name})
	  if $self->{debug}->{drawtransitroutes};
	my $agency_id = $gtfs->{data}{agency_id};
	foreach my $route ($self->get_transit_routes($gtfs)) {
			
	    my $route_short_name = $route->{route_short_name};
	    my $agency_route = $agency_id . "/" . $route_short_name;

	    next if scalar(@routes) && !grep { $_ eq $route_short_name || $_ eq $agency_route } @routes;

	    my $route_long_name = $route->{route_long_name};
	    my $route_desc  = $route->{route_desc};
	    my $route_name  = $route->{name}  = join(" - ", grep { $_ } ($route_short_name, $route_long_name));
	    my $route_title = $route->{title} = join(" - ", grep { $_ } ($route_short_name, $route_long_name, $route_desc));

	    $self->diag("  Route $agency_route - $route_title ...\n");

	    my @shape_id = @{$route_shape_id{$agency_route}};
	    foreach my $map_area (@{$self->{_map_areas}}) {
		my $map_area_index = $map_area->{index};
		$self->update_scale($map_area);
				
		my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
		my $transit_map_layer = $self->update_or_create_transit_map_layer($map_area, $map_area_layer);
				
		my $normal_shape_collection    = { shortname => "normal",
						   suffix => "",
						   group => $route_group{$agency_route},
						   shapes => [ ] };
		my $exception_shape_collection = { shortname => "exception",
						   suffix => "_ex",
						   group => $exceptions_group,
						   shapes => [ ] };
		my $shape_collections = [ $exception_shape_collection,
					  $normal_shape_collection ];
				
		foreach my $collection (@$shape_collections) {
		    my $route_group = $collection->{group};
		    my $route_group_class = $route_group->{class};
		    my $route_group_layer = $self->update_or_create_layer(name    => $route_group->{name},
									  class   => "transitRouteGroupLayer",
									  id      => $map_area->{id_prefix} . "transitRouteGroupLayer_rt" . $route_short_name . $collection->{suffix},
									  z_index => $route_group->{index},
									  parent  => $transit_map_layer,
									  autogenerated => 1);
		    my $route_layer = $self->update_or_create_layer(name   => $route_name,
								    class  => "transitRouteLayer",
								    id     => $map_area->{id_prefix} . "transitRouteLayer_rt" . $route_short_name . $collection->{suffix},
								    parent => $route_group_layer,
								    insensitive => 1,
								    autogenerated => 1,
								    children_autogenerated => 1);
		    my $clipped_group = $self->find_or_create_clipped_group(parent => $route_layer,
									    clip_path_id => $map_area->{clip_path_id});
		    $collection->{class}   = "${route_group_class} ta_${agency_id}_rt rt_${route_short_name}";
		    $collection->{class_2} = "${route_group_class}_2 ta_${agency_id}_rt_2 rt_${route_short_name}_2";
		    $collection->{route_group_layer} = $route_group_layer;
		    $collection->{route_layer}       = $route_layer;
		    $collection->{clipped_group}     = $clipped_group;
		}
				
		foreach my $shape_id (@shape_id) {
		    next unless $shape_svg_coords{$map_area_index};
		    next unless $shape_svg_coords{$map_area_index}{$agency_route};
		    next unless $shape_svg_coords{$map_area_index}{$agency_route}{$shape_id};

		    my @svg_coords = @{$shape_svg_coords{$map_area_index}{$agency_route}{$shape_id}};
		    my $collection;
		    if ($shape_excluded{$agency_route}{$shape_id}) {
			next;
		    } elsif ($shape_excepted{$agency_route}{$shape_id}) {
			$collection = $exception_shape_collection;
		    } else {
			$collection = $normal_shape_collection;
		    }
		    next unless $collection;
		    push(@{$collection->{shapes}}, \@svg_coords);
		}

		foreach my $collection (@$shape_collections) {
		    $collection->{shapes} = [ find_chunks(@{$collection->{shapes}}) ];
		}

		foreach my $collection (@$shape_collections) {
		    my $class             = $collection->{class};
		    my $class_2           = $collection->{class_2};
		    my $clipped_group     = $collection->{clipped_group};
		    my $index = 0;
		    foreach my $shape (@{$collection->{shapes}}) {

			if ($self->{debug}->{drawtransitroutes}) {
			    $self->warnf("       drawing a shape for rt $route_short_name $collection->{shortname}\n");
			}
						
			my $id = $map_area->{id_prefix} . "rt" . $route_short_name . "_ch" . $index;
			my $id2 = $id . "_2";
			my $polyline = $self->polyline(points => $shape, class => $class, id => $id);
			$clipped_group->appendChild($polyline);
			if ($self->has_style_2(class => $class)) {
			    my $polyline_2 = $self->polyline(points => $shape, class => $class_2, id => $id2);
			    $clipped_group->appendChild($polyline_2);
			}
		    } continue {
			$index += 1;
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

    $self->{_dirty_} = 1;
    $self->stuff_all_layers_need();
    foreach my $map_area (@{$self->{_map_areas}}) {
	$self->update_scale($map_area); # don't think this is necessary, but . . .
	$self->update_or_create_style_node();
    }
}

sub stuff_all_layers_need {
    my ($self) = @_;

    $self->{_dirty_} = 1;

    foreach my $map_area (@{$self->{_map_areas}}) {
	$self->update_scale($map_area);
	my $map_area_under_layer = $self->update_or_create_map_area_layer($map_area, { under => 1 });
	my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
	$self->update_or_create_clip_path_node($map_area);
	$self->update_or_create_white_layer($map_area, $map_area_under_layer);
	$self->update_or_create_background_layer($map_area, $map_area_under_layer);
	$self->update_or_create_style_node();
	$self->update_or_create_border_layer($map_area, $map_area_layer);
    }
}

sub draw_openstreetmap_maps {
    my ($self) = @_;

    $self->init_xml();
    $self->{_dirty_} = 1;
    $self->stuff_all_layers_need();
	
    foreach my $map_area (@{$self->{_map_areas}}) {
	$self->update_scale($map_area);
	my $prefix = $map_area->{id_prefix};
	my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
	my $clip_path_id = $map_area->{clip_path_id};
	my $osm_layer = $self->update_or_create_openstreetmap_layer($map_area,
								    $map_area_layer);
	$self->erase_autogenerated_content_within($osm_layer);
	foreach my $info (@{$self->{osm_layers}}) {
	    my $layer = $self->update_or_create_layer(name => $info->{name},
						      parent => $osm_layer,
						      insensitive => 1,
						      autogenerated => 1,
						      children_autogenerated => 1);
	    my $group = $self->find_or_create_clipped_group(parent => $layer,
							    clip_path_id => $clip_path_id);
	    $group->removeChildNodes(); # OK
	    $info->{_map_area_layer} //= [];
	    $info->{_map_area_group} //= [];
	    push(@{$info->{_map_area_layer}}, $layer);
	    push(@{$info->{_map_area_group}}, $group);
	}
    }

    my %unused;
    my $num_maps = scalar(@{$self->{_map_xml_filenames}});
    my $map_number = 0;
    my %wayid_used;
    my %nodeid_used;

    my %way_preindex_k;
    my %node_preindex_k;
    my %way_preindex_kv;
    my %node_preindex_kv;
    foreach my $info (@{$self->{osm_layers}}) {
	my $tags = $info->{tags};
	my $type = $info->{type} // "way"; # 'way' or 'node'
	foreach my $tag (@$tags) {
	    my ($k, $v) = @{$tag}{qw(k v)};
	    if ($type eq "way") {
		$way_preindex_k{$k} = 1;
		$way_preindex_kv{$k,$v} = 1 if defined $v;
	    } elsif ($type eq "node") {
		$node_preindex_k{$k} = 1;
		$node_preindex_kv{$k,$v} = 1 if defined $v;
	    }
	}
    }

    foreach my $filename (@{$self->{_map_xml_filenames}}) {
	$map_number += 1;

	$self->diag("($map_number/$num_maps) Parsing $filename ... ");
	my $doc = $self->{_parser}->parse_file($filename);
	$self->diag("done.\n");

	$self->diag("  Finding <node> elements ... ");
	my @nodes = $doc->findnodes("/osm/node");

	my %node_coords;
	my %node_info;
	my %node_index_k;
	my %node_index_kv;
	my %nodeid_exclude;

	$self->diag(scalar(@nodes) . " elements found.\n");
	foreach my $map_area (@{$self->{_map_areas}}) {
	    $self->update_scale($map_area);
	    my $index = $map_area->{index};
	    my $area_name = $map_area->{name};
	    $self->diag("    Indexing for map area $area_name ... ");
	    my $west_svg  = $self->west_outer_map_boundary_svg;
	    my $east_svg  = $self->east_outer_map_boundary_svg;
	    my $north_svg = $self->north_outer_map_boundary_svg;
	    my $south_svg = $self->south_outer_map_boundary_svg;
	    foreach my $node (@nodes) {
		my $id  = $node->getAttribute("id");
		my $lat_deg = 0 + $node->getAttribute("lat");
		my $lon_deg = 0 + $node->getAttribute("lon");
		my ($svgx, $svgy) = $self->{converter}->lon_lat_deg_to_x_y_px($lon_deg, $lat_deg);
		my $xzone = ($svgx <= $west_svg)  ? -1 : ($svgx >= $east_svg)  ? 1 : 0;
		my $yzone = ($svgy <= $north_svg) ? -1 : ($svgy >= $south_svg) ? 1 : 0;
		my $result = [$svgx, $svgy, $xzone, $yzone];
		$node_coords{$id}[$index] = $result;
	    }
	}
	$self->diag("done.\n");

	foreach my $node (@nodes) {
	    my $id = $node->getAttribute("id");
	    if ($nodeid_used{$id}) { # for all split-up areas
		$nodeid_exclude{$id} = 1; # for this split-up area
		next;
	    }
	    $nodeid_used{$id} = 1;

	    my $result = { id => $id, tags => {} };

	    my @tag = $node->findnodes("tag");
	    foreach my $tag (@tag) {
		my $k = $tag->getAttribute("k");
		my $v = $tag->getAttribute("v");
		$result->{tags}->{$k} = $v;
		if ($node_preindex_kv{$k,$v}) {
		    push(@{$node_index_kv{$k, $v}}, $result);
		}
		if ($node_preindex_k{$k}) {
		    push(@{$node_index_k{$k}}, $result);
		}
	    }
	}
	$self->diag("done.\n");

	$self->diag("  Finding <way> elements ... ");
	my @ways = $doc->findnodes("/osm/way");

	my %ways;
	my %way_index_k;
	my %way_index_kv;
	my %wayid_exclude;

	$self->diag(scalar(@ways) . " elements found; indexing ... ");
	foreach my $way (@ways) {
	    my $id = $way->getAttribute("id");
	    if ($wayid_used{$id}) { # for all split-up areas
		$wayid_exclude{$id} = 1; # for this split-up area
		next;
	    }
	    $wayid_used{$id} = 1;
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
		$result->{tags}->{$k} = $v;
		if ($way_preindex_kv{$k,$v}) {
		    push(@{$way_index_kv{$k, $v}}, $result);
		}
		if ($way_preindex_k{$k}) {
		    push(@{$way_index_k{$k}}, $result);
		}
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
		next if $wayid_exclude{$id};
		my @nodeid = @{$ways{$id}{nodeid}};
		my @points = map { $node_coords{$_}[$index] } @nodeid;
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
		my $group = $info->{_map_area_group}[$index];
		my $type = $info->{type} // "way"; # 'way' or 'node'

		if ($type eq "way") {

		    my $class = $info->{class};

		    my @ways;
		    foreach my $tag (@$tags) {
			my $k = $tag->{k};
			my $v = $tag->{v};
			if (defined $v) {
			    eval { push(@ways, @{$way_index_kv{$k, $v}}); };
			} else {
			    eval { push(@ways, @{$way_index_k{$k}}); };
			}
		    }
		    @ways = uniq @ways;

		    $self->warnf("  %s (%d objects) ...\n", $name, scalar(@ways))
		      if $self->{debug}->{countobjectsbygroup} or $self->{verbose} >= 2;

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

			my $id  = $map_area->{id_prefix} . "w" . $way->{id};
			my $id2 = $map_area->{id_prefix} . "w" . $way->{id} . "_2";

			if ($way->{closed}) {
			    my $polygon = $self->polygon(points => $points,
							 class => $closed_class,
							 id => $id);
			    $group->appendChild($polygon);
			    if ($self->has_style_2(class => $class)) {
				my $polygon_2 = $self->polygon(points => $points,
							       class => $closed_class_2,
							       id => $id2);
				$group->appendChild($polygon_2);
			    }
			} else {
			    my $polyline = $self->polyline(points => $points,
							   class => $open_class,
							   id => $id);
			    $group->appendChild($polyline);
			    if ($self->has_style_2(class => $class)) {
				my $polyline_2 = $self->polyline(points => $points,
								 class => $open_class_2,
								 id => $id2);
				$group->appendChild($polyline_2);
			    }
			}
		    }
		} elsif ($type eq "node") {
		    my @nodes;
		    foreach my $tag (@$tags) {
			my $k = $tag->{k};
			my $v = $tag->{v};
			if (defined $v) {
			    eval { push(@nodes, @{$node_index_kv{$k, $v}}); };
			} else {
			    eval { push(@nodes, @{$node_index_k{$k}}); };
			}
		    }
		    @nodes = uniq @nodes;

		    $self->warnf("  %s (%d objects) ...\n", $name, scalar(@nodes))
		      if $self->{debug}->{countobjectsbygroup} or $self->{verbose} >= 2;

		    if ($info->{output_text}) {
			my $class = $info->{text_class};
			foreach my $node (@nodes) {
			    $node->{used} = 1;
			    my $coords = $node_coords{$node->{id}}[$index];
			    my ($x, $y) = @$coords;
			    # don't care about if out of bounds i guess
			    my $text = $node->{tags}->{name};
			    my $id  = $map_area->{id_prefix} . "tn" . $node->{id};
			    my $text_node = $self->text_node(x => $x, y => $y, text => $text,
							     class => $class, id => $id);
			    $group->appendChild($text_node);
			}
		    }

		    if ($info->{output_dot}) {
			my $class = $info->{dot_class};
			my $r = $self->get_style_property(class => $class, property => "r");
			foreach my $node (@nodes) {
			    $node->{used} = 1;
			    my $coords = $node_coords{$node->{id}}[$index];
			    my ($x, $y) = @$coords;
			    # don't care about if out of bounds i guess
			    my $id  = $map_area->{id_prefix} . "cn" . $node->{id};
			    my $circle = $self->circle_node(x => $x, y => $y, r => $r,
							    class => $class, id => $id);
			    $group->appendChild($circle);
			}
		    }

		}
	    }

	    $self->diag("\ndone.\n");
	}

	foreach my $k (keys(%way_index_k)) {
	    my @unused = grep { !$_->{used} } @{$way_index_k{$k}};
	    foreach my $v (map { $_->{tags}->{$k} } @unused) {
		$unused{$k,$v} += 1;
	    }
	}
    }

    if ($self->{verbose} >= 2) {
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
}

sub polygon {
    my ($self, %args) = @_;
    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $self->points_to_path(1, @{$args{points}}));
    $path->setAttribute("class", $args{class}) if defined $args{class};
    $path->setAttribute("id",    $args{id})    if defined $args{id};
    return $path;
}

sub polyline {
    my ($self, %args) = @_;
    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $self->points_to_path(0, @{$args{points}}));
    $path->setAttribute("class", $args{class}) if defined $args{class};
    $path->setAttribute("id",    $args{id})    if defined $args{id};
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

sub find_or_create_clipped_group {
    my ($self, %args) = @_;
    my $clip_path_id = $args{clip_path_id};
    my $parent = $args{parent};

    if ($parent) {
	my ($group) = $parent->findnodes("svg:g[\@clip-path='url(#${clip_path_id})' and \@clip-rule='nonzero']");
	return $group if $group;
    }

    $self->{_dirty_} = 1;

    my $group = $self->{_svg_doc}->createElementNS($NS{"svg"}, "g");
    $group->setAttribute("clip-path" => "url(#${clip_path_id})");
    $group->setAttribute("clip-rule" => "nonzero");
    $group->setAttribute("class", $args{class}) if defined $args{class};
    $group->setAttribute("id",    $args{id})    if defined $args{id};
    if ($parent) {
	$parent->appendChild($group);
    }
    return $group;
}

sub update_or_create_layer {
    my ($self, %args) = @_;

    $self->init_xml();

    my $insertion_point        = $args{insertion_point};
    my $name                   = $args{name};
    my $parent                 = $args{parent} // $self->{_svg_doc_elt};
    my $z_index                = $args{z_index};
    my $insensitive            = $args{insensitive};
    my $id                     = $args{id};
    my $class                  = $args{class};
    my $no_create              = $args{no_create};
    my $no_modify              = $args{no_modify};
    my $autogenerated          = $args{autogenerated};
    my $children_autogenerated = $args{children_autogenerated};
    my $recurse                = $args{recurse};

    my $but_before             = $args{but_before};
    my $but_after              = $args{but_after};

    my $search_prefix = "";
    if ($recurse) {
	if ($no_create) {
	    $search_prefix = ".//";
	} else {
	    die("Cannot use recurse option without no_create option.");
	}
    }

    my $layer;
    if (!$layer && defined $id) {
	($layer) = $parent->findnodes($search_prefix . "svg:g[\@id='$id']");
    }
    if (!$layer && defined $name) {
	($layer) = $parent->findnodes($search_prefix . "svg:g[\@inkscape:label='$name']");
    }
    if (!$layer && !$no_create) {
	$self->{_dirty_} = 1;
	$layer = $self->{_svg_doc}->createElementNS($NS{"svg"}, "g");
	if ($insertion_point) {
	    if (defined $but_before) {
		my $new = $insertion_point->findnodes("previous-sibling::node()[\@inkscape::label='$but_before']");
		if ($new) {
		    $insertion_point = $new;
		}
	    }
	    if (defined $but_after) {
		my $new = $insertion_point->findnodes("next-sibling::node()[\@inkscape::label='$but_after']/next-sibling::node()[1]");
		if ($new) {
		    $insertion_point = $new;
		}
	    }
	    $parent->insertBefore($layer, $insertion_point);
	} elsif (defined $z_index) {
	    my $prefix = "";
	    my @below = $parent->findnodes("svg:g[\@inkscape:groupmode='layer' and \@mapmaker:z-index and \@mapmaker:z-index < $z_index]");
	    my @above = $parent->findnodes("svg:g[\@inkscape:groupmode='layer' and \@mapmaker:z-index and \@mapmaker:z-index > $z_index]");
	    if (scalar(@below)) {
		$parent->insertAfter($layer, $below[-1]);
	    } elsif (scalar(@above)) {
		$parent->insertBefore($layer, $above[0]);
	    } else {
		$parent->appendChild($layer);
	    }
	} else {
	    $parent->appendChild($layer);
	}
    }
    if ($layer && !$no_modify) {
	$self->{_dirty_} = 1;
	$layer->setAttributeNS($NS{"inkscape"}, "groupmode", "layer");
	if (defined $id) {
	    $layer->setAttribute("id", $id);
	} else {
	    $layer->removeAttribute("id");
	}
	if (defined $class) {
	    $layer->setAttribute("class", $class);
	} else {
	    $layer->removeAttribute("class");
	}
	if (defined $name) {
	    $layer->setAttributeNS($NS{"inkscape"}, "label", $name);
	} else {
	    $layer->removeAttributeNS($NS{"inkscape"}, "label");
	}
	if (defined $z_index) {
	    $layer->setAttributeNS($NS{"mapmaker"}, "z-index", $z_index);
	} else {
	    $layer->removeAttributeNS($NS{"mapmaker"}, "z-index");
	}
	if ($insensitive) {
	    $layer->setAttributeNS($NS{"sodipodi"}, "insensitive", "true");
	} else {
	    $layer->removeAttributeNS($NS{"sodipodi"}, "insensitive");
	}
	if ($autogenerated) {
	    $layer->setAttributeNS($NS{"mapmaker"}, "autogenerated", "true");
	} else {
	    $layer->removeAttributeNS($NS{"mapmaker"}, "autogenerated");
	}
	if ($children_autogenerated) {
	    $layer->setAttributeNS($NS{"mapmaker"}, "children-autogenerated", "true");
	} else {
	    $layer->removeAttributeNS($NS{"mapmaker"}, "children-autogenerated");
	}
    }
    return $layer;
}

sub create_element {
    my ($self, $name, %args) = @_;
    my $autogenerated          = $args{autogenerated};
    my $children_autogenerated = $args{children_autogenerated};
    my $prefix;
    if ($name =~ m{:}) {
	$prefix = $`;
	$name = $';
    }
    my $element;
    if (defined $prefix) {
	if (defined $NS{$prefix}) {
	    $element = $self->{_svg_doc}->createElementNS($NS{$prefix}, $name);
	} else {
	    croak("create_element: prefix '$prefix' is not supported.  ($prefix:$name)");
	}
    } else {
	croak("create_element: prefix must be specified.  ($name)");
    }
    if ($autogenerated) {
	$element->setAttributeNS($NS{"mapmaker"}, "mapmaker:autogenerated", "true");
    }
    if ($children_autogenerated) {
	$element->setAttributeNS($NS{"mapmaker"}, "mapmaker:children-autogenerated", "true");
    }
    $element->setAttribute("class", $args{class}) if defined $args{class};
    $element->setAttribute("id",    $args{id})    if defined $args{id};
    return $element;
}

sub rectangle {
    my ($self, %args) = @_;
    my $left   = $args{x};
    my $right  = $args{x} + $args{width};
    my $top    = $args{y};
    my $bottom = $args{y} + $args{height};
    my $d = sprintf("M %.2f %.2f H %.2f V %.2f H %.2f Z",
		    $left, $top, $right, $bottom, $left);
    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $d);
    $path->setAttribute("class",  $args{class}) if defined $args{class};
    $path->setAttribute("id",     $args{id})    if defined $args{id};
    return $path;

    # we're not using a rectangle node here for some reason...
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
	    } else {
		return $hash;
	    }
	}
    }
    if (wantarray) {
	return @style;
    } else {
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
	    $gtfs->{verbose} = $self->{verbose};
	    $gtfs->{debug}   = $self->{debug};
	    $hash->{index} = $index;
	    $hash->{name} //= $hash->{index};
	    $gtfs->{data} = $hash;
	    push(@$gtfs_list, $gtfs);
	    $index += 1;
	}
	return @{$self->{_gtfs_list}};
    } else {
	return @{$self->{_gtfs_list}};
    }
}

###############################################################################

sub remove_grid {
    my ($self) = @_;
    $self->{_dirty_} = 1;
    foreach my $map_area (@{$self->{_map_areas}}) {
	my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
	my $grid_layer = $self->update_or_create_layer(name => "Grid",
						       z_index => 9998,
						       parent => $map_area_layer,
						       no_create => 1);
	if ($grid_layer) {
	    $grid_layer->unbindNode();
	}
    }
}

sub remove_crop_lines {
    my ($self) = @_;
    $self->{_dirty_} = 1;
    my $crop_lines_layer = $self->update_or_create_layer(name => "Crop Lines", no_create => 1);
    if ($crop_lines_layer) {
	$crop_lines_layer->unbindNode();
    }
    my $crop_marks_layer = $self->update_or_create_layer(name => "Crop Marks", no_create => 1);
    if ($crop_marks_layer) {
	$crop_marks_layer->unbindNode();
    }
}

sub draw_crop_lines {
    my ($self) = @_;

    # FIXME: don't use longitude/latitude coordinates, just use SVG
    # coordinates to determine where to plot the crop lines and crop
    # marks.

    return;

    $self->init_xml();

    $self->{_dirty_} = 1;
    $self->remove_crop_lines(); # incase z-index changes

    my $crop_lines = $self->{crop_lines};
    my $crop_x = eval { $crop_lines->{x} } // 4;
    my $crop_y = eval { $crop_lines->{y} } // 4;
    my $crop_lines_class = eval { $crop_lines->{class} } // "crop-lines";

    $self->stuff_all_layers_need();
    my $map_area = $self->{_map_areas}->[0];
    $self->update_scale($map_area);

    my $crop_lines_layer = $self->update_or_create_layer(name => "Crop Lines",
							 z_index => 9996,
							 insensitive => 1,
							 autogenerated => 1,
							 children_autogenerated => 1);
    $crop_lines_layer->removeChildNodes(); # OK

    my $south_deg = $self->{converter}->{south_lat_deg}; my $y_south = $self->{converter}->lat_deg_to_y_px($south_deg);
    my $north_deg = $self->{converter}->{north_lat_deg}; my $y_north = $self->{converter}->lat_deg_to_y_px($north_deg);
    my $east_deg  = $self->{converter}->{east_lon_deg};  my $x_east = $self->{converter}->lon_deg_to_x_px($east_deg);
    my $west_deg  = $self->{converter}->{west_lon_deg};  my $x_west = $self->{converter}->lon_deg_to_x_px($west_deg);

    my $top    = 0;
    my $bottom = $self->{paper_height_px};
    my $left   = 0;
    my $right  = $self->{paper_width_px};

    # vertical lines, from left to right
    foreach my $x (1 .. ($crop_x - 1)) {
	my $xx = $x_east + ($x_west - $x_east) * ($x / $crop_x);
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d = sprintf("M %.2f,%.2f %.2f,%.2f", $xx, $top, $xx, $bottom);
	$path->setAttribute("d", $d);
	$path->setAttribute("class", $crop_lines_class);
	$crop_lines_layer->appendChild($path);
    }

    # horizontal lines, from top to bottom
    foreach my $y (1 .. ($crop_y - 1)) {
	my $yy = $y_north + ($y_south - $y_north) * ($y / $crop_y);
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d = sprintf("M %.2f,%.2f %.2f,%.2f", $left, $yy, $right, $yy);
	$path->setAttribute("d", $d);
	$path->setAttribute("class", $crop_lines_class);
	$crop_lines_layer->appendChild($path);
    }

    ### CROP MARKS ###

    my $crop_marks = $self->{crop_marks};
    my $crop_size = eval { $crop_marks->{size} } // 22.5;
    my $crop_marks_class = eval { $crop_marks->{class} } // "crop-marks";

    my $crop_marks_layer = $self->update_or_create_layer(name => "Crop Marks",
							 z_index => 9997,
							 insensitive => 1,
							 autogenerated => 1,
							 children_autogenerated => 1);
    $crop_marks_layer->removeChildNodes(); # OK

    # crop marks inside the map
    foreach my $x (1 .. ($crop_x - 1)) {
	foreach my $y (1 .. ($crop_y - 1)) {
	    my $xx = $x_east + ($x_west - $x_east) * ($x / $crop_x);
	    my $yy = $y_north + ($y_south - $y_north) * ($y / $crop_y);
	    my $x1 = $xx - $crop_size;
	    my $x2 = $xx + $crop_size;
	    my $y1 = $yy - $crop_size;
	    my $y2 = $yy + $crop_size;

	    my $path1 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	    my $d1    = sprintf("M %.2f,%.2f %.2f,%.2f", $xx, $y1, $xx, $y2);
	    $path1->setAttribute("d", $d1);
	    $path1->setAttribute("class", $crop_marks_class);
	    $crop_marks_layer->appendChild($path1);

	    my $path2 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	    my $d2    = sprintf("M %.2f,%.2f %.2f,%.2f", $x1, $yy, $x2, $yy);
	    $path2->setAttribute("d", $d2);
	    $path2->setAttribute("class", $crop_marks_class);
	    $crop_marks_layer->appendChild($path2);
	}
    }

    # vertical lines, from left to right
    foreach my $x (1 .. ($crop_x - 1)) {
	my $xx = $x_east + ($x_west - $x_east) * ($x / $crop_x);

	my $path1 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d1    = sprintf("M %.2f,%.2f %.2f,%.2f", $xx, $top, $xx, $y_north);

	$path1->setAttribute("d", $d1);
	$path1->setAttribute("class", $crop_marks_class);
	$crop_marks_layer->appendChild($path1);

	my $path2 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d2    = sprintf("M %.2f,%.2f %.2f,%.2f", $xx, $y_south, $xx, $bottom);

	$path2->setAttribute("d", $d2);
	$path2->setAttribute("class", $crop_marks_class);
	$crop_marks_layer->appendChild($path2);
    }

    # horizontal lines, from top to bottom
    foreach my $y (1 .. ($crop_y - 1)) {
	my $yy = $y_north + ($y_south - $y_north) * ($y / $crop_y);

	my $path1 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d1 = sprintf("M %.2f,%.2f %.2f,%.2f", $left, $yy, $x_west, $yy);

	$path1->setAttribute("d", $d1);
	$path1->setAttribute("class", $crop_marks_class);
	$crop_marks_layer->appendChild($path1);

	my $path2 = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d2 = sprintf("M %.2f,%.2f %.2f,%.2f", $x_east, $yy, $right, $yy);

	$path2->setAttribute("d", $d2);
	$path2->setAttribute("class", $crop_marks_class);
	$crop_marks_layer->appendChild($path2);
    }

}

sub draw_grid {
    my ($self) = @_;
    my $grid = $self->{grid};
    if (!$grid) { return; }

    $self->init_xml();

    $self->{_dirty_} = 1;

    my $increment = $grid->{increment} // 0.01;
    my $format = $grid->{format};
    my $doc = $self->{_svg_doc};

    $self->stuff_all_layers_need();

    my $class = $grid->{class};
    my $text_class   = $grid->{"text-class"};
    my $text_2_class = $grid->{"text-2-class"};

    foreach my $map_area (@{$self->{_map_areas}}) {
	$self->update_scale($map_area);
	my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
	my $grid_layer = $self->update_or_create_layer(name => "Grid",
						       z_index => 9998,
						       parent => $map_area_layer,
						       insensitive => 1,
						       autogenerated => 1,
						       children_autogenerated => 1);
	$grid_layer->removeChildNodes(); # OK
	my $clipped_group = $self->find_or_create_clipped_group(parent => $grid_layer,
								clip_path_id => $map_area->{clip_path_id});

	# FIXME: do coordinate conversions for each point, not each x and each y.

	my $south_deg = $self->south_outer_map_boundary_deg; my $y_south = $self->{converter}->lat_deg_to_y_px($south_deg);
	my $north_deg = $self->north_outer_map_boundary_deg; my $y_north = $self->{converter}->lat_deg_to_y_px($north_deg);
	my $east_deg = $self->east_outer_map_boundary_deg;   my $x_east = $self->{converter}->lon_deg_to_x_px($east_deg);
	my $west_deg = $self->west_outer_map_boundary_deg;   my $x_west = $self->{converter}->lon_deg_to_x_px($west_deg);

	for (my $lat_deg = int($south_deg / $increment) * $increment; $lat_deg <= $north_deg; $lat_deg += $increment) {
	    my $lat_text = sprintf($format, $lat_deg);
	    my $y = $self->{converter}->lat_deg_to_y_px($lat_deg);

	    my $path = $doc->createElementNS($NS{"svg"}, "path");
	    $path->setAttribute("d", sprintf("M %.2f,%.2f %.2f,%.2f", $x_west, $y, $x_east, $y));
	    $path->setAttribute("class", $class);
	    $clipped_group->appendChild($path);

	    for (my $lon_deg = (int($west_deg / $increment) + 0.5) * $increment; $lon_deg <= $east_deg; $lon_deg += $increment) {
		my $x = $self->{converter}->lon_deg_to_x_px($lon_deg);
		my $text_node = $self->text_node(x => $x, y => $y, class => $text_2_class, text => $lat_text);
		$clipped_group->appendChild($text_node);
	    }
	}

	for (my $lon_deg = int($west_deg / $increment) * $increment; $lon_deg <= $east_deg; $lon_deg += $increment) {
	    my $lon_text = sprintf($format, $lon_deg);
	    my $x = $self->{converter}->lon_deg_to_x_px($lon_deg);

	    my $path = $doc->createElementNS($NS{"svg"}, "path");
	    $path->setAttribute("d", "M $x,$y_south $x,$y_north");
	    $path->setAttribute("class", $class);
	    $clipped_group->appendChild($path);

	    for (my $lat_deg = (int($south_deg / $increment) + 0.5) * $increment; $lat_deg <= $north_deg; $lat_deg += $increment) {
		my $y = $self->{converter}->lat_deg_to_y_px($lat_deg);
		my $text_node = $self->text_node(x => $x, y => $y, class => $text_2_class, text => $lon_text);
		$clipped_group->appendChild($text_node);
	    }
	}
    }
}

sub circle_node {
    my ($self, %args) = @_;
    my $x = $args{x};
    my $y = $args{y};
    my $r = $args{r} // 1.0;
    my $class = $args{class};
    my $id = $args{id};
    my $title = $args{title};

    my $doc = $self->{_svg_doc};
    my $circle_node = $doc->createElementNS($NS{"svg"}, "circle");
    $circle_node->setAttribute("cx", sprintf("%.2f", $x));
    $circle_node->setAttribute("cy", sprintf("%.2f", $y));
    $circle_node->setAttribute("class", $class);
    $circle_node->setAttribute("r", sprintf("%.2f", $r));
    $circle_node->setAttribute("title", $title) if defined $title && $title =~ /\S/;
    $circle_node->setAttribute("id", $id) if defined $id;
    return $circle_node;
}

sub text_node {
    my ($self, %args) = @_;
    my $x = $args{x};
    my $y = $args{y};
    my $text = $args{text};
    my $class = $args{class};
    my $id = $args{id};

    my $doc = $self->{_svg_doc};
    my $text_node = $doc->createElementNS($NS{"svg"}, "text");
    $text_node->setAttribute("x", sprintf("%.2f", $x));
    $text_node->setAttribute("y", sprintf("%.2f", $y));
    $text_node->setAttribute("class", "TEXT_NODE_BASE " . $class);
    $text_node->setAttribute("id", $id) if defined $id;
    my $tspan_node = $doc->createElementNS($NS{"svg"}, "tspan");
    $tspan_node->setAttribute("x", sprintf("%.2f", $x));
    $tspan_node->setAttribute("y", sprintf("%.2f", $y));
    $tspan_node->appendText($text);
    $tspan_node->setAttribute("id", $id . "_s") if defined $id;
    $text_node->appendChild($tspan_node);
    return $text_node;
}

# does not remove the node specified as the argument.
sub erase_autogenerated_content_within {
    my ($self, $element) = @_;
    if ($element->getAttributeNS($NS{mapmaker}, "children-autogenerated")) {
	$self->{_dirty_} = 1;
	$element->removeChildNodes();
    } else {
	foreach my $child ($element->childNodes()) {
	    $self->erase_autogenerated_content($child);
	}
    }
}

# can remove the node specified as the argument.
sub erase_autogenerated_content {
    my ($self, $element) = @_;
    if ($element->getAttributeNS($NS{mapmaker}, "autogenerated")) {
	$self->{_dirty_} = 1;
	$element->unbindNode();
    } elsif ($element->getAttributeNS($NS{mapmaker}, "children-autogenerated")) {
	$self->{_dirty_} = 1;
	$element->removeChildNodes();
    } else {
	foreach my $child ($element->childNodes()) {
	    $self->erase_autogenerated_content($child);
	}
    }
}

###############################################################################

sub find_chunks {
    my @paths = @_;

    my $idcount = 0;
    my %coords2id;
    my @id2coords;

    foreach my $path (@paths) {
	foreach my $coord (@$path) {
	    next unless ref($coord) eq "ARRAY";
	    my $key = join($;, @$coord);
	    if (!$coords2id{$key}) {
		$coords2id{$key} = $idcount;
		$id2coords[$idcount] = [@$coord];
		++$idcount;
	    }
	    $coord = $coords2id{$key};
	}
    }

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
	} elsif ($direction == -1) {
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
		    } else {
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
    foreach my $chunk (@chunks) {
	@$chunk = map { $id2coords[$_] } @$chunk;
    }
    return @chunks;
}

sub save {
    my ($self, $filename) = @_;

    if (!defined $filename) {
	if (!(defined($self->{_read_filename}) and
		defined($self->{filename}) and
		  ($self->{_read_filename} eq $self->{filename}))) {
	    return;
	}
    }
	
    $filename //= $self->{filename};

    if (!defined $filename && !$self->{_dirty_}) {
	return;
    }

    open(my $fh, ">", $filename) or die("cannot write $filename: $!\n");
    $self->diag("Writing $filename ... ");
    my $string = $self->{_svg_doc}->toString(1);

    # we're fine with indentation everywhere else, but inserting
    # whitespace within a <text> node, before the first <tspan>
    # node or after the last <tspan> node, screws things up.  and
    # yes this is quick-and-dirty, :dealwithit:
    $string =~ s{(<(?:text|flowRoot)[^>]*>)[\s\r\n]*}{$1}gs;
    $string =~ s{[\s\r\n]*(?=</(?:text|flowRoot)>)}{}gs;
    $string =~ s{(</tspan>)\s*(<tspan\b)}{$1$2}gs;

    $string =~ s{\s*(<flowRegion\b)}{$1}gs;
    $string =~ s{(</flowRegion>)\s*}{$1}gs;
    $string =~ s{\s*(<flowPara\b)}{$1}gs;
    $string =~ s{(</flowPara>)\s*}{$1}gs;

    # minimize diffs with netscape-output XML
    $string =~ s{\s*/>}{ />}gs;

    print $fh $string;
    close($fh);

    $self->{_dirty_} = 0; # assuming we want no auto-save when doing save-as.
	
    $self->diag("done.\n");
}

sub list_layers {
    my ($self) = @_;
    $self->init_xml();
    my $xpath = "//svg:g[\@inkscape:label]";
    foreach my $layer ($self->{_svg_doc}->findnodes($xpath)) {
	my $path = $layer->nodePath();;
	my $count =()= $path =~ m{/}g;
	print("  " x $count, 
	      $layer->getAttributeNS($NS{inkscape}, "label"), "\n");
    }
}

sub enable_layers {
    my ($self, @layer_name) = @_;
    $self->init_xml();
    foreach my $layer_name (@layer_name) {
	my $layer = $self->update_or_create_layer(no_create => 1,
						  no_modify => 1,
						  recurse => 1,
						  name => $layer_name);
	if ($layer) {
	    $self->{_dirty_} = 1;
	    $layer->setAttribute("style", "display:inline");
	}
    }
}

sub disable_layers {
    my ($self, @layer_name) = @_;
    $self->init_xml();
    foreach my $layer_name (@layer_name) {
	my $layer = $self->update_or_create_layer(no_create => 1,
						  no_modify => 1,
						  recurse => 1,
						  name => $layer_name);
	if ($layer) {
	    $self->{_dirty_} = 1;
	    $layer->setAttribute("style", "display:none");
	}
    }
}

###############################################################################

sub west_map_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
	return ($self->{map_data_west_deg}  // $self->{west_deg});
    }
}
sub east_map_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
	return ($self->{map_data_east_deg}  // $self->{east_deg});
    }
}
sub north_map_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
	return ($self->{map_data_north_deg} // $self->{north_deg});
    }
}
sub south_map_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
	return ($self->{map_data_south_deg} // $self->{south_deg});
    }
}

sub west_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{converter}->{left_x_px};
}
sub east_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{converter}->{right_x_px};
}
sub north_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{converter}->{top_y_px};
}
sub south_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{converter}->{bottom_y_px};
}

sub update_scale {
    my ($self, $map_area) = @_;
    if (defined $self->{west_deg} && defined $self->{east_deg} && defined $self->{north_deg} && defined $self->{south_deg}) {
	my $converter = Geo::MapMaker::CoordinateConverter->new();
	$converter->set_paper_size_px($self->{paper_width_px}, $self->{paper_height_px});
	$converter->set_paper_margin_px($self->{paper_margin_px});
	$converter->set_fudge_factor_px($self->{fudge_factor_px});
	$converter->set_lon_lat_boundaries($self->{west_deg}, $self->{east_deg}, $self->{north_deg}, $self->{south_deg});
	$self->{converter} = $converter;
    } else {
	die("You must specify a map area somehow.\n");
	$self->{converter} = undef;
    }
}

###############################################################################

sub diag {
    my ($self, @args) = @_;
    return unless $self->{verbose};
    print STDERR (@args);
}
sub diagf {
    my ($self, $format, @args) = @_;
    return unless $self->{verbose};
    printf STDERR ($format, @args);
}
sub warn {
    my ($self, @args) = @_;
    print STDERR (@args);
}
sub warnf {
    my ($self, $format, @args) = @_;
    printf STDERR ($format, @args);
}

1;

