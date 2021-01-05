package App::TimeTracker::Utils;

# ABSTRACT: Utility Methods/Functions for App::TimeTracker
# VERSION

use strict;
use warnings;
use 5.010;

use Scalar::Util qw(blessed);
use Term::ANSIColor;
use Exporter;
use parent qw(Exporter);

our @EXPORT      = qw();
our @EXPORT_OK   = qw(pretty_date now error_message warning_message);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

sub error_message {
    _message( 'bold red', @_ );
}

sub warning_message {
    _message( 'bold yellow', @_ );
}

sub _message {
    my ( $color, $message, @params ) = @_;

    my $string = sprintf( $message, @params );

    print color $color;
    print $string;
    say color 'reset';
}

sub pretty_date {
    my ($date) = @_;

    unless ( blessed $date
        && $date->isa('DateTime') )
    {
        return $date;
    }
    else {
        my $now = now();
        my $yesterday = now()->subtract( days => 1 );
        if ( $date->dmy eq $now->dmy ) {
            return $date->hms(':');
        }
        elsif ( $date->dmy eq $yesterday->dmy ) {
            return 'yesterday ' . $date->hms(':');
        }
        else {
            return $date->dmy('.') . ' ' . $date->hms(':');
        }
    }
}

sub now {
    my $dt = DateTime->now();
    $dt->set_time_zone('local');
    return $dt;
}
1;

