package Geo::MapMaker::OSM::Collection;
use warnings;
use strict;
use v5.10.0;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";

use fields qw(array hash override_on_add);

sub new {
    my $class = shift;
    my $self = fields::new($class);
    $self->{array} = [];
    $self->{hash}  = {};
    $self->add(@_);
    return $self;
}

sub clear {
    my ($self) = @_;
    @{$self->{array}} = ();
    %{$self->{hash}}  = ();
}

sub add {
    my ($self, @objects) = @_;
    foreach my $object (@objects) {
        next unless eval { $object->isa('Geo::MapMaker::OSM::Object') };
        my $id = $object->{-id};
        if (exists $self->{hash}->{$id}) {
            $self->{hash}->{$id} = $object if $self->{override_on_add};
        } else {
            push(@{$self->{array}}, $object);
            $self->{hash}->{$id} = $object;
        }
    }
}

sub ids {
    my ($self) = @_;
    return map { $_->{-id} } @{$self->{array}};
}

sub objects {
    my ($self) = @_;
    return @{$self->{array}};
}

sub count {
    my ($self) = @_;
    return scalar @{$self->{array}};
}

sub get {
    my ($self, $id) = @_;
    return $self->{hash}->{$id};
}

sub has {
    my ($self, $id) = @_;
    return exists $self->{hash}->{$id};
}

sub override_on_add {
    my $self = shift;
    return $self->{override_on_add} if !scalar @_;
    return $self->{override_on_add} = shift;
}

1;
