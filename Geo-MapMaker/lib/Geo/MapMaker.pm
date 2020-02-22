package Geo::MapMaker;
use warnings;
use strict;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";
use Geo::MapMaker::Constants qw(:all);

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
                  css

		  layers
		  route_colors
		  route_overrides
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

		  north_lat_deg
		  south_lat_deg
		  east_lon_deg
		  west_lon_deg

                  center_lat_deg
                  center_lon_deg
                  scale
                  scale_basis_lat_deg

                  _center_lat_er
                  _center_lon_er
                  _actual_scale
                  _center_x
                  _center_y
                  _cos_lat
                  _px_scaled
                  _px_scaled_x

		  paper_width_px
		  paper_height_px
		  paper_margin_px
		  paper_margin_x_px
		  paper_margin_y_px

		  orientation

                  _id_counter
                  _xml_debug_info
                  disable_read_only

                  no_edit
                  log_prefix

                  pixels_per_inch
             );
}
use fields @_FIELDS;

use Sort::Naturally qw(nsort);
use List::Util qw(max);

use constant PI => 4 * CORE::atan2(1, 1);
use constant D2R => PI / 180;
use constant WGS84_ER_KM => 6378.1370;
use constant IN_PER_ER => 1 / 25.4 * 1_000_000 * WGS84_ER_KM;
use constant PT_PER_IN => 72;

use POSIX qw(atan);

sub new {
    my ($class, %options) = @_;
    my $self = fields::new($class);
    $self->{pixels_per_inch} = 96;
    $self->{verbose} = 0;
    $self->{debug} = {};
    $self->{_cache} = {};
    $self->{paper_width_px}    = $self->{pixels_per_inch} * 8.5;
    $self->{paper_height_px}   = $self->{pixels_per_inch} * 11;
    $self->{paper_margin_px}   = $self->{pixels_per_inch} * 0.25;
    $self->{paper_margin_x_px} = $self->{pixels_per_inch} * 0.25;
    $self->{paper_margin_y_px} = $self->{pixels_per_inch} * 0.25;
    $self->{log_prefix} = '';

    foreach my $key (qw(verbose no_edit debug filename)) {
        if (exists $options{$key}) {
            $self->{$key} = delete $options{$key};
        }
    }

    if (defined(my $pw = delete $options{paper_width})) {
        my $dim = $self->dim($pw);
        if (!defined $dim) {
            die("invalid paper_width: $pw\n");
        }
        $self->{paper_width_px} = $dim;
    }

    if (defined(my $ph = delete $options{paper_height})) {
        my $dim = $self->dim($ph);
        if (!defined $dim) {
            die("invalid paper_height: $ph\n");
        }
        $self->{paper_height_px} = $dim;
    }

    if (defined(my $pm = delete $options{paper_margin})) {
        my $dim = $self->dim($pm);
        if (!defined $dim) {
            die("invalid paper_margin: $pm\n");
        }
        $self->{paper_margin_px} = $dim;
        $self->{paper_margin_x_px} = $dim;
        $self->{paper_margin_y_px} = $dim;
    }

    if (defined(my $pmx = delete $options{paper_margin_x})) {
        my $dim = $self->dim($pmx);
        if (!defined $dim) {
            die("invalid paper_margin_x: $pmx\n");
        }
        $self->{paper_margin_x_px} = $dim;
    }

    if (defined(my $pmy = delete $options{paper_margin_y})) {
        my $dim = $self->dim($pmy);
        if (!defined $dim) {
            die("invalid paper_margin_y: $pmy\n");
        }
        $self->{paper_margin_y_px} = $dim;
    }

    {
        my $center_lat_deg      = delete $options{center_lat_deg}; # e.g., 38.2
        my $center_lon_deg      = delete $options{center_lon_deg}; # e.g., -85.7
        my $scale               = delete $options{scale}; # 1:45,000 would be 45000
        my $scale_basis_lat_deg = delete $options{scale_basis_lat_deg};

        my $north_lat_deg       = delete $options{north_lat_deg};
        my $south_lat_deg       = delete $options{south_lat_deg};
        my $east_lon_deg        = delete $options{east_lon_deg};
        my $west_lon_deg        = delete $options{west_lon_deg};

        if (defined $north_lat_deg && defined $south_lat_deg &&
                defined $east_lon_deg && defined $west_lon_deg) {
            $self->set_from_boundaries($north_lat_deg, $south_lat_deg,
                                       $west_lon_deg, $east_lon_deg);
        } elsif (defined $center_lat_deg && defined $center_lon_deg && defined $scale) {
            $self->set_from_center_and_scale($center_lat_deg, $center_lon_deg,
                                             $scale, $scale_basis_lat_deg);
        } else {
            die(":-(\n");
        }
    }

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

    $self->show_settings();

    return $self;
}

