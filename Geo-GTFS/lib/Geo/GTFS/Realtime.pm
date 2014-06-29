package Geo::GTFS::Realtime;
use warnings;
use strict;

use lib "$ENV{HOME}/git/HTTP-Cache-Transparent/lib";

use LWP::Simple;
use HTTP::Cache::Transparent;
use Google::ProtocolBuffers;
use File::Path qw(make_path);
use POSIX qw(strftime);
use File::Basename qw(dirname);
use JSON qw(-convert_blessed_universally);
use YAML::Syck;
use Data::Dumper;
use Errno qw(EEXIST);
use File::Spec::Functions qw(abs2rel);
use POSIX qw(uname);

BEGIN {
    # in osx you may have to run: cpan Crypt::SSLeay and do other
    # things
    my ($uname) = uname();
    if ($uname =~ m{^Darwin}) {
	my $ca_file = "/usr/local/opt/curl-ca-bundle/share/ca-bundle.crt";
	if (-e $ca_file) {
	    $ENV{HTTPS_CA_FILE} = $ca_file;
	} else {
	    warn(<<"END");

Looks like you are using a Mac.  You should run:
    brew install curl-ca-bundle.
You may also need to run:
    sudo cpan Crypt::SSLeay

END
	    exit(1);
	}
    }
}

sub new {
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->init() if $self->can('init');
    return $self;
}

sub cache_set {
    my ($self, %args) = @_;
    my $cache_options = $self->{cache_options} //=
      { BasePath => "$ENV{HOME}/.http-cache-transparent",
	Verbose => 1,
	NoUpdate => 30,
	NoUpdateUseMtime => 1 };
    %$cache_options = (%$cache_options, %args);
    HTTP::Cache::Transparent::init($cache_options);
}

