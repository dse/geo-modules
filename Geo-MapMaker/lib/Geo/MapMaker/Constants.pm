package Geo::MapMaker::Constants;
use warnings;
use strict;

use base qw(Exporter);
use Exporter;

our @EXPORT_OK = qw(FALSE
                    TRUE
                    POINT_X
                    POINT_Y
                    POINT_X_ZONE
                    POINT_Y_ZONE
                    LOG_ERROR
                    LOG_WARN
                    LOG_INFO
                    LOG_DEBUG
                    $EXCLUDE_TAG_NAMES
                    @EXCLUDE_TAG_NAMES
                    $TAG_NAME_WHITELIST
                    $TAG_NAME_VALUE_WHITELIST);

our %EXPORT_TAGS = (
    tags    => [qw($EXCLUDE_TAG_NAMES
                   @EXCLUDE_TAG_NAMES
                   $TAG_NAME_WHITELIST
                   $TAG_NAME_VALUE_WHITELIST)],
    log     => [qw(LOG_ERROR
                   LOG_WARN
                   LOG_INFO
                   LOG_DEBUG)],
    point   => [qw(POINT_X
                   POINT_Y
                   POINT_X_ZONE
                   POINT_Y_ZONE)],
    boolean => [qw(FALSE
                   TRUE)],
    all     => [qw(FALSE
                   TRUE
                   POINT_X
                   POINT_Y
                   POINT_X_ZONE
                   POINT_Y_ZONE
                   LOG_ERROR
                   LOG_WARN
                   LOG_INFO
                   LOG_DEBUG
                   $EXCLUDE_TAG_NAMES
                   @EXCLUDE_TAG_NAMES
                   $TAG_NAME_WHITELIST
                   $TAG_NAME_VALUE_WHITELIST)],
);

use constant FALSE => 0;
use constant TRUE  => 1;

use constant POINT_X => 0;
use constant POINT_Y => 1;
use constant POINT_X_ZONE => 2;
use constant POINT_Y_ZONE => 3;

use constant LOG_ERROR => 0;
use constant LOG_WARN  => 1;
use constant LOG_INFO  => 2;
use constant LOG_DEBUG => 3;

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
    website       => 1,
    phone         => 1,
    start_date    => 1,
    repeat_on     => 1,
    opening_hours => 1,
    ele           => 1,
    FIXME         => 1,
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

1;
