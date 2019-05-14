package Geo::MapMaker::GTFS;
use warnings;
use strict;

# heh, this package is actually a mixin.  ;-)

package Geo::MapMaker;
use warnings;
use strict;

use Geo::MapMaker::Constants qw(:all);

use List::MoreUtils qw(uniq);
use Text::Diff qw(diff);

use fields qw(
		 _gtfs_list
		 transit_route_overrides
		 transit_route_defaults
		 transit_route_groups
		 transit_orig_route_color_mapping
		 transit_trip_exceptions
	    );

# set to 0 to turn off path simplifying
use constant SIMPLIFY_THRESHOLD => 0;

use constant SIMPLIFY_MINIMUM_DISTANCE => 4;

use constant GROUP_INTO_CHUNKS => 0;

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

# not used anywhere for now
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
	    CORE::warn("  shape id to direction id mapping not possible!\n");
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

    my @trip_ids  = sort { $a <=> $b } grep { /\S/ } uniq map { $_->{trip_id}  } @trips;
    my @shape_ids = sort { $a <=> $b } grep { /\S/ } uniq map { $_->{shape_id} } @trips;
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
                      and shape_id != ' ' and shape_id != '' and shape_id is not null
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
    $self->add_indexes_to_array($self->{transit_route_groups});
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

	    my @shape_id = $self->get_transit_route_shape_ids($gtfs, $route_short_name);
            $self->diagf("    %d shape_ids\n", scalar @shape_id);
	    $route_shape_id{$agency_route} = [@shape_id];

	    my @excepted_trips = $self->get_excepted_transit_trips(gtfs => $gtfs, route => $route_short_name);
	    my @excluded_trips = $self->get_excepted_transit_trips(gtfs => $gtfs, route => $route_short_name, return_excluded_trips => 1);
	    my @excepted_shape_id = $self->get_transit_shape_ids_from_trip_ids(gtfs => $gtfs, trips => \@excepted_trips);
	    my @excluded_shape_id = $self->get_transit_shape_ids_from_trip_ids(gtfs => $gtfs, trips => \@excluded_trips);
	    $shape_excepted{$agency_route}{$_} = 1 foreach @excepted_shape_id;
	    $shape_excluded{$agency_route}{$_} = 1 foreach @excluded_shape_id;

            $self->diagf("    %d excepted trips\n", scalar @excepted_trips);
            $self->diagf("    %d excluded trips\n", scalar @excluded_trips);
            $self->diagf("    %d excepted shape_ids\n", scalar @excepted_shape_id);
            $self->diagf("    %d excluded shape_ids\n", scalar @excluded_shape_id);

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
                    $self->diagf("      %d shape points\n", scalar @coords);
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
                    if (SIMPLIFY_THRESHOLD) {
                        printf STDERR ("shape id %s\n", $shape_id);
                        @svg_coords = $self->simplify_path(@svg_coords);
                    }
		    $shape_svg_coords{$map_area_index}{$agency_route}{$shape_id} = \@svg_coords;
		}
	    }
	}
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
		    if (defined $route_group_class) {
			$collection->{class}   = "${route_group_class} ta_${agency_id}_rt rt_${route_short_name}";
			$collection->{class_2} = "${route_group_class}_2 ta_${agency_id}_rt_2 rt_${route_short_name}_2";
		    } else {
			$collection->{class}   = "ta_${agency_id}_rt rt_${route_short_name}";
			$collection->{class_2} = "ta_${agency_id}_rt_2 rt_${route_short_name}_2";
		    }
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
		    push(@{$collection->{shapes}}, {
                        shape_id => $shape_id,
                        points => \@svg_coords
                    });
		}

                if (GROUP_INTO_CHUNKS) {
                    foreach my $collection (@$shape_collections) {
                        $collection->{shapes} = [
                            find_chunks(@{$collection->{shapes}})
                        ];
                    }
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
			my $polyline = $self->polyline(points => $shape->{points}, class => $class, id => $id,
                                                       shape_id => $shape->{shape_id},
                                                       shape_id_hash => $shape->{shape_id_hash});
			$clipped_group->appendChild($polyline);
			if ($self->has_style_2(class => $class)) {
			    my $polyline_2 = $self->polyline(points => $shape->{points}, class => $class_2, id => $id2,
                                                             shape_id => $shape->{shape_id},
                                                             shape_id_hash => $shape->{shape_id_hash});
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

sub simplify_path {
    my ($self, @coords) = @_;

    my $text1 = join('', map { sprintf("%g, %g\n", @$_) } @coords);

    my $totalNodes = scalar @coords;
    # CORE::warn(sprintf("simplify_path: %s nodes\n", scalar @coords));

    my @duplicateIndexes;
    for (my $i = 0; $i < scalar(@coords) - 1; $i += 1) {
        my ($x1, $y1) = @{$coords[$i]};
        my ($x2, $y2) = @{$coords[$i + 1]};
        if ($x1 == $x2 && $y1 == $y2) {
            push(@duplicateIndexes, $i);
        }
    }
    @duplicateIndexes = reverse @duplicateIndexes;
    foreach my $index (@duplicateIndexes) {
        splice(@coords, $index, 1);
    }
    # CORE::warn(sprintf("               %s duplicate nodes removed\n", scalar @duplicateIndexes));

    # for (my $i = 0; $i < scalar(@coords); $i += 1) {
    #     CORE::warn(sprintf("%5d: (%g, %g)\n", $i, $coords[$i][0], $coords[$i][1]));
    # }

    my $duplicateNodes = scalar @duplicateIndexes;

    my @distance;
    for (my $i = 1; $i < scalar(@coords) - 1; $i += 1) {
        my ($x0, $y0) = @{$coords[$i - 1]};
        my ($x1, $y1) = @{$coords[$i]};
        my ($x2, $y2) = @{$coords[$i + 1]};
        if ($x0 == $x2 && $y0 == $y2) {
            # points exactly the same
            next;
        }
        if (sqrt(($x2 - $x0) ** 2 + ($y2 - $y0) ** 2) < SIMPLIFY_MINIMUM_DISTANCE) {
            # points close enough to one another
            next;
        }
        my $distance = $self->distance_from_point_to_line(
            $i, $x0, $y0, $x2, $y2, $x1, $y1
        );
        if ($distance <= SIMPLIFY_THRESHOLD) {
            push(@distance, { distance => $distance, coordsIndex => $i });
            # CORE::warn(sprintf("%5d: (%g %g) (%g %g) (%g %g) %g\n", $i, $x0, $y0, $x2, $y2, $x1, $y1, $distance));
        }
    }
    my @coordsIndex = sort { $b <=> $a } map { $_->{coordsIndex} } @distance;
    my $removedNodes = scalar @coordsIndex;
    foreach my $coordsIndex (@coordsIndex) {
        warn(sprintf("between (%g %g) and (%g %g) removing %d (%g %g)\n",
                     @{$coords[$coordsIndex - 1]},
                     @{$coords[$coordsIndex + 1]},
                     $coordsIndex,
                     @{$coords[$coordsIndex]}));
        splice(@coords, $coordsIndex, 1);
    }
    # CORE::warn(sprintf("               %s nodes removed\n", scalar @candidates));

    CORE::warn(sprintf("simplify_path %d %d %d\n", $totalNodes, $duplicateNodes, $removedNodes));

    my $text2 = join('', map { sprintf("%g, %g\n", @$_) } @coords);

    print STDERR diff(\$text1, \$text2), "\n";

    return @coords;
}

sub distance_from_point_to_line {
    my ($self, $i, $x1, $y1, $x2, $y2, $x0, $y0) = @_;
    # https://en.wikipedia.org/wiki/Distance_from_a_point_to_a_line
    # CORE::warn(sprintf("%5d: (%g, %g) (%g, %g) (%g, %g)\n", $i,
    #                    $x1, $y1, $x0, $y0, $x2, $y2));
    return
        abs(
            ($y2 - $y1) * $x0 - ($x2 - $x1) * $y0 + $x2 * $y1 - $y2 * $x1
        )
        /
        sqrt(
            ($y2 - $y1) ** 2 + ($x2 - $x1) ** 2
        );
}

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
	$self->{_gtfs_list} //= [];
	return @{$self->{_gtfs_list}};
    }
}

1;

