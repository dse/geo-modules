package Geo::MapMaker::OSM;
use warnings;
use strict;
use v5.10.0;

# heh, this package is actually a mixin.  ;-)

package Geo::MapMaker;
use warnings;
use strict;
use v5.10.0;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";
use Geo::MapMaker::Constants qw(:all);

use fields qw(_osm_xml_filenames
              osm_layers
              _doc

              _css_class_count

              _unused_object_tag_count
              _unused_object_tag_value_count
              _object_tag_count
              _object_tag_value_count
              _layer_object_count

              osm_map_boundaries
              osm_data_north_lat_deg
              osm_data_south_lat_deg
              osm_data_east_lon_deg
              osm_data_west_lon_deg

              osm_data_source

              _map_tile_nodes
              _map_tile_ways
              _map_tile_relations

              _map_tile_number
              _map_tile_count);

use Geo::MapMaker::Dumper qw(Dumper);
use Geo::MapMaker::OSM::Node;
use Geo::MapMaker::OSM::Relation;
use Geo::MapMaker::OSM::Way;
use Geo::MapMaker::SVG::Path;
use Geo::MapMaker::SVG::Point;
use Geo::MapMaker::SVG::PolyLine;
use Geo::MapMaker::Util qw(normalize_space);

use Digest::SHA qw(sha1_hex);
use Encode;
use File::Basename qw(dirname);
use File::MMagic;
use File::Path qw(make_path);
use File::Slurper qw(read_text);
use IO::Uncompress::AnyUncompress qw(anyuncompress);
use LWP::Simple;                # RC_NOT_MODIFIED
use List::MoreUtils qw(all uniq);
use Path::Tiny;
use Scalar::Util qw(looks_like_number);
use Sort::Naturally;
use Text::Trim;
use XML::Fast;
use Hash::Ordered;
use File::Path qw(mkpath);

# can be a regexp or an arrayref of tile numbers
our $TEST_WITH_LIMITED_TILES = 0;

# can be a sub called with a layer as its only arg
our $TEST_WITH_LIMITED_LAYERS = 0;

# mapping between object id and 1/0
our $WATCH_OBJECT_ID = {};

sub update_openstreetmap                 { goto &update_osm;                 }
sub update_openstreetmap_from_source     { goto &update_osm_from_source;     }
sub update_openstreetmap_from_source_url { goto &update_osm_from_source_url; }
sub update_or_create_openstreetmap_layer { goto &update_or_create_osm_layer; }
sub draw_openstreetmap_maps              { goto &draw_osm_maps;              }

sub update_osm {
    my ($self, $force) = @_;
    my $source = $self->{osm_data_source};
    if ($source) {
        $self->update_osm_from_source($force);
    } else {
        $self->update_osm_from_osm($force);
    }
}

sub map_url {
    my ($self, $west_deg, $south_deg, $east_deg, $north_deg) = @_;
    return sprintf("http://api.openstreetmap.org/api/0.6/map?bbox=%.8f,%.8f,%.8f,%.8f",
                   $west_deg, $south_deg, $east_deg, $north_deg);
}
sub map_txt_filename {
    my ($self, $west_deg, $south_deg, $east_deg, $north_deg) = @_;
    return sprintf("%s/.geo-mapmaker-osm/map_%.8f_%.8f_%.8f_%.8f_bbox.txt",
                   $ENV{HOME}, $west_deg, $south_deg, $east_deg, $north_deg);
}
sub map_xml_filename {
    my ($self, $west_deg, $south_deg, $east_deg, $north_deg) = @_;
    return sprintf("%s/.geo-mapmaker-osm/map_%.8f_%.8f_%.8f_%.8f_bbox.xml",
                   $ENV{HOME}, $west_deg, $south_deg, $east_deg, $north_deg);
}

sub update_osm_from_osm {
    my ($self, $force, $west_deg, $south_deg, $east_deg, $north_deg, $split_direction) = @_;

    my $force_mirror = 1;

    $west_deg  //= $self->west_osm_data_boundary_deg();
    $south_deg //= $self->south_osm_data_boundary_deg();
    $east_deg  //= $self->east_osm_data_boundary_deg();
    $north_deg //= $self->north_osm_data_boundary_deg();
    my $center_lat = ($north_deg + $south_deg) / 2;
    my $center_lon = ($west_deg + $east_deg) / 2;

    my $url = $self->map_url($west_deg, $south_deg, $east_deg, $north_deg);
    my $txt_filename = $self->map_txt_filename($west_deg, $south_deg, $east_deg, $north_deg);
    my $xml_filename = $self->map_xml_filename($west_deg, $south_deg, $east_deg, $north_deg);

    if ($force_mirror && -e $xml_filename) {
        if ($self->file_is_split($xml_filename)) {
            $self->update_osm_from_osm__split(
                $force, $west_deg, $south_deg, $east_deg, $north_deg, $split_direction
            );
            return;
        }
        push(@{$self->{_osm_xml_filenames}}, $xml_filename);
        print STDERR ("+1 $xml_filename\n");
        return;
    }

    mkpath(dirname($xml_filename));

    my $ua = LWP::UserAgent->new();
    warn("Requesting $url ...\n");
    my $response = $ua->mirror($url, $xml_filename);
    my $content = $response->decoded_content;
    warn(sprintf("    %s %s\n", $response->code(), $response->status_line()));
    my $rc = $response->code();
    if ($rc == RC_NOT_MODIFIED) {
        if ($self->file_is_split($xml_filename)) {
            $self->update_osm_from_osm__split(
                $force, $west_deg, $south_deg, $east_deg, $north_deg, $split_direction
            );
            return;
        }
        push(@{$self->{_osm_xml_filenames}}, $xml_filename);
        print STDERR ("+2 $xml_filename\n");
        return;
    }
    if (is_success($rc)) {
        push(@{$self->{_osm_xml_filenames}}, $xml_filename);
        print STDERR ("+3 $xml_filename\n");
        return;
    }
    if ($rc == 400 && $content =~ m{^You requested too many nodes\b}) {
        $self->update_osm_from_osm__split(
            $force, $west_deg, $south_deg, $east_deg, $north_deg, $split_direction
        );
        return;
    }
    die("exiting\n");
}

