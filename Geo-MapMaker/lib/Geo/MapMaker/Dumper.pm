package Geo::MapMaker::Dumper;
use warnings;
use strict;
use v5.10.0;

use Exporter;
use base 'Exporter';

our @EXPORT = qw();
our @EXPORT_OK = qw(Dumper);

use Data::Dumper qw();
use Sort::Naturally qw(nsort);
use List::Util qw(max);

our $IndentStyle   = 1;
our $SettingsByKey = {};
our $LinePrefix    = '';
our $AppendNewline = 1;

=head1 $Geo::MapMaker::Dumper::IndentStyle

    local $Geo::MapMaker::Dumper::IndentStyle = 0;
    # [ a, b, c ]
    # [ a,
    #   b,
    #   c ]
    # [
    #     a,
    #     b,
    #     c
    # ]

    local $Geo::MapMaker::Dumper::IndentStyle = 1;
    local $Geo::MapMaker::Dumper::IndentStyle = 2;

=head1 $Geo::MapMaker::Dumper::SettingsByKey

    local $Geo::MapMaker::Dumper::SettingsByKey = {
        'member' => {
            IndentStyle => 0
        }
    };

=cut

sub Dumper {
    my $o = shift;
    my $result;
    {
        local $Data::Dumper::Indent   = 1;
        local $Data::Dumper::Terse    = 1;
        local $Data::Dumper::Deepcopy = 1;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Useqq    = 1;
        local $AppendNewline          = 0;
        if (!ref $o) {
            $result = Data::Dumper::Dumper($o);
        } elsif (ref $o eq 'HASH') {
            $result = HashDumper($o);
        } elsif (ref $o eq 'ARRAY') {
            $result = ArrayDumper($o);
        } else {
            $result = Data::Dumper::Dumper($o);
        }
    }
    $result =~ s{[\s\r\n]+\z}{};
    if ($AppendNewline) {
        $result .= "\n";
    }
    return $result;
}

sub ArrayDumper {
    my $o = shift;
    my $result = '';
    if ($IndentStyle == 0) {
        $result .= "[";
        my $first = 1;
        foreach my $v (@$o) {
            if ($first) {
                $result .= " ";
            } else {
                $result .= ", ";
            }
            $result .= Dumper($v);
            $first = 0;
        }
        $result .= " ]";
        return $result;
    }
    if ($IndentStyle == 1) {
        $result .= "[";
        {
            local $LinePrefix = $LinePrefix . '  ';
            my $first = 1;
            foreach my $v (@$o) {
                if ($first) {
                    $result .= " ";
                } else {
                    $result .= ",\n" . $LinePrefix;
                }
                $result .= Dumper($v);
                $first = 0;
            }
        }
        $result .= " ]";
        return $result;
    }
    if ($IndentStyle == 2) {
        $result .= "[";
        {
            local $LinePrefix = $LinePrefix . '    ';
            my $first = 1;
            foreach my $v (@$o) {
                if ($first) {
                    $result .= "\n" . $LinePrefix;
                } else {
                    $result .= ",\n" . $LinePrefix;
                }
                $result .= Dumper($v);
                $first = 0;
            }
        }
        $result .= "\n" . $LinePrefix . "]";
        return $result;
    }
}

sub HashDumper {
    my $o = shift;
    my @k = nsort keys %$o;
    my %k = map { ($_ => Dumper($_)) } keys %$o;
    my $result = '';
    if ($IndentStyle == 0) {
        $result .= "{";
        my $first = 1;
        foreach my $k (@k) {
            my $kk = $k{$k};
            my $v = $o->{$k};
            if ($first) {
                $result .= " ";
            } else {
                $result .= ", ";
            }
            $result .= $kk . " => " . Dumper($v);
            $first = 0;
        }
        $result .= "}";
        return $result;
    }
    if ($IndentStyle == 1) {
        $result .= "{";
        {
            local $LinePrefix = $LinePrefix . '  ';
            my $first = 1;
            foreach my $k (@k) {
                my $kk = $k{$k};
                my $v = $o->{$k};
                if ($first) {
                    $result .= " ";
                } else {
                    $result .= ",\n" . $LinePrefix;
                }
                local $LinePrefix = $LinePrefix . (' ' x (4 + length($kk)));
                $result .= $kk . " => " . Dumper($v);
                $first = 0;
            }
        }
        $result .= " }";
        return $result;
    }
    if ($IndentStyle == 2) {
        $result .= "{";
        {
            local $LinePrefix = $LinePrefix . '    ';
            my $first = 1;
            foreach my $k (@k) {
                my $kk = $k{$k};
                my $v = $o->{$k};
                if ($first) {
                    $result .= "\n" . $LinePrefix;
                } else {
                    $result .= ",\n" . $LinePrefix;
                }
                $result .= $kk . " => " . Dumper($v);
                $first = 0;
            }
        }
        $result .= "\n" . $LinePrefix . "}";
        return $result;
    }
}

1;
