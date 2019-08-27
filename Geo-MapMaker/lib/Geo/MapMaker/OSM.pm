package Geo::MapMaker::OSM;
use warnings;
use strict;

# heh, this package is actually a mixin.  ;-)

package Geo::MapMaker;
use warnings;
use strict;

use Geo::MapMaker::Constants qw(:all);

use fields qw(_osm_xml_filenames
              osm_layers);

use LWP::Simple;                # RC_NOT_MODIFIED
use List::MoreUtils qw(all uniq);
use Sort::Naturally;

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
	CORE::warn("Not updating $xml_filename\n") if $self->{verbose};
	push(@{$self->{_osm_xml_filenames}}, $xml_filename);
    } elsif (-e $xml_filename && $force && -M $xml_filename < 1) {
	CORE::warn("Not updating $xml_filename (force in effect but less than 1 day old)\n") if $self->{verbose};
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

    # keep track of which <node> and <way> ids we've iterated through
    # because they can be duplicated across different XML files
    my %nodeid_exists;
    my %wayid_exists;

    # track the same but for determining whether to use each node or
    # way.  NOTE: $..._use_kv{$k,$v} does not imply $..._use_k{$k}
    my %way_use_k;
    my %way_use_kv;
    my %node_use_k;
    my %node_use_kv;

    # track used and unused <node> and <way> ids
    my @used_nodeid;           # array of nodeids
    my @used_wayid;            # array of wayids
    my @unused_nodeid;         # array of nodeids
    my @unused_wayid;          # array of wayids
    my %used_nodeid;
    my %used_wayid;

    my %used_node_tag_k; # track keys of used nodes' tags, value = arrayref of node ids
    my %used_node_tag_kv; # track key-values of used nodes' tags, value = arrayref of node ids
    my %used_way_tag_k; # track keys of used nodes' tags, value = arrayref of node ids
    my %used_way_tag_kv; # track key-values of used nodes' tags, value = arrayref of node ids

    my %unused_node_tag_k; # track keys of unused nodes' tags, value = arrayref of node ids
    my %unused_node_tag_kv; # track key-values of unused nodes' tags, value = arrayref of node ids
    my %unused_way_tag_k; # track keys of unused nodes' tags, value = arrayref of node ids
    my %unused_way_tag_kv; # track key-values of unused nodes' tags, value = arrayref of node ids

    my %bridge_wayid;

    my @deferred;

    foreach my $info (@{$self->{osm_layers}}) {
	my $tags = $info->{tags};
	my $type = $info->{type} // "way"; # 'way' or 'node'
	foreach my $tag (@$tags) {
	    my ($k, $v) = @{$tag}{qw(k v)};
            if (defined $k) {
                if ($type eq 'way') {
                    if (defined $v) {
                        $way_use_kv{$k,$v} = 1;
                    } else {
                        $way_use_k{$k} = 1;
                    }
                } elsif ($type eq 'node') {
                    if (defined $v) {
                        $node_use_kv{$k,$v} = 1;
                    } else {
                        $node_use_k{$k} = 1;
                    }
                }
            }
	}
    }

    foreach my $filename (@{$self->{_osm_xml_filenames}}) {
	$xml_file_number += 1;

	$self->diag("($xml_file_number/$num_xml_files) Parsing $filename ... ");
	my $doc = $self->{_parser}->parse_file($filename);
	$self->diag("done.\n");

	$self->diag("  Finding <node> elements ... ");
	my @nodeElements = $doc->findnodes("/osm/node");

        # each <node> element's coordinates for each map area
        #
        # %node_coords is a multi-level hash
        # first key <node> id; second key <map area index>
        # each value is an array:
        #     [<x>, <y>, <xzone>, <yzone>]
        #     where <x> and <y> are in px
        #     and <xzone> is -1 if west of bounds,
        #                     0 if in bounds, or
        #                     1 if east of bounds
        #     and <yzone> is -1 if north of bounds,
        #                     0 if in bounds, or
        #                     1 if south of bounds
	my %node_coords;

        my %node_k;
        my %node_kv;
	my %way_k;
	my %way_kv;
        my %ways;

        # lists of <node> and <way> ids to exclude for this XML file
        # due to being duplicated from earlier XML files
	my %this_xml_nodeid_is_dup;
	my %this_xml_wayid_is_dup;

        my @this_xml_used_nodeid;        # array of nodeids
        my @this_xml_used_wayid;         # array of wayids
        my @this_xml_unused_nodeid;      # array of nodeids
        my @this_xml_unused_wayid;       # array of wayids

	$self->diag(scalar(@nodeElements) . " <node> elements found; indexing ...\n");

        my $converter = $self->{converter};

	foreach my $map_area (@{$self->{_map_areas}}) {
	    $self->update_scale($map_area);
	    my $index = $map_area->{index};
	    my $area_name = $map_area->{name};
	    $self->diag("    Indexing for map area $area_name ... ");
	    my $west_svg  = $self->west_outer_map_boundary_svg;
	    my $east_svg  = $self->east_outer_map_boundary_svg;
	    my $north_svg = $self->north_outer_map_boundary_svg;
	    my $south_svg = $self->south_outer_map_boundary_svg;
	    foreach my $nodeElement (@nodeElements) {
		my $nodeId = $nodeElement->getAttribute("id");
		my $lat_deg = 0 + $nodeElement->getAttribute("lat");
		my $lon_deg = 0 + $nodeElement->getAttribute("lon");
		my ($svgx, $svgy) = $converter->lon_lat_deg_to_x_y_px($lon_deg, $lat_deg);
		my $xzone = ($svgx < $west_svg)  ? -1 : ($svgx > $east_svg)  ? 1 : 0;
		my $yzone = ($svgy < $north_svg) ? -1 : ($svgy > $south_svg) ? 1 : 0;
		my $result = [$svgx, $svgy, $xzone, $yzone];
		$node_coords{$nodeId}[$index] = $result;
	    }
	}
	$self->diag("done.\n");

	foreach my $nodeElement (@nodeElements) {
	    my $nodeId = $nodeElement->getAttribute("id");
	    if ($nodeid_exists{$nodeId}) { # for all split-up areas
		$this_xml_nodeid_is_dup{$nodeId} = 1; # for this split-up area
		next;
	    }
	    $nodeid_exists{$nodeId} = 1;

            my $use_this_node = 0;

	    my $result = { id => $nodeId, tags => {} };

	    my @tag = $nodeElement->findnodes("tag");
	    foreach my $tag (@tag) {
		my $k = $tag->getAttribute("k");
		my $v = $tag->getAttribute("v");
                if (defined $k) {
                    if ($node_use_k{$k}) {
                        $use_this_node = 1;
                        push(@{$node_k{$k}}, $result);
                    }
                    if (defined $v && $node_use_kv{$k,$v}) {
                        $use_this_node = 1;
                        push(@{$node_kv{$k,$v}}, $result);
                    }

                    # DON'T WORRY: a node cannot have two tags with the same key
                    $result->{tags}->{$k} = $v if defined $v;
                }
	    }

            if ($use_this_node) {
                push(@used_nodeid, $nodeId);
                $used_nodeid{$nodeId} = 1;
                push(@this_xml_used_nodeid, $nodeId);
                foreach my $tag (@tag) {
                    my $k = $tag->getAttribute("k");
                    my $v = $tag->getAttribute("v");
                    $used_node_tag_k{$k} += 1;
                    $used_node_tag_kv{$k,$v} += 1;
                }
            } else {
                push(@unused_nodeid, $nodeId);
                $used_nodeid{$nodeId} = 0;
                push(@this_xml_unused_nodeid, $nodeId);
                foreach my $tag (@tag) {
                    my $k = $tag->getAttribute("k");
                    my $v = $tag->getAttribute("v");
                    $unused_node_tag_k{$k} += 1;
                    $unused_node_tag_kv{$k,$v} += 1;
                }
            }
	}
	$self->diag("done.\n");

	$self->diag("  Finding <way> elements ... ");
	my @wayElements = $doc->findnodes("/osm/way");

	$self->diag(scalar(@wayElements) . " <way> elements found; indexing ... ");
	foreach my $wayElement (@wayElements) {
	    my $wayId = $wayElement->getAttribute("id");
	    if ($wayid_exists{$wayId}) { # for all split-up areas
		$this_xml_wayid_is_dup{$wayId} = 1; # for this split-up area
		next;
	    }
	    $wayid_exists{$wayId} = 1;

            my $use_this_way = 0;

	    my @nodeid = map { $_->getAttribute("ref"); } $wayElement->findnodes("nd");
	    my $closed = (scalar(@nodeid)) > 2 && ($nodeid[0] == $nodeid[-1]);
	    pop(@nodeid) if $closed;

	    my $result = { id     => $wayId,
			   nodeid => \@nodeid,
			   closed => $closed,
			   points => [],
			   tags   => {}
			  };
	    $ways{$wayId} = $result;

	    my @tag = $wayElement->findnodes("tag");
	    foreach my $tag (@tag) {
		my $k = $tag->getAttribute("k");
		my $v = $tag->getAttribute("v");
                if (defined $k) {
                    if ($way_use_k{$k}) {
                        $use_this_way = 1;
                    } elsif (defined $v && $way_use_kv{$k,$v}) {
                        $use_this_way = 1;
                    }

                    # DON'T WORRY: a node cannot have two tags with the same key
                    $result->{tags}->{$k} = $v if defined $v;

		    if ($k eq "bridge" and defined $v and $v eq "yes") {
			$bridge_wayid{$wayId} = 1;
		    }
                }
	    }

            if ($use_this_way) {
                push(@used_wayid, $wayId);
                $used_wayid{$wayId} = 1;
                push(@this_xml_used_wayid, $wayId);
                foreach my $tag (@tag) {
                    my $k = $tag->getAttribute("k");
                    my $v = $tag->getAttribute("v");
                    $used_way_tag_k{$k} += 1;
                    $used_way_tag_kv{$k,$v} += 1;
                }
            } else {
                push(@unused_wayid, $wayId);
                $used_wayid{$wayId} = 0;
                push(@this_xml_unused_wayid, $wayId);
                foreach my $tag (@tag) {
                    my $k = $tag->getAttribute("k");
                    my $v = $tag->getAttribute("v");
                    $unused_way_tag_k{$k} += 1;
                    $unused_way_tag_kv{$k,$v} += 1;
                }
            }
	}
	$self->diag("done.\n");

	foreach my $map_area (@{$self->{_map_areas}}) {
	    $self->update_scale($map_area);
	    my $index = $map_area->{index};
	    my $area_name = $map_area->{name};
	    $self->diag("    Indexing for map area $area_name ... ");
	    foreach my $wayElement (@wayElements) {
		my $wayId = $wayElement->getAttribute("id");
                next unless $used_wayid{$wayId};
                next if $this_xml_wayid_is_dup{$wayId};

		my @nodeid = @{$ways{$wayId}{nodeid}};
		my @points = map { $node_coords{$_}[$index] } @nodeid;
		$ways{$wayId}{points}[$index] = \@points;
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

		    my $cssClass = $info->{class};

		    my @ways;
		    foreach my $tag (@$tags) {
			my $k = $tag->{k};
			my $v = $tag->{v};
			if (defined $k) {
			    if (defined $v) {
                                eval { push(@ways, @{$way_kv{$k,$v}}); };
			    } else {
				eval { push(@ways, @{$way_k{$k}}); };
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
			my $wayid = $way->{id};
			my $is_bridge = $bridge_wayid{$wayid};
			my $defer = 0;

			$way->{used} = 1;
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
								    id => $cssId3);
				push(@append, [ $group, $polygon_BRIDGE ]);
				$defer = 1 if $is_bridge;
			    }
			    my $polygon = $self->polygon(points => $points,
							 class => $closed_class,
							 id => $cssId);
			    push(@append, [ $group, $polygon ]);
			    if ($self->has_style_2(class => $cssClass)) {
				my $polygon_2 = $self->polygon(points => $points,
							       class => $closed_class_2,
							       id => $cssId2);
				push(@append, [ $group, $polygon_2 ]);
				$defer = 1 if $is_bridge;
			    }
			} else {
			    if ($is_bridge && $self->has_style_BRIDGE(class => $cssClass)) {
				my $polyline_BRIDGE = $self->polyline(points => $points,
								      class => $open_class_BRIDGE,
								      id => $cssId3);
				push(@append, [ $group, $polyline_BRIDGE ]);
				$defer = 1 if $is_bridge;
			    }
			    my $polyline = $self->polyline(points => $points,
							   class => $open_class,
							   id => $cssId);
			    push(@append, [ $group, $polyline ]);
			    if ($self->has_style_2(class => $cssClass)) {
				my $polyline_2 = $self->polyline(points => $points,
								 class => $open_class_2,
								 id => $cssId2);
				push(@append, [ $group, $polyline_2 ]);
				$defer = 1 if $is_bridge;
			    }
			}

			if ($defer) {
			    push(@deferred, @append);
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
				eval { push(@nodes, @{$node_kv{$k, $v}}); };
			    } else {
				eval { push(@nodes, @{$node_k{$k}}); };
			    }
			}
		    }
		    @nodes = uniq @nodes;

		    $self->warnf("  %s (%d objects) ...\n", $name, scalar(@nodes))
		      if $self->{debug}->{countobjectsbygroup} or $self->{verbose} >= 2;

		    if ($info->{output_text}) {
			my $cssClass = $info->{text_class};
			foreach my $node (@nodes) {
			    $node->{used} = 1;
			    my $coords = $node_coords{$node->{id}}[$index];
			    my ($x, $y) = @$coords;
			    # don't care about if out of bounds i guess
			    my $text = $node->{tags}->{name};
			    my $cssId  = $map_area->{id_prefix} . "tn" . $node->{id};
			    my $text_node = $self->text_node(x => $x, y => $y, text => $text,
							     class => $cssClass, id => $cssId);
			    $group->appendChild($text_node);
			}
		    }

		    if ($info->{output_dot}) {
			my $cssClass = $info->{dot_class};
			my $r = $self->get_style_property(class => $cssClass, property => "r");
			foreach my $node (@nodes) {
			    $node->{used} = 1;
			    my $coords = $node_coords{$node->{id}}[$index];
			    my ($x, $y) = @$coords;
			    # don't care about if out of bounds i guess
			    my $cssId  = $map_area->{id_prefix} . "cn" . $node->{id};
			    my $circle = $self->circle_node(x => $x, y => $y, r => $r,
							    class => $cssClass, id => $cssId);
			    $group->appendChild($circle);
			}
		    }
		}
	    }

	    $self->diag("\ndone.\n");
	}
    }

    foreach my $deferred (@deferred) {
	my ($parent, $child) = @$deferred;
	$parent->appendChild($child);
    }

    $self->write_objects_not_included(
        \%unused_node_tag_k,
        \%unused_node_tag_kv,
        \%unused_way_tag_k,
        \%unused_way_tag_kv,
    );
}

