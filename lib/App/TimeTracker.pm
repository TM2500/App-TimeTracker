package App::TimeTracker;
use strict;
use warnings;
use 5.010;

our $VERSION = "2.009";
# ABSTRACT: Track time spend on projects from the commandline

use App::TimeTracker::Data::Task;

use DateTime;
use Moose;
use Moose::Util::TypeConstraints;
use Path::Class::Iterator;
use MooseX::Storage::Format::JSONpm;
use JSON::XS;

our $HOUR_RE = qr/(?<hour>[012]?\d)/;
our $MINUTE_RE = qr/(?<minute>[0-5]?\d)/;
our $DAY_RE = qr/(?<day>[0123]?\d)/;
our $MONTH_RE = qr/(?<month>[01]?\d)/;
our $YEAR_RE = qr/(?<year>2\d{3})/;

with qw(
    MooseX::Getopt
);

subtype 'TT::DateTime' => as class_type('DateTime');
subtype 'TT::RT' => as 'Int';
subtype 'TT::Duration' => as enum([qw(day week month year)]);

coerce 'TT::RT'
    => from 'Str'
    => via {
    my $raw = $_;
    $raw=~s/\D//g;
    return $raw;
};

coerce 'TT::DateTime'
    => from 'Str'
    => via {
    my $raw = $_;
    my $dt = DateTime->now;
    $dt->set_time_zone('local');

    given ($raw) {
        when(/^ $HOUR_RE : $MINUTE_RE $/x) { # "13:42"
            $dt = DateTime->today;
            $dt->set(hour=>$+{hour}, minute=>$+{minute});
        }
        when(/^ $YEAR_RE [-.]? $MONTH_RE [-.]? $DAY_RE $/x) { # "2010-02-26"
            $dt = DateTime->today;
            $dt->set(year => $+{year}, month=>$+{month}, day=>$+{day});
        }
        when(/^ $YEAR_RE [-.]? $MONTH_RE [-.]? $DAY_RE \s+ $HOUR_RE : $MINUTE_RE $/x) { # "2010-02-26 12:34"
            $dt = DateTime->new(year => $+{year}, month=>$+{month}, day=>$+{day}, hour=>$+{hour}, minute=>$+{minute});
        }
        when(/^ $DAY_RE [-.]? $MONTH_RE [-.]? $YEAR_RE $/x) { # "26-02-2010"
            $dt = DateTime->today;
            $dt->set(year => $+{year}, month=>$+{month}, day=>$+{day});
        }
        when(/^ $DAY_RE [-.]? $MONTH_RE [-.]? $YEAR_RE \s $HOUR_RE : $MINUTE_RE $/x) { # "26-02-2010 12:34"
            $dt = DateTime->new(year => $+{year}, month=>$+{month}, day=>$+{day}, hour=>$+{hour}, minute=>$+{minute});
        }
        default {
            confess "Invalid date format '$raw'";
        }
    }
    return $dt;
};

MooseX::Getopt::OptionTypeMap->add_option_type_to_map(
    'TT::DateTime' => '=s',
);
MooseX::Getopt::OptionTypeMap->add_option_type_to_map(
    'TT::RT' => '=i',
);

no Moose::Util::TypeConstraints;

has 'home' => (
    is=>'ro',
    isa=>'Path::Class::Dir',
    traits => [ 'NoGetopt' ],
    required=>1,
);
has 'config' => (
    is=>'ro',
    isa=>'HashRef',
    required=>1,
    traits => [ 'NoGetopt' ],
);
has '_current_project' => (
    is=>'ro',
    isa=>'Str',
    predicate => 'has_current_project',
    traits => [ 'NoGetopt' ],
);

has 'tags' => (
    isa=>'ArrayRef',
    is=>'ro',
    traits  => ['Array'],
    default=>sub {[]},
    handles => {
        insert_tag  => 'unshift',
        add_tag  => 'push',
    },
    documentation => 'Tags [Multiple]',
);

has '_current_command' => (
    isa=>'Str',
    is=>'rw',
    traits => [ 'NoGetopt' ],
);

has '_current_task' => (
    isa=>'App::TimeTracker::Data::Task',
    is=>'rw',
    traits => [ 'NoGetopt' ],
);

has '_previous_task' => (
    isa=>'App::TimeTracker::Data::Task',
    is=>'rw',
    traits => [ 'NoGetopt' ],
);

sub run {
    my $self = shift;
    my $command = 'cmd_'.($self->extra_argv->[0] || 'missing');

    $self->cmd_commands unless $self->can($command);
    $self->_current_command($command);
    $self->$command;
}

sub now {
    my $dt = DateTime->now();
    $dt->set_time_zone('local');
    return $dt;
}

sub beautify_seconds {
    my ( $self, $s ) = @_;
    return '0' unless $s;
    my ( $m, $h )= (0, 0);

    if ( $s >= 60 ) {
        $m = int( $s / 60 );
        $s = $s - ( $m * 60 );
    }
    if ( $m && $m >= 60 ) {
        $h = int( $m / 60 );
        $m = $m - ( $h * 60 );
    }
    return sprintf("%02d:%02d:%02d",$h,$m,$s);
}

