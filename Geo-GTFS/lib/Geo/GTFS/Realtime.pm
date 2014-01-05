package Geo::GTFS::Realtime;

use LWP::Simple;
use HTTP::Cache::Transparent;
use Google::ProtocolBuffers;
use File::Path qw(make_path);
use XML::LibXML;
use YAML;
use POSIX qw(strftime);
use Geo::GTFS;
use Time::ParseDate;

use lib "/home/dse/git/geo-modules/Geo-GTFS/lib";
use Geo::GTFS;

use constant CACHE_KEEP_SECONDS => 29;

sub new {
	my ($class) = @_;
	my $self = bless({}, $class);
	$self->init();
	return $self;
}

sub init {
	my ($self) = @_;
	my $HOME = $ENV{HOME} // "/tmp";
	$self->{gtfs_provider} = "ridetarc.org";
	$self->{cache_dir} = "$HOME/.geo-gtfs/gtfsrt-cache";
	$self->{proto_file} = "$HOME/.geo-gtfs/gtfs-realtime.proto";

	$self->{vp_url} = "http://gtfsrealtime.ridetarc.org/vehicle/VehiclePositions.pb";
	$self->{tu_url} = "http://gtfsrealtime.ridetarc.org/trip_update/TripUpdates.pb";
	
	if ($ENV{REQUEST_METHOD}) {
		$self->{cache_dir}  = "/tmp/gtfsrt-cache-$>";
		$self->{proto_file} = "/home/dse/.geo-gtfs/gtfs-realtime.proto";
		$self->{gtfs_dir}   = "/home/dse/.geo-gtfs";
		$self->{gtfs} = Geo::GTFS->new(
					       "ridetarc.org", {
								verbose => 1,
								gtfs_dir => $self->{gtfs_dir},
							       },
					      );
	} else {
		$self->{gtfs} = Geo::GTFS->new(
					       "ridetarc.org", {
								verbose => 1,
							       },
					      );
	}

	HTTP::Cache::Transparent::init({ BasePath => $self->{cache_dir},
					 MaxAge => CACHE_KEEP_SECONDS / 3600,
					 NoUpdate => CACHE_KEEP_SECONDS,
					 ApproveContent => sub {
						 return $_[0]->is_success();
					 },
				       });
	Google::ProtocolBuffers->parsefile($self->{proto_file});
}

sub get_vehicle_positions_raw_pb_data {
	my ($self) = @_;
	if ($self->{vp_pb_data} &&
	    $self->{vp_pb_data_time} >= (time() - CACHE_KEEP_SECONDS)) {
		return $self->{vp_pb_data};
	}
	my $vp_pb_data = $self->{vp_pb_data} = get($self->{vp_url});
	die("failure") if !defined $vp_pb_data;
	return $vp_pb_data;
}

sub get_vehicle_positions_data {
	my ($self) = @_;
	my $pb = $self->get_vehicle_positions_raw_pb_data();
	my $vp = $self->{vp_data} = TransitRealtime::FeedMessage->decode($pb);
	return $vp;
}

sub get_trip_updates_raw_pb_data {
	my ($self) = @_;
	if ($self->{tu_pb_data} &&
	    $self->{tu_pb_data_time} >= (time() - CACHE_KEEP_SECONDS)) {
		return $self->{tu_pb_data};
	}
	my $tu_pb_data = $self->{tu_pb_data} = get($self->{tu_url});
	die("failure") if !defined $tu_pb_data;
	return $tu_pb_data;
}

sub get_trip_updates_data {
	my ($self) = @_;
	my $pb = $self->get_trip_updates_raw_pb_data();
	my $tu = $self->{tu_data} = TransitRealtime::FeedMessage->decode($pb);

	foreach my $entity (@{$tu->{entity}}) {
		my $trip_update = eval { $entity->{trip_update} };
		if (!$trip_update) {
			$entity->{x} = 1;
			next;
		}
		my $trip_id = eval { $trip_update->{trip}->{trip_id} };
		if (!defined $trip_id) {
			$entity->{x} = 2;
			next;
		}
		my $trip = $self->{gtfs}->get_trip_by_trip_id($trip_id);
		if (!$trip) {
			$entity->{x} = 3;
			next;
		}
		my $trip_headsign = eval { $trip->{trip_headsign} };
		if (!defined $trip_headsign) {
			$entity->{x} = 4;
			next;
		}
		$trip_update->{trip}->{trip_headsign} = $trip_headsign;
	}
	
	return $tu;
}

sub get_all_data {
	my ($self) = @_;
	my $vp = $self->get_vehicle_positions_data();
	my $tu = $self->get_trip_updates_data();
	return {
		vehicle_positions => $vp,
		trip_updates      => $tu
	       };
}

