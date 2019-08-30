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

              _seek_object_id
              _seek_map_tile_number

              _doc

              _map_tile_nodes_by_id
              _map_tile_relations_by_id
              _map_tile_ways_by_id

              _map_tile_node_elements
              _map_node_id_exists

              _relation_data
              _map_tile_relation_elements

              _map_relation_id_exists
              _map_relations_by_id
              _map_ways_by_id
              _map_nodes_by_id

              _map_relation_elements

              _map_tile_number
              _map_tile_count

              _map_tile_way_elements
              _map_way_id_exists);

use LWP::Simple;                # RC_NOT_MODIFIED
use List::MoreUtils qw(all uniq);
use Sort::Naturally;
use Geo::MapMaker::Dumper qw(Dumper);

use File::Slurper qw(read_text);
use Path::Tiny;
use Encode;

use XML::Fast;

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
        CORE::warn("Not updating $xml_filename\n    $url\n") if $self->{verbose};
        push(@{$self->{_osm_xml_filenames}}, $xml_filename);
    } elsif (-e $xml_filename && $force && -M $xml_filename < 1) {
        CORE::warn("Not updating $xml_filename\n    $url\n    (force in effect but less than 1 day old)\n") if $self->{verbose};
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
            CORE::warn("Waiting 30 seconds...\n");
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
                my $layer = $self->update_or_create_layer(name => $osm_layer_info->{name},
                                                          parent => $osm_layer,
                                                          class => $osm_layer_info->{class},
                                                          style => $osm_layer_info->{style},
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

    local $self->{_map_node_id_exists}     = {};
    local $self->{_map_relation_id_exists} = {};
    local $self->{_map_way_id_exists}      = {};

    foreach my $layer (@{$self->{osm_layers}}) {
        $layer->{type} //= { way => 1 };
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

    # local $self->{_seek_map_tile_number} = [117, 118, 120, 153, 154, 155];
    # local $self->{_seek_object_id} = '3962892';

    local $self->{_map_tile_node_elements};
    local $self->{_map_tile_relation_elements};
    local $self->{_map_tile_way_elements};
    local $self->{_map_tile_nodes_by_id};
    local $self->{_map_tile_relations_by_id};
    local $self->{_map_tile_ways_by_id};
    local $self->{_map_tile_count} = scalar @{$self->{_osm_xml_filenames}};
    local $self->{_map_tile_number} = 0;

    local $self->{_map_relation_elements} = [];
    local $self->{_map_relations_by_id} = {};
    local $self->{_map_ways_by_id} = {};
    local $self->{_map_nodes_by_id} = {};

    foreach my $layer (@{$self->{osm_layers}}) {
        $layer->{map_objects} = [];
    }

    foreach my $filename (@{$self->{_osm_xml_filenames}}) {
        $self->{_map_tile_number} += 1;
        if ($ENV{PERFORMANCE}) {
            last if $self->{_map_tile_number} >= 16;
        }

        if ($self->{_seek_map_tile_number}) {
            if (ref $self->{_seek_map_tile_number} eq 'ARRAY') {
                next unless grep { $_ == $self->{_map_tile_number} } @{$self->{_seek_map_tile_number}};
            } else {
                next unless $self->{_map_tile_number} == $self->{_seek_map_tile_number};
            }
        }

        $self->{_map_tile_node_elements}     = [];
        $self->{_map_tile_relation_elements} = [];
        $self->{_map_tile_way_elements}      = [];
        $self->{_map_tile_nodes_by_id}       = {};
        $self->{_map_tile_relations_by_id}   = {};
        $self->{_map_tile_ways_by_id}        = {};

        $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Parsing $filename ...\n");

        local $self->{_doc} = xml2hash(path($filename)->slurp(), array => 1);

        $self->diag("done.\n");

        foreach my $layer (@{$self->{osm_layers}}) {
            $layer->{map_tile_objects} = [];
        }

        $self->set_elements();
        $self->convert_tags();
        $self->convert_node_coordinates();
        $self->collect_relations_for_later();
        $self->remove_duplicate_objects();
        $self->collect_objects_into_layers();
        if (!$self->{no_edit}) {
            $self->draw_map_tile_objects();
        }
    }
    if (!$self->{no_edit}) {
        $self->draw_map_objects();
    }
}

sub index_tags {
    my ($self, $object) = @_;
    $object->{tags} = {};
    $object->{index} = {};
    foreach my $tag (@{$object->{tag}}) {
        my $k = $tag->{-k};
        next if index($k, ':') > -1;
        next if $k eq 'name';
        next if $k eq 'ref';
        next if $k eq 'phone';
        next if $k eq 'website';
        next if $k eq 'opening_hours';
        next if $k eq 'brand';
        next if $k eq 'description';
        next if $k eq 'wikidata';
        my $v = $tag->{-v};
        $object->{tags}->{$k} = $v;
        if (defined $v) {
            $object->{index}->{$k,$v} = 1;
        } else {
            $object->{index}->{$k} = 1;
        }
    }
}

sub index_match {
    my $self = shift;
    my $a = shift;
    my $b = shift;
    foreach my $k (keys %$a) {
        if ($b->{$k}) {
            return 1;
        }
    }
    return 0;
}

sub set_elements {
    my $self = shift;
    $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Running set_elements ...\n");

    my $node_elements = $self->{_map_tile_node_elements};
    @$node_elements = @{$self->{_doc}->{osm}->[0]->{node}};
    my $relation_elements = $self->{_map_tile_relation_elements};
    @$relation_elements = @{$self->{_doc}->{osm}->[0]->{relation}};
    my $way_elements = $self->{_map_tile_way_elements};
    @$way_elements = @{$self->{_doc}->{osm}->[0]->{way}};

    if ($self->{verbose} >= 2) {
        $self->diag(sprintf("  Found %d nodes.\n", scalar @$node_elements));
        $self->diag(sprintf("  Found %d relations.\n", scalar @$relation_elements));
        $self->diag(sprintf("  Found %d ways.\n", scalar @$way_elements));
    }

    if ($self->{_seek_object_id}) {
        my ($node)     = grep { $_->{-id} eq $self->{_seek_object_id} } @$node_elements;
        my ($relation) = grep { $_->{-id} eq $self->{_seek_object_id} } @$relation_elements;
        my ($way)      = grep { $_->{-id} eq $self->{_seek_object_id} } @$way_elements;
        if ($node) {
            @$node_elements = ($node);
            @$way_elements = ();
            @$relation_elements = ();
            $self->diag("  Tile number $self->{_map_tile_number} contains object id $self->{_seek_object_id}\n");
        } elsif ($way) {
            # @$node_elements = ();
            @$way_elements = ($way);
            @$relation_elements = ();
            $self->diag("  Tile number $self->{_map_tile_number} contains object id $self->{_seek_object_id}\n");
        } elsif ($relation) {
            # @$node_elements = ();
            # @$way_elements = ();
            @$relation_elements = ($relation);
            $self->diag("  Tile number $self->{_map_tile_number} contains object id $self->{_seek_object_id}\n");
        } else {
            @$node_elements = ();
            @$relation_elements = ();
            @$way_elements = ();
        }
    }

    $self->diag("Done.\n");
}

# Collect *all* <node>s' coordinates.  Even if a <node> is not
# used directly, it could be used by a <way>.
sub convert_node_coordinates {
    my $self = shift;
    my $node_elements = $self->{_map_tile_node_elements};
    my $converter = $self->{converter};
    my $count = scalar @$node_elements;
    $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Converting coordinates for $count nodes ...\n");
    foreach my $node_element (@$node_elements) {
        $node_element->{svg_coords} = [];
    }
    foreach my $map_area (@{$self->{_map_areas}}) {
        $self->update_scale($map_area);
        my $index = $map_area->{index};
        my $area_name = $map_area->{name};
        my $west_svg  = $self->west_outer_map_boundary_svg;
        my $east_svg  = $self->east_outer_map_boundary_svg;
        my $north_svg = $self->north_outer_map_boundary_svg;
        my $south_svg = $self->south_outer_map_boundary_svg;
        foreach my $node_element (@$node_elements) {
            my $node_id = $node_element->{-id};
            my $lat_deg = 0 + $node_element->{-lat};
            my $lon_deg = 0 + $node_element->{-lon};
            my ($svgx, $svgy) = $converter->lon_lat_deg_to_x_y_px($lon_deg, $lat_deg);
            my $xzone = ($svgx < $west_svg)  ? -1 : ($svgx > $east_svg)  ? 1 : 0;
            my $yzone = ($svgy < $north_svg) ? -1 : ($svgy > $south_svg) ? 1 : 0;
            my $result = [$svgx, $svgy, $xzone, $yzone];
            $node_element->{svg_coords}->[$index] = $result;
        }
    }
    $self->diag("Done.\n");
}

sub draw_map_tile_objects {
    my $self = shift;
    foreach my $map_area (@{$self->{_map_areas}}) {
        $self->draw_map_tile_map_area($map_area);
    }
}

sub draw_map_objects {
    my $self = shift;
    foreach my $map_area (@{$self->{_map_areas}}) {
        $self->draw_map_area($map_area);
    }
}

sub draw_map_tile_map_area {
    my $self = shift;
    my $map_area = shift;

    my $map_area_index = $map_area->{index};
    my $map_area_name = $map_area->{name};

    $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Drawing into map area [$map_area_name] ...\n");

    $self->update_scale($map_area);

    foreach my $layer (@{$self->{osm_layers}}) {
        next unless $layer->{map_tile_objects};

        my $layer_name = $layer->{name};
        my $layer_group = $layer->{_map_area_group}[$map_area_index];

        my $count = scalar @{$layer->{map_tile_objects}};

        if ($count && $self->{verbose} >= 2) {
            $self->diag("  This map tile will add no more than $count objects to layer '$layer_name' now...\n");
        }

        my $count_added = 0;

        foreach my $object (@{$layer->{map_tile_objects}}) {
            my $css_class = $layer->{class};

            my $attr = {};
            $attr->{'data-name'} = $object->{tags}->{name} if defined $object->{tags}->{name};

            my @svg_coords;
            if ($object->{type} eq 'way') {
                if (!$object->{node_elements}) {
                    $object->{node_elements} = [ map { $self->{_map_tile_nodes_by_id}->{$_} } map { $_->{-ref} } @{$object->{nd}} ];
                }
                @svg_coords = map { $_->{svg_coords}->[$map_area_index] } @{$object->{node_elements}};
            } elsif ($object->{type} eq 'node') {
                # not yet supported here
                next;
            } elsif ($object->{type} eq 'relation') {
                # not supported here
                next;
            }

            if (all { $_->[POINT_X_ZONE] == -1 } @svg_coords) { next; }
            if (all { $_->[POINT_X_ZONE] ==  1 } @svg_coords) { next; }
            if (all { $_->[POINT_Y_ZONE] == -1 } @svg_coords) { next; }
            if (all { $_->[POINT_Y_ZONE] ==  1 } @svg_coords) { next; }

            if ($object->{type} eq 'way') {
                my $is_closed = scalar @{$object->{node_elements}} >= 3 && $object->{node_elements}->[0] eq $object->{node_elements}->[-1];
                my $css_id = $map_area->{id_prefix} . "w" . $object->{-id};
                my $svg_object;
                if ($is_closed) {
                    $svg_object = $self->polygon(points => \@svg_coords,
                                                 class => $css_class,
                                                 attr => $attr,
                                                 id => $css_id);
                } else {
                    $svg_object = $self->polyline(points => \@svg_coords,
                                                  class => $css_class . ' OPEN',
                                                  attr => $attr,
                                                  id => $css_id);
                }
                $layer_group->appendChild($svg_object);
                $count_added += 1;
            } elsif ($object->{type} eq 'node') {
                # not yet supported
            } elsif ($object->{type} eq 'relation') {
                # not yet supported
            }
        }
        if ($count_added && $self->{verbose} >= 2) {
            $self->diag("  $count_added objects added.\n");
        }
    }
    $self->diag("Done.\n");
}

sub draw_map_area {
    my $self = shift;
    my $map_area = shift;

    my $map_area_index = $map_area->{index};
    my $map_area_name = $map_area->{name};

    $self->diag("Drawing global objects into map area [$map_area_name] ...\n");

    foreach my $layer (@{$self->{osm_layers}}) {
        my $layer_name = $layer->{name};
        my $layer_group = $layer->{_map_area_group}[$map_area_index];
        my $count = scalar @{$layer->{map_objects}};
      object:
        foreach my $object (@{$layer->{map_objects}}) {
            my $css_class = $layer->{class};
            my $attr = {};
            $attr->{'data-name'} = $object->{tags}->{name} if defined $object->{tags}->{name};
            if ($object->{type} eq 'relation') {
                my @way_ids = @{$object->{way_ids}};
                my @way_ids_not_found = grep { !$object->{ways_by_id}->{$_} } @way_ids;
                if (scalar @way_ids_not_found) {
                    warn("oh crap, $object->{-type} $object->{-id} way ids not found: @way_ids_not_found\n");
                    next object;
                }
                my @ways = map { $object->{ways_by_id}->{$_} } @way_ids;
                foreach my $way (@ways) {
                    my @node_ids = @{$way->{node_ids}};
                    my @node_ids_not_found = grep { !$object->{nodes_by_id}->{$_} } @node_ids;
                    if (scalar @node_ids_not_found) {
                        warn("oh crap, $object->{-type} $object->{-id} way $way->{-id} node ids not found: @node_ids_not_found\n");
                        next object;
                    }
                }
                my @outer_way_ids = @{$object->{outer_way_ids}};
                my @inner_way_ids = @{$object->{inner_way_ids}};
                my @outer_ways = map { $object->{ways_by_id}->{$_} } @outer_way_ids;
                my @inner_ways = map { $object->{ways_by_id}->{$_} } @inner_way_ids;
                my @node_ids = map { @{$_->{node_ids}} } @outer_ways;
                my @nodes = map { $object->{nodes_by_id}->{$_} } @node_ids;
                my @svg_coords = map { $_->{svg_coords}->[$map_area_index] } @nodes;

                if (all { $_->[POINT_X_ZONE] == -1 } @svg_coords) { next; }
                if (all { $_->[POINT_X_ZONE] ==  1 } @svg_coords) { next; }
                if (all { $_->[POINT_Y_ZONE] == -1 } @svg_coords) { next; }
                if (all { $_->[POINT_Y_ZONE] ==  1 } @svg_coords) { next; }

                my $css_id = $map_area->{id_prefix} . "w" . $object->{-id};
                my $svg_object = $self->polygon(
                    points => \@svg_coords,
                    class => $css_class,
                    attr => $attr,
                    id => $css_id
                );
                $layer_group->appendChild($svg_object);
            } elsif ($object->{type} eq 'way') {
                # not supported here
                next;
            } elsif ($object->{type} eq 'node') {
                # not supported here
                next;
            }
        }
    }

    $self->diag("Done.\n");
}

our $IS_IDENTIFYING_TAG;
BEGIN {
    $IS_IDENTIFYING_TAG = {
        name => 1,
        ref => 1,
        phone => 1,
        website => 1,
        opening_hours => 1,
        brand => 1,
        description => 1,
        wikidata => 1,
    };
}

sub is_identifying_tag {
    my $self = shift;
    my $tag = shift;
    return if $IS_IDENTIFYING_TAG->{$tag};
}

sub object_matches_layer {
    my ($self, $object, $layer) = @_;
    return 0 unless $layer->{type}->{$object->{type}};
    return $self->index_match($object->{index}, $layer->{index});
}

sub convert_tags {
    my $self = shift;

    my $nc = scalar @{$self->{_map_tile_node_elements}};
    my $rc = scalar @{$self->{_map_tile_relation_elements}};
    my $wc = scalar @{$self->{_map_tile_way_elements}};
    my $oc = $nc + $rc + $wc;

    if ($oc) {
        $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Converting tags for $oc objects ...\n");
    }

    if ($nc && $self->{verbose} >= 2) {
        $self->diag("  Converting tags for for $nc nodes ...\n");
    }
    foreach my $node (@{$self->{_map_tile_node_elements}}) {
        my $id = $node->{-id};
        $self->{_map_tile_nodes_by_id}->{$id} = $node;
        $self->index_tags($node);
        $node->{type} = 'node';
    }
    if (grep { $_->{relation} } map { $_->{type} } @{$self->{osm_layers}}) {
        if ($rc && $self->{verbose} >= 2) {
            $self->diag("  Converting tags for $rc relations ...\n");
        }
        foreach my $relation (@{$self->{_map_tile_relation_elements}}) {
            my $id = $relation->{-id};
            $self->{_map_tile_relations_by_id}->{$id} = $relation;
            $self->index_tags($relation);
            $relation->{type} = 'relation';
        }
    }
    if (grep { $_->{way} } map { $_->{type} } @{$self->{osm_layers}}) {
        if ($wc && $self->{verbose} >= 2) {
            $self->diag("  Converting tags for $wc ways ...\n");
        }
        foreach my $way (@{$self->{_map_tile_way_elements}}) {
            my $id = $way->{-id};
            $self->{_map_tile_ways_by_id}->{$id} = $way;
            $self->index_tags($way);
            $way->{type} = 'way';
        }
    }
    $self->diag("Done.\n");
}

sub remove_duplicate_objects {
    my $self = shift;

    $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Removing duplicate objects ...\n");

    my $node_id_exists = $self->{_map_node_id_exists};
    my $relation_id_exists = $self->{_map_relation_id_exists};
    my $way_id_exists = $self->{_map_way_id_exists};

    foreach my $node (@{$self->{_map_tile_node_elements}}) {
        my $node_id = $node->{-id};
        if ($node_id_exists->{$node_id}) {
            $node->{is_duplicated} = 1;
            next;
        }
        $node_id_exists->{$node_id} = 1;
    }

    # We do not want to remove duplicate relation objects AT THIS
    # TIME.  Not every map tile containing a relation will have all
    # the ways and all the nodes required to render it.

    if (grep { $_->{way} } map { $_->{type} } @{$self->{osm_layers}}) {
        foreach my $way (@{$self->{_map_tile_way_elements}}) {
            my $way_id = $way->{-id};
            if ($way_id_exists->{$way_id}) {
                $way->{is_duplicated} = 1;
                next;
            }
            $way_id_exists->{$way_id} = 1;
        }
    }

    my $nc = scalar @{$self->{_map_tile_node_elements}};
    my $wc = scalar @{$self->{_map_tile_way_elements}};

    @{$self->{_map_tile_node_elements}}     = grep { !$_->{is_duplicated} } @{$self->{_map_tile_node_elements}};
    @{$self->{_map_tile_way_elements}}      = grep { !$_->{is_duplicated} } @{$self->{_map_tile_way_elements}};

    my $nc2 = scalar @{$self->{_map_tile_node_elements}};
    my $wc2 = scalar @{$self->{_map_tile_way_elements}};

    if ($self->{verbose} >= 2) {
        if ($nc) {
            $self->diag(sprintf("  Nodes     before: %-6d => after: %-6d\n", $nc, $nc2));
        }
        if ($wc) {
            $self->diag(sprintf("  Ways      before: %-6d => after: %-6d\n", $wc, $wc2));
        }
    }

    $self->diag("Done.\n");
}

sub collect_relations_for_later {
    my $self = shift;

    $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Collecting relations into layers ...\n");

    my $rc = scalar @{$self->{_map_tile_relation_elements}};

    my $count = 0;

    foreach my $layer (@{$self->{osm_layers}}) {
        if ($layer->{type}->{relation}) {
            foreach my $object (@{$self->{_map_tile_relation_elements}}) {
                next unless $self->index_match($layer->{index}, $object->{index});
                my ($existing_object) = grep { $_->{-id} eq $object->{-id} } @{$layer->{map_objects}};
                if ($existing_object) {
                    $object = $existing_object;
                } else {
                    push(@{$layer->{map_objects}}, $object);
                    $count += 1;

                    my @outer_way_ids = map { $_->{-ref} } grep { eval { $_->{-role} eq 'outer' && $_->{-type} eq 'way' && defined $_->{-ref} } } @{$object->{member}};
                    my @inner_way_ids = map { $_->{-ref} } grep { eval { $_->{-role} eq 'inner' && $_->{-type} eq 'way' && defined $_->{-ref} } } @{$object->{member}};
                    my @way_ids = (@outer_way_ids, @inner_way_ids);

                    $object->{way_ids}       = \@way_ids;
                    $object->{outer_way_ids} = \@outer_way_ids;
                    $object->{inner_way_ids} = \@inner_way_ids;
                    $object->{way_id_found}  = {};
                    $object->{node_id_found} = {};
                    $object->{ways_by_id}    = {};
                }
                foreach my $way_id (@{$object->{way_ids}}) {
                    my ($way) = grep { $_->{-id} eq $way_id } @{$self->{_map_tile_way_elements}};
                    if ($way) {
                        $object->{way_id_found}->{$way_id} = 1;
                        $object->{ways_by_id}->{$way_id} //= $way;
                        my @node_ids = map { $_->{-ref} } @{$way->{nd}};
                        $way->{node_ids} = \@node_ids;
                        foreach my $node_id (@node_ids) {
                            my ($node) = grep { $_->{-id} eq $node_id } @{$self->{_map_tile_node_elements}};
                            if ($node) {
                                $object->{node_id_found}->{$node_id} = 1;
                                $object->{nodes_by_id}->{$node_id} //= $node;
                            }
                        }
                    }
                }
            }
        }
        my $layer_name = $layer->{name};
        if ($count && $self->{verbose} >= 2) {
            $self->diag("  This map tile will add no more than $count of $rc relation objects to layer '$layer_name' later...\n");
        }
    }

    $self->diag("Done.\n");
}

sub collect_objects_into_layers {
    my $self = shift;

    $self->diag("($self->{_map_tile_number}/$self->{_map_tile_count}) Collecting objects into layers ...\n");

    my $nc = scalar @{$self->{_map_tile_node_elements}};
    my $wc = scalar @{$self->{_map_tile_way_elements}};
    my $oc = $nc + $wc;

    foreach my $layer (@{$self->{osm_layers}}) {
        if ($layer->{type}->{node}) {
            foreach my $object (@{$self->{_map_tile_node_elements}}) {
                next unless $self->index_match($layer->{index}, $object->{index});
                push(@{$layer->{map_tile_objects}}, $object);
            }
        }
        if ($layer->{type}->{way}) {
            foreach my $object (@{$self->{_map_tile_way_elements}}) {
                next unless $self->index_match($layer->{index}, $object->{index});
                push(@{$layer->{map_tile_objects}}, $object);
            }
        }
        my $layer_name = $layer->{name};
        if ($layer->{map_tile_objects}) {
            my $count = scalar @{$layer->{map_tile_objects}};
            if ($count && $self->{verbose} >= 2) {
                $self->diag("  This map tile will add no more than $count of $oc objects to layer '$layer_name' later...\n");
            }
        }
    }

    $self->diag("Done.\n");
}

1;
