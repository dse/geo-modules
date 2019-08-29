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

              _nodeid_exists
              _wayid_exists
              _node_use_k
              _node_use_kv
              _way_use_k
              _way_use_kv
              _node_elements
              _way_elements
              _used_way_elements
              _nodeid_is_dup
              _wayid_is_dup
              _node_data
              _way_data
              _node_k
              _node_kv
              _way_k
              _way_kv

              _bridge_wayid

              _count_used_node_tag_k
              _count_used_node_tag_kv
              _count_used_way_tag_k
              _count_used_way_tag_kv
              _count_unused_node_tag_k
              _count_unused_node_tag_kv
              _count_unused_way_tag_k
              _count_unused_way_tag_kv

              _deferreds
);

use LWP::Simple;                # RC_NOT_MODIFIED
use List::MoreUtils qw(all uniq);
use Sort::Naturally;
use Data::Dumper qw(Dumper);

use File::Slurper qw(read_text);
use Path::Tiny;
use Encode;

use constant USE_XML_FAST => 1;
use constant USE_XML_BARE => 0;

BEGIN {
    if (USE_XML_FAST) {
        require XML::Fast;
        import XML::Fast qw();
    }
    if (USE_XML_BARE) {
        require XML::Bare;
        import XML::Bare qw();
    }
}


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
                                                      class => $info->{class},
                                                      style => $info->{style},
                                                      insensitive => 1,
                                                      autogenerated => 1,
                                                      children_autogenerated => 1);
            my $group = $self->find_or_create_clipped_group(parent => $layer,
                                                            class => $info->{group_class},
                                                            style => $info->{group_style},
                                                            clip_path_id => $clip_path_id);
            $group->removeChildNodes(); # OK
            $info->{_map_area_layer} //= [];
            $info->{_map_area_group} //= [];
            push(@{$info->{_map_area_layer}}, $layer);
            push(@{$info->{_map_area_group}}, $group);
        }
    }

    my $num_xml_files = scalar(@{$self->{_osm_xml_filenames}});

    # dispaly counter through XML files
    my $xml_file_number = 0;

    local $self->{_nodeid_exists}            = my $nodeid_exists = {};
    local $self->{_wayid_exists}             = my $wayid_exists  = {};
    local $self->{_way_use_k}                = my $way_use_k   = {};
    local $self->{_way_use_kv}               = my $way_use_kv  = {};
    local $self->{_node_use_k}               = my $node_use_k  = {};
    local $self->{_node_use_kv}              = my $node_use_kv = {};
    local $self->{_count_used_node_tag_k}    = my $count_used_node_tag_k    = {};
    local $self->{_count_used_node_tag_kv}   = my $count_used_node_tag_kv   = {};
    local $self->{_count_used_way_tag_k}     = my $count_used_way_tag_k     = {};
    local $self->{_count_used_way_tag_kv}    = my $count_used_way_tag_kv    = {};
    local $self->{_count_unused_node_tag_k}  = my $count_unused_node_tag_k  = {};
    local $self->{_count_unused_node_tag_kv} = my $count_unused_node_tag_kv = {};
    local $self->{_count_unused_way_tag_k}   = my $count_unused_way_tag_k   = {};
    local $self->{_count_unused_way_tag_kv}  = my $count_unused_way_tag_kv  = {};
    local $self->{_bridge_wayid}             = my $bridge_wayid = {};
    local $self->{_deferreds}                = my $deferreds = [];

    $self->collect_k_v_flags();

    foreach my $filename (@{$self->{_osm_xml_filenames}}) {
        $xml_file_number += 1;

        if ($ENV{PERFORMANCE}) {
            exit 0 if $xml_file_number >= 16;
        }

        $self->diag("($xml_file_number/$num_xml_files) Parsing $filename ... ");

        local $self->{_doc};

        my $doc;
        my $bareObject;
        my $bareTree;
        my $docHash;
        if (USE_XML_FAST) {
            my $xml = path($filename)->slurp();
            $self->{_doc} = $docHash = xml2hash($xml, array => 1);
        } elsif (USE_XML_BARE) {
            $bareObject = XML::Bare->new(file => $filename);
            $self->{_doc} = $bareTree = $bareObject->parse();
        } else {
            $self->{_doc} = $doc = $self->{_parser}->parse_file($filename);
        }

        $self->diag("done.\n");

        # data for each <node> element
        local $self->{_node_data} = my $node_data = {};

        # data for each <way> element
        local $self->{_way_data} = my $way_data = {};

        # list nodes/ways by key, key/value
        local $self->{_node_k} = my $node_k = {};
        local $self->{_node_kv} = my $node_kv = {};
        local $self->{_way_k} = my $way_k = {};
        local $self->{_way_kv} = my $way_kv = {};

        # lists of <node> and <way> ids to exclude for this XML file
        # due to being duplicated from earlier XML files
        local $self->{_nodeid_is_dup} = my $this_xml_nodeid_is_dup = {};
        local $self->{_wayid_is_dup}  = my $this_xml_wayid_is_dup = {};

        local $self->{_node_elements}           = my $node_elements = [];

        my $converter = $self->{converter};

        $self->set_node_elements();
        $self->collect_node_coordinates();
        $self->collect_nodes();

        local $self->{_way_elements}     = my $way_elements = [];
        local $self->{_used_way_elements} = my $used_way_elements = [];

        $self->set_way_elements();
        $self->collect_ways();

        $self->diag("done.\n");

        if (!$ENV{COUNT_UNUSED_ONLY}) {
            $self->collect_way_coordinates();
            $self->draw();
        }
    }

    $self->draw_deferred();

    $self->write_objects_not_included();
}