sub kml_doc {
	my ($self) = @_;

	$self->get_vehicle_positions_data();
	my $vehicle_positions = $self->{vp_data};

	my $gtfs = $self->{gtfs};
	
	my $parser = XML::LibXML->new();
	$parser->set_options({ no_blanks => 1 });
	my $docstr = xml_trim(<<"END");
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
</kml>
END
	my $doc = $parser->parse_string($docstr);
	my $root = $doc->documentElement();
	my $Document = $doc->createElement("Document");
	$root->appendChild($Document);

	my $TIME_FORMAT = "%Y-%m-%d/%H:%M:%S%z";
	my $TIME_FORMAT_SHORT = "%m/%d %H:%M:%S";

	my $header = $vehicle_positions->{header};
	my $version = $header->{gtfs_realtime_version};
	my $h_timestamp = $header->{timestamp};
	my $h_timestamp_fmt   = strftime($TIME_FORMAT,       localtime($h_timestamp));
	my $h_timestamp_short = strftime($TIME_FORMAT_SHORT, localtime($h_timestamp));

	$Document->appendTextChild("name", "Vehicle Positions ${h_timestamp_short}");
	my $description = <<"END";
URL: ${vp_url}
Timestamp: ${h_timestamp_fmt}
GTFS Realtime version: ${version}
END
	appendCDATA($Document, "description", $description);

	my $Folder = $Document->addNewChild(undef, "Folder");
	$Folder->appendTextChild("open", 0);
	$Folder->appendTextChild("visibility", 0);
	$Folder->appendTextChild("name", "Where The TARC Buses Are");
	$Folder->appendTextChild("description", "Where The TARC Buses Are");

	foreach my $entity (@{$vehicle_positions->{entity}}) {
		my $id = eval { $entity->{id}; };

		my $vehicle               = eval { $entity->{vehicle}; };
		if (!$vehicle) {
			warn(sprintf("No vehicle data (id = $id).\n"));
		}

		my $lat                   = eval { $vehicle->{position}->{latitude}; };
		my $lon                   = eval { $vehicle->{position}->{longitude}; };
		my $current_stop_sequence = eval { $vehicle->{current_stop_sequence}; };
		my $current_status        = eval { $vehicle->{current_status}; };
		my $congestion_level      = eval { $vehicle->{congestion_level}; };

		my $timestamp             = eval { $vehicle->{timestamp} };
		my $vehicle_label         = eval { $vehicle->{vehicle}->{label}; };

		my $trip_id               = eval { $vehicle->{trip}->{trip_id}; };
		my $route_id              = eval { $vehicle->{trip}->{route_id}; };
		my $start_time            = eval { $vehicle->{trip}->{start_time}; };
		my $start_date            = eval { $vehicle->{trip}->{start_date}; };
		my $schedule_relationship = eval { $vehicle->{trip}->{schedule_relationship}; };

		my $age;
		$age = $h_timestamp - $timestamp if defined $h_timestamp && defined $timestamp;

		next if defined $age && $age > 3600; # really old data :-(

		my $trip = $gtfs->get_trip_by_trip_id($trip_id);
		if (!$trip) {
			warn(sprintf("Bogus trip ID: %s (vehicle %s at %f %f)\n",
				     $trip_id, $id, $lat, $lon));
			warn(Dump($entity));
		}

		my $trip_route_id = ($trip && $trip->{route_id})      // "??";
		my $trip_headsign = ($trip && $trip->{trip_headsign}) // "????????";

		my $timestamp_fmt   = eval { strftime($TIME_FORMAT,       localtime($timestamp)) };
		my $timestamp_short = eval { strftime($TIME_FORMAT_SHORT, localtime($timestamp)) };

		my $Placemark = $Folder->addNewChild(undef, "Placemark");
		$Placemark->appendTextChild("name", "$trip_route_id $trip_headsign");
		$Placemark->appendTextChild("title", "$trip_route_id $trip_headsign");
		$Placemark->appendTextChild("visibility", 0);

		my %red = qw(94 1 95 1);
		my $red = $red{$trip_route_id};

		my $express = (($trip_headsign =~ m{\bexpress\b}i) ? 1 : 0);

		my $etran = 0;
		if ($id =~ m{^\d+$} && $id >= 1350 && $id <= 1370) {
			$etran = 1;
		} elsif ($vehicle_label =~m{^\d+$} && $vehicle_label >= 1350 && $vehicle_label <= 1370) {
			$etran = 1;
		}

		my $description = "";
		$description .= sprintf("<p>Vehicle: %s</p>\n", $vehicle_label) if defined $vehicle_label;
		$description .= sprintf("<p>Trip ID: %s</p>\n", $trip_id);
		$description .= sprintf("<p>(As of %d seconds ago)</p>\n", $age) if defined $age;
		$description .= sprintf("<p><b>THIS BUS IS FANCY</b></p>\n") if $etran;

		appendCDATA($Placemark, "description", $description);

		my $Point = $Placemark->addNewChild(undef, "Point");
		$Point->appendTextChild("coordinates", sprintf("%f,%f", $lon, $lat));

		my $icon_style;
		if ($etran) {
			$icon_style = $express ? "blue-on-white" : "white-on-blue";
		} else {
			$icon_style = $express ? "black-on-yellow" : $red ? "white-on-red" : "white-on-black";
		}
		my $icon_style_kml = kml_icon_style($trip_route_id, icon_style => $icon_style);
		warn($icon_style_kml);
		my $fragment = $parser->parse_balanced_chunk($icon_style_kml);
		$Placemark->appendChild($fragment);
	}
	$doc->toString(1);

	return $doc;
}

sub kml_string {
	my ($self) = @_;
	my $kml_doc = $self->kml_doc();
	return $kml_doc->toString();
}

sub kml_icon_style {
	my ($route, %args) = @_;
	my $route_number = $route // "00";
	my $icon_style   = $args{icon_style} // "white-on-black";
	my $xml = xml_trim(<<"END");
<Style>
  <IconStyle>
    <Icon>
      <href>http://webonastick.com/route-icons/target/route-icons/png/${icon_style}/${route_number}.png</href>
    </Icon>
    <hotSpot x="0.5" y="0.5" xunits="fraction" yunits="fraction" />
  </IconStyle>
</Style>
END
	return $xml;
}

sub appendCDATA {
	my ($parent, $name, $text) = @_;
	my $doc = $parent->ownerDocument();
	my $cdata = $doc->createCDATASection($text);
	my $element = $doc->createElement($name);
	$element->appendChild($cdata);
	$parent->appendChild($element);
}

sub xml_trim {
	my ($s) = @_;
	$s =~ s{^\s*<}{<}gsm;
	$s =~ s{>\s*$}{>}gsm;
	$s =~ s{>\s*<}{><}gsm;
	return $s;
}

1;