sub set_from_boundaries {
    my ($self, $north_lat_deg, $south_lat_deg, $west_lon_deg, $east_lon_deg) = @_;

    my $center_lon_deg = ($east_lon_deg + $west_lon_deg) / 2;

    my $north_lat_rad = $north_lat_deg * D2R;
    my $south_lat_rad = $south_lat_deg * D2R;
    my $north_lat_er = log(abs((1 + sin($north_lat_rad)) / cos($north_lat_rad)));
    my $south_lat_er = log(abs((1 + sin($south_lat_rad)) / cos($south_lat_rad)));
    my $center_lat_er = ($north_lat_er + $south_lat_er) / 2;
    my $center_lat_rad = (2 * atan(exp($center_lat_er)) - PI / 2);
    my $center_lat_deg = $center_lat_rad * 180 / PI;

    my $cos_center_lat = cos($center_lat_rad);

    my $drawing_width_px  = $self->{paper_width_px}  - 2 * $self->{paper_margin_x_px};
    my $drawing_height_px = $self->{paper_height_px} - 2 * $self->{paper_margin_y_px};

    my $px_per_er = $self->{pixels_per_inch} * IN_PER_ER;

    my $scale_x = ($east_lon_deg - $west_lon_deg) / $drawing_width_px * $px_per_er * D2R * $cos_center_lat;
    my $scale_y = ($north_lat_er - $south_lat_er) / $drawing_height_px * $px_per_er * $cos_center_lat;
    my $scale;
    if ($scale_x > $scale_y) {
        $scale = $scale_x;
        $drawing_height_px = $drawing_height_px * $scale_y / $scale_x;
        $self->{paper_margin_y_px} = ($self->{paper_height_px} - $drawing_height_px) / 2;
    } else {
        $scale = $scale_y;
        $drawing_width_px = $drawing_width_px * $scale_x / $scale_y;
        $self->{paper_margin_x_px} = ($self->{paper_width_px} - $drawing_width_px) / 2;
    }

    $self->{south_lat_deg} = $south_lat_deg;
    $self->{north_lat_deg} = $north_lat_deg;
    $self->{west_lon_deg}  = $west_lon_deg;
    $self->{east_lon_deg}  = $east_lon_deg;

    $self->{_center_lat_er} = $center_lat_er;
    $self->{center_lat_deg} = $center_lat_deg;
    $self->{center_lon_deg} = $center_lon_deg;
    $self->{scale} = $scale;
    $self->{scale_basis_lat_deg} = $center_lat_deg;
    $self->{_actual_scale} = $scale;

    $self->{_center_x} = $self->{paper_width_px} / 2;
    $self->{_center_y} = $self->{paper_height_px} / 2;
    $self->{_cos_lat} = cos($center_lat_deg * D2R);
    $self->{_px_scaled_x} = $px_per_er / $scale * $self->{_cos_lat};
}

