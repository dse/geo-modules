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
              _map_tile_node_hash
              _map_tile_way_hash
              _map_tile_relation_hash
              _map_tile_node_array
              _map_tile_way_array
              _map_tile_relation_array
              _map_tile_number
              _map_tile_count);

use LWP::Simple;                # RC_NOT_MODIFIED
use List::MoreUtils qw(all uniq);
use Sort::Naturally;
use Geo::MapMaker::Dumper qw(Dumper);
use Geo::MapMaker::SVG::Point;
use Geo::MapMaker::SVG::PolyLine;
use Geo::MapMaker::SVG::Path;

use File::Slurper qw(read_text);
use Path::Tiny;
use Encode;

use XML::Fast;

use constant TEST_WITH_LIMITED_TILES => 1;
use constant TEST_WITH_LIMITED_LAYERS => 1;

sub update_openstreetmap {
    my ($self, $force) = @_;
    $self->{_osm_xml_filenames} = [];
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
            $self->_update_openstreetmap($force, $west_deg,   $south_deg,  $center_lon, $center_lat);
            $self->_update_openstreetmap($force, $center_lon, $south_deg,  $east_deg,   $center_lat);
            $self->_update_openstreetmap($force, $west_deg,   $center_lat, $center_lon, $north_deg);
            $self->_update_openstreetmap($force, $center_lon, $center_lat, $east_deg,   $north_deg);
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

sub force_update_openstreetmap {
    my ($self) = @_;
    $self->update_openstreetmap(1);
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

sub draw_openstreetmap_maps {
    my ($self) = @_;

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

    my $num_xml_files = scalar(@{$self->{_osm_xml_filenames}});

    if (TEST_WITH_LIMITED_LAYERS) {
        splice(@{$self->{osm_layers}}, 1);
    }

    foreach my $layer (@{$self->{osm_layers}}) {
        $layer->{type} //= { way => 1, relation => 1 };
        $layer->{index} = {};
        foreach my $tag (@{$layer->{tags}}) {
            my $k = $tag->{k};
            my $v = $tag->{v};
            if (defined $v) {
                $layer->{index}->{$k,$v} = 1;
            } else {
                $layer->{index}->{$k} = 1;
            }
        }
    }

    foreach my $layer (@{$self->{osm_layers}}) {
        # persistent objects
        $layer->{object_hash}  = {};
        $layer->{object_array} = [];

        $self->index_layer_tags($layer);
    }

    local $self->{_map_tile_number} = 0;
    local $self->{_map_tile_count} = scalar @{$self->{_osm_xml_filenames}};

    foreach my $filename (@{$self->{_osm_xml_filenames}}) {
        $self->{_map_tile_number} += 1;
        if ($ENV{PERFORMANCE}) {
            last if $self->{_map_tile_number} > 16;
        }

        if (TEST_WITH_LIMITED_TILES) {
            next unless grep { $self->{_map_tile_number} == $_ } (117, 118, 120, 153, 154, 155);
        }

        $self->twarn("Parsing %s ...\n", $filename);
        local $self->{_doc} = xml2hash(path($filename)->slurp(), array => 1);
        $self->twarn("done.\n");

        # all objects for each map tile
        local $self->{_map_tile_node_hash} = {};
        local $self->{_map_tile_way_hash} = {};
        local $self->{_map_tile_relation_hash} = {};
        local $self->{_map_tile_node_array} = [];
        local $self->{_map_tile_way_array} = [];
        local $self->{_map_tile_relation_array} = [];

        foreach my $layer (@{$self->{osm_layers}}) {
            # filtered objects for each map tile
            $layer->{map_tile_object_hash} = {};
            $layer->{map_tile_object_array} = [];
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

    $self->twarn("draw_openstreetmap_maps is done\n");
}

sub load_map_tile_objects {
    my $self = shift;
    $self->twarn("Loading map tile objects ...\n");
    my $nc = 0;
    my $wc = 0;
    my $rc = 0;
    my $order = 0;
    foreach my $node (@{$self->{_doc}->{osm}->[0]->{node}}) {
        my $id = $node->{-id};
        $self->{_map_tile_node_hash}->{$id} = $node;
        push(@{$self->{_map_tile_node_array}}, $node);
        $nc += 1;
        delete $node->{-changeset};
        delete $node->{-timestamp};
        delete $node->{-uid};
        delete $node->{-user};
        delete $node->{-version};
        delete $node->{-visible};
        $node->{type} = 'node';
        $node->{order} = ++$order;
    }
    $self->tdebug("  %d nodes\n", $nc);
    foreach my $way (@{$self->{_doc}->{osm}->[0]->{way}}) {
        my $id = $way->{-id};
        $self->{_map_tile_way_hash}->{$id} = $way;
        push(@{$self->{_map_tile_way_array}}, $way);
        $wc += 1;
        delete $way->{-changeset};
        delete $way->{-timestamp};
        delete $way->{-uid};
        delete $way->{-user};
        delete $way->{-version};
        delete $way->{-visible};
        $way->{type} = 'way';
        $way->{order} = ++$order;
    }
    $self->tdebug("  %d ways\n", $wc);
    foreach my $relation (@{$self->{_doc}->{osm}->[0]->{relation}}) {
        my $id = $relation->{-id};
        $self->{_map_tile_relation_hash}->{$id} = $relation;
        push(@{$self->{_map_tile_relation_array}}, $relation);
        $rc += 1;
        delete $relation->{-changeset};
        delete $relation->{-timestamp};
        delete $relation->{-uid};
        delete $relation->{-user};
        delete $relation->{-version};
        delete $relation->{-visible};
        $relation->{type} = 'relation';
        $relation->{order} = ++$order;
    }
    $self->tdebug("  %d relations\n", $rc);
    $self->twarn("Done.\n");
}

sub convert_map_tile_tags {
    my ($self) = @_;
    my $nodes     = $self->{_map_tile_node_array};
    my $ways      = $self->{_map_tile_way_array};
    my $relations = $self->{_map_tile_relation_array};
    my $count = (scalar @$nodes) + (scalar @$ways) + (scalar @$relations);
    $self->twarn("Converting tags on %d objects ...\n", $count);
    foreach my $node (@$nodes) {
        my $id = $node->{-id};
        $self->convert_object_tags($node);
    }
    foreach my $way (@$ways) {
        my $id = $way->{-id};
        $self->convert_object_tags($way);
    }
    foreach my $relation (@$relations) {
        my $id = $relation->{-id};
        $self->convert_object_tags($relation);
    }
    $self->twarn("Done.\n");
}

sub convert_object_tags {
    my ($self, $object) = @_;
    return if $object->{tags} || $object->{index};
    $object->{tags} = {};
    $object->{index} = {};
    foreach my $tag (@{$object->{tag}}) {
        my $k = $tag->{-k};
        my $v = $tag->{-v};
        $object->{tags}->{$k} = $v;
        $object->{index}->{$k} = 1; # incase of tags: { k: '...' } in a layer.
        if (defined $v && $v ne '') {
            $object->{index}->{$k,$v} = 1;
        }
    }
    delete $object->{tag};
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
            foreach my $relation (grep { $_->{type} eq 'relation' } @{$layer->{object_array}}) {
                foreach my $way (@{$relation->{way_array}}) {
                    foreach my $node (@{$way->{node_array}}) {
                        $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
                    }
                }
            }
            foreach my $way (grep { $_->{type} eq 'way' } @{$layer->{object_array}}) {
                foreach my $node (@{$way->{node_array}}) {
                    $node->{svg_coords}->[$map_area_index] ||= $self->convert_node_coordinates($node);
                }
            }
            foreach my $node (grep { $_->{type} eq 'node' } @{$layer->{object_array}}) {
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
            my @objects = @{$layer->{object_array}};
            $self->twarn("    Adding %d objects to layer $layer_name ...\n", scalar @objects);
            foreach my $object (@objects) {
                my $css_class = $layer->{class};
                my $css_id;
                my $attr = {};
                $attr->{'data-name'} = $object->{tags}->{name} if defined $object->{tags}->{name};
                my $is_multipolygon_relation = 0;
                if ($object->{type} eq 'relation') {
                    if ($object->{tags}->{type} eq 'multipolygon') {
                        $is_multipolygon_relation = 1;
                    }
                    my $css_id = $map_area->{id_prefix} . "w" . $object->{-id};
                    if ($is_multipolygon_relation) {
                        $css_class .= ' MPR';
                    } else {
                        $css_class .= ' AREA';
                    }
                } else {
                    my $css_id = $map_area->{id_prefix} . "r" . $object->{-id};
                    if ($object->{is_closed}) {
                        $css_class .= ' CLOSED';
                    } else {
                        $css_class .= ' OPEN';
                    }
                }

                my $svg_object;
                if ($is_multipolygon_relation || $object->{type} eq 'relation') {
                    my $path = $self->relation_to_svg_path($object, $map_area_index);
                    next unless $path;
                    $svg_object = $self->svg_path(
                        path => $path,
                        class => $css_class,
                        attr => $attr,
                        id => $css_id,
                        map_area_index => $map_area_index,
                    );
                } elsif ($object->{type} eq 'way') {
                    my $polyline = $self->way_to_svg_polyline($object, $map_area_index);
                    next unless $polyline;
                    $svg_object = $self->svg_path(
                        polyline => $polyline,
                        class => $css_class,
                        attr => $attr,
                        id => $css_id,
                        map_area_index => $map_area_index,
                    );
                }
                if ($svg_object) {
                    $layer_group->appendChild($svg_object);
                }
            }
        }
    }
    $self->twarn("Done.\n");
}

sub way_to_svg_polyline {
    my ($self, $way, $map_area_index) = @_;
    $self->log_warn("E1\n");
    my @svg_coords = grep { $_ } map { $_->{svg_coords}->[$map_area_index] } @{$way->{node_array}};
    $self->log_warn("E2\n");
    return unless scalar @svg_coords;
    $self->log_warn("E3\n");
    if (all { $_->[POINT_X_ZONE] == -1 } @svg_coords) { return; }
    if (all { $_->[POINT_X_ZONE] ==  1 } @svg_coords) { return; }
    if (all { $_->[POINT_Y_ZONE] == -1 } @svg_coords) { return; }
    if (all { $_->[POINT_Y_ZONE] ==  1 } @svg_coords) { return; }
    $self->log_warn("E4 %d\n", scalar @svg_coords);
    my $polyline = Geo::MapMaker::SVG::PolyLine->new(@svg_coords);
    $self->log_warn("E5\n");
    if ($way->{is_area}) {
        $polyline->is_closed(1);
    }
    $self->log_warn("E6\n");
    return $polyline;
}

sub relation_to_svg_path {
    my ($self, $relation, $map_area_index) = @_;
    my @outer_ways = @{$relation->{outer_way_array}};
    my @inner_ways = @{$relation->{inner_way_array}};
    my $is_multipolygon_relation = ($relation->{tags}->{type} eq 'multipolygon');
    foreach my $way (@outer_ways) {
        $way->{is_inner} = 0;
    }
    foreach my $way (@inner_ways) {
        $way->{is_inner} = 1;
    }
    my @polyline;
    foreach my $way (@outer_ways, @inner_ways) {
        my $polyline = $self->way_to_svg_polyline($way, $map_area_index);
        next unless $polyline;
        if ($is_multipolygon_relation) {
            $polyline->is_closed(1);
        }
        push(@polyline, $polyline);
    }
    my $path = Geo::MapMaker::SVG::Path->new(@polyline);
    return $path;
}

sub collect_map_tile_layer_objects {
    my ($self) = @_;
    my $count = 0;
    $self->twarn("Collecting objects for layers ...\n");
    foreach my $layer (@{$self->{osm_layers}}) {
        my @objects;
        push(@objects, @{$self->{_map_tile_node_array}})     if $layer->{type}->{node};
        push(@objects, @{$self->{_map_tile_way_array}})      if $layer->{type}->{way};
        push(@objects, @{$self->{_map_tile_relation_array}}) if $layer->{type}->{relation};
        foreach my $object (@objects) {
            my $match = 0;
            foreach my $index (@{$layer->{index}}) {
                if ($object->{index}->{$index}) {
                    $match = 1;
                    last;
                }
            }
            next unless $match;
            push(@{$layer->{object_array}}, $object)          unless $layer->{object_hash}->{$object->{-id}};;
            push(@{$layer->{map_tile_object_array}}, $object) unless $layer->{map_tile_object_hash}->{$object->{-id}};
            $layer->{object_hash}->{$object->{-id}} //= $object; # persistent
            $layer->{map_tile_object_hash}->{$object->{-id}} = $object;
            $count += 1;
        }
    }
    $self->twarn("Done.  Added %d objects.\n", $count);
}

sub link_map_tile_objects {
    my ($self) = @_;
    $self->twarn("Linking objects ...\n");
    my $count = 0;
    foreach my $layer (@{$self->{osm_layers}}) {
        foreach my $relation_id (map { $_->{-id} } grep { $_->{type} eq 'relation' } @{$layer->{map_tile_object_array}}) {
            $self->link_relation_object($layer, $relation_id);
            $count += 1;
        }
        foreach my $way_id (map { $_->{-id} } grep { $_->{type} eq 'way' } @{$layer->{map_tile_object_array}}) {
            $self->link_way_object($layer, $way_id);
            $count += 1;
        }
    }
    $self->twarn("Done.  Linked %d objects.\n", $count);
}

sub link_relation_object {
    my ($self, $layer, $relation_id) = @_;

    my $relation          = $layer->{object_hash}->{$relation_id}; # persistent
    my $map_tile_relation = $layer->{map_tile_object_hash}->{$relation_id}; # current, where we get way_ids

    # store ways in persistent objects
    $relation->{way_hash} //= {};
    $relation->{outer_way_hash} //= {};
    $relation->{inner_way_hash} //= {};
    $relation->{way_array} //= [];
    $relation->{outer_way_array} //= [];
    $relation->{inner_way_array} //= [];

    my @outer_way_ids = map { $_->{-ref} } grep { eval { $_->{-role} eq 'outer' && $_->{-type} eq 'way' && defined $_->{-ref} } } @{$map_tile_relation->{member}};
    my @inner_way_ids = map { $_->{-ref} } grep { eval { $_->{-role} eq 'inner' && $_->{-type} eq 'way' && defined $_->{-ref} } } @{$map_tile_relation->{member}};

    $relation->{contains_outer_way} //= {};
    $relation->{contains_inner_way} //= {};

    foreach my $way_id (@outer_way_ids) {
        $relation->{contains_outer_way}->{$way_id} = 1;
    }
    foreach my $way_id (@inner_way_ids) {
        $relation->{contains_inner_way}->{$way_id} = 1;
    }

    foreach my $way_id (@outer_way_ids) {
        my $way;
        my $existing_way = $relation->{way_hash}->{$way_id};
        if (defined $existing_way) {
            $way = $existing_way;
        } else {
            $way = $self->{_map_tile_way_hash}->{$way_id};
            if ($way) {
                $relation->{way_hash}->{$way_id} = $way;
                $relation->{outer_way_hash}->{$way_id} = $way;
                $self->link_way_object($layer, $way_id, $way);
            }
        }
        push(@{$relation->{way_array}}, $way);
        push(@{$relation->{outer_way_array}}, $way);
    }
    foreach my $way_id (@inner_way_ids) {
        my $way;
        my $existing_way = $relation->{way_hash}->{$way_id};
        if (defined $existing_way) {
            $way = $existing_way;
        } else {
            $way = $self->{_map_tile_way_hash}->{$way_id};
            if ($way) {
                $relation->{way_hash}->{$way_id} = $way;
                $relation->{inner_way_hash}->{$way_id} = $way;
                $self->link_way_object($layer, $way_id, $way);
            }
        }
        push(@{$relation->{way_array}}, $way);
        push(@{$relation->{inner_way_array}}, $way);
    }
}

sub link_way_object {
    my ($self, $layer, $way_id, $way) = @_;

    if (!$way) {
        $way = $layer->{object_hash}->{$way_id};
    }

    $way->{node_hash} //= {};
    $way->{node_array} //= [];

    my @node_ids = map { $_->{-ref} } @{$way->{nd}};
    $way->{node_ids} = \@node_ids;

    foreach my $node_id (@node_ids) {
        my $node = $self->{_map_tile_node_hash}->{$node_id};
        if (!$node) {
            next;
        }

        my $existing_node = $way->{node_hash}->{$node_id};
        if (defined $existing_node) {
            $node = $existing_node;
        } else {
            $way->{node_hash}->{$node_id} = $node;
        }
        push(@{$way->{node_array}}, $node);
    }

    if (scalar @node_ids > 1 && $node_ids[0] eq $node_ids[-1]) {
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
}

use vars qw($prefix2);

sub tlog {
    my ($self, $level, $format, @args) = @_;
    local $prefix2;
    my $number = $self->{_map_tile_number};
    my $count = $self->{_map_tile_count};
    if (defined $number && defined $count) {
        $prefix2 = sprintf("(%d/%d) ", $number, $count);
    } else {
        $prefix2 = "";
    }
    return $self->log($level, $format, @args);
}

sub terror {
    my ($self, $format, @args) = @_;
    return $self->tlog(LOG_ERROR, $format, @args);
}

sub twarn {
    my ($self, $format, @args) = @_;
    return $self->tlog(LOG_WARN, $format, @args);
}

sub tinfo {
    my ($self, $format, @args) = @_;
    return $self->tlog(LOG_INFO, $format, @args);
}

sub tdebug {
    my ($self, $format, @args) = @_;
    return $self->tlog(LOG_DEBUG, $format, @args);
}

1;
