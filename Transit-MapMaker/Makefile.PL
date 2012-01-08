use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Transit::GTFS',
    AUTHOR              => 'Darren Embry <dse@webonastick.com>',
    VERSION_FROM        => 'lib/Transit/GTFS.pm',
    ABSTRACT_FROM       => 'lib/Transit/GTFS.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Transit-GTFS-*' },
);