sub update_osm_from_osm__split {
    my ($self, $force, $west_deg, $south_deg, $east_deg, $north_deg, $split_direction) = @_;
    $split_direction //= 'horizontal';
    my $next_split_direction = $split_direction eq 'horizontal' ? 'vertical' : 'horizontal';

    my ($w1, $s1, $e1, $n1) = ($west_deg, $south_deg, $east_deg, $north_deg);
    my ($w2, $s2, $e2, $n2) = ($west_deg, $south_deg, $east_deg, $north_deg);

    if ($split_direction eq 'horizontal') {
        my $center = ($south_deg + $north_deg) / 2;
        ($s1, $n1) = ($south_deg, $center);
        ($s2, $n2) = ($center, $north_deg);
    } else {
        my $center = ($west_deg + $east_deg) / 2;
        ($w1, $e1) = ($west_deg, $center);
        ($w2, $e2) = ($center, $east_deg);
    }

    my $xml_filename = $self->map_xml_filename($west_deg, $south_deg, $east_deg, $north_deg);
    my $fh;
    open($fh, '>', $xml_filename) or die("$xml_filename: $!\n");
    print $fh "#%SPLIT%#\n";
    printf $fh ("%s\n", $self->map_xml_filename($w1, $s1, $e1, $n1));
    printf $fh ("%s\n", $self->map_xml_filename($w2, $s2, $e2, $n2));
    close($fh);

    $self->update_osm_from_osm($force, $w1, $s1, $e1, $n1, $next_split_direction);
    $self->update_osm_from_osm($force, $w2, $s2, $e2, $n2, $next_split_direction);
}

sub file_is_split {
    my ($self, $filename) = @_;
    my $fh;
    open($fh, '<', $filename) or return;
    my $scalar;
    my $bytes = read($fh, $scalar, 9);
    return if !defined $bytes || $bytes < 9;
    print("[$scalar]\n");
    return $scalar eq '#%SPLIT%#';
}

sub update_osm_from_source {
    my ($self, $force) = @_;
    my $source = $self->{osm_data_source};
    if (ref $source eq 'ARRAY' || !ref $source) {
        $self->update_osm_from_source_url($force);
    }
}

