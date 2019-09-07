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

              _map_tile_nodes
              _map_tile_ways
              _map_tile_relations

              _map_tile_number
              _map_tile_count);

use LWP::Simple;                # RC_NOT_MODIFIED
use List::MoreUtils qw(all uniq);
use Sort::Naturally;
use Geo::MapMaker::Dumper qw(Dumper);

use Geo::MapMaker::SVG::Point;
use Geo::MapMaker::SVG::PolyLine;
use Geo::MapMaker::SVG::Path;

use Geo::MapMaker::OSM::Node;
use Geo::MapMaker::OSM::Relation;
use Geo::MapMaker::OSM::Way;
use Geo::MapMaker::OSM::Collection;

use File::Slurper qw(read_text);
use Path::Tiny;
use Encode;
use Scalar::Util qw(looks_like_number);
use Digest::SHA qw(sha1_hex);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use XML::Fast;
use File::MMagic;
use IO::Uncompress::AnyUncompress qw(anyuncompress);

our $TEST_WITH_LIMITED_TILES = 0;
# $TEST_WITH_LIMITED_TILES = qr{<\s*tag\s+k="name"\s+v="Ohio River"\s*/>}i;
# $TEST_WITH_LIMITED_TILES = [117, 118, 120, 153, 154, 155];

our $TEST_WITH_LIMITED_LAYERS = 0;
# $TEST_WITH_LIMITED_LAYERS = sub {
#     return $_->{name} =~ m{river}i;
# };

our $WATCH_OBJECT_ID = {
    #'471312697' => 1,
    #'2182501' => 1,
    #'3962892' => 1,
};

our $COUNT_CSS_CLASSES = 0;

sub update_openstreetmap {
    my ($self, $force) = @_;
    my $source = $self->{map_data_source};
    if ($source) {
        $self->update_openstreetmap_from_source($force);
    } else {
        $self->update_openstreetmap_from_osm_xml_api($force);
    }
}

sub update_openstreetmap_from_source {
    my ($self, $force) = @_;
    my $source = $self->{map_data_source};
    if (ref $source eq 'ARRAY' || !ref $source) {
        $self->update_openstreetmap_from_source_url($force);
    }
}

sub update_openstreetmap_from_source_url {
    my ($self, $force) = @_;
    my $source = $self->{map_data_source};
    my @url;

    if (ref $source eq 'ARRAY') {
        @url = @$source;
    } else {
        @url = ($source);
    }

    my $ua = LWP::UserAgent->new();

    foreach my $url (@url) {
        my $filename = $self->cache_filename($url);
        if (-e $filename && !$force) {
            $self->log_warn("Not updating\n");
            push(@{$self->{_osm_xml_filenames}}, $filename);
        } elsif (-e $filename && $force && -M $filename < 1) {
            $self->log_warn("Not updating (force in effect but file is less than 1 day old)\n");
            push(@{$self->{_osm_xml_filenames}}, $filename);
        } else {
            make_path(dirname($filename));
            $self->log_warn("Downloading %s ...\n", $url);
            my $response = $ua->mirror($url, $filename);
            my $content_type = $response->content_type;
            $self->log_warn("=> %s (%s)\n", $response->status_line, $response->content_type);
            if (!$response->is_success) {
                exit(1);
            }
            push(@{$self->{_osm_xml_filenames}}, $filename);
        }
    }
}

sub cache_filename {
    my ($self, $url) = @_;
    return sprintf('%s/.geo-mapmaker-osm/cache/%s', $ENV{HOME}, sha1_hex($url));
}

sub update_openstreetmap_from_osm_xml_api {
    my ($self, $force) = @_;
    $self->{_osm_xml_filenames} = [];
    $self->_update_openstreetmap_from_osm_xml_api($force);
}

