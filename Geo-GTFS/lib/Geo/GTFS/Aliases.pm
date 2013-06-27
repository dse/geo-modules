package Geo::GTFS::Aliases;
use warnings;
use strict;
use YAML qw(LoadFile DumpFile Load Dump);

# we do our best here to prevent multiple objects sharing a single
# file.
our $single_object = {};

sub new {
	my ($class, %args) = @_;
	%args = (
		 filename  => "$ENV{HOME}/.geo-gtfs/aliases",
		 url_regex => qr{^(https?|ftp)://},
		 %args
		);
	my $filename = $args{filename};

	return $single_object->{$filename}
		if exists $single_object->{$filename};

	my $self = bless(\%args, $class);
	$self->init_rc();
	return $self;
}

sub init_rc {
	my ($self) = @_;
	my $filename = $self->{filename};
	if (-e $filename) {
		$self->{aliases} = LoadFile($filename);
	} else {
		$self->{aliases} = {};
	}
	$self->{dirty} = 0;
}

sub save_rc {
	my ($self) = @_;
	my $filename = $self->{filename};
	eval { make_path(dirname($filename)); };
	if ($filename && $self->{dirty}) {
		DumpFile($filename, $self->{aliases});
	}
}

sub list {
	my ($self) = @_;
	foreach my $alias (sort keys(%{$self->{aliases}})) {
		my $url = $self->{aliases}->{$alias};
		printf("%-16s => %s\n", $alias, $url);
	}
}

sub dump {
	my ($self) = @_;
	print Dump($self->{aliases});
}

sub add {
	my ($self, @args) = @_;
	my $url_regex = $self->{url_regex};
	my @url     = grep { $_ =~ $url_regex } @args;
	my @aliases = grep { $_ !~ $url_regex } @args;
	if (!@url) {
		die("$0: you must specify one URL when adding one or more aliases.");
	} elsif (scalar(@url) > 1) {
		die("$0: you must specify one URL when adding one or more aliases.");
	}
	if (!@aliases) {
		die("$0: you must specify at least one alias name.");
	}
	my ($url) = @url;
	foreach my $alias (@aliases) {
		$self->{aliases}->{$alias} = $url;
		$self->{dirty} = 1;
	}
}

sub delete {
	my ($self, @args) = @_;
	foreach my $arg (@args) {
		if (exists $self->{aliases}->{$arg}) {
			delete $self->{aliases}->{$arg};
			$self->{dirty} = 1;
		}
	}
}

sub DESTROY {
	my ($self) = @_;
	$self->save_rc();
}

sub resolve {
	my ($self, $url_or_alias) = @_;
	my $alias;
	my $url;
	if ($url_or_alias =~ $self->{url_regex}) {
		$url = $url_or_alias;
	} else {
		$alias = $url_or_alias;
		$url = $self->{aliases}->{$alias};
		if (!$url) {
			die("$0: '$url_or_alias' is neither an alias nor a URL.");
		}
	}
	return ($url, $alias) if wantarray;
	return $url;
}

sub reverse_lookup {
	my ($self, $url) = @_;
	
}

1;

