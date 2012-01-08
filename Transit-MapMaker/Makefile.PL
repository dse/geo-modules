use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Transit::MapMaker',
    AUTHOR              => 'Darren Embry <dse@webonastick.com>',
    VERSION_FROM        => 'lib/Transit/MapMaker.pm',
    ABSTRACT_FROM       => 'lib/Transit/MapMaker.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Transit-MapMaker-*' },
);
