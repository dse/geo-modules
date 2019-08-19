package Geo::MapMaker;
use warnings;
use strict;

use Geo::MapMaker::Constants qw(:all);

use Carp qw(croak);
use Carp qw(confess);

# NOTE: "ground" and "background" are apparently treated as the same
# classname in SVG, or some shit.

=head1 NAME

Geo::MapMaker - Create semi-usable maps from GTFS and OSM data.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.02';

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
		  inset_maps
		  _map_areas
		  _parser
		  _svg_doc
		  _svg_doc_elt
		  _xpc

		  _cache
		  include
		  _dirty_
		  debug
		  verbose

		  extra_defs


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

		  left_point
		  right_point
		  top_point
		  bottom_point

                  osm_features_not_included_filename

                  _id_counter
                  _xml_debug_info
                  disable_read_only
		);
}
use fields @_FIELDS;

use Sort::Naturally qw(nsort);

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
    while (my ($k, $v) = each(%options)) {
	if ($self->can($k)) {
	    $self->$k($v);
	} else {
	    $self->{$k} = $v;
	}
    }
    if (defined(my $filename = $self->{filename})) {
	my $mapmaker_yaml_filename = $self->mapmaker_yaml_filename($filename);
	$self->load_mapmaker_yaml($mapmaker_yaml_filename);
    }
    $self->{osm_features_not_included_filename} = undef;
    return $self;
}

sub mapmaker_yaml_filename {
    my ($self, $filename) = @_;
    $filename .= ".mapmaker.yaml";
    return $filename;
}

use YAML::Syck qw(Load LoadFile);

sub load_mapmaker_yaml {
    my ($self, $filename) = @_;
    my $data = eval { -e $filename && LoadFile($filename); };
    if ($@) { warn($@); }
    if ($data) {
	while (my ($k, $v) = each(%$data)) {
	    if ($k eq "INCLUDE" || $k eq "include") {
		if (ref($v) eq "ARRAY") {
		    foreach my $f (@$v) {
			$self->include_mapmaker_yaml($f, $filename);
		    }
		} else {
		    $self->include_mapmaker_yaml($v, $filename);
		}
	    } elsif ($k eq "gtfs") {
		$self->gtfs($v);
	    } else {
		$self->{$k} = $v;
	    }
	}
    }
}

use File::Basename qw(dirname);

