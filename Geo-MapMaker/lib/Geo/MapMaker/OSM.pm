package Geo::MapMaker::OSM;
use warnings;
use strict;

# heh, this package is actually a mixin.  ;-)

package Geo::MapMaker;
use warnings;
use strict;

use Geo::MapMaker::Constants qw(:all);

use fields qw(
		 _osm_xml_filenames
		 osm_layers
         );

use LWP::Simple;                # RC_NOT_MODIFIED
use List::MoreUtils qw(all uniq);

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

    my %unused;

    my %unused_node_k;
    my %unused_node_kv;
    my %unused_way_k;
    my %unused_way_kv;

    my %wayid_exists;

    # keep track of which <node> ids we've iterated through
    # because they can be duplicated across different XML files
    my %nodeid_exists;

    my %wayid_included;

    my %keep_ways;              # cloned DOM <way> nodes

    # track which keys and key-value pairs we're looking for
    # when searching through <way> elements and <node> elements
    my %way_preindex_k;
    my %node_preindex_k;
    my %way_preindex_kv;
    my %node_preindex_kv;

    my %bridge_wayid;

    my @deferred;

    foreach my $info (@{$self->{osm_layers}}) {
	my $tags = $info->{tags};
	my $type = $info->{type} // "way"; # 'way' or 'node'
	foreach my $tag (@$tags) {
	    my ($k, $v) = @{$tag}{qw(k v)};
	    # k/v from osm_layers
	    if (defined $k) {
		if ($type eq "way") {
		    $way_preindex_k{$k} = 1;
		    $way_preindex_kv{$k,$v} = 1 if defined $v;
		} elsif ($type eq "node") {
		    $node_preindex_k{$k} = 1;
		    $node_preindex_kv{$k,$v} = 1 if defined $v;
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
	my @nodes = $doc->findnodes("/osm/node");

        # multi-level hash
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

	my %node_info;

        # {<tagkey>} => [ { id => <id>, tags => { } }, ... ]
	my %node_index_k;

        # {<tagkey>,<tagvalue>} => [ { id => <id>, tags => { } }, ... ]
	my %node_index_kv;

        # list of <node> ids to exclude for this XML file due to being
        # duplicated from earlier XML files
	my %nodeid_exclude;

        my %doc_wayid_exists;
        my %doc_wayid_included;

	$self->diag(scalar(@nodes) . " node elements found.\n");

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
	    if ($nodeid_exists{$id}) { # for all split-up areas
		$nodeid_exclude{$id} = 1; # for this split-up area
		next;
	    }
	    $nodeid_exists{$id} = 1;

	    my $result = { id => $id, tags => {} };

	    my @tag = $node->findnodes("tag");
	    foreach my $tag (@tag) {
		my $k = $tag->getAttribute("k");
		my $v = $tag->getAttribute("v");
		# k/v from xml
		if (defined $k) {
		    if (defined $v) {
			$result->{tags}->{$k} = $v;
			if ($node_preindex_kv{$k,$v}) {
			    push(@{$node_index_kv{$k, $v}}, $result);
                        }
		    }
		    if ($node_preindex_k{$k}) {
			push(@{$node_index_k{$k}}, $result);
                    }
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

            $doc_wayid_exists{$id} = 1;

	    if ($wayid_exists{$id}) { # for all split-up areas
		$wayid_exclude{$id} = 1; # for this split-up area
		next;
	    }

	    $wayid_exists{$id} = 1;

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
		# k/v from xml
		if (defined $k) {
		    if ($k eq "bridge" and $v eq "yes") {
			$bridge_wayid{$id} = 1;
		    }
		    if (defined $v) {
			$result->{tags}->{$k} = $v;
			if ($way_preindex_kv{$k,$v}) {
			    push(@{$way_index_kv{$k, $v}}, $result);
			}
		    }
		    if ($way_preindex_k{$k}) {
			push(@{$way_index_k{$k}}, $result);
		    }
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
			# k/v from osm_layers
			if (defined $k) {
			    if (defined $v) {
				eval { push(@ways, @{$way_index_kv{$k, $v}}); };
			    } else {
				eval { push(@ways, @{$way_index_k{$k}}); };
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

			my $id  = $map_area->{id_prefix} . "w" . $way->{id};
			my $id2 = $map_area->{id_prefix} . "w" . $way->{id} . "_2";
			my $id3 = $map_area->{id_prefix} . "w" . $way->{id} . "_BRIDGE"; # bridge

			my @append;

                        $wayid_included{$wayid} = 1;
                        $doc_wayid_included{$wayid} = 1;

			if ($way->{closed}) {
			    if ($is_bridge && $self->has_style_BRIDGE(class => $class)) {
				my $polygon_BRIDGE = $self->polygon(points => $points,
								    class => $closed_class_BRIDGE,
								    id => $id3);
				push(@append, [ $group, $polygon_BRIDGE ]);
				$defer = 1 if $is_bridge;
			    }
			    my $polygon = $self->polygon(points => $points,
							 class => $closed_class,
							 id => $id);
			    push(@append, [ $group, $polygon ]);
			    if ($self->has_style_2(class => $class)) {
				my $polygon_2 = $self->polygon(points => $points,
							       class => $closed_class_2,
							       id => $id2);
				push(@append, [ $group, $polygon_2 ]);
				$defer = 1 if $is_bridge;
			    }
			} else {
			    if ($is_bridge && $self->has_style_BRIDGE(class => $class)) {
				my $polyline_BRIDGE = $self->polyline(points => $points,
								      class => $open_class_BRIDGE,
								      id => $id3);
				push(@append, [ $group, $polyline_BRIDGE ]);
				$defer = 1 if $is_bridge;
			    }
			    my $polyline = $self->polyline(points => $points,
							   class => $open_class,
							   id => $id);
			    push(@append, [ $group, $polyline ]);
			    if ($self->has_style_2(class => $class)) {
				my $polyline_2 = $self->polyline(points => $points,
								 class => $open_class_2,
								 id => $id2);
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
			# k/v from osm_layers
			if (defined $k) {
			    if (defined $v) {
				eval { push(@nodes, @{$node_index_kv{$k, $v}}); };
			    } else {
				eval { push(@nodes, @{$node_index_k{$k}}); };
			    }
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

        if ($self->{osm_features_not_included_filename}) {
            my @doc_wayids_not_included =
                grep { !exists $doc_wayid_included{$_} }
                keys %doc_wayid_exists;
            foreach my $wayid (@doc_wayids_not_included) {
                my ($way_node) = $doc->findnodes('/osm/way[@id=' + $wayid + ']');
                $way_node = $way_node->cloneNode(1);
                $keep_ways{$wayid} = $way_node;
            }
        }
    }

    foreach my $deferred (@deferred) {
	my ($parent, $child) = @$deferred;
	$parent->appendChild($child);
    }

    if ($self->{osm_features_not_included_filename}) {
        my @wayids_not_included =
            grep { !exists $wayid_included{$_} }
            keys %wayid_exists;
        my @ways_not_included = map { $keep_ways{$_} } @wayids_not_included;
        $self->write_features_not_included(@ways_not_included);
    }

    $self->write_objects_not_included(\%unused);
}

sub write_objects_not_included {
    my $self = shift;
    my $unused = shift;         # hash
    my $filename = $self->{osm_objects_not_included_filename};
    if (!defined $filename) {
        return;
    }
    if (!scalar keys %$unused) {
        if (!unlink($filename)) {
            warn("cannot unlink $filename: $!\n");
        }
        return;
    }
    my $fh;
    if (!open($fh, '>', $filename)) {
        warn("cannot write $filename: $!\n");
        return;
    }
    foreach my $kv (sort keys %$unused) {
        my ($k, $v) = split($;, $kv);
        my $n = $unused->{$kv};
        printf $fh ("%8d %s %s\n", $n, $k, $v);
    }
    warn("Wrote $filename\n");
}

sub write_features_not_included {
    my ($self, @ways_not_included) = @_;

    my $filename = $self->{osm_features_not_included_filename};
    if (!defined $filename) {
        return;
    }

    my $fh;
    if (!open($fh, ">", $filename)) {
        CORE::warn("Cannot write $filename: $!\n");
        return;
    };

    my $doc = XML::LibXML::Document->new();
    my $root = $doc->createElement("features-not-included");
    $doc->setDocumentElement($root);

    foreach my $way_not_included (@ways_not_included) {
        $root->appendChild($way_not_included);
    }

    $doc->toFH($fh, 1);
    close($fh);
}

1;