sub update_osm_from_source_url {
    my ($self, $force) = @_;
    my $source = $self->{osm_data_source};
    my @source;

    if (ref $source eq 'ARRAY') {
        @source = @$source;
    } else {
        @source = ($source);
    }

    my $ua = LWP::UserAgent->new();

    foreach my $source (@source) {
        if ($source =~ m{://}) {
            my $filename = $self->cache_filename($source);
            if (-e $filename && !$force) {
                $self->log_warn("Not updating\n");
                push(@{$self->{_osm_xml_filenames}}, $filename);
            } else {
                make_path(dirname($filename));
                $self->log_warn("Downloading %s ...\n", $source);
                my $response = $ua->mirror($source, $filename);
                my $content_type = $response->content_type;
                $self->log_warn("=> %s (%s)\n", $response->status_line, $response->content_type);
                if (!$response->is_success) {
                    exit(1);
                }
                push(@{$self->{_osm_xml_filenames}}, $filename);
            }
        } else {                # assume filename
            push(@{$self->{_osm_xml_filenames}}, $source);
        }
    }
}

sub cache_filename {
    my ($self, $url) = @_;
    return sprintf('%s/.geo-mapmaker-osm/cache/%s', $ENV{HOME}, sha1_hex($url));
}

sub update_or_create_osm_layer {
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

sub get_xml_string {
    my ($self, $filename) = @_;
    my $mm = File::MMagic->new();
    my $mime_type = $mm->checktype_filename($filename);
    if ($mime_type eq 'text/plain') {
        return path($filename)->slurp();
    }
    if ($mime_type eq 'application/x-gzip') {
        $self->log_warn("Uncompressing %d bytes...\n", (-s $filename));
        my $data;
        my $status = anyuncompress($filename => \$data);
        if (!$status) {
            die(sprintf("uncompress failed: %s\n",
                        $IO::Uncompress::AnyUncompress::AnyUncompressError));
        }
        $self->log_warn("  got %d bytes\n", length $data);
        return $data;
    }
    say $mime_type;
    exit(0);
}

sub draw_osm_maps {
    my ($self) = @_;

    local $TEST_WITH_LIMITED_TILES  = $TEST_WITH_LIMITED_TILES;
    local $TEST_WITH_LIMITED_LAYERS = $TEST_WITH_LIMITED_LAYERS;
    local $WATCH_OBJECT_ID          = $WATCH_OBJECT_ID;

    if ($ENV{TEST_MAPMAKER_OSM_PERFORMANCE}) {
        $TEST_WITH_LIMITED_TILES = 16;
    }

    local $self->{log_prefix} = $self->{log_prefix} . '(drawing) ';

    if (!$self->{no_edit}) {
        $self->init_xml();
        $self->{_dirty_} = 1;
        $self->stuff_all_layers_need();

        foreach my $map_area (@{$self->{_map_areas}}) {
            my $prefix = $map_area->{id_prefix};
            my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
            my $clip_path_id = $map_area->{clip_path_id};
            my $osm_layer = $self->update_or_create_osm_layer($map_area,
                                                              $map_area_layer);
            $self->erase_autogenerated_content_within($osm_layer);
            foreach my $osm_layer_info (@{$self->{osm_layers}}) {
                my $layer_class    = $osm_layer_info->{class};
                my $layer_id       = $osm_layer_info->{id};
                my $layer_geometry = $osm_layer_info->{geometry};
                my $layer_id_class;

                if (defined $layer_id) {
                    $layer_id_class = $layer_id;
                    if ($layer_id_class !~ m{^osm-layer-}) {
                        $layer_id_class = 'osm-layer-' . $layer_id_class;
                    }
                }

                my @css_classes;
                push(@css_classes, grep { m{\S} } split(' ', $layer_class)) if defined $layer_class;
                push(@css_classes, 'osm-layer');
                push(@css_classes, $layer_id_class)                         if defined $layer_id_class;
                push(@css_classes, 'osm-geometry-' . $layer_geometry)       if defined $layer_geometry;
                my $css_classes = (scalar @css_classes) ? join(' ', @css_classes) : undef;

                my $layer = $self->update_or_create_layer(name => $osm_layer_info->{name},
                                                          id => $layer_id,
                                                          parent => $osm_layer,
                                                          class => $css_classes,
                                                          insensitive => 1,
                                                          autogenerated => 1,
                                                          children_autogenerated => 1);
                my $group = $self->find_or_create_clipped_group(parent => $layer,
                                                                class => $osm_layer_info->{group_class},
                                                                style => $osm_layer_info->{group_style},
                                                                clip_path_id => $clip_path_id);
                $group->removeChildNodes(); # OK
                $osm_layer_info->{_map_area_layer} //= [];
                $osm_layer_info->{_map_area_group} //= [];
                push(@{$osm_layer_info->{_map_area_layer}}, $layer);
                push(@{$osm_layer_info->{_map_area_group}}, $group);
            }
        }
    }

    if ($TEST_WITH_LIMITED_LAYERS) {
        if (ref $TEST_WITH_LIMITED_LAYERS eq 'SUB') {
            @{$self->{osm_layers}} = grep { $TEST_WITH_LIMITED_LAYERS->() } @{$self->{osm_layers}};
        } else {
            @{$self->{osm_layers}} = grep { $_->{name} =~ m{river}i } @{$self->{osm_layers}};
        }
    }

    my $num_xml_files = scalar(@{$self->{_osm_xml_filenames}});

    foreach my $layer (@{$self->{osm_layers}}) {
        $layer->{type} //= { way => 1, relation => 1 };
        $self->index_layer_tags($layer);
        $layer->{persistent_objects} = Hash::Ordered->new(); # persistent objects
        $layer->{objects} = Hash::Ordered->new(); # subset of persistent objects used directly
    }

    local $self->{_map_tile_number} = 0;
    local $self->{_map_tile_count} = scalar @{$self->{_osm_xml_filenames}};
    local $self->{_css_class_count} = {};

    local $self->{_unused_object_tag_count} = {};
    local $self->{_unused_object_tag_value_count} = {};
    local $self->{_object_tag_count} = {};
    local $self->{_object_tag_value_count} = {};
    local $self->{_layer_object_count} = {};

    foreach my $filename (@{$self->{_osm_xml_filenames}}) {
        $self->{_map_tile_number} += 1;

        local $self->{log_prefix} = $self->{log_prefix} .
            sprintf('(%d/%d) ', $self->{_map_tile_number}, $self->{_map_tile_count});

        if ($TEST_WITH_LIMITED_TILES) {
            if (looks_like_number($TEST_WITH_LIMITED_TILES)) {
                last if $self->{_map_tile_number} > $TEST_WITH_LIMITED_TILES;
            } elsif (ref $TEST_WITH_LIMITED_TILES eq 'ARRAY') {
                next unless grep { $self->{_map_tile_number} == $_ } @$TEST_WITH_LIMITED_TILES;
            }
        }

        $self->log_warn("Reading %s ...\n", $filename);

        my $doc = $self->get_xml_string($filename);

        if ($TEST_WITH_LIMITED_TILES) {
            if (lc(ref $TEST_WITH_LIMITED_TILES) eq 'regexp') {
                next unless $doc =~ $TEST_WITH_LIMITED_TILES;
            }
        }

        $self->log_warn("Parsing XML ...\n");
        local $self->{_doc} = xml2hash($doc, array => 1);

        $self->log_warn("done.\n");

        # all objects for each map tile
        local $self->{_map_tile_nodes}     = Hash::Ordered->new();
        local $self->{_map_tile_ways}      = Hash::Ordered->new();
        local $self->{_map_tile_relations} = Hash::Ordered->new();

        foreach my $layer (@{$self->{osm_layers}}) {
            # filtered objects for each map tile
            $layer->{map_tile_objects} = Hash::Ordered->new();
        }

        $self->load_map_tile_objects();
        $self->convert_map_tile_tags();
        $self->collect_map_tile_layer_objects();
        $self->link_map_tile_objects();
        $self->convert_coordinates();
    }

    $self->{_map_tile_number} = undef;
    $self->{_map_tile_count} = undef;

    if (!$self->{no_edit}) {
        $self->draw();
    }

    $self->log_warn("  Writing unused object tag and tag=value counts ...\n");
    $self->write_object_tag_counts(0);
    $self->write_object_tag_value_counts(0);
    $self->log_warn("  Writing object tag and tag=value counts ...\n");
    $self->write_object_tag_counts(1);
    $self->write_object_tag_value_counts(1);
    $self->log_warn("  Writing layer object counts ...\n");
    $self->write_layer_object_counts();
    $self->log_warn("  Done.\n");

    $self->log_warn("draw_osm_maps is done\n");
}

sub load_map_tile_objects {
    my $self = shift;
    $self->log_warn("Loading map tile objects (%d nodes, %d ways, and %d relations) ...\n",
                    scalar @{$self->{_doc}->{osm}->[0]->{node}},
                    scalar @{$self->{_doc}->{osm}->[0]->{way}},
                    scalar @{$self->{_doc}->{osm}->[0]->{relation}});
    my $nc = 0;
    my $wc = 0;
    my $rc = 0;
    foreach my $node (@{$self->{_doc}->{osm}->[0]->{node}}) {
        $node = Geo::MapMaker::OSM::Node->new($node);
        $self->{_map_tile_nodes}->set($node->{-id}, $node);
        $nc += 1;
        # delete $node->{-changeset};
        # delete $node->{-timestamp};
        # delete $node->{-uid};
        # delete $node->{-user};
        # delete $node->{-version};
        # delete $node->{-visible};
        $node->{type} = 'node';
    }
    $self->log_debug("  %d nodes\n", $nc);

    foreach my $way (@{$self->{_doc}->{osm}->[0]->{way}}) {
        $way = Geo::MapMaker::OSM::Way->new($way);
        $self->{_map_tile_ways}->set($way->{-id}, $way);
        $wc += 1;
        # delete $way->{-changeset};
        # delete $way->{-timestamp};
        # delete $way->{-uid};
        # delete $way->{-user};
        # delete $way->{-version};
        # delete $way->{-visible};
        $way->{type} = 'way';
    }
    $self->log_debug("  %d ways\n", $wc);

    foreach my $relation (@{$self->{_doc}->{osm}->[0]->{relation}}) {
        $relation = Geo::MapMaker::OSM::Relation->new($relation);
        $self->{_map_tile_relations}->set($relation->{-id}, $relation);
        $rc += 1;
        # delete $relation->{-changeset};
        # delete $relation->{-timestamp};
        # delete $relation->{-uid};
        # delete $relation->{-user};
        # delete $relation->{-version};
        # delete $relation->{-visible};
        $relation->{type} = 'relation';
    }
    $self->log_debug("  %d relations\n", $rc);

    $self->log_warn("Done.\n");
}

sub convert_map_tile_tags {
    my ($self) = @_;
    my $count =
        (scalar $self->{_map_tile_nodes}->keys) +
        (scalar $self->{_map_tile_ways}->keys) +
        (scalar $self->{_map_tile_relations}->keys);
    $self->log_warn("Converting tags on %d objects ...\n", $count);
    if (grep { $_->{type}->{node} } @{$self->{osm_layers}}) {
        foreach my $node ($self->{_map_tile_nodes}->values) {
            $node->convert_tags();
        }
    }
    foreach my $way ($self->{_map_tile_ways}->values) {
        $way->convert_tags();
    }
    foreach my $relation ($self->{_map_tile_relations}->values) {
        $relation->convert_tags();
    }
    $self->log_warn("Done.\n");
}

sub index_layer_tags {
    my ($self, $layer) = @_;
    my $index = $layer->{index} = [];
    foreach my $tag (@{$layer->{tags}}) {
        my $k = $tag->{k};
        my $v = $tag->{v};
        if (defined $v) {
            if (ref $v eq 'ARRAY') {
                foreach my $v (@$v) {
                    $self->index_layer_tag($layer, $k, $v);
                }
            } else {
                $self->index_layer_tag($layer, $k, $v);
            }
        } else {
            $self->index_layer_tag($layer, $k);
        }
    }
}

sub index_layer_tag {
    my ($self, $layer, $key, $value) = @_;
    my $index = $layer->{index};
    if (defined $value) {
        if (substr($value, 0, 1) eq '!') {
            my $value = substr($value, 1);
            if ($value ne '') {
                my $string = join($;, $key, $value);
                # scalarref means negation
                push(@$index, \$string);
            }
        } else {
            if ($value ne '') {
                push(@$index, join($;, $key, $value));
            }
        }
    } else {
        push(@$index, $key);
    }
}

sub convert_coordinates {
    my ($self) = @_;
    $self->log_warn("Converting coordinates ...\n");
    foreach my $map_area (@{$self->{_map_areas}}) {
        my $map_area_index = $map_area->{index};
        foreach my $layer (@{$self->{osm_layers}}) {
            foreach my $relation (grep { $_->{type} eq 'relation' } $layer->{objects}->values) {
                foreach my $way (@{$relation->{way_array}}) {
                    foreach my $node (@{$way->{node_array}}) {
                        $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
                    }
                }
            }
            foreach my $way (grep { $_->{type} eq 'way' } $layer->{objects}->values) {
                foreach my $node (@{$way->{node_array}}) {
                    $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
                }
            }
            foreach my $node (grep { $_->{type} eq 'node' } $layer->{objects}->values) {
                $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
            }
        }
    }
    $self->log_warn("Done.\n");
}

sub convert_node_coordinates {
    my ($self, $node) = @_;
    my $lon_deg = 0 + $node->{-lon};
    my $lat_deg = 0 + $node->{-lat};
    my ($svgx, $svgy) = $self->lon_lat_deg_to_svg($lon_deg, $lat_deg);

    my $west_lon_deg  = $self->{west_lon_deg};
    my $east_lon_deg  = $self->{east_lon_deg};
    my $south_lat_deg = $self->{south_lat_deg};
    my $north_lat_deg = $self->{north_lat_deg};

    my $xzone = $lon_deg < $west_lon_deg  ? -1 : $lon_deg > $east_lon_deg  ? 1 : 0;
    my $yzone = $lat_deg < $south_lat_deg ? -1 : $lat_deg > $north_lat_deg ? 1 : 0;
    my $result = [$svgx, $svgy, $xzone, $yzone];
    return $result;
}

use vars qw(%NS);

sub draw {
    my ($self) = @_;
    $self->log_warn("Drawing into map ...\n");
    foreach my $map_area (@{$self->{_map_areas}}) {
        my $map_area_index = $map_area->{index};
        my $map_area_name = $map_area->{name};
        $self->log_warn("  Drawing into map area $map_area_index - $map_area_name ...\n");
        foreach my $layer (@{$self->{osm_layers}}) {
            my $layer_name     = $layer->{name};
            my $layer_group    = $layer->{_map_area_group}[$map_area_index];
            my $layer_id       = $layer->{id};
            my $layer_geometry = $layer->{geometry};
            my $layer_object_class = $layer->{object_class};

            my $position       = $layer->{position};
            my $position_dx    = eval { $position->{left} };
            my $position_dy    = eval { $position->{top} };

            my @objects = $layer->{objects}->values;
            $self->log_warn("    Adding %d objects to layer $layer_name ...\n", scalar @objects);
            foreach my $object (@objects) {

                my $css_class_string = $object->css_class_string(
                    layer => $layer,
                    map_area => $map_area,
                    object_class => $layer_object_class,
                );

                my $css_id = $object->css_id(
                    layer => $layer,
                    map_area => $map_area,
                );
                my $attr = {};
                $attr->{'data-name'} = $object->{tags}->{name} if defined $object->{tags}->{name};

                my $svg_element;
                if ($object->is_multipolygon_relation) {
                    my $path = $object->svg_object(map_area_index => $map_area_index);
                    next unless $path;
                    $svg_element = $self->svg_path(
                        position_dx => $position_dx,
                        position_dy => $position_dy,
                        path => $path,
                        class => $css_class_string,
                        attr => $attr,
                        id => $css_id,
                        map_area_index => $map_area_index,
                    );
                } elsif ($object->isa('Geo::MapMaker::OSM::Relation')) {
                    my $path = $object->svg_object(map_area_index => $map_area_index);
                    next unless $path;
                    $svg_element = $self->svg_path(
                        position_dx => $position_dx,
                        position_dy => $position_dy,
                        path => $path,
                        class => $css_class_string,
                        attr => $attr,
                        id => $css_id,
                        map_area_index => $map_area_index,
                    );
                } elsif ($object->{type} eq 'way') {
                    my $polyline = $object->svg_object(map_area_index => $map_area_index);
                    next unless $polyline;
                    $svg_element = $self->svg_path(
                        position_dx => $position_dx,
                        position_dy => $position_dy,
                        polyline => $polyline,
                        class => $css_class_string,
                        attr => $attr,
                        id => $css_id,
                        map_area_index => $map_area_index,
                    );
                }
                if ($svg_element) {
                    $layer_group->appendChild($svg_element);
                }
            }
        }
    }
    $self->log_warn("Done.\n");
}

sub object_matches_layer {
    my ($self, $object, $layer) = @_;
    my $object_index = $object->{index};
    foreach my $index (@{$layer->{index}}) {
        if (ref $index eq 'SCALAR') {
            # scalarref means negation
            if ($object_index->{$$index}) {
                return 0;
            }
        } else {
            if ($object_index->{$index}) {
                return 1;
            }
        }
    }
    return;
}

sub collect_map_tile_layer_objects {
    my ($self) = @_;
    my $count = 0;
    $self->log_warn("Collecting objects for layers ...\n");
    foreach my $layer (@{$self->{osm_layers}}) {
        my @objects;
        push(@objects, $self->{_map_tile_nodes}->values)     if $layer->{type}->{node};
        push(@objects, $self->{_map_tile_ways}->values)      if $layer->{type}->{way};
        push(@objects, $self->{_map_tile_relations}->values) if $layer->{type}->{relation};
        $self->log_warn("  Checking %d objects in layer %s\n",
                        scalar @objects, $layer->{name});
        my $layer_object_count = 0;
        foreach my $object (@objects) {
            next unless $self->object_matches_layer($object, $layer);

            $object->{used} = 1;

            $layer->{persistent_objects}->or_equals($object->{-id}, $object);

            # objects used directly
            $layer->{objects}->or_equals($object->{-id}, $object);

            # Current objects, from which we pull any ways not found
            # in previously pulled relations.
            $layer->{map_tile_objects}->set($object->{-id}, $object);

            $self->count_layer_object($layer, $object);

            $count += 1;
            $layer_object_count += 1;
        }
        $self->log_warn("    matched %d objects\n", $layer_object_count);
    }
    if (grep { $_->{type}->{node} } @{$self->{osm_layers}}) {
        foreach my $node ($self->{_map_tile_nodes}->values) {
            $self->count_object_tags($node, $node->{used} ? 1 : 0);
        }
    }
    if (grep { $_->{type}->{way} } @{$self->{osm_layers}}) {
        foreach my $way ($self->{_map_tile_ways}->values) {
            $self->count_object_tags($way, $way->{used} ? 1 : 0);
        }
    }
    if (grep { $_->{type}->{relation} } @{$self->{osm_layers}}) {
        foreach my $relation ($self->{_map_tile_relations}->values) {
            $self->count_object_tags($relation, $relation->{used} ? 1 : 0);
        }
    }
    $self->log_warn("Done.  Added %d objects.\n", $count);
}

sub count_layer_object {
    my ($self, $layer, $object) = @_;
    my $type = $object->{type};
    $self->{_layer_object_count}->{$layer->{id} // $layer->{name}}->{TOTAL} += 1;
    $self->{_layer_object_count}->{$layer->{id} // $layer->{name}}->{$type} += 1;
}

sub count_object_tags {
    my ($self, $object, $used_flag) = @_;
    my $type = $object->{type};
  tag:
    foreach my $k (keys %{$object->{tags}}) {
        next if $EXCLUDE_TAG_NAMES->{$k};
        foreach my $exclude (@EXCLUDE_TAG_NAMES) {
            next tag if ref $exclude eq 'Regexp' && $k =~ $exclude;
        }
        my $v = $object->{tags}->{$k};
        next unless $TAG_NAME_WHITELIST->{$k} || $TAG_NAME_VALUE_WHITELIST->{"${k}=${v}"};
        if ($used_flag) {
            $self->{_object_tag_count}->{$type}->{$k} += 1;
            $self->{_object_tag_value_count}->{$type}->{$k}->{$v} += 1;
        } else {
            $self->{_unused_object_tag_count}->{$type}->{$k} += 1;
            $self->{_unused_object_tag_value_count}->{$type}->{$k}->{$v} += 1;
        }
    }
}

sub stats_filename {
    my ($self, $stats_filename) = @_;
    my $basename = basename($self->{filename});
    my $dirname  = dirname($self->{filename});
    return sprintf('%s/%s--%s', $dirname, $basename, $stats_filename);
}

sub write_layer_object_counts {
    my ($self) = @_;
    my $fh;
    my $filename = $self->stats_filename('layer-object-counts.txt');
    open($fh, '>', $filename) or return;
    my $hash = $self->{_layer_object_count};
    print $fh ("#TOTAL   Nodes    Ways  Reltns  Layer Name\n");
    print $fh ("#-----  ------  ------  ------  -----------------------------------------------\n");
    foreach my $layer (@{$self->{osm_layers}}) {
        my $id = $layer->{id};
        my $name = $layer->{name};
        my $key = $layer->{id} // $layer->{name};
        my $display = '?';
        if (defined $id && defined $name) {
            $display = "$name ($id)"
        } elsif (defined $id) {
            $display = "($id)"
        } elsif (defined $name) {
            $display = "$name"
        }
        my $total_count = $hash->{$key}->{TOTAL} // 0;
        my $node_count = $hash->{$key}->{node} // 0;
        my $way_count = $hash->{$key}->{way} // 0;
        my $relation_count = $hash->{$key}->{relation} // 0;
        printf $fh ("%6d  %6d  %6d  %6d  %s\n",
                    $total_count, $node_count, $way_count, $relation_count,
                    normalize_space($display));
    }
}

sub write_object_tag_counts {
    my ($self, $used_flag) = @_;
    my $fh;
    my $filename;
    my $hash;
    if ($used_flag) {
        $filename = $self->stats_filename('object-tag-counts.txt');
        $hash = $self->{_object_tag_count};
    } else {
        $filename = $self->stats_filename('unused-object-tag-counts.txt');
        $hash = $self->{_unused_object_tag_count};
    }
    open($fh, '>', $filename) or return;
    $self->log_warn("    Writing $filename ...\n");
    foreach my $type (nsort keys %$hash) {
        my $subhash = $hash->{$type};
        foreach my $key (nsort keys %$subhash) {
            printf $fh ("%6d  %-14s  %s\n", $subhash->{$key}, $type, $key);
        }
    }
}

sub write_object_tag_value_counts {
    my ($self, $used_flag) = @_;
    my $fh;
    my $filename;
    my $hash;
    if ($used_flag) {
        $filename = $self->stats_filename('object-tag-value-counts.txt');
        $hash = $self->{_object_tag_value_count};
    } else {
        $filename = $self->stats_filename('unused-object-tag-value-counts.txt');
        $hash = $self->{_unused_object_tag_value_count};
    }
    open($fh, '>', $filename) or return;
    $self->log_warn("    Writing $filename ...\n");
    foreach my $type (nsort keys %$hash) {
        my $subhash = $hash->{$type};
        foreach my $key (nsort keys %$subhash) {
            my $subsubhash = $subhash->{$key};
            foreach my $value (nsort keys %$subsubhash) {
                my $selecting = scalar $self->layers_collecting($type, $key, $value);
                printf $fh ("%6d  %6d  %-14s  %-22s  %s\n", $subsubhash->{$value}, $selecting, $type, $key, normalize_space($value));
            }
        }
    }
}

sub layers_collecting {
    my ($self, $type, $key, $value) = @_;
    return grep {
        $self->layer_collects($_, $type, $key, $value)
    } @{$self->{osm_layers}};
}

sub layer_collects {
    my ($self, $layer, $type, $key, $value) = @_;
    if (index($key, $;) != -1) {
        ($key, $value) = split($;, $key);
    }
    return 0 if !$layer->{type}->{$type};
    my $object_index = {};
    $object_index->{$key,$value} = 1 if defined $key && defined $value;
    $object_index->{$key}        = 1 if defined $key;
    foreach my $index (@{$layer->{index}}) {
        if (ref $index eq 'SCALAR') {
            # scalarref means negation
            if ($object_index->{$$index}) {
                return 0;
            }
        } else {
            if ($object_index->{$index}) {
                return 1;
            }
        }
    }
    return;
}

sub link_map_tile_objects {
    my ($self) = @_;
    $self->log_warn("Linking objects ...\n");
    my $count = 0;
    foreach my $layer (@{$self->{osm_layers}}) {
        foreach my $relation (grep { $_->{type} eq 'relation' } $layer->{map_tile_objects}->values) {
            my $id = $relation->{-id};
            my $relation = $self->find_persistent_object($layer, $relation);
            $self->link_relation_object($layer, $id, $relation);
            $count += 1;
        }
        foreach my $way (grep { $_->{type} eq 'way' } $layer->{map_tile_objects}->values) {
            my $id = $way->{-id};
            my $way = $self->find_persistent_object($layer, $way);
            $self->link_way_object($layer, $id, $way);
            $count += 1;
        }
    }
    $self->log_warn("Done.  Linked %d objects.\n", $count);
}

sub find_persistent_object {
    my ($self, $layer, $object) = @_;
    if (!$object) {
        return;
    }
    if (!ref $object) {
        my $id = $object;
        return $layer->{persistent_objects}->get($id);
    }
    my $id = $object->{-id};
    if ($layer->{persistent_objects}->exists($id)) {
        return $layer->{persistent_objects}->get($id);
    }
    $layer->{persistent_objects}->or_equals($object->{-id}, $object);
    return $object;
}

sub link_relation_object {
    my ($self, $layer, $relation_id) = @_;

    my $relation = $layer->{persistent_objects}->get($relation_id); # persistent

    # current objects, where we get way_ids from to merge them in
    # because not all relation objects across tiles have the same list
    # of ways
    my $map_tile_relation = $layer->{map_tile_objects}->get($relation_id);

    # store ways in persistent objects
    $relation->{way_hash} //= {};
    $relation->{way_id_is_outer} //= {};
    $relation->{way_id_is_inner} //= {};

    my @way_ids       = map { $_->{-ref} } grep { eval { $_->{-type} eq 'way' && defined $_->{-ref} } } @{$map_tile_relation->{member}};
    my @outer_way_ids = map { $_->{-ref} } grep { eval { $_->{-role} eq 'outer' && $_->{-type} eq 'way' && defined $_->{-ref} } } @{$map_tile_relation->{member}};
    my @inner_way_ids = map { $_->{-ref} } grep { eval { $_->{-role} eq 'inner' && $_->{-type} eq 'way' && defined $_->{-ref} } } @{$map_tile_relation->{member}};

    foreach my $id (@outer_way_ids) {
        $relation->{way_id_is_outer}->{$id} = 1;
    }
    foreach my $id (@inner_way_ids) {
        $relation->{way_id_is_inner}->{$id} = 1;
    }

    foreach my $id (@way_ids) {
        my $way = $self->{_map_tile_ways}->get($id);
        if ($way) {
            $way = $self->find_persistent_object($layer, $way);
        } else {
            $way = $self->find_persistent_object($layer, $id);
        }
        if ($way) {
            $relation->{way_hash}->{$id} = $way;
        } else {
            # do nothing
        }
    }

    @{$relation->{way_array}} =
        grep { $_ } map { $relation->{way_hash}->{$_} } sort { $a <=> $b } keys %{$relation->{way_hash}};
    @{$relation->{outer_way_array}} = grep { $relation->{way_id_is_outer}->{$_->{-id}} } @{$relation->{way_array}};
    @{$relation->{inner_way_array}} = grep { $relation->{way_id_is_inner}->{$_->{-id}} } @{$relation->{way_array}};
    @{$relation->{other_way_array}} =
        grep { !$relation->{way_id_is_inner}->{$_->{-id}} && !$relation->{way_id_is_outer}->{$_->{-id}} }
        @{$relation->{way_array}};

    foreach my $way (@{$relation->{way_array}}) {
        $self->link_way_object($layer, $way->{-id}, $way);
    }
}

sub link_way_object {
    my ($self, $layer, $way_id, $way) = @_;

    $way ||= $layer->{persistent_objects}->get($way_id);

    $way->{node_hash} //= {};

    my @node_ids = map { $_->{-ref} } @{$way->{nd}};
    $way->{node_ids} = \@node_ids; # should always be the same

    foreach my $node_id (@node_ids) {
        my $node = $self->{_map_tile_nodes}->get($node_id);
        if ($node) {
            $node = $self->find_persistent_object($layer, $node);
        } else {
            $node = $self->find_persistent_object($layer, $node_id);
        }
        if ($node) {
            $way->{node_hash}->{$node_id} = $node;
        } else {
            # do nothing
        }
    }

    @{$way->{node_array}} =
        grep { $_ }
        map { $self->find_persistent_object($layer, $way->{node_hash}->{$_}) }
        @{$way->{node_ids}};

    if ($way->is_complete()) {
        if ($way->is_self_closing()) {
            $way->{is_closed} = 1;
            if ($way->{tags} && defined $way->{tags}->{area} && $way->{tags}->{area} eq 'yes') {
                $way->{is_area} = 1;
            } elsif (!exists $way->{tags}->{highway} && !exists $way->{tags}->{barrier}) {
                $way->{is_area} = 1;
            }
            # Normally a way with highway=* or barrier=* is a closed
            # polyline that's not filled.  However, if area=yes is
            # specified, it can be filled.
        } else {
            $way->{is_closed} = 0;
        }
    } else {
        $way->{is_closed} = 0;
    }
}

sub west_osm_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
        return (eval { $self->{osm_map_boundaries}->{west_lon_deg} } //
                $self->{osm_data_west_lon_deg} //
                $self->{west_lon_deg});
    }
}

sub east_osm_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
        return (eval { $self->{osm_map_boundaries}->{east_lon_deg} } //
                $self->{osm_data_east_lon_deg} //
                $self->{east_lon_deg});
    }
}

sub north_osm_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
        return (eval { $self->{osm_map_boundaries}->{north_lat_deg} } //
                $self->{osm_data_north_lat_deg} //
                $self->{north_lat_deg});
    }
}

sub south_osm_data_boundary_deg {
    my ($self) = @_;
    my $o = $self->{orientation};
    if ($o) {
	# FIXME
	die("non-zero orientation not supported yet");
    } else {
        return (eval { $self->{osm_map_boundaries}->{south_lat_deg} } //
                $self->{osm_data_south_lat_deg} //
                $self->{south_lat_deg});
    }
}

1;