sub write_objects_not_included {
    my ($self) = @_;

    my $count_unused_node_tag_k = $self->{_count_unused_node_tag_k};
    my $count_unused_node_tag_kv = $self->{_count_unused_node_tag_kv};
    my $count_unused_way_tag_k = $self->{_count_unused_way_tag_k};
    my $count_unused_way_tag_kv = $self->{_count_unused_way_tag_kv};

    my $filename = $self->{osm_objects_not_included_filename};
    if (!defined $filename) {
        return;
    }
    if (!scalar keys %$count_unused_node_tag_k &&
            !scalar keys %$count_unused_node_tag_kv &&
            !scalar keys %$count_unused_way_tag_k &&
            !scalar keys %$count_unused_way_tag_kv) {
        if (!unlink($filename)) {
            CORE::warn("cannot unlink $filename: $!\n");
        }
        return;
    }
    my $fh;
    if (!open($fh, '>', $filename)) {
        CORE::warn("cannot write $filename: $!\n");
        return;
    }

    foreach my $key (nsort keys %$count_unused_node_tag_k) {
        my $count = $count_unused_node_tag_k->{$key};
        my $tagkey = $key;
        $tagkey //= '(undef)';
        printf $fh ("%8s NODE %-32s\n", $count, $tagkey);
    }
    foreach my $key (nsort keys %$count_unused_node_tag_kv) {
        my $count = $count_unused_node_tag_kv->{$key};
        my ($tagkey, $tagvalue) = split($;, $key);
        $tagkey //= '(undef)';
        $tagvalue //= '(undef)';
        printf $fh ("%8d NODE %-32s = %-32s\n", $count, $tagkey, $tagvalue);
    }
    foreach my $key (nsort keys %$count_unused_way_tag_k) {
        my $count = $count_unused_way_tag_k->{$key};
        my $tagkey = $key;
        $tagkey //= '(undef)';
        printf $fh ("%8d WAY  %-32s\n", $count, $tagkey);
    }
    foreach my $key (nsort keys %$count_unused_way_tag_kv) {
        my $count = $count_unused_way_tag_kv->{$key};
        my ($tagkey, $tagvalue) = split($;, $key);
        $tagkey //= '(undef)';
        $tagvalue //= '(undef)';
        printf $fh ("%8d WAY  %-32s = %-32s\n", $count, $tagkey, $tagvalue);
    }

    close($fh);
    CORE::warn("Wrote $filename\n");
}

