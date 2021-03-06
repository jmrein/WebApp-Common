package WebAppCommon::Util::FarmJobRunner;

use warnings FATAL => 'all';

use Moose;
use Moose::Util::TypeConstraints;
use MooseX::Types::Path::Class::MoreCoercions qw( File );
use MooseX::Params::Validate;

with 'MooseX::Log::Log4perl';

use Try::Tiny;
use Path::Class;
use File::Which qw( which );
use IPC::Run;
use Data::Dumper;

#all of these can be overriden per job.
has default_group => (
    is      => 'rw',
    isa     => 'Str',
    default => 'team87-grp',
);

has default_queue => (
    is      => 'rw',
    isa     => 'Str',
    default => 'normal',
);

has default_memory => (
    is      => 'rw',
    isa     => 'Num',
    default => 2000,
);

has default_processors => (
    is      => 'rw',
    isa     => 'Num',
    default => 1,
);

has bsub_wrapper => (
    is      => 'rw',
    isa     => File,
    coerce  => 1,
    default => sub{ file( '/nfs/team87/farm3_lims2_vms/conf/run_in_farm3' ) },
);

#to make testing easier
has dry_run => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0
);

#allow an array of job refs or just a single one.
subtype 'ArrayRefOfInts',
    as 'ArrayRef[Int]';

coerce 'ArrayRefOfInts',
    from 'Int',
    via { [ $_ ] };

sub submit_pspec {
    my ( $self ) = @_;

    return (
        out_file        => { isa => File, coerce => 1 },
        cmd             => { isa => 'ArrayRef' },
        # the rest are optional
        group           => { isa => 'Str', optional => 1, default => $self->default_group },
        queue           => { isa => 'Str', optional => 1, default => $self->default_queue },
        memory_required => { isa => 'Int', optional => 1, default => $self->default_memory },
        processors      => { isa => 'Int', optional => 1, default => $self->default_processors },
        err_file        => { isa => File,  optional => 1, coerce => 1 },
        dependencies    => { isa => 'ArrayRefOfInts', optional => 1, coerce => 1 },
        # these are only relevant to submit_and_wait. times are in seconds
        timeout         => { isa => 'Int', optional => 1, default => 600 },
        interval        => { isa => 'Int', optional => 1, default => 10 },
    );
}

#set all common options for bsub and run the user specified command.
sub submit {
    my ( $self ) = shift;
    my %args = validated_hash( \@_, $self->submit_pspec );

    my @bsub = (
        'bsub',
        '-q', $args{ queue },
        '-o', $args{ out_file },
        '-M', $args{ memory_required },
        '-n', $args{ processors },
        '-R',
              '"select[mem>' . $args{memory_required}
            . '] rusage[mem=' . $args{memory_required}
            . '] span[hosts=1]"',
        '-G', $args{ group },
    );

    #add the optional parameters if they're set
    if ( exists $args{ err_file } ) {
        push @bsub, ( '-e', $args{ err_file } );
    }

    if ( exists $args{ dependencies } ) {
        push @bsub, $self->_build_job_dependency( $args{ dependencies } );
    }

    #
    #TODO: add ' around cmd
    #

    #add the actual command at the very end.
    push @bsub, @{ $args{ cmd } };

    my @cmd = $self->_wrap_bsub( @bsub ); #this is the end command that will be run

    return \@cmd if $self->dry_run;

    my $output = $self->_run_cmd( @cmd );
    my ( $job_id ) = $output =~ /Job <(\d+)>/;

    return $job_id;
}

# Submit bsub command and then wait until it has finished running
# Return 1 if job finishes within timeout, otherwise return 0
sub submit_and_wait{
    my ( $self ) = shift;

    my %args = validated_hash( \@_, $self->submit_pspec );

    my $job_id = $self->submit(\%args);
    my $start = time;
    return $job_id if $self->dry_run;

    $self->log->info("Waiting for job $job_id to complete");

    my @job_status_cmd = $self->_wrap_bsub('bjobs', $job_id);

    # Run job status command every <interval> seconds until <timeout> is exceeded
    my $duration = 0;
    while($duration < $args{timeout}){
        $self->log->info("Checking job status after $duration seconds");
        my $output = $self->_run_cmd( @job_status_cmd );
        # Parse job info output like:
        # JOBID   USER    STAT  QUEUE      FROM_HOST   EXEC_HOST   JOB_NAME   SUBMIT_TIME
        # 7236539 af11    DONE  normal     farm3-head2 bc-26-1-15  *ches.json Feb 19 11:28
        my @lines = split "\n", $output;
        if(my $jobinfo = $lines[1]){
            my @info = split /\s+/, $jobinfo;
            if($info[2] eq 'DONE'){
                return 1;
            }
            elsif($info[2] ne 'PEND' and $info[2] ne 'RUN'){
                # Job has failed in some way
                return 0;
            }
        }
        sleep($args{interval});
        $duration = time - $start;
    }

    # Must have timed out so return completion status of 0
    return 0;
}

sub kill_job{
    my ($self, $job_id) = @_;

    if($job_id){
        my @cmd = $self->_wrap_bsub("bkill $job_id");

        return \@cmd if $self->dry_run;

        $self->_run_cmd( @cmd );
    }
    else{
        $self->log->info("No job ID provided to kill_job. No jobs will be killed");
    }
    return;
}