sub include_mapmaker_yaml {
    my ($self, $filename, $orig_filename) = @_;

    my $dirname = dirname($orig_filename);
    my $abs_path = File::Spec->rel2abs($filename, $dirname);
    print("[$dirname] $filename => $abs_path\n");

    my $data = eval { LoadFile($filename); };
    if ($@) { warn($@); }
    if ($data) {
	while (my ($k, $v) = each(%$data)) {
	    if ($k eq "gtfs") {
		$self->gtfs($v);
	    } else {
		$self->{$k} = $v;
	    }
	}
    }
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
use Geo::MapMaker::Util qw(file_get_contents file_put_contents);
use Geo::MapMaker::CoordinateConverter;

our %NS;
BEGIN {
    $NS{"xmlns"}    = undef;
    $NS{"svg"}      = "http://www.w3.org/2000/svg";
    $NS{"inkscape"} = "http://www.inkscape.org/namespaces/inkscape";
    $NS{"sodipodi"} = "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd";
    $NS{"mapmaker"} = "http://webonastick.com/namespaces/geo-mapmaker";
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
    my ($defs) = $doc->findnodes("/*/svg:defs[\@id='geoMapmakerDefs']");
    if (!$defs) {
	$self->{_dirty_} = 1;
	$defs = $doc->createElementNS($NS{"svg"}, "defs");
	$defs->setAttribute("id", "geoMapmakerDefs");
	$doc_elt->insertBefore($defs, $doc_elt->firstChild());
    }
    return $defs;
}

sub create_or_delete_extra_defs_node {
    my ($self) = @_;
    my $doc = $self->{_svg_doc};
    my $doc_elt = $doc->documentElement();

    if (defined $self->{extra_defs}) {
	my ($extra_defs) = $doc->findnodes("/*/svg:defs[\@id='geoMapmakerExtraDefs']");
	if (!$extra_defs) {
	    $self->{_dirty_} = 1;
	    $extra_defs = $doc->createElementNS($NS{"svg"}, "defs");
	    $extra_defs->setAttribute("id", "geoMapmakerExtraDefs");
	    $extra_defs->appendWellBalancedChunk($self->{extra_defs});
	    $doc_elt->insertAfter($extra_defs, $self->find_or_create_defs_node());
	}
	return $extra_defs;
    } else {
	my ($extra_defs) = $doc->findnodes("/*/svg:defs[\@id='geoMapmakerExtraDefs']");
	if ($extra_defs) {
	    $extra_defs->unbindNode();
	}
	return;
    }
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
	.WHITE { fill: #fff; }
	.MAP_BORDER { fill: none !important; stroke-linejoin: square !important; }
	.OPEN { fill: none !important; stroke-linecap: round; stroke-linejoin: round; }
	.TEXT_NODE_BASE {
		text-align: center;
		text-anchor: middle;
	}
END

    foreach my $class (sort keys %{$self->{classes}}) {
	my $css        = $self->compose_style_string(class => $class);
	my $css_2      = $self->compose_style_string(class => $class, style_attr_name => "style_2");
	my $css_BRIDGE = $self->compose_style_string(class => $class, style_attr_name => "style_BRIDGE");
	$contents .= "\t.${class}   { $css }\n";
	$contents .= "\t.${class}_2 { $css_2 }\n"      if $self->has_style_2(class => $class);
	$contents .= "\t.${class}_2 { $css_BRIDGE }\n" if $self->has_style_BRIDGE(class => $class);
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

sub update_styles {
    my ($self) = @_;

    $self->init_xml();

    $self->{_dirty_} = 1;
    $self->stuff_all_layers_need();
    foreach my $map_area (@{$self->{_map_areas}}) {
	$self->update_scale($map_area); # don't think this is necessary, but . . .
	$self->update_or_create_style_node();
	$self->create_or_delete_extra_defs_node();
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
	$self->create_or_delete_extra_defs_node();
	$self->update_or_create_border_layer($map_area, $map_area_layer);
    }
}

sub new_id {
    my $self = shift;
    if (!defined $self->{_id_counter}) {
        $self->{_id_counter} = 0;
    }
    $self->{_id_counter} += 1;
    return 'mm-' . $self->{_id_counter};
}

sub polygon {
    my ($self, %args) = @_;

    my $id = $args{id};
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $self->points_to_path(1, @{$args{points}}));
    $path->setAttribute("class", $args{class}) if defined $args{class};
    $path->setAttribute("id", $id) if defined $id;
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-id", $args{shape_id}) if defined $args{shape_id};
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-ids",
                          join(', ', nsort keys %{$args{shape_id_hash}}))
        if defined $args{shape_id_hash};
    return $path;
}

sub polyline {
    my ($self, %args) = @_;

    my $id = $args{id};
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $self->points_to_path(0, @{$args{points}}));
    $path->setAttribute("class", $args{class}) if defined $args{class};
    $path->setAttribute("id", $id) if defined $id;
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-id", $args{shape_id}) if defined $args{shape_id};
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-ids",
                          join(', ', nsort keys %{$args{shape_id_hash}}))
        if defined $args{shape_id_hash};
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

    my $id = $args{id};
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

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
    $group->setAttribute("style", $args{style}) if defined $args{style};
    $group->setAttribute("id", $id) if defined $id;
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
    my $class                  = $args{class};
    my $style                  = $args{style};
    my $no_create              = $args{no_create};
    my $no_modify              = $args{no_modify};
    my $autogenerated          = $args{autogenerated};
    my $children_autogenerated = $args{children_autogenerated};
    my $recurse                = $args{recurse};

    my $but_before             = $args{but_before};
    my $but_after              = $args{but_after};

    my $id = $args{id};
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

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
	if (defined $style) {
	    $layer->setAttribute("style", $style);
	} else {
	    $layer->removeAttribute("style");
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
        if ($self->{disable_read_only}) {
            $layer->removeAttributeNS($NS{"sodipodi"}, "insensitive");
        } else {
            if ($insensitive) {
                $layer->setAttributeNS($NS{"sodipodi"}, "insensitive", "true");
            } else {
                $layer->removeAttributeNS($NS{"sodipodi"}, "insensitive");
            }
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

    my $id = $args{id};
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

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
    $element->setAttribute("style", $args{style}) if defined $args{style};
    $element->setAttribute("id", $id) if defined $id;
    return $element;
}

sub rectangle {
    my ($self, %args) = @_;

    my $id = $args{id};
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

    my $left   = $args{x};
    my $right  = $args{x} + $args{width};
    my $top    = $args{y};
    my $bottom = $args{y} + $args{height};
    my $d = sprintf("M %.2f %.2f H %.2f V %.2f H %.2f Z",
		    $left, $top, $right, $bottom, $left);
    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $d);
    $path->setAttribute("class",  $args{class}) if defined $args{class};
    $path->setAttribute("style",  $args{style}) if defined $args{style};
    $path->setAttribute("id", $id) if defined $id;
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

sub has_style_BRIDGE {
    my ($self, %args) = @_;
    my $class = $args{class};
    return scalar($self->get_style_hashes(class => $class, style_attr_name => "style_BRIDGE")) ? 1 : 0;
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
        my $id = $self->{_xml_debug_info} ? $self->new_id() : undef;
	my $xx = $x_east + ($x_west - $x_east) * ($x / $crop_x);
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d = sprintf("M %.2f,%.2f %.2f,%.2f", $xx, $top, $xx, $bottom);
	$path->setAttribute("d", $d);
	$path->setAttribute("class", $crop_lines_class);
        $path->setAttribute("id", $id);
	$crop_lines_layer->appendChild($path);
    }

    # horizontal lines, from top to bottom
    foreach my $y (1 .. ($crop_y - 1)) {
        my $id = $self->{_xml_debug_info} ? $self->new_id() : undef;
	my $yy = $y_north + ($y_south - $y_north) * ($y / $crop_y);
	my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
	my $d = sprintf("M %.2f,%.2f %.2f,%.2f", $left, $yy, $right, $yy);
	$path->setAttribute("d", $d);
	$path->setAttribute("class", $crop_lines_class);
        $path->setAttribute("id", $id);
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
    my $title = $args{title};

    my $id = $args{id};
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

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
    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

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
    my @shapes = @_;

    my $idcount = 0;
    my %coords2id;
    my @id2coords;

    foreach my $shape (@shapes) {
        my $path = $shape->{points};
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
        my %args = @_;
	my @points    = @{$args{points}};
	$chunk_id_counter += 1;
	$working_chunk_id = $chunk_id_counter;
	$working_chunk = $chunks[$working_chunk_id] = {
            shape_id_hash => {},
            points => [@points]
        };

	for (my $i = 0; $i < scalar(@points) - 1; $i += 1) {
	    my $A = $points[$i];
	    my $B = $points[$i + 1];
	    $which_chunk_id{$A, $B} = [$working_chunk_id, 1];
	    $which_chunk_id{$B, $A} = [$working_chunk_id, -1];
	}

        my $shape_id = $args{shape_id};
        if ($working_chunk && defined $shape_id) {
            $working_chunk->{shape_id_hash}->{$shape_id} = 1;
        }
    };

    my $work_on_existing_chunk = sub {
        my %args = @_;
        my $chunk_id = $args{chunk_id};
        my $direction = $args{direction} // 1;
	if ($direction == 1) {
	    $working_chunk_id = $chunk_id;
	    $working_chunk = $chunks[$chunk_id];
	} elsif ($direction == -1) {
	    $working_chunk_id = $chunk_id;
	    $working_chunk = $chunks[$chunk_id];
	    @{$chunks[$chunk_id]->{points}} =
                reverse @{$chunks[$chunk_id]->{points}};
	    my @k = keys(%which_chunk_id);
	    foreach my $k (@k) {
		if ($which_chunk_id{$k}[0] == $chunk_id) {
		    $which_chunk_id{$k}[1] *= -1;
		}
	    }
	}

        my $shape_id = $args{shape_id};
        if ($working_chunk && defined $shape_id) {
            $working_chunk->{shape_id_hash}->{$shape_id} = 1;
        }
    };

    my $append_to_working_chunk = sub {
        my %args = @_;
        my @points = @{$args{points}};
	my $A;
	foreach my $B (@points) {
	    $A //= $working_chunk->{points}->[-1];
	    push(@{$working_chunk->{points}}, $B);
	    $which_chunk_id{$A, $B} = [$working_chunk_id, 1];
	    $which_chunk_id{$B, $A} = [$working_chunk_id, -1];
	    $A = $B;
	}

        my $shape_id = $args{shape_id};
        if ($working_chunk && defined $shape_id) {
            $working_chunk->{shape_id_hash}->{$shape_id} = 1;
        }
    };

    for (my $i = 0; $i < scalar(@shapes); $i += 1) {
	my $shape = $shapes[$i];
        my $shape_id = $shape->{shape_id};
        my $path = $shape->{points};
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
		    $work_on_new_chunk->(shape_id => $shape_id,
                                         points => [$A, $B]);
		} elsif ($direction == 1) {
		    # existing chunk contains A-B segment
		    my $A_index = firstidx { $_ == $A } @{$chunk->{points}};
		    if ($A_index == 0) {
			# existing chunk starts with A-B
			$work_on_existing_chunk->(shape_id => $shape_id,
                                                  chunk_id => $chunk_id);
		    } else {
			# existing chunk has segments before A-B
			# split it into      ...-A and A-B-...
			#               (existing)     (new chunk)
			my $new_chunk = {
                            points => [
                                $A, splice(@{$chunks[$chunk_id]->{points}}, $A_index + 1)
                            ]
                        };
			$work_on_new_chunk->(shape_id => $shape_id,
                                             points => $new_chunk->{points});
			# working chunk is now A-B-...
		    }
		} elsif ($direction == -1) {
		    # existing chunk contains B-A segment
		    my $B_index = firstidx { $_ == $B } @{$chunk->{points}};
		    if ($B_index == scalar(@{$chunks[$chunk_id]->{points}}) - 2) {
			# existing chunk ends at B-A
			$work_on_existing_chunk->(shape_id => $shape_id,
                                                  chunk_id => $chunk_id,
                                                  direction => -1);
			# working chunk is now A-B-...
		    } else {
			# existing chunk has segments after B-A
			# split it into ...-B-A and A-...
			#                 (new)     (existing)
                        my @points = (splice(@{$chunks[$chunk_id]->{points}}, 0, $B_index + 1), $A);
			$work_on_new_chunk->(shape_id => $shape_id,
                                             points => [reverse @points]);
			# working chunk is now A-B-...
		    }
		}
	    } else {
				# path: ...-Z-A-B-...
				# working chunk has ...-Z-A-...
		my ($chunk_id, $direction) = eval { @{$which_chunk_id{$A, $B}} };
		if (!defined $chunk_id) {
		    # no existing chunk has A-B (or B-A) segment
		    if ($working_chunk->{points}->[-1] == $A) {
			# working chunk ends with A
			$append_to_working_chunk->(shape_id => $shape_id,
                                                   points => [$B]);
		    } else {
			my $A_index = firstidx { $_ == $A } @{$working_chunk->{points}};
			# working chunk has stuff after A.
			# split it into      ...-A and A-...
			#               (existing)     (new)
			my @points = ($A, splice(@{$working_chunk->{points}}, $A_index + 1));
			$work_on_new_chunk->(shape_id => $shape_id,
                                             points => \@points);
			$work_on_new_chunk->(shape_id => $shape_id,
                                             points => [$A, $B]);
		    }
		} elsif ($direction == 1) {
		    # an existing chunk has A-B segment
		    if ($working_chunk_id == $chunk_id) {
			# current working chunk is existing chunk so it has ...-Z-A-B-...
			$work_on_existing_chunk->(shape_id => $shape_id,
                                                  chunk_id => $chunk_id);
		    } else {
			# working chunk has ...-Z-A-...
			# existing chunk has ...-A-B-...
			$work_on_existing_chunk->(shape_id => $shape_id,
                                                  chunk_id => $chunk_id);
		    }
		} else {
		    # an existing chunk has B-A segment
		    if ($working_chunk_id == $chunk_id) {
			# current working chunk with ...-Z-A-...
			# is same as existing chunk with ...-B-A-Z-...
			$work_on_existing_chunk->(shape_id => $shape_id,
                                                  chunk_id => $chunk_id,
                                                  direction => -1);
		    } else {
			# working chunk has ...-Z-A-...
			# existing chunk has ...-B-A-...
			$work_on_existing_chunk->(shape_id => $shape_id,
                                                  chunk_id => $chunk_id,
                                                  direction => -1);
		    }
		}
	    }
	}
    }
    foreach my $chunk (@chunks) {
	@{$chunk->{points}} = map { $id2coords[$_] } @{$chunk->{points}};
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

sub just_rewrite {
    my ($self) = @_;
    $self->{_dirty_} = 1;       # force a rewrite;
    $self->save();
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

    my $converter = Geo::MapMaker::CoordinateConverter->new();
    $converter->set_paper_size_px($self->{paper_width_px}, $self->{paper_height_px});
    $converter->set_paper_margin_px($self->{paper_margin_px});
    $converter->set_fudge_factor_px($self->{fudge_factor_px});
    $self->{converter} = $converter;

    if (defined $self->{west_deg} && defined $self->{east_deg} && defined $self->{north_deg} && defined $self->{south_deg}) {
	$self->{converter}->set_lon_lat_boundaries($self->{west_deg}, $self->{east_deg}, $self->{north_deg}, $self->{south_deg});
	$self->{converter}->set_orientation(0);
    } elsif (defined $self->{left_point} && defined $self->{right_point}) {
	$self->{converter}->set_left_right_geographic_points($self->{left_point}->{longitude},
							     $self->{left_point}->{latitude},
							     $self->{right_point}->{longitude},
							     $self->{right_point}->{latitude});
    } elsif (defined $self->{top_point} && defined $self->{bottom_point}) {
	$self->{converter}->set_top_bottom_geographic_points($self->{top_point}->{longitude},
							     $self->{top_point}->{latitude},
							     $self->{bottom_point}->{longitude},
							     $self->{bottom_point}->{latitude});
    } else {
	die("You must specify a map area somehow.\n");
	$self->{converter} = undef;
    }

    # FIXME: if we do inset maps again the CoordinateConverter and
    # possibly this method will have to be modified to support them.
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

###############################################################################

use Geo::MapMaker::OSM;
use Geo::MapMaker::GTFS;

1;