sub _update_openstreetmap_from_osm_xml_api {
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
        $self->_update_openstreetmap_from_osm_xml_api($force, $west_deg,   $south_deg,  $center_lon, $center_lat);
        $self->_update_openstreetmap_from_osm_xml_api($force, $center_lon, $south_deg,  $east_deg,   $center_lat);
        $self->_update_openstreetmap_from_osm_xml_api($force, $west_deg,   $center_lat, $center_lon, $north_deg);
        $self->_update_openstreetmap_from_osm_xml_api($force, $center_lon, $center_lat, $east_deg,   $north_deg);
    } elsif (-e $xml_filename && !$force) {
        $self->log_warn("Not updating $xml_filename\n    $url\n") if $self->{verbose};
        push(@{$self->{_osm_xml_filenames}}, $xml_filename);
    } elsif (-e $xml_filename && $force && -M $xml_filename < 1) {
        $self->log_warn("Not updating $xml_filename\n    $url\n    (force in effect but less than 1 day old)\n") if $self->{verbose};
        push(@{$self->{_osm_xml_filenames}}, $xml_filename);
    } else {
        my $ua = LWP::UserAgent->new();
        print STDERR ("Downloading $url ... ");
      try_again:
        my $response = $ua->mirror($url, $xml_filename);
        printf STDERR ("%s\n", $response->status_line());
        my $rc = $response->code();
        if ($rc == RC_NOT_MODIFIED) {
            push(@{$self->{_osm_xml_filenames}}, $xml_filename);
            # ok then
        } elsif ($rc == 400) {	# Bad Request
            file_put_contents($txt_filename, "split-up");
            my $center_lat = ($north_deg + $south_deg) / 2;
            my $center_lon = ($west_deg + $east_deg) / 2;
            $self->_update_openstreetmap_from_osm_xml_api($force, $west_deg,   $south_deg,  $center_lon, $center_lat);
            $self->_update_openstreetmap_from_osm_xml_api($force, $center_lon, $south_deg,  $east_deg,   $center_lat);
            $self->_update_openstreetmap_from_osm_xml_api($force, $west_deg,   $center_lat, $center_lon, $north_deg);
            $self->_update_openstreetmap_from_osm_xml_api($force, $center_lon, $center_lat, $east_deg,   $north_deg);
        } elsif (is_success($rc)) {
            push(@{$self->{_osm_xml_filenames}}, $xml_filename);
            # ok then
        } elsif ($rc == 509) {	# Bandwidth Exceeded
            $self->log_warn("Waiting 30 seconds...\n");
            sleep(30);
            goto try_again;
        } else {
            croak(sprintf("Failure: %s => %s\n",
                          $response->base(),
                          $response->status_line()));
        }
    }
}

