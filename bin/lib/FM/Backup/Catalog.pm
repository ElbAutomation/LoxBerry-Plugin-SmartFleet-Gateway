# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Catalog;

use strict;
use warnings;

use constant DEFAULT_SCOPE => { system => 1, stats => 0, logs => 0 };

sub scope_dirs {
    my ($scope) = @_;
    $scope = {} if !$scope || ref($scope) ne 'HASH';

    my @dirs = ('/prog', '/sys', '/user', '/web');
    push @dirs, '/stats' if $scope->{stats};
    push @dirs, '/log'   if $scope->{logs};

    my @sortiert = sort @dirs;
    return \@sortiert;
}

sub excluded {
    my ($pfad) = @_;
    return 1 if !defined $pfad || $pfad eq '';

    return 1 if $pfad =~ m{^/prog/Default[^/]*\.Loxone$};

    return 1 if $pfad =~ m{^/sys/addons(?:/|$)};

    return 1 if $pfad =~ m{^/sys/rem(?:/|$)};

    return 1 if $pfad =~ m{^/sys/remoteconnect(?:/|$)};

    return 1 if $pfad eq '/sys/Secret.txt';
    return 1 if $pfad eq '/sys/Sizes.bin';
    return 1 if $pfad eq '/sys/UpdateInfo.xml';
    return 1 if $pfad eq '/sys/addons.json';
    return 1 if $pfad eq '/sys/links.txt';
    return 1 if $pfad eq '/sys/monitor.json';
    return 1 if $pfad =~ m{^/sys/ap_(control|sections)[^/]*\.json$};

    return 1 if $pfad =~ m{^/sys/internal(?:/|$)};

    return 1 if $pfad eq '/sys/tokens.xml';

    return 1 if $pfad =~ m{^/sys/sys_[^/]*\.zip$};        # Sprachpakete
    return 1 if $pfad =~ m{^/sys/licenses[^/]*\.txt$};    # Lizenztexte
    return 1 if $pfad eq '/sys/timezones.txt';
    return 1 if $pfad eq '/sys/times.bin';
    return 1 if $pfad eq '/sys/trusts/trusts.json';

    return 1 if $pfad eq '/web/commonv2.agz';
    return 1 if $pfad eq '/web/robots.txt';
    return 1 if $pfad eq '/web/data/weatheru.bin';
    return 1 if $pfad =~ m{^/web/stats(?:/|$)};

    return 0;
}

1;