sub init {
    my ($self) = @_;

    $self->cache_set();
    $self->{ua} = LWP::UserAgent->new();

    $self->{gtfs_realtime_proto}   = "https://developers.google.com/transit/gtfs-realtime/gtfs-realtime.proto";
    $self->pull_protocol();

    $self->{my_cache}              = "$ENV{HOME}/.my-gtfs-realtime-data/cache";
    make_path($self->{my_cache});

    $self->{feed_types} = [ qw(alerts
			       realtime_feed
			       trip_updates
			       vehicle_positions) ];
    $self->{feed_urls}  = { qw(alerts             http://googletransit.ridetarc.org/realtime/alerts/Alerts.pb
			       realtime_feed      http://googletransit.ridetarc.org/realtime/gtfs-realtime/TrapezeRealTimeFeed.pb
			       trip_updates       http://googletransit.ridetarc.org/realtime/trip_update/TripUpdates.pb
			       vehicle_positions  http://googletransit.ridetarc.org/realtime/vehicle/VehiclePositions.pb) };
    $self->init_converters();
}

sub init_converters {
    my ($self) = @_;
    my $json = JSON->new()->allow_nonref()->pretty()->convert_blessed();
    $self->{output_formats} = [ qw(json yaml dumper) ]; 
    $self->{output_converters} = {
	"json" => { 
	    # "code" => sub { ... },
	    "ext"  => "json"
	},
	"yaml" => {
	    # "code" => sub { ... },
	    "ext"  => "yaml"
	},
	"dumper" => {
	    # "code" => sub { ... },
	    "ext"  => "dumper"
	},
    };
}

sub pull_protocol {
    my ($self) = @_;
    $self->cache_set(NoUpdate => 86400, NoUpdateUseMtime => 0);
    my $request = HTTP::Request->new("GET", $self->{gtfs_realtime_proto});
    my $response = $self->{ua}->request($request);
    if (!$response->is_success()) {
	warn(sprintf("Failed to pull protocol: %s\n", $response->status_line()));
	exit(1);
    }
    my $proto = $response->content();
    if (!defined $proto) {
	die("Failed to pull protocol: undefined content\n");
    }
    if (!$proto) {
	die("Failed to pull protocol: no content\n");
    }
    Google::ProtocolBuffers->parse($proto);
}

sub test {
    my ($self) = @_;
    $self->cache_set(NoUpdate => 30, NoUpdateUseMtime => 1);
    warn(sprintf("Current time: %d %s\n", time(), scalar(localtime())));
    my $request = HTTP::Request->new("GET", $self->{feed_urls}->{vehicle_positions});
    my $response = $self->{ua}->request($request);
}

sub pull {
    my ($self) = @_;

    my @feed_types = @{$self->{feed_types}};

    my $make_hash_by_feed_type = sub {
	my ($sub) = @_;
	return map { ($_ => &$sub()) } @feed_types;
    };
    my %req = $make_hash_by_feed_type->(sub { HTTP::Request->new("GET", $self->{feed_urls}->{$_}) });
    $self->cache_set(NoUpdate => 30, NoUpdateUseMtime => 1);
    my %res = $make_hash_by_feed_type->(sub { $self->{ua}->request($req{$_}) });
    my @failures = grep { !$_->is_success() } values %res;
    if (scalar(@failures)) {
	warn(sprintf("FAIL: %s => %s\n", $_->request()->uri(), $_->status_line())) foreach @failures;
	exit(1);
    }

    my %pb = $make_hash_by_feed_type->(sub { $res{$_}->content() });
    my %lm = $make_hash_by_feed_type->(sub { $res{$_}->last_modified() });
    my %ts = $make_hash_by_feed_type->(sub { strftime("%Y/%m/%d/%H%M%SZ", gmtime($lm{$_})) });

    warn("Decoding ...\n");
    my %message_object = $make_hash_by_feed_type->(sub { TransitRealtime::FeedMessage->decode($pb{$_}) });

    my %filename;
    my %latest;

    # write .pb files

    $filename{pb}   = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/pb/%s.pb",     $self->{my_cache}, $_, $ts{$_}) }) };
    $latest{pb}     = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/pb/latest.pb", $self->{my_cache}, $_         ) }) };

    foreach my $feed_type (@feed_types) {
	_file_put_contents($filename{pb}{$feed_type}, $pb{$feed_type});
    }

    # convert to other formats and write them

    my @output_formats = @{$self->{output_formats}};
    foreach my $output_format (@output_formats) {
	my $converter = $self->{output_converters}->{$output_format};
	$filename{$output_format} = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/%s/%s.%s",     $self->{my_cache}, $_, $output_format, $ts{$_}, $converter->{ext}) }) };
	$latest{$output_format}   = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/%s/latest.%s", $self->{my_cache}, $_, $output_format,          $converter->{ext}) }) };
    }

    my $json = JSON->new()->allow_nonref()->pretty()->convert_blessed();

    my $output_formats = _join_and(@output_formats);
    warn("Encoding $output_formats ...\n");
    my %encoded;
    $encoded{json}   = { $make_hash_by_feed_type->(sub { $json->encode($message_object{$_}) }) };
    $encoded{yaml}   = { $make_hash_by_feed_type->(sub { YAML::Syck::Dump($message_object{$_}) }) };
    $encoded{dumper} = { $make_hash_by_feed_type->(sub { Data::Dumper::Dumper($message_object{$_}) }) };
    foreach my $feed_type (@feed_types) {
	foreach my $output_format (@output_formats) {
	    _file_put_contents($filename{$output_format}{$feed_type}, $encoded{$output_format}{$feed_type});
	}
    }

    # create symlinks

    warn("Creating symbolic links ...\n");
    foreach my $output_format (@output_formats, "pb") {
	foreach my $feed_type (@feed_types) {
	    my ($source, $dest) = ($filename{$output_format}{$feed_type}, $latest{$output_format}{$feed_type});
	    _symlink($source, $dest);
	}
    }

    # /home/dembry/.my-gtfs-realtime-data/cache/FEED_TYPE/OUTPUT_FORMAT/YYYY/MM/DD/HHMMSSZ.EXT

    # warn("Wildcards:\n");
    # foreach my $output_format (@output_formats, "pb") {
    # 	my $converter = $self->{output_converters}->{$output_format};
    # 	warn(sprintf("  %s/%s/%s/%s.%s\n", $self->{my_cache}, "*",        $output_format, "*/*/*/*", $converter->{ext}));
    # }
    # foreach my $feed_type (@feed_types) {
    # 	warn(sprintf("  %s/%s/%s/%s.%s\n", $self->{my_cache}, $feed_type, "*",            "*/*/*/*", "*"));
    # }
}

sub _symlink {
    my ($source, $dest) = @_;
    if (!-e $source) {
	warn("  not creating link $dest: $source does not exist\n");
	return;
    }
    if (!symlink($source, $dest)) {
	if ($!{EEXIST}) {
	    if (!unlink($dest)) {
		warn("  cannot unlink $dest: $!\n");
		return;
	    }
	    if (!symlink($source, $dest)) {
		warn("  cannot symlink $source as $dest: $!\n");
		return;
	    }
	}
    }
    my $rel_source = abs2rel($source, dirname($dest));
    warn(sprintf("  Created symlink to %-27s: %s\n", $rel_source, $dest)); # assuming max 8 chars. extension
}

BEGIN {
    my $h = select(STDERR);
    $| = 1;
    select($h);
}

sub _file_put_contents {
    my ($filename, $data, $mode) = @_;
    make_path(dirname($filename));
    open(my $fh, ">", $filename) or do {
	warn("  cannot write $filename: $!\n");
	return;
    };
    printf STDERR ("  Writing %s (%d bytes) ... ", $filename, length($data));
    if (defined $mode && $mode eq "b") {
	binmode($fh);
    }
    print $fh $data;
    print STDERR ("Done.\n");
}

sub _join_and {
    my @items = @_;
    if (scalar(@items) == 2) {
	return join(" and ", @items);
    } elsif (scalar(@items) > 2) {
	my $last = pop(@items);
	return join(", ", @items) . ", and " . $last;
    } else {
	return join(" ", @items);
    }
}

1;