sub force_update_openstreetmap_from_osm_xml_api {
    my ($self) = @_;
    $self->update_openstreetmap_from_osm_xml_api(1);
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

sub draw_openstreetmap_maps {
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
            $self->update_scale($map_area);
            my $prefix = $map_area->{id_prefix};
            my $map_area_layer = $self->update_or_create_map_area_layer($map_area);
            my $clip_path_id = $map_area->{clip_path_id};
            my $osm_layer = $self->update_or_create_openstreetmap_layer($map_area,
                                                                        $map_area_layer);
            $self->erase_autogenerated_content_within($osm_layer);
            foreach my $osm_layer_info (@{$self->{osm_layers}}) {
                my $layer_class = $osm_layer_info->{layer_class};
                my $layer_style = $osm_layer_info->{layer_style};
                my $layer = $self->update_or_create_layer(name => $osm_layer_info->{name},
                                                          parent => $osm_layer,
                                                          class => $layer_class,
                                                          style => $layer_style,
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
        $layer->{index} = {};
        foreach my $tag (@{$layer->{tags}}) {
            my $k = $tag->{k};
            my $v = $tag->{v};
            if (defined $v) {
                if (ref $v eq 'ARRAY') {
                    foreach my $v (@$v) {
                        $layer->{index}->{$k,$v} = 1;
                    }
                } else {
                    $layer->{index}->{$k,$v} = 1;
                }
            } else {
                $layer->{index}->{$k} = 1;
            }
        }
    }

    foreach my $layer (@{$self->{osm_layers}}) {
        $layer->{persistent_objects} = Geo::MapMaker::OSM::Collection->new(); # persistent objects
        $layer->{objects} = Geo::MapMaker::OSM::Collection->new(); # subset of persistent objects used directly
        $self->index_layer_tags($layer);
    }

    local $self->{_map_tile_number} = 0;
    local $self->{_map_tile_count} = scalar @{$self->{_osm_xml_filenames}};
    local $self->{_css_class_count} = {};

    local $self->{_unused_object_tag_count} = {};
    local $self->{_unused_object_tag_value_count} = {};

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

        $self->twarn("Reading %s ...\n", $filename);

        my $doc = $self->get_xml_string($filename);

        if ($TEST_WITH_LIMITED_TILES) {
            if (lc(ref $TEST_WITH_LIMITED_TILES) eq 'regexp') {
                next unless $doc =~ $TEST_WITH_LIMITED_TILES;
            }
        }

        $self->twarn("Parsing XML ...\n");
        local $self->{_doc} = xml2hash($doc, array => 1);

        $self->twarn("done.\n");

        # all objects for each map tile
        local $self->{_map_tile_nodes}     = Geo::MapMaker::OSM::Collection->new();
        local $self->{_map_tile_ways}      = Geo::MapMaker::OSM::Collection->new();
        local $self->{_map_tile_relations} = Geo::MapMaker::OSM::Collection->new();

        foreach my $layer (@{$self->{osm_layers}}) {
            # filtered objects for each map tile
            $layer->{map_tile_objects} = Geo::MapMaker::OSM::Collection->new();
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
    $self->write_unused_object_tag_counts();
    $self->write_unused_object_tag_value_counts();
    $self->log_warn("  Done.\n");

    $self->log_warn("draw_openstreetmap_maps is done\n");
}

sub load_map_tile_objects {
    my $self = shift;
    $self->twarn("Loading map tile objects (%d nodes, %d ways, and %d relations) ...\n",
                 scalar @{$self->{_doc}->{osm}->[0]->{node}},
                 scalar @{$self->{_doc}->{osm}->[0]->{way}},
                 scalar @{$self->{_doc}->{osm}->[0]->{relation}});
    my $nc = 0;
    my $wc = 0;
    my $rc = 0;
    my $order = 0;
    foreach my $node (@{$self->{_doc}->{osm}->[0]->{node}}) {
        $node = Geo::MapMaker::OSM::Node->new($node);
        $self->{_map_tile_nodes}->add($node);
        $nc += 1;
        delete $node->{-changeset};
        delete $node->{-timestamp};
        delete $node->{-uid};
        delete $node->{-user};
        delete $node->{-version};
        delete $node->{-visible};
        $node->{type} = 'node';

        # if ($WATCH_OBJECT_ID) {
        #     my $id = $node->{-id};
        #     if ($WATCH_OBJECT_ID->{$id}) {
        #     }
        # }
    }
    $self->tdebug("  %d nodes\n", $nc);

    foreach my $way (@{$self->{_doc}->{osm}->[0]->{way}}) {
        $way = Geo::MapMaker::OSM::Way->new($way);
        $self->{_map_tile_ways}->add($way);
        $wc += 1;
        delete $way->{-changeset};
        delete $way->{-timestamp};
        delete $way->{-uid};
        delete $way->{-user};
        delete $way->{-version};
        delete $way->{-visible};
        $way->{type} = 'way';

        # if ($WATCH_OBJECT_ID) {
        #     my $id = $way->{-id};
        #     if ($WATCH_OBJECT_ID->{$id}) {
        #     }
        # }
    }
    $self->tdebug("  %d ways\n", $wc);

    foreach my $relation (@{$self->{_doc}->{osm}->[0]->{relation}}) {
        $relation = Geo::MapMaker::OSM::Relation->new($relation);
        $self->{_map_tile_relations}->add($relation);
        $rc += 1;
        delete $relation->{-changeset};
        delete $relation->{-timestamp};
        delete $relation->{-uid};
        delete $relation->{-user};
        delete $relation->{-version};
        delete $relation->{-visible};
        $relation->{type} = 'relation';

        # if ($WATCH_OBJECT_ID) {
        #     my $id = $relation->{-id};
        #     if ($WATCH_OBJECT_ID->{$id}) {
        #     }
        # }
    }
    $self->tdebug("  %d relations\n", $rc);

    $self->twarn("Done.\n");
}

sub convert_map_tile_tags {
    my ($self) = @_;
    my $count =
        $self->{_map_tile_nodes}->count() +
        $self->{_map_tile_ways}->count() +
        $self->{_map_tile_relations}->count();
    $self->twarn("Converting tags on %d objects ...\n", $count);
    if (grep { $_->{type}->{node} } @{$self->{osm_layers}}) {
        foreach my $node ($self->{_map_tile_nodes}->objects) {
            $node->convert_tags();
        }
    }
    foreach my $way ($self->{_map_tile_ways}->objects) {
        $way->convert_tags();
        # if ($WATCH_OBJECT_ID) {
        #     my $id = $way->{-id};
        #     if ($WATCH_OBJECT_ID->{$id}) {
        #         say Dumper $way;
        #     }
        # }
    }
    foreach my $relation ($self->{_map_tile_relations}->objects) {
        $relation->convert_tags();
    }
    $self->twarn("Done.\n");
}

sub index_layer_tags {
    my ($self, $layer) = @_;
    $layer->{index} = [];
    foreach my $tag (@{$layer->{tags}}) {
        my $k = $tag->{k};
        my $v = $tag->{v};
        if (defined $v && $v ne '') {
            push(@{$layer->{index}}, join($;, $k, $v));
        } else {
            push(@{$layer->{index}}, join($;, $k));
        }
    }
}

sub convert_coordinates {
    my ($self) = @_;
    $self->twarn("Converting coordinates ...\n");
    foreach my $map_area (@{$self->{_map_areas}}) {
        $self->update_scale($map_area);
        my $map_area_index = $map_area->{index};
        foreach my $layer (@{$self->{osm_layers}}) {
            foreach my $relation (grep { $_->{type} eq 'relation' } $layer->{objects}->objects) {
                foreach my $way (@{$relation->{way_array}}) {
                    foreach my $node (@{$way->{node_array}}) {
                        $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
                    }
                }
            }
            foreach my $way (grep { $_->{type} eq 'way' } $layer->{objects}->objects) {
                foreach my $node (@{$way->{node_array}}) {
                    $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
                }
                # if ($WATCH_OBJECT_ID) {
                #     my $id = $way->{-id};
                #     if ($WATCH_OBJECT_ID->{$id}) {
                #         say "# <5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<5<";
                #         say Dumper $way;
                #         say "# >5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>5>";
                #     }
                # }
            }
            foreach my $node (grep { $_->{type} eq 'node' } $layer->{objects}->objects) {
                $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
            }
        }
    }
    $self->twarn("Done.\n");
}

sub convert_node_coordinates {
    my ($self, $node) = @_;
    my $west_svg  = $self->west_outer_map_boundary_svg;
    my $east_svg  = $self->east_outer_map_boundary_svg;
    my $north_svg = $self->north_outer_map_boundary_svg;
    my $south_svg = $self->south_outer_map_boundary_svg;
    my $lat = 0 + $node->{-lat};
    my $lon = 0 + $node->{-lon};
    my ($svgx, $svgy) = $self->{converter}->lon_lat_deg_to_x_y_px($lon, $lat);
    my $xzone = ($svgx < $west_svg)  ? -1 : ($svgx > $east_svg)  ? 1 : 0;
    my $yzone = ($svgy < $north_svg) ? -1 : ($svgy > $south_svg) ? 1 : 0;
    my $result = [$svgx, $svgy, $xzone, $yzone];
    return $result;
}

use vars qw(%NS);

sub draw {
    my ($self) = @_;
    $self->twarn("Drawing into map ...\n");
    foreach my $map_area (@{$self->{_map_areas}}) {
        $self->update_scale($map_area);
        my $map_area_index = $map_area->{index};
        my $map_area_name = $map_area->{name};
        $self->twarn("  Drawing into map area $map_area_index - $map_area_name ...\n");
        foreach my $layer (@{$self->{osm_layers}}) {
            my $layer_name = $layer->{name};
            my $layer_group = $layer->{_map_area_group}[$map_area_index];
            my @objects = $layer->{objects}->objects;
            $self->twarn("    Adding %d objects to layer $layer_name ...\n", scalar @objects);
            foreach my $object (@objects) {
                my $css_class_string = $object->css_class_string(
                    layer => $layer,
                    map_area => $map_area,
                );
                my $css_id = $object->css_id(
                    layer => $layer,
                    map_area => $map_area,
                );
                my $attr = {};
                $attr->{'data-name'} = $object->{tags}->{name} if defined $object->{tags}->{name};

                # my $watch = $WATCH_OBJECT_ID && $WATCH_OBJECT_ID->{$object->{-id}};

                my $svg_element;
                if ($object->is_multipolygon_relation) {
                    my $path = $object->svg_object(map_area_index => $map_area_index);
                    next unless $path;
                    $svg_element = $self->svg_path(
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
                        path => $path,
                        class => $css_class_string,
                        attr => $attr,
                        id => $css_id,
                        map_area_index => $map_area_index,
                    );
                    # if ($watch) {
                    #     say "#<6>";
                    #     say Dumper $svg_element;
                    #     say "#</6>";
                    # }
                } elsif ($object->{type} eq 'way') {
                    my $polyline = $object->svg_object(map_area_index => $map_area_index);
                    next unless $polyline;
                    $svg_element = $self->svg_path(
                        polyline => $polyline,
                        class => $css_class_string,
                        attr => $attr,
                        id => $css_id,
                        map_area_index => $map_area_index,
                    );
                }
                if ($svg_element) {
                    $layer_group->appendChild($svg_element);
                    # if ($COUNT_CSS_CLASSES) {
                    #     my @css_classes = $object->css_classes(
                    #         layer => $layer,
                    #         map_area => $map_area,
                    #     );
                    #     foreach my $css_class (@css_classes) {
                    #         $self->{_css_class_count}->{$css_class} += 1;
                    #     }
                    # }
                }
            }
        }
    }
    $self->twarn("Done.\n");
    # if ($COUNT_CSS_CLASSES) {
    #     my $fh;
    #     if (open($fh, '>', 'css-classes.txt')) {
    #         foreach my $css_class (nsort keys %{$self->{_css_class_count}}) {
    #             printf $fh ("%8d %s\n", $self->{_css_class_count}->{$css_class},
    #                         Geo::MapMaker::OSM::Object->escape_css_class_name($css_class));
    #         }
    #     }
    # }
}

sub collect_map_tile_layer_objects {
    my ($self) = @_;
    my $count = 0;
    $self->twarn("Collecting objects for layers ...\n");
    foreach my $layer (@{$self->{osm_layers}}) {
        my @objects;
        push(@objects, $self->{_map_tile_nodes}->objects)     if $layer->{type}->{node};
        push(@objects, $self->{_map_tile_ways}->objects)      if $layer->{type}->{way};
        push(@objects, $self->{_map_tile_relations}->objects) if $layer->{type}->{relation};
        foreach my $object (@objects) {
            my $match = 0;
            foreach my $index (@{$layer->{index}}) {
                if ($object->{index}->{$index}) {
                    $match = 1;
                    last;
                }
            }
            next unless $match;

            $object->{used} = 1;
            # $object->{used_directly} = 1;

            $layer->{persistent_objects}->add($object);

            # objects used directly
            $layer->{objects}->add($object);

            # current objects, from which we pull any ways not found
            # in previously pulled relations
            $layer->{map_tile_objects}->add_override($object);

            $count += 1;
        }
    }
    if (grep { $_->{type}->{node} } @{$self->{osm_layers}}) {
        foreach my $node ($self->{_map_tile_nodes}->objects) {
            next if $node->{used};
            $self->count_unused_object_tags($node);
        }
    }
    if (grep { $_->{type}->{way} } @{$self->{osm_layers}}) {
        foreach my $way ($self->{_map_tile_ways}->objects) {
            next if $way->{used};
            $self->count_unused_object_tags($way);
        }
    }
    if (grep { $_->{type}->{relation} } @{$self->{osm_layers}}) {
        foreach my $relation ($self->{_map_tile_relations}->objects) {
            next if $relation->{used};
            $self->count_unused_object_tags($relation);
        }
    }
    $self->twarn("Done.  Added %d objects.\n", $count);
}

sub count_unused_object_tags {
    my ($self, $object) = @_;
    my $type = $object->{type};
  tag:
    foreach my $k (keys %{$object->{tags}}) {
        next if $EXCLUDE_TAG_NAMES->{$k};
        foreach my $exclude (@EXCLUDE_TAG_NAMES) {
            next tag if ref $exclude eq 'Regexp' && $k =~ $exclude;
        }
        my $v = $object->{tags}->{$k};
        next unless $TAG_NAME_WHITELIST->{$k} || $TAG_NAME_VALUE_WHITELIST->{"${k}=${v}"};
        $self->{_unused_object_tag_count}->{$type}->{$k} += 1;
        $self->{_unused_object_tag_value_count}->{$type}->{$k}->{$v} += 1;
    }
}

sub write_unused_object_tag_counts {
    my ($self) = @_;
    my $fh;
    my $filename = 'unused-object-tag-counts.txt';
    open($fh, '>', $filename) or return;
    $self->log_warn("    Writing $filename ...\n");
    my $hash = $self->{_unused_object_tag_count};
    foreach my $type (nsort keys %$hash) {
        my $subhash = $hash->{$type};
        foreach my $key (nsort keys %$subhash) {
            printf $fh ("%8d %-15s %s\n", $subhash->{$key}, $type, $key);
        }
    }
}

sub write_unused_object_tag_value_counts {
    my ($self) = @_;
    my $fh;
    my $filename = 'unused-object-tag-value-counts.txt';
    open($fh, '>', $filename) or return;
    $self->log_warn("    Writing $filename ...\n");
    my $hash = $self->{_unused_object_tag_value_count};
    foreach my $type (nsort keys %$hash) {
        my $subhash = $hash->{$type};
        foreach my $key (nsort keys %$subhash) {
            my $subsubhash = $subhash->{$key};
            foreach my $value (nsort keys %$subsubhash) {
                printf $fh ("%8d %-15s %-23s %s\n", $subsubhash->{$value}, $type, $key, $value);
            }
        }
    }
}

sub link_map_tile_objects {
    my ($self) = @_;
    $self->twarn("Linking objects ...\n");
    my $count = 0;
    foreach my $layer (@{$self->{osm_layers}}) {
        foreach my $relation (grep { $_->{type} eq 'relation' } $layer->{map_tile_objects}->objects) {
            my $id = $relation->{-id};
            my $relation = $self->find_persistent_object($layer, $relation);
            $self->link_relation_object($layer, $id, $relation);
            $count += 1;
        }
        foreach my $way (grep { $_->{type} eq 'way' } $layer->{map_tile_objects}->objects) {
            my $id = $way->{-id};
            my $way = $self->find_persistent_object($layer, $way);
            $self->link_way_object($layer, $id, $way);
            $count += 1;
            # if ($WATCH_OBJECT_ID) {
            #     if ($WATCH_OBJECT_ID->{$id}) {
            #         say "# <4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<4<";
            #         say Dumper $way;
            #         say "# >4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>4>";
            #     }
            # }
        }
    }
    $self->twarn("Done.  Linked %d objects.\n", $count);
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
    if ($layer->{persistent_objects}->has($id)) {
        return $layer->{persistent_objects}->get($id);
    }
    $layer->{persistent_objects}->add($object);
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

    my @way_ids       = map { $_->{-ref} } @{$map_tile_relation->{member}};
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
        if ($way && eval { $self->$WATCH_OBJECT_ID->{$id} }) {
            $self->log_warn("link_relation_object: relation id %s: way id %s: persistent object is %s\n",
                            $relation_id,
                            $id,
                            $way);
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
        # $way->{used} = 1;
        # $way->{used_indirectly} = 1;
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

    # foreach my $node (@{$way->{node_array}}) {
    #     $node->{used} = 1;
    #     $node->{used_indirectly} = 1;
    # }

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

sub tlog {
    my ($self, $level, $format, @args) = @_;
    return $self->log($level, $format, @args);
}

sub terror {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_ERROR, $format, @args);
}

sub twarn {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_WARN, $format, @args);
}

sub tinfo {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_INFO, $format, @args);
}

sub tdebug {
    my ($self, $format, @args) = @_;
    return $self->log(LOG_DEBUG, $format, @args);
}

1;