sub collect_k_v_flags {
    my $self = shift;
    my $node_use_k  = $self->{_node_use_k};
    my $node_use_kv = $self->{_node_use_kv};
    my $way_use_k   = $self->{_way_use_k};
    my $way_use_kv  = $self->{_way_use_kv};
    foreach my $info (@{$self->{osm_layers}}) {
        my $tags = $info->{tags};
        my $type = $info->{type} // "way"; # 'way' or 'node'
        foreach my $tag (@$tags) {
            my ($k, $v) = @{$tag}{qw(k v)};
            if (defined $k) {
                if ($type eq 'way') {
                    if (defined $v) {
                        $way_use_kv->{$k,$v} = 1;
                    } else {
                        $way_use_k->{$k} = 1;
                    }
                } elsif ($type eq 'node') {
                    if (defined $v) {
                        $node_use_kv->{$k,$v} = 1;
                    } else {
                        $node_use_k->{$k} = 1;
                    }
                }
            }
        }
    }
}

sub collect_nodes {
    my $self = shift;

    my $node_elements = $self->{_node_elements};
    my $nodeid_exists = $self->{_nodeid_exists};
    my $this_xml_nodeid_is_dup = $self->{_nodeid_is_dup};
    my $node_use_k = $self->{_node_use_k};
    my $node_use_kv = $self->{_node_use_kv};
    my $count_used_node_tag_k = $self->{_count_used_node_tag_k};
    my $count_used_node_tag_kv = $self->{_count_used_node_tag_kv};
    my $count_unused_node_tag_k = $self->{_count_unused_node_tag_k};
    my $count_unused_node_tag_kv = $self->{_count_unused_node_tag_kv};
    my $node_k = $self->{_node_k};
    my $node_kv = $self->{_node_kv};

    foreach my $nodeElement (@$node_elements) {
        my $nodeId;
        if (USE_XML_FAST) {
            $nodeId = $nodeElement->{-id};
        } elsif (USE_XML_BARE) {
            $nodeId = $nodeElement->{id}->{value};
        } else {
            $nodeId = $nodeElement->getAttribute("id");
        }

        if ($nodeid_exists->{$nodeId}) { # for all split-up areas
            $this_xml_nodeid_is_dup->{$nodeId} = 1; # for this split-up area
            next;
        }
        $nodeid_exists->{$nodeId} = 1;

        my $use_this_node = 0;

        my $result = { id => $nodeId, tags => {} };

        my @tag_elements;
        if (USE_XML_FAST) {
            @tag_elements = eval { @{$nodeElement->{tag}} };
        } elsif (USE_XML_BARE) {
            @tag_elements = eval { @{$nodeElement->{tag}} };
        } else {
            @tag_elements = $nodeElement->findnodes("tag");
        }

        my @tag;
        if (USE_XML_FAST) {
            @tag = map { [$_->{-k}, $_->{-v}] } @tag_elements;
        } elsif (USE_XML_BARE) {
            @tag = map { [$_->{k}->{value}, $_->{v}->{value}] } @tag_elements;
        } else {
            @tag = map { [$_->getAttribute('k'), $_->getAttribute('v')] } @tag_elements;
        }

        foreach my $tag (@tag) {
            my ($k, $v) = @$tag;
            if (defined $k) {
                if ($node_use_k->{$k}) {
                    $use_this_node = 1;
                    push(@{$node_k->{$k}}, $result);
                }
                if (defined $v && $node_use_kv->{$k,$v}) {
                    $use_this_node = 1;
                    push(@{$node_kv->{$k,$v}}, $result);
                }

                # DON'T WORRY: a node cannot have two tags with the same key
                $result->{tags}->{$k} = $v if defined $v;
            }
        }

        if ($use_this_node) {
            foreach my $tag (@tag) {
                my ($k, $v) = @$tag;
                next if $k eq 'name';
                next if $k eq 'ref';
                $count_used_node_tag_k->{$k} += 1;
                next if $k =~ m{:};
                $count_used_node_tag_kv->{$k,$v} += 1;
            }
        } else {
            foreach my $tag (@tag) {
                my ($k, $v) = @$tag;
                next if $k eq 'name';
                next if $k eq 'ref';
                $count_unused_node_tag_k->{$k} += 1;
                next if $k =~ m{:};
                $count_unused_node_tag_kv->{$k,$v} += 1;
            }
        }
    }
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

sub set_way_elements {
    my $self = shift;

    my $way_elements = $self->{_way_elements};

    if (USE_XML_FAST) {
        @$way_elements = @{$self->{_doc}->{osm}->[0]->{way}};
    } elsif (USE_XML_BARE) {
        my $way = $self->{_doc}->{osm}->{way};
        @$way_elements = (ref $way eq 'ARRAY') ? @$way : $way ? ($way) : ();
    } else {
        @$way_elements = $self->{_doc}->findnodes("/osm/way");
    }
}

sub collect_ways {
    my $self = shift;

    my $wayid_exists = $self->{_wayid_exists};
    my $way_use_k = $self->{_way_use_k};
    my $way_use_kv = $self->{_way_use_kv};
    my $count_used_way_tag_k = $self->{_count_used_way_tag_k};
    my $count_used_way_tag_kv = $self->{_count_used_way_tag_kv};
    my $count_unused_way_tag_k = $self->{_count_unused_way_tag_k};
    my $count_unused_way_tag_kv = $self->{_count_unused_way_tag_kv};
    my $bridge_wayid = $self->{_bridge_wayid};
    my $way_k = $self->{_way_k};
    my $way_kv = $self->{_way_kv};
    my $this_xml_wayid_is_dup = $self->{_wayid_is_dup};
    my $way_elements = $self->{_way_elements};
    my $used_way_elements = $self->{_used_way_elements};
    my $way_data = $self->{_way_data};

    foreach my $wayElement (@$way_elements) {
        my $wayId;
        if (USE_XML_FAST) {
            $wayId = $wayElement->{-id};
        } elsif (USE_XML_BARE) {
            $wayId = $wayElement->{id}->{value};
        } else {
            $wayId = $wayElement->getAttribute("id");
        }

        if ($wayid_exists->{$wayId}) {                # for all split-up areas
            $this_xml_wayid_is_dup->{$wayId} = 1;     # for this split-up area
            next;
        }
        $wayid_exists->{$wayId} = 1;

        my $use_this_way = 0;

        my @nodeid;
        if (USE_XML_FAST) {
            @nodeid = eval { map { $_->{-ref} } @{$wayElement->{nd}} };
        } elsif (USE_XML_BARE) {
            my $nd = $wayElement->{nd};
            my @nd = (ref $nd eq 'ARRAY') ? @$nd : $nd ? ($nd) : ();
            @nodeid = map { eval { $_->{ref}->{value} } } @nd;
        } else {
            @nodeid = map { $_->getAttribute("ref"); } $wayElement->findnodes("nd");
        }

        my $closed = (scalar(@nodeid)) > 2 && ($nodeid[0] == $nodeid[-1]);
        pop(@nodeid) if $closed;

        my $result = { id     => $wayId,
                       nodeid => \@nodeid,
                       closed => $closed,
                       points => [],
                       tags   => {}
                   };
        $way_data->{$wayId} = $result;

        my @tag_elements;
        if (USE_XML_FAST) {
            @tag_elements = eval { @{$wayElement->{tag}} };
        } elsif (USE_XML_BARE) {
            my $tag = eval { $wayElement->{tag} };
            @tag_elements = (ref $tag eq 'ARRAY') ? @$tag : $tag ? ($tag) : ();
        } else {
            @tag_elements = $wayElement->findnodes("tag");
        }

        my @tag;
        if (USE_XML_FAST) {
            @tag = map { [$_->{-k}, $_->{-v}] } @tag_elements;
        } elsif (USE_XML_BARE) {
            @tag = map { [$_->{k}->{value}, $_->{v}->{value}] } @tag_elements;
        } else {
            @tag = map { [$_->getAttribute('k'), $_->getAttribute('v')] } @tag_elements;
        }

        foreach my $tag (@tag) {
            my ($k, $v) = @$tag;
            if (defined $k) {
                if ($way_use_k->{$k}) {
                    $use_this_way = 1;
                    push(@{$way_k->{$k}}, $result);
                } elsif (defined $v && $way_use_kv->{$k,$v}) {
                    $use_this_way = 1;
                    push(@{$way_kv->{$k,$v}}, $result);
                }

                # DON'T WORRY: a node cannot have two tags with the same key
                $result->{tags}->{$k} = $v if defined $v;

                if ($k eq "bridge" and defined $v and $v eq "yes") {
                    $bridge_wayid->{$wayId} = 1;
                }
            }
        }

        if ($use_this_way) {
            foreach my $tag (@tag) {
                my ($k, $v) = @$tag;
                next if $k eq 'name';
                next if $k eq 'ref';
                $count_used_way_tag_k->{$k} += 1;
                next if $k =~ m{:};
                $count_used_way_tag_kv->{$k,$v} += 1;
            }
            push(@$used_way_elements, $wayElement);
        } else {
            foreach my $tag (@tag) {
                my ($k, $v) = @$tag;
                next if $k eq 'name';
                next if $k eq 'ref';
                $count_unused_way_tag_k->{$k} += 1;
                next if $k =~ m{:};
                $count_unused_way_tag_kv->{$k,$v} += 1;
            }
        }
    }
}

# Collect *all* <node>s' coordinates.  Even if a <node> is not
# used directly, it could be used by a <way>.
sub collect_node_coordinates {
    my $self = shift;
    my $node_elements = $self->{_node_elements};
    my $converter = $self->{converter};
    my $node_data = $self->{_node_data};
    foreach my $map_area (@{$self->{_map_areas}}) {
        $self->update_scale($map_area);
        my $index = $map_area->{index};
        my $area_name = $map_area->{name};
        $self->diag("    Indexing for map area $area_name ... ");
        my $west_svg  = $self->west_outer_map_boundary_svg;
        my $east_svg  = $self->east_outer_map_boundary_svg;
        my $north_svg = $self->north_outer_map_boundary_svg;
        my $south_svg = $self->south_outer_map_boundary_svg;
        foreach my $nodeElement (@$node_elements) {
            my $nodeId;
            my $lat_deg;
            my $lon_deg;
            if (USE_XML_FAST) {
                $nodeId = $nodeElement->{-id};
                $lat_deg = 0 + $nodeElement->{-lat};
                $lon_deg = 0 + $nodeElement->{-lon};
            } elsif (USE_XML_BARE) {
                $nodeId = $nodeElement->{id}->{value};
                $lat_deg = 0 + $nodeElement->{lat}->{value};
                $lon_deg = 0 + $nodeElement->{lon}->{value};
            } else {
                $nodeId = $nodeElement->getAttribute("id");
                $lat_deg = 0 + $nodeElement->getAttribute("lat");
                $lon_deg = 0 + $nodeElement->getAttribute("lon");
            }
            my ($svgx, $svgy) = $converter->lon_lat_deg_to_x_y_px($lon_deg, $lat_deg);
            my $xzone = ($svgx < $west_svg)  ? -1 : ($svgx > $east_svg)  ? 1 : 0;
            my $yzone = ($svgy < $north_svg) ? -1 : ($svgy > $south_svg) ? 1 : 0;
            my $result = [$svgx, $svgy, $xzone, $yzone];
            $node_data->{$nodeId}[$index] = $result;
        }
    }
}

sub set_node_elements {
    my $self = shift;
    my $node_elements = $self->{_node_elements};
    if (!scalar @$node_elements) {
        if (USE_XML_FAST) {
            @$node_elements = @{$self->{_doc}->{osm}->[0]->{node}};
        } elsif (USE_XML_BARE) {
            my $node = $self->{_doc}->{osm}->{node};
            @$node_elements = (ref $node eq 'ARRAY') ? @$node : $node ? ($node) : ();
        } else {
            @$node_elements = $self->{_doc}->findnodes("/osm/node");
        }
    }
}

sub collect_way_coordinates {
    my $self = shift;

    my $used_way_elements = $self->{_used_way_elements};
    my $way_data = $self->{_way_data};
    my $node_data = $self->{_node_data};

    foreach my $map_area (@{$self->{_map_areas}}) {
        $self->update_scale($map_area);
        my $index = $map_area->{index};
        my $area_name = $map_area->{name};
        foreach my $wayElement (@$used_way_elements) {
            my $wayId;
            if (USE_XML_FAST) {
                $wayId = $wayElement->{-id};
            } elsif (USE_XML_BARE) {
                $wayId = $wayElement->{id}->{value};
            } else {
                $wayId = $wayElement->getAttribute("id");
            }
            my @nodeid = @{$way_data->{$wayId}{nodeid}};
            my @points = map { $node_data->{$_}[$index] } @nodeid;
            $way_data->{$wayId}{points}[$index] = \@points;
        }
    }
}

sub draw {
    my $self = shift;

    my $way_kv = $self->{_way_kv};
    my $way_k = $self->{_way_k};
    my $bridge_wayid = $self->{_bridge_wayid};
    my $deferreds = $self->{_deferreds};
    my $node_kv = $self->{_node_kv};
    my $node_k = $self->{_node_k};
    my $node_data = $self->{_node_data};

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

                my $cssClass = $info->{class};

                my @ways;
                foreach my $tag (@$tags) {
                    my $k = $tag->{k};
                    my $v = $tag->{v};
                    if (defined $k) {
                        if (defined $v) {
                            eval { push(@ways, @{$way_kv->{$k,$v}}); };
                        } else {
                            eval { push(@ways, @{$way_k->{$k}}); };
                        }
                    }
                }
                @ways = uniq @ways;

                $self->warnf("  %s (%d objects) ...\n", $name, scalar(@ways))
                    if $self->{debug}->{countobjectsbygroup} or $self->{verbose} >= 2;

                my $options = {};
                if ($map_area->{scale_stroke_width} && exists $map_area->{zoom}) {
                    $options->{scale} = $map_area->{zoom};
                }

                my $open_class          = "OPEN " . $info->{class};
                my $closed_class        =           $info->{class};
                my $open_class_2        = "OPEN " . $info->{class} . "_2";
                my $closed_class_2      =           $info->{class} . "_2";
                my $open_class_BRIDGE   = "OPEN " . $info->{class} . "_BRIDGE";
                my $closed_class_BRIDGE =           $info->{class} . "_BRIDGE";

                foreach my $way (@ways) {
                    my $attr = {};
                    $attr->{'data-name'} = $way->{tags}->{name} if defined $way->{tags}->{name};

                    my $wayid = $way->{id};
                    my $is_bridge = $bridge_wayid->{$wayid};
                    my $defer = 0;

                    my $points = $way->{points}[$index];

                    if (all { $_->[POINT_X_ZONE] == -1 } @$points) { next; }
                    if (all { $_->[POINT_X_ZONE] ==  1 } @$points) { next; }
                    if (all { $_->[POINT_Y_ZONE] == -1 } @$points) { next; }
                    if (all { $_->[POINT_Y_ZONE] ==  1 } @$points) { next; }

                    my $cssId  = $map_area->{id_prefix} . "w" . $way->{id};
                    my $cssId2 = $map_area->{id_prefix} . "w" . $way->{id} . "_2";
                    my $cssId3 = $map_area->{id_prefix} . "w" . $way->{id} . "_BRIDGE"; # bridge

                    my @append;

                    if ($way->{closed}) {
                        if ($is_bridge && $self->has_style_BRIDGE(class => $cssClass)) {
                            my $polygon_BRIDGE = $self->polygon(points => $points,
                                                                class => $closed_class_BRIDGE,
                                                                attr => $attr,
                                                                id => $cssId3);
                            push(@append, [ $group, $polygon_BRIDGE ]);
                            $defer = 1 if $is_bridge;
                        }
                        my $polygon = $self->polygon(points => $points,
                                                     class => $closed_class,
                                                     attr => $attr,
                                                     id => $cssId);
                        push(@append, [ $group, $polygon ]);
                        if ($self->has_style_2(class => $cssClass)) {
                            my $polygon_2 = $self->polygon(points => $points,
                                                           class => $closed_class_2,
                                                           attr => $attr,
                                                           id => $cssId2);
                            push(@append, [ $group, $polygon_2 ]);
                            $defer = 1 if $is_bridge;
                        }
                    } else {
                        if ($is_bridge && $self->has_style_BRIDGE(class => $cssClass)) {
                            my $polyline_BRIDGE = $self->polyline(points => $points,
                                                                  class => $open_class_BRIDGE,
                                                                  attr => $attr,
                                                                  id => $cssId3);
                            push(@append, [ $group, $polyline_BRIDGE ]);
                            $defer = 1 if $is_bridge;
                        }
                        my $polyline = $self->polyline(points => $points,
                                                       class => $open_class,
                                                       attr => $attr,
                                                       id => $cssId);
                        push(@append, [ $group, $polyline ]);
                        if ($self->has_style_2(class => $cssClass)) {
                            my $polyline_2 = $self->polyline(points => $points,
                                                             class => $open_class_2,
                                                             attr => $attr,
                                                             id => $cssId2);
                            push(@append, [ $group, $polyline_2 ]);
                            $defer = 1 if $is_bridge;
                        }
                    }

                    if ($defer) {
                        push(@$deferreds, @append);
                    } else {
                        foreach my $append (@append) {
                            my ($parent, $child) = @$append;
                            $parent->appendChild($child);
                        }
                    }
                }
            } elsif ($type eq "node") {
                my @nodes;
                foreach my $tag (@$tags) {
                    my $k = $tag->{k};
                    my $v = $tag->{v};
                    if (defined $k) {
                        if (defined $v) {
                            eval { push(@nodes, @{$node_kv->{$k, $v}}); };
                        } else {
                            eval { push(@nodes, @{$node_k->{$k}}); };
                        }
                    }
                }
                @nodes = uniq @nodes;

                $self->warnf("  %s (%d objects) ...\n", $name, scalar(@nodes))
                    if $self->{debug}->{countobjectsbygroup} or $self->{verbose} >= 2;

                if ($info->{output_text}) {
                    my $cssClass = $info->{text_class};
                    foreach my $node (@nodes) {
                        my $attr = {};
                        $attr->{'data-name'} = $node->{tags}->{name} if defined $node->{tags}->{name};

                        my $coords = $node_data->{$node->{id}}[$index];
                        my ($x, $y) = @$coords;
                                # don't care about if out of bounds i guess
                        my $text = $node->{tags}->{name};
                        my $cssId  = $map_area->{id_prefix} . "tn" . $node->{id};
                        my $text_node = $self->text_node(x => $x, y => $y, text => $text,
                                                         attr => $attr, class => $cssClass, id => $cssId);
                        $group->appendChild($text_node);
                    }
                }

                if ($info->{output_dot}) {
                    my $cssClass = $info->{dot_class};
                    my $r = $self->get_style_property(class => $cssClass, property => "r");
                    foreach my $node (@nodes) {
                        my $attr = {};
                        $attr->{'data-name'} = $node->{tags}->{name} if defined $node->{tags}->{name};

                        my $coords = $node_data->{$node->{id}}[$index];
                        my ($x, $y) = @$coords;
                                # don't care about if out of bounds i guess
                        my $cssId  = $map_area->{id_prefix} . "cn" . $node->{id};
                        my $circle = $self->circle_node(x => $x, y => $y, r => $r,
                                                        attr => $attr, class => $cssClass, id => $cssId);
                        $group->appendChild($circle);
                    }
                }
            }
        }

    }
    $self->diag("\ndone.\n");
}

sub draw_deferred {
    my $self = shift;

    my $deferreds = $self->{_deferreds};

    foreach my $deferred (@$deferreds) {
        my ($parent, $child) = @$deferred;
        $parent->appendChild($child);
    }
}

1;