sub set_from_center_and_scale {
    my ($self, $center_lat_deg, $center_lon_deg, $scale, $scale_basis_lat_deg) = @_;

    my $actual_scale = $scale;
    if (defined $scale_basis_lat_deg) {
        $self->log_info("1:%.2f at %.2f\n", $scale, $scale_basis_lat_deg);
        $actual_scale = $scale * cos($center_lat_deg * D2R) / cos($scale_basis_lat_deg * D2R);
        $self->log_info("1:%.2f at %.2f\n", $actual_scale, $center_lat_deg);
    }

    my $center_lat_rad = $center_lat_deg * D2R;
    my $cos_center_lat = cos($center_lat_rad);

    my $px_per_er = $self->{pixels_per_inch} * IN_PER_ER;

    my $edge_from_center_x_px = $self->{paper_width_px}  / 2 - $self->{paper_margin_x_px};
    my $edge_from_center_y_px = $self->{paper_height_px} / 2 - $self->{paper_margin_y_px};
    my $edge_from_center_x_er = $edge_from_center_x_px * $actual_scale / $px_per_er;
    my $edge_from_center_y_er = $edge_from_center_y_px * $actual_scale / $px_per_er;

    my $west_lon_deg = $center_lon_deg - $edge_from_center_x_px * $actual_scale / $px_per_er / D2R / $cos_center_lat;
    my $east_lon_deg = $center_lon_deg + $edge_from_center_x_px * $actual_scale / $px_per_er / D2R / $cos_center_lat;

    my $center_lat_er = log(abs((1 + sin($center_lat_rad)) / cos($center_lat_rad)));
    my $north_lat_er = $center_lat_er + $edge_from_center_y_er / $cos_center_lat;
    my $south_lat_er = $center_lat_er - $edge_from_center_y_er / $cos_center_lat;
    my $north_lat_deg = (2 * atan(exp($north_lat_er)) - PI / 2) * 180 / PI;
    my $south_lat_deg = (2 * atan(exp($south_lat_er)) - PI / 2) * 180 / PI;

    $self->{south_lat_deg} = $south_lat_deg;
    $self->{north_lat_deg} = $north_lat_deg;
    $self->{west_lon_deg}  = $west_lon_deg;
    $self->{east_lon_deg}  = $east_lon_deg;

    $self->{_center_lat_er} = $center_lat_er;
    $self->{center_lat_deg} = $center_lat_deg;
    $self->{center_lon_deg} = $center_lon_deg;
    $self->{scale} = $scale;
    $self->{scale_basis_lat_deg} = $scale_basis_lat_deg;
    $self->{_actual_scale} = $actual_scale;

    $self->{_center_x} = $self->{paper_width_px} / 2;
    $self->{_center_y} = $self->{paper_height_px} / 2;
    $self->{_cos_lat} = cos($center_lat_deg * D2R);
    $self->{_px_scaled_x} = $px_per_er / $actual_scale * $self->{_cos_lat};
}

sub show_settings {
    my ($self) = @_;
    foreach my $setting (qw(paper_width_px
                            paper_height_px
                            paper_margin_x_px
                            paper_margin_y_px
                            south_lat_deg
                            north_lat_deg
                            west_lon_deg
                            east_lon_deg
                            center_lat_deg
                            center_lon_deg
                            scale
                            _actual_scale)) {
        $self->log_warn("%s = %f\n", $setting, $self->{$setting});
    }
}

sub lon_lat_deg_to_svg {
    my ($self, $lon_deg, $lat_deg) = @_;
    my $svg_x = $self->{_center_x} + ($lon_deg - $self->{center_lon_deg}) * D2R * $self->{_px_scaled_x};
    my $lat_rad = $lat_deg * D2R;
    my $lat_er = log(abs((1 + sin($lat_rad)) / cos($lat_rad)));
    my $svg_y = $self->{_center_y} - ($lat_er - $self->{_center_lat_er}) * $self->{_px_scaled_x};
    return ($svg_x, $svg_y);
}

use Regexp::Common qw(number);

sub dim {
    my ($self, $value) = @_;
    my $px_per_in = $self->{pixels_per_inch};
    if ($value =~ m{^
                    \s*
                    ($RE{num}{real})
                    (?:
                        \s*(cm|mm|in|px|pt)
                    )?
                    \s*
                    $}xi) {
        my ($px, $unit) = ($1, $2);
        if (defined $unit) {
            $px *= $px_per_in             if $unit eq 'in';
            $px *= $px_per_in / 25.4      if $unit eq 'mm';
            $px *= $px_per_in / 2.54      if $unit eq 'cm';
            $px *= $px_per_in / PT_PER_IN if $unit eq 'pt';
        }
        return $px;
    } else {
        die("invalid value: $value\n");
    }
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
    my ($self, $whatever, $orig_filename) = @_;
    if (!ref $whatever) {
        $self->include_mapmaker_yaml_file($whatever, $orig_filename);
        return;
    }
    if (ref $whatever eq 'HASH') {
        $self->include_mapmaker_yaml_hash($whatever);
        return;
    }
}

sub include_mapmaker_yaml_hash {
    my ($self, $hash) = @_;
    foreach my $k (keys %$hash) {
        my $v = $hash->{$k};
        if ($k eq 'gtfs') {
            $self->gtfs($v);
        } else {
            $self->{$k} = $v;
        }
    }
}