sub find_task_files {
    my ($self, $args) = @_;

    my ($cmp_from, $cmp_to);

    if (my $from = $args->{from}) {
        my $to = $args->{to} || $self->now;
        $to->set(hour=>23,minute=>59,second=>59) unless $to->hour;
        $cmp_from = $from->strftime("%Y%m%d%H%M%S");
        $cmp_to = $to->strftime("%Y%m%d%H%M%S");
    }
    my $projects;
    if ($args->{projects}) {
        $projects = join('|',map {s/-/./g; $_} @{$args->{projects}});
    }
    my $tags;
    if ($args->{tags}) {
        $tags = join('|',@{$args->{tags}});
    }

    my @found;
    my $iterator = Path::Class::Iterator->new(
        root => $self->home,
    );
    until ($iterator->done) {
        my $file = $iterator->next;
        next unless -f $file;
        my $name = $file->basename;
        next unless $name =~/\.trc$/;

        if ($cmp_from) {
            $file =~ /(\d{8})-(\d{6})/;
            my $time = $1 . $2;
            next if $time < $cmp_from;
            next if $time > $cmp_to;
        }

        next if $projects && ! ($name ~~ /$projects/i);

        if ($tags) {
            my $raw_content = $file->slurp;
            next unless $raw_content =~ /$tags/i;
        }

        push(@found,$file);
    }
    return sort @found;
}

sub project_tree {
    my $self = shift;
    my $file = $self->home->file('projects.json');
    return unless -e $file && -s $file;
    my $projects = decode_json($file->slurp);

    my %tree;
    while (my ($project,$location) = each %$projects) {
        $tree{$project} //= {parent=>undef,childs=>{}};
        my @parts = Path::Class::file($location)->parent->parent->dir_list;
        foreach my $dir (@parts) {
            if (my $parent = $projects->{$dir}) {
                $tree{$project}->{parent} = $dir;
                $tree{$dir}->{children}{$project}=1;
            }
        }
    }
    return \%tree;
}

1;

__END__

=head1 SYNOPSIS

Backend for the C<tracker> command. See C<man tracker> and/or C<perldoc tracker> for details.

=head1 CONTRIBUTORS

Maros Kollar C<< <maros@cpan.org> >>, Klaus Ita C<< <klaus@worstofall.com> >>

=head1 INSTALLATION

=head3 From CPAN

The easiest way to install the current stable version of App::TimeTracker is via L<CPAN|http://cpan.org>. There are several different CPAN clients available:

=head4 cpanminus

The new and shiny CPAN client!

  ~$ cpanm App::TimeTracker
  --> Working on App::TimeTracker
  Fetching http://search.cpan.org/CPAN/authors/id/D/DO/DOMM/App-TimeTracker-2.009.tar.gz ... OK
  Configuring App-TimeTracker-2.009 ... OK
  Building and testing App-TimeTracker-2.009 ... OK
  Successfully installed App-TimeTracker-2.009
  1 distribution installed

If you don't have C<<cpanminus>> installed yet, install it right now.

=head4 CPANPLUS

CPANPLUS comes preinstalled with recent Perls (5.10 and newer).

  cpanp install App::TimeTracker

=head4 CPAN.pm

CPAN.pm is available on ancient Perls, and feels a bit ancient, too.

  cpanp install App::TimeTracker

=head3 From a tarball or git checkout

To install App::TimeTracker from a tarball or a git checkout, do the usual CPAN module install dance:

  ~/perl/App-TimeTracker$ perl Build.PL
  ~/perl/App-TimeTracker$ ./Build
  ~/perl/App-TimeTracker$ ./Build test
  ~/perl/App-TimeTracker$ ./Build install  # might require sudo

=head1 SOURCE CODE

=head3 git

We use C<< git >> for version control and maintain a public repository on L<github|http://github.com>.

You can find the latest version of App::TimeTracker here:

https://github.com/domm/App-TimeTracker

If you want to work on App::TimeTracker, add a feature, add a plugin or fix a bug, please feel free to L<fork|http://help.github.com/fork-a-repo/> the repo and send us L<pull requests|http://help.github.com/send-pull-requests/> to merge your changes.

To report a bug, please do not use the C<< issues >> feature from github. Use RT instead.

=head3 CPAN

App::TimeTracker is distributed via L<CPAN|http://cpan.org>, the Comprehensive Perl Archive Network. Here are a few different views into the CPAN, offering slightly different features:

=over

=item * https://metacpan.org/release/App-TimeTracker

=item * http://search.cpan.org/dist/App-TimeTracker

=back


=head1 Viewing and reporting Bugs

We use L<rt.cpan.org|http://rt.cpan.org> (thank you L<BestPractical|http://rt.bestpractical.com>) for bug reporting. Please do not use the C<issues> feature of github! We pay no attention to those...

Please use this URL to view and report bugs:

https://rt.cpan.org/Public/Dist/Display.html?Name=App-TimeTracker



