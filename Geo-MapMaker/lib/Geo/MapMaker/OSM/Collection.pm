package Geo::MapMaker::OSM::Collection;
use warnings;
use strict;
use v5.10.0;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";

use fields qw(array hash index);

sub new {
    my $class = shift;
    my $self = fields::new($class);
    $self->{array} = [];
    $self->{hash}  = {};
    $self->{index} = {};
    $self->add(@_) if scalar @_;
    return $self;
}

sub clear {
    my ($self) = @_;
    @{$self->{array}} = ();
    %{$self->{hash}}  = ();
    %{$self->{index}} = ();
}

sub add {
    my ($self, @objects) = @_;
    foreach my $object (@objects) {
        next unless eval { $object->isa('Geo::MapMaker::OSM::Object') };
        my $id = $object->{-id};
        if (exists $self->{hash}->{$id}) {
            my $existing_object = $self->{hash}->{$id};
            # We might replace this code with smarter code for
            # existing what's in the new object we're passing to this
            # method, into the existing object.
            foreach my $key (qw(used)) {
                if (exists $object->{$key}) {
                    $existing_object->{$key} = $object->{$key};
                }
            }
            next;
        }
        my $index = scalar @{$self->{array}};
        push(@{$self->{array}}, $object);
        $self->{hash}->{$id} = $object;
        $self->{index}->{$id} = $index;
    }
}

sub add_override {
    my ($self, @objects) = @_;
    foreach my $object (@objects) {
        next unless eval { $object->isa('Geo::MapMaker::OSM::Object') };
        my $id = $object->{-id};
        if (exists $self->{hash}->{$id}) {
            my $index = $self->{index}->{$id};
            $self->{hash}->{$id} = $object;
            $self->{array}->[$index] = $object;
            next;
        }
        my $index = scalar @{$self->{array}};
        push(@{$self->{array}}, $object);
        $self->{hash}->{$id} = $object;
        $self->{index}->{$id} = $index;
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

1;