sub include_mapmaker_yaml_file {
    my ($self, $filename, $orig_filename) = @_;

    my $dirname = dirname($orig_filename);
    my $abs_path = File::Spec->rel2abs($filename, $dirname);

    my $data = eval { LoadFile($filename); };
    if ($@) { warn($@); }
    if (ref $data eq 'HASH') {
        $self->include_mapmaker_yaml_hash($data);
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
use File::Path qw(mkpath);
use File::Basename;
use List::MoreUtils qw(all firstidx uniq);
use Geo::MapMaker::Util qw(file_get_contents file_put_contents);

our %NS;
BEGIN {
    $NS{"xmlns"}    = undef;
    $NS{"svg"}      = "http://www.w3.org/2000/svg";
    $NS{"inkscape"} = "http://www.inkscape.org/namespaces/inkscape";
    $NS{"sodipodi"} = "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd";
    $NS{"mapmaker"} = "http://webonastick.com/namespaces/geo-mapmaker";
    $NS{"cc"}       = "http://creativecommons.org/ns#";
    $NS{"dc"}       = "http://purl.org/dc/elements/1.1/";
    $NS{"rdf"}      = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
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
   xmlns="http://www.w3.org/2000/svg"
   xmlns:dc="http://purl.org/dc/elements/1.1/"
   xmlns:cc="http://creativecommons.org/ns#"
   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
   xmlns:svg="http://www.w3.org/2000/svg"
   xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd"
   xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
   xmlns:mapmaker="http://webonastick.com/namespaces/geo-mapmaker"
   version="1.1"
   sodipodi:docname="Map"
   mapmaker:version="1">
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

    my $px_per_in = $self->{pixels_per_inch};

    $doc_elt->setAttribute("width",  sprintf("%.2fpt", $self->{paper_width_px} / $px_per_in * PT_PER_IN));
    $doc_elt->setAttribute("height", sprintf("%.2fpt", $self->{paper_height_px} / $px_per_in * PT_PER_IN));
    $doc_elt->setNamespace($NS{"svg"}, "svg", 0);
    $doc_elt->setAttribute('viewBox', sprintf('%.2f %.2f %.2f %.2f',
                                              0, 0,
                                              $self->{paper_width_px},
                                              $self->{paper_height_px}));

    my $xpc = XML::LibXML::XPathContext->new($doc);
    $xpc->registerNs("svg"      => $NS{"svg"});
    $xpc->registerNs("inkscape" => $NS{"inkscape"});
    $xpc->registerNs("sodipodi" => $NS{"sodipodi"});
    $xpc->registerNs("mapmaker" => $NS{"mapmaker"});
    $xpc->registerNs("dc"       => $NS{"dc"});
    $xpc->registerNs("cc"       => $NS{"cc"});
    $xpc->registerNs("rdf"      => $NS{"rdf"});
    $self->{_xpc} = $xpc;

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
    $self->log_warn("Document is at mapmaker:version $version.  Checking for upgrades...\n");
    while (TRUE) {
	my $next_version = $version + 1;
	my $sub_name = "upgrade_mapmaker_version_from_${version}_to_${next_version}";
	last if (!(exists &$sub_name));
	$self->log_warn("  Upgrading from version ${version} to version ${next_version}...\n");
	$self->$sub_name();
	$version = $next_version;
	$doc_elt->setAttributeNS($NS{"mapmaker"}, "version", $version);
	$self->{_dirty_} = 1;
	$self->log_warn("  Done.\n");
    }
    if ($old_version eq $version) {
	$self->log_warn("No upgrades necessary.\n");
    } else {
	$self->log_warn("All upgrades complete.\n");
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
        .CLOSED { stroke-linecap: round; stroke-linejoin: round; }
	.OPEN   { fill: none !important; stroke-linecap: round; stroke-linejoin: round; }
        .MPR    { fill-rule: evenodd !important; stroke-linecap: round; stroke-linejoin: round; }
        .NMPR   { fill: none !important; stroke-linecap: round; stroke-linejoin: round; }
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

    if (defined $self->{css}) {
        $contents .= $self->{css};
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

sub update_styles { goto &update_css; }

sub update_css {
    my ($self) = @_;

    $self->init_xml();

    $self->{_dirty_} = 1;
    $self->stuff_all_layers_need();
    foreach my $map_area (@{$self->{_map_areas}}) {
	# $self->update_scale($map_area); # don't think this is necessary, but . . .
	$self->update_or_create_style_node();
	$self->create_or_delete_extra_defs_node();
    }
}

sub stuff_all_layers_need {
    my ($self) = @_;

    $self->{_dirty_} = 1;

    foreach my $map_area (@{$self->{_map_areas}}) {
	# $self->update_scale($map_area);
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

sub svg_path {
    my ($self, %args) = @_;
    my $is_closed = $args{is_closed};
    my $position_dx = $args{position_dx};
    my $position_dy = $args{position_dy};
    my $id = $args{id};

    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

    my $d;
    if ($args{path}) {
        my $path = Geo::MapMaker::SVG::Path->object($args{path});
        $d = $path->as_string(
            position_dx => $position_dx,
            position_dy => $position_dy,
        );
    } elsif ($args{polyline}) {
        my $polyline = Geo::MapMaker::SVG::Path->object($args{polyline});
        $d = $polyline->as_string(
            position_dx => $position_dx,
            position_dy => $position_dy,
        );
    } elsif ($args{points}) {
        $d = $self->points_to_path(
            position_dx => $position_dx,
            position_dy => $position_dy,
            closed => $is_closed,
            points => $args{points}
        );
    }
    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $d);
    $path->setAttribute("class", $args{class}) if defined $args{class};
    $path->setAttribute("id", $id) if defined $id;
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-id", $args{shape_id}) if defined $args{shape_id};
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-ids",
                          join(', ', nsort keys %{$args{shape_id_hash}}))
        if defined $args{shape_id_hash};

    if (eval { ref $args{attr} eq 'HASH' }) {
        foreach my $key (nsort keys %{$args{attr}}) {
            $path->setAttribute($key, $args{attr}->{$key});
        }
    }

    return $path;
}

sub legacy_polygon {
    my ($self, %args) = @_;
    $args{is_closed} = 1;
    return $self->legacy_polyline(%args);
}

sub legacy_polyline {
    my ($self, %args) = @_;
    my $is_closed = $args{is_closed} ? 1 : 0;
    my $id = $args{id};

    if ($self->{_xml_debug_info}) {
        $id //= $self->new_id();
    }

    my $path = $self->{_svg_doc}->createElementNS($NS{"svg"}, "path");
    $path->setAttribute("d", $self->points_to_path(
        closed => $is_closed,
        points => $args{points}
    ));
    $path->setAttribute("class", $args{class}) if defined $args{class};
    $path->setAttribute("id", $id) if defined $id;
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-id", $args{shape_id}) if defined $args{shape_id};
    $path->setAttributeNS($NS{"mapmaker"}, "mapmaker:shape-ids",
                          join(', ', nsort keys %{$args{shape_id_hash}}))
        if defined $args{shape_id_hash};

    if (eval { ref $args{attr} eq 'HASH' }) {
        foreach my $key (nsort keys %{$args{attr}}) {
            $path->setAttribute($key, $args{attr}->{$key});
        }
    }
    return $path;
}

sub points_to_path {
    my ($self, %args) = @_;
    my $closed = $args{is_closed};
    my @points = @{$args{points}};
    my $position_dx = $args{position_dx};
    my $position_dy = $args{position_dy};

    my @coords = map { [ int($_->[POINT_X] * 100 + 0.5) / 100,
			 int($_->[POINT_Y] * 100 + 0.5) / 100 ] } @points;
    if (defined $position_dx || defined $position_dy) {
        foreach my $coord (@coords) {
            $coord->[0] += $position_dx if defined $position_dx;
            $coord->[1] += $position_dy if defined $position_dy;
        }
    }
    my $result = sprintf("m %.2f,%.2f", @{$coords[0]});
    for (my $i = 1; $i < scalar(@coords); $i += 1) {
	$result .= sprintf(" %.2f,%.2f",
			   $coords[$i][POINT_X] - $coords[$i - 1][POINT_X],
			   $coords[$i][POINT_Y] - $coords[$i - 1][POINT_Y]);
    }
    $result .= " z" if $closed;
    return $result;
}

sub legacy_points_to_path {
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

    if (eval { ref $args{attr} eq 'HASH' }) {
        foreach my $key (nsort keys %{$args{attr}}) {
            $group->setAttribute($key, $args{attr}->{$key});
        }
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
	    $self->log_warn("create_element: prefix '$prefix' is not supported.  ($prefix:$name)");
	}
    } else {
	$self->log_warn("create_element: prefix must be specified.  ($name)");
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

    if (eval { ref $args{attr} eq 'HASH' }) {
        foreach my $key (nsort keys %{$args{attr}}) {
            $element->setAttribute($key, $args{attr}->{$key});
        }
    }

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

    if (eval { ref $args{attr} eq 'HASH' }) {
        foreach my $key (nsort keys %{$args{attr}}) {
            $path->setAttribute($key, $args{attr}->{$key});
        }
    }

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

sub circle_node {
    my ($self, %args) = @_;
    my $x = $args{x};
    my $y = $args{y};
    my $r = $args{r};
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
    $circle_node->setAttribute("r", sprintf("%.2f", $r)) if defined $r;
    $circle_node->setAttribute("title", $title) if defined $title && $title =~ /\S/;
    $circle_node->setAttribute("id", $id) if defined $id;

    if (eval { ref $args{attr} eq 'HASH' }) {
        foreach my $key (nsort keys %{$args{attr}}) {
            $circle_node->setAttribute($key, $args{attr}->{$key});
        }
    }

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

    if (eval { ref $args{attr} eq 'HASH' }) {
        foreach my $key (nsort keys %{$args{attr}}) {
            $text_node->setAttribute($key, $args{attr}->{$key});
        }
    }

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

    if ($self->{no_edit}) {
        $self->{_dirty_} = 0;
        return;
    }

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

sub clean {
    my ($self) = @_;
    $self->init_xml();

    my $doc = $self->{_svg_doc};
    foreach my $node ($doc->findnodes('//svg:style[@mapmaker:autogenerated]')) {
        $node->unbindNode();
    }
    foreach my $node ($doc->findnodes('//svg:defs[@id="geoMapmakerExtraDefs"]')) {
        $node->unbindNode();
    }
    foreach my $node ($doc->findnodes('//svg:defs[@id="geoMapmakerDefs"]')) {
        $node->unbindNode();
    }
    foreach my $node ($doc->findnodes('//svg:style[@id="geoMapmakerStyles"]')) {
        $node->unbindNode();
    }
    foreach my $node ($doc->findnodes('//svg:clipPath[@mapmaker:autogenerated]')) {
        $node->unbindNode();
    }
    foreach my $node ($doc->findnodes('//svg:path[@mapmaker:autogenerated]')) {
        $node->unbindNode();
    }
    foreach my $node ($doc->findnodes('//svg:g[@mapmaker:autogenerated]')) {
        $node->unbindNode();
    }
}

###############################################################################

sub west_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{paper_margin_x_px};
}

sub east_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{paper_width_px} - $self->{paper_margin_x_px};
}

sub north_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{paper_margin_y_px};
}

sub south_outer_map_boundary_svg {
    my ($self) = @_;
    return $self->{paper_height_px} - $self->{paper_margin_y_px};
}

###############################################################################

BEGIN {
    my $select = select(STDERR);
    $| = 1;
    select($select);
}

use File::Basename qw(basename);

our $prepend;
our $progname;
our $prefix2;
BEGIN {
    $prepend = 1;
    $progname = basename($0);
    $prefix2 = '';
}

sub log_error {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_ERROR, $format, @args);
}
sub log_warn {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_WARN, $format, @args);
}
sub log_info {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_INFO, $format, @args);
}
sub log_debug {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_DEBUG, $format, @args);
}

sub log {
    my ($self, $level, $format, @args) = @_;
    return if $level > $self->{verbose};
    my $string;
    if (!defined $format) {
        $string = join('', @args);
    } else {
        $string = sprintf($format, @args);
    }
    if ($prepend) {
        $string = $progname . ': ' . $self->{log_prefix} . $string;
    }
    print STDERR $string;
    if ($string =~ m{\n\z}) {
        $prepend = 1;
    } else {
        $prepend = 0;
    }
}

sub diag {
    my ($self, @args) = @_;
    return $self->log_warn(undef, @args);
}
sub diagf {
    my ($self, $format, @args) = @_;
    return $self->log_warn($format, @args);
}
sub warn {
    my ($self, @args) = @_;
    return $self->log_error(undef, @args);
}
sub warnf {
    my ($self, $format, @args) = @_;
    return $self->log_error(undef, @args);
}

###############################################################################

use Geo::MapMaker::OSM;
use Geo::MapMaker::GTFS;

1;

