package Geo::MapMaker::OSM::Object;
use warnings;
use strict;
use v5.10.0;

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
    my $map_area = $args{map_area};
    my $result = '';
    if ($map_area) {
        $result .= $map_area->{id_prefix};
    }
    if ($self->isa('Geo::MapMaker::OSM::Node')) {
        $result .= 'n';
    } elsif ($self->isa('Geo::MapMaker::OSM::Way')) {
        $result .= 'w';
    } elsif ($self->isa('Geo::MapMaker::OSM::Relation')) {
        $result .= 'r';
    } else {
        $result .= 'o';
    }
    $result .= $self->{-id};
    return $result;
}

sub css_class_suffix {
    my ($self) = @_;
    return '';
}

1;