sub write_objects_not_included {
    my ($self,
        $unused_node_tag_k,
        $unused_node_tag_kv,
        $unused_way_tag_k,
        $unused_way_tag_kv) = @_;

    my $filename = $self->{osm_objects_not_included_filename};
    if (!defined $filename) {
        return;
    }
    if (!scalar keys %$unused_node_tag_k &&
            !scalar keys %$unused_node_tag_kv &&
            !scalar keys %$unused_way_tag_k &&
            !scalar keys %$unused_way_tag_kv) {
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

    foreach my $key (nsort keys %$unused_node_tag_k) {
        my $count = $unused_node_tag_k->{$key};
        my $tagkey = $key;
        printf $fh ("%8s NODE %-32s\n", $count, $tagkey);
    }
    foreach my $key (nsort keys %$unused_node_tag_kv) {
        my $count = $unused_node_tag_kv->{$key};
        my ($tagkey, $tagvalue) = split($;, $key);
        printf $fh ("%8s NODE %-32s = %-32s\n", $count, $tagkey, $tagvalue);
    }
    foreach my $key (nsort keys %$unused_way_tag_k) {
        my $count = $unused_way_tag_k->{$key};
        my $tagkey = $key;
        printf $fh ("%8s WAY %-32s\n", $count, $tagkey);
    }
    foreach my $key (nsort keys %$unused_way_tag_kv) {
        my $count = $unused_node_tag_kv->{$key};
        my ($tagkey, $tagvalue) = split($;, $key);
        printf $fh ("%8s WAY %-32s = %-32s\n", $count, $tagkey, $tagvalue);
    }

    close($fh);
    CORE::warn("Wrote $filename\n");
}

1;

