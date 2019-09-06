package Geo::MapMaker::OSM::Object;
use warnings;
use strict;
use v5.10.0;

use Sort::Naturally qw(nsort);

sub new {
    my ($class, $self) = @_;
    $self ||= {};
    bless($self, $class);
    return $self;
}

sub convert_tags {
    my ($self) = @_;
    return if $self->{tags} || $self->{index};
    $self->{tags} = {};
    $self->{index} = {};
    foreach my $tag (@{$self->{tag}}) {
        my $k = $tag->{-k};
        my $v = $tag->{-v};
        $self->{tags}->{$k} = $v;
        $self->{index}->{$k} = 1; # incase of tags: { k: '...' } in a layer.
        if (defined $v && $v ne '') {
            $self->{index}->{$k,$v} = 1;
        }
    }
    delete $self->{tag};
}

# can be checked on all objects
sub is_multipolygon_relation {
    my $self = shift;
    return $self->isa('Geo::MapMaker::OSM::Relation') &&
        defined $self->{tags}->{type} &&
        $self->{tags}->{type} eq 'multipolygon';
}

sub css_id {
    my ($self, %args) = @_;
    my $result = '';
    if ($self->isa('Geo::MapMaker::OSM::Node')) {
        $result .= 'osm-node-';
    } elsif ($self->isa('Geo::MapMaker::OSM::Way')) {
        $result .= 'osm-way-';
    } elsif ($self->isa('Geo::MapMaker::OSM::Relation')) {
        $result .= 'osm-relation-';
    } else {
        $result .= 'osm-object-';
    }
    $result .= $self->{-id};
    return $result;
}

sub css_class_suffix {
    my ($self) = @_;
    return '';
}

# https://wiki.openstreetmap.org/wiki/Map_Features

our $EXCLUDE_TAG_NAMES = {
    name          => 1,
    created_by    => 1,
    ref           => 1,
    int_name      => 1,
    loc_name      => 1,
    nat_name      => 1,
    official_name => 1,
    old_name      => 1,
    reg_name      => 1,
    short_name    => 1,
    sorting_name  => 1,
    alt_name      => 1,
};

our @EXCLUDE_TAG_NAMES = [
    qr{:},
    qr{^name_\d+$},
];

our $TAG_NAME_WHITELIST = {
    aerialway        => 1,
    aeroway          => 1,
    amenity          => 1,
    barrier          => 1,
    boundary         => 1,
    building         => 1,
    craft            => 1,
    emergency        => 1,
    geological       => 1,
    highway          => 1,
    sidewalk         => 1,
    cycleway         => 1,
    busway           => 1,
    historic         => 1,
    landuse          => 1,
    leisure          => 1,
    man_made         => 1,
    military         => 1,
    natural          => 1,
    office           => 1,
    place            => 1,
    power            => 1,
    public_transport => 1,
    railway          => 1,
    electrified      => 1,
    embedded_rails   => 1,
    service          => 1,
    usage            => 1,
    route            => 1,
    shop             => 1,
    sport            => 1,
    telecom          => 1,
    tourism          => 1,
    waterway         => 1,
};

our $TAG_NAME_VALUE_WHITELIST = {
    'line=busbar'    => 1,
    'line=bay'       => 1,
    'bridge=yes'     => 1,
    'cutting=yes'    => 1,
    'embankment=yes' => 1,
    'tunnel=yes'     => 1,
};

sub css_classes {
    my ($self, %args) = @_;
    say "A: @_";
    my @css_classes = ();
  tag:
    foreach my $k (nsort keys %{$self->{tags}}) {
        foreach my $t (@EXCLUDE_TAG_NAMES) {
            next tag if ref $t eq 'Regexp' && $k =~ $t;
        }
        next if $EXCLUDE_TAG_NAMES->{$k};
        my $v = $self->{tags}->{$k};
        next unless $TAG_NAME_WHITELIST->{$k} || $TAG_NAME_VALUE_WHITELIST->{"${k}=${v}"};
        push(@css_classes, "${k}-${v}");
    }
    my $layer = $args{layer};

    say "K: ", join(' ', keys %args);
    say "L: ", $layer;
    say "C: ", $layer->{class};

    if ($layer) {
        my $class = $layer->{class};
        if ($class) {
            my @class = $self->split_css_class($class);
            push(@css_classes, @class);
        }
    }
    return @css_classes;
}

sub css_class_string {
    my ($self, %args) = @_;
    my $layer = $args{layer};

    say "K: ", join(' ', keys %args);
    say "L: ", $layer;
    say "C: ", $layer->{class};

    my @css_classes = $self->css_classes(%args);
    my $css_class_string = $self->join_css_class(@css_classes);
    return $css_class_string;
}

sub escape_css_class_name {
    my ($self, $class_name) = @_;
    return unless defined $class_name;
    $class_name =~ s{[ -\,\.\/\:-\@\[-\^\`\{-~]}
                    {'\\' . $&}gex;
    $class_name =~ s{[\t\r\n\v\f]}
                    {'\\' . sprintf('%06x', ord($&)) . ' '}gex;
    return $class_name;
}

sub split_css_class {
    my ($self, $class) = @_;
    $class =~ s{^\s+}{};
    $class =~ s{\s+$}{};
    $class =~ s{\s+}{ }g;
    return split(' ', $class);
}

sub join_css_class {
    my ($self, @class) = @_;
    return join(' ', @class);
}

1;