#take an array with bsub commands and produce the final command
#to give to _run_cmd
sub _wrap_bsub {
    my ( $self, @bsub ) = @_;

    #which returns undef if it cant find the file
    #which( $self->bsub_wrapper )
        #or confess "Couldn't locate " . $self->bsub_wrapper;
    my $env = $self->_work_out_env;
    my $cmd
        = 'source /etc/profile;'
        . 'source ' . $self->bsub_wrapper->stringify . " $env;"
        . join( " ", @bsub );

    return $self->_wrap_with_ssh($cmd);
}

sub _wrap_with_ssh{
    my ($self, $cmd) = @_;

    # temp wrap in ssh to farm3-login, until vms can submit to farm3 directly
    my @wrapped_cmd = ( 'ssh', '-o CheckHostIP=no', '-o BatchMode=yes', 'farm3-login');
    push @wrapped_cmd, $cmd;

    return @wrapped_cmd;
}

sub _build_job_dependency {
    my ( $self, $dependencies ) = @_;

    #make sure we got an array
    confess "_build_job_dependency expects an ArrayRef"
        unless ref $dependencies eq 'ARRAY';

    #return an empty list so nothing gets added to the bsub if we dont have any
    return () unless @{ $dependencies };

    #this creates a list of dependencies, for example 'done(12) && done(13) && done(14)'
    return ( '-w', '"' . join( " && ", map { 'done(' . $_ . ')' } @{ $dependencies } ) . '"' );
}

sub _run_cmd {
    my ( $self, @cmd ) = @_;

    my $output;

    $self->log->info("IPC Run version: ".$IPC::Run::VERSION);
    $self->log->info( "CMD: " . join(' ', @cmd) );
    try {
        IPC::Run::run( \@cmd, '<', \undef, '>&', \$output )
                or die "$output";
    }
    catch {
        confess "Output: $output \n Command failed: $_";
    };
    $self->log->info( "CMD Output: $output" );

    return $output;
}

sub _work_out_env {
    my $self = shift;
    my $env;

    my $lims2_env = $ENV{LIMS2_DB};
    my $wge_env = $ENV{WGE_DB};

    if ( $lims2_env && $wge_env ) {
        confess( 'Can not have both LIMS2_DB and WGE_DB env variables set' );
    }

    if ( $lims2_env ) {
        if ( $lims2_env eq 'LIMS2_LIVE' ) {
            return 'lims2_live';
        }
        elsif ( $lims2_env eq 'LIMS2_STAGING' ) {
            return 'lims2_staging';
        }
        elsif ( $ENV{LIMS2_REST_CLIENT_CONFIG} ) {
            return $ENV{LIMS2_REST_CLIENT_CONFIG};
        }
        else {
            confess 'For LIMS2 must be in live or staging environment, '
                . 'or else must have LIMS2_REST_CLIENT_CONFIG env variable set';
        }
    }
    elsif ( $wge_env ) {
        if ( $wge_env eq 'WGE_NEW' ) {
            return 'wge';
        }
        elsif ( $ENV{LIMS2_REST_CLIENT_CONFIG} ) {
            return $ENV{LIMS2_REST_CLIENT_CONFIG};
        }
        else {
            confess "For WGE must be in live environment, or else must have LIMS2_REST_CLIENT_CONFIG set";
        }
    }
    else {
        confess 'For LIMS2 must be in live or staging environment '
            . ', for WGE the live environment'
            . ' or for development have the LIMS2_REST_CLIENT_CONFIG env variable set';
    }

    return;
}

__PACKAGE__->meta->make_immutable;

1;

=pod

=head1 NAME

LIMS2::Util::FarmJobRunner

=head1 SYNOPSIS

  use LIMS2::Util::FarmJobRunner;

  my $runner = LIMS2::Util::FarmJobRunner->new;

  #alternatively, override default parameters:
  $runner = LIMS2::Util::FarmJobRunner->new( {
    default_queue  => "basement",
    default_memory => "3000",
    default_processors => 2,
    bsub_wrapper   => "custom_environment_setter.pl"
  } );

  #required parameters
  my $job_id = $runner->submit(
    out_file => "/nfs/users/nfs_a/ah19/bsub_output.out",
    cmd      => [ "echo", "test" ]
  );

  #all optional parameters set
  my $next_job_id = $runner->submit(
    out_file        => "/nfs/users/nfs_a/ah19/bsub_output2.out",
    err_file        => "/nfs/users/nfs_a/ah19/bsub_output2.err",
    queue           => "short",
    memory_required => 4000,
    dependencies    => $job_id,
    cmd             => [ "echo", "test" ]
  );

  #multiple dependencies
  $runner->submit(
    out_file     => "/nfs/users/nfs_a/ah19/bsub_output3.out",
    dependencies => [ $job_id, $next_job_id ],
    cmd          => [ "echo", "test" ]
  );

=head1 DESCRIPTION

NOTE: Temporary hack to get it working in farm3 ( by sshing command to farm3-login )

Helper module for running bsub jobs from LIMS2/The VMs.
Sets the appropriate environment for using our perlbrew install in /software.

The default queue is normal, and the default memory required is 2000 MB.

=head1 TODO

Write a jobarray wrapper that will take a yaml file or something, so that we can support params,
and wrap anything into a jobarray.

=head1 AUTHOR

Alex Hodgkins

=cut
