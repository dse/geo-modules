package Geo::MapMaker::SVG::Path;
use warnings;
use strict;
use v5.10.0;

use fields qw(polylines);

sub new {
    my $class = shift;
    my $self = fields::new($class);
    $self->{polylines} = [];
    if (scalar @_ == 0) {
        return $self;
    }
    if (scalar @_ == 1 && ref $_->[0] eq __PACKAGE__) {
        @{$self->{polylines}} = @{$_->[0]->{polylines}};
        return $self;
    }
    foreach my $polyline (@_) {
        push(@{$self->{polylines}}, Geo::MapMaker::SVG::PolyLine->object($polyline));
    }
    return $self;
}

sub object {
    my $class = shift;
    return $_[0] if scalar @_ == 1 && eval { $_[0]->isa(__PACKAGE__) };
    return $class->new(@_);
}

sub add { goto &add_polylines; }

sub add_polylines {
    my $self = shift;
    foreach my $polyline (@_) {
        push(@{$self->{polylines}}, Geo::MapMaker::SVG::PolyLine->object($polyline));
    }
}

sub add_polyline {
    my $self = shift;
    push(@{$self->{polylines}}, Geo::MapMaker::SVG::PolyLine->object(@_));
}

sub clear {
    my ($self) = @_;
    @{$self->{polylines}} = [];
}

sub polylines {
    my $self = shift;
    if (scalar @_) {
        @{$self->{polylines}} = @_;
    }
    return @{$self->{polylines}} if wantarray;
    return $self->{polylines};
}

sub as_string {
    my ($self, %args) = @_;
    my $count = scalar @{$self->{polylines}};
    my $is_only = ($count == 1);
    my @result;
    for (my $i = 0; $i < $count; $i += 1) {
        my $polyline = $self->{polylines}->[$i];
        my $is_first = ($i == 0);
        push(@result, $polyline->as_string(is_first => $is_first,
                                           is_only => $is_only));
    }
    my $result = join(' ', @result);
    return $result;
}

1;
