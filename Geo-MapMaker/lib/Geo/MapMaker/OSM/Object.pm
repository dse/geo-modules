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

1;
