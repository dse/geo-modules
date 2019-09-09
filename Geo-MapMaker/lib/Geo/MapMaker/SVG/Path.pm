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

sub stitch_polylines {
    my ($self) = @_;
    my %stitch_forward;
    my %self_closing;

    my $polyline_count = scalar @{$self->{polylines}};

    # determine which polylines self-close
    for (my $i = 0; $i < $polyline_count; $i += 1) {
        my $polyline_i = $self->{polylines}->[$i];
        if ($polyline_i->is_self_closing()) {
            $self_closing{$i} = 1;
        }
    }

    # determine which polylines connect (including with themselves)
    for (my $i = 0; $i < $polyline_count; $i += 1) {
        my $polyline_i = $self->{polylines}->[$i];
        for (my $j = 0; $j < $polyline_count; $j += 1) {
            my $polyline_j = $self->{polylines}->[$j];
            my $point_i = $polyline_i->{points}->[-1];
            my $point_j = $polyline_j->{points}->[0];
            if ($point_i->is_at($point_j)) {
                if (exists $stitch_forward{$i}) {
                    # no more than two polylines may share an endpoint
                    return 0;
                }
                $stitch_forward{$i} = $j;
            }
        }
    }

    my $stitch_count;
    do {
        $stitch_count = 0;
        for (my $i = 0; $i < $polyline_count; $i += 1) {
            next if $self_closing{$i};
            my $j = delete $stitch_forward{$i};
            next if !defined $j;
            my $polyline_i = $self->{polylines}->[$i];
            my $polyline_j = $self->{polylines}->[$j];
            next if !$polyline_i || !$polyline_j;

            my @points = $polyline_j->points;
            splice(@points, 0, 1);
            $polyline_i->add_points(@points);
            $self->{polylines}->[$j] = undef;
            $stitch_count += 1;

            if ($polyline_i->is_self_closing()) {
                $self_closing{$i} = 1;
            }
        }
    } while ($stitch_count);

    @{$self->{polylines}} = grep { $_ } @{$self->{polylines}};

    return 1;
}

1;
