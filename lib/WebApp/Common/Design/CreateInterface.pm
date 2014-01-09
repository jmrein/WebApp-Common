package WebApp::Common::Design::CreateInterface;

use strict;
use warnings FATAL => 'all';

use Moose::Role;
use LIMS2::Exception;
use List::MoreUtils qw( uniq );
use Data::UUID;
use JSON;
use Hash::MoreUtils qw( slice_def );
use LIMS2::Util::FarmJobRunner;

requires qw(
species
ensembl_util
check_params
create_design_attempt
user
assembly_id
build_id
base_design_dir
);

=head2 get_ensembl_gene

Grab a ensembl gene object.
First need to work out format of gene name user has supplied

=cut
## no critic(BuiltinFunctions::ProhibitComplexMappings)
sub get_ensembl_gene {
    my ( $self, $gene_name ) = @_;

    my $ga = $self->ensembl_util->gene_adaptor( $self->species );

    my $gene;
    if ( $gene_name =~ /ENS(MUS)?G\d+/ ) {
        $gene = $ga->fetch_by_stable_id( $gene_name );
    }
    elsif ( $gene_name =~ /HGNC:(\d+)/ ) {
        $gene = $self->_fetch_by_external_name( $ga, $1, 'HGNC' );
    }
    elsif ( $gene_name =~ /MGI:\d+/  ) {
        $gene = $self->_fetch_by_external_name( $ga, $gene_name, 'MGI' );
    }
    else {
        #assume its a marker symbol
        $gene = $self->_fetch_by_external_name( $ga, $gene_name );
    }

    return $gene;
}
## use critic

=head2 _fetch_by_external_name

Wrapper around fetching ensembl gene given external gene name.

=cut
sub _fetch_by_external_name {
    my ( $self, $ga, $gene_name, $type ) = @_;

    my @genes = @{ $ga->fetch_all_by_external_name($gene_name, $type) };
    unless( @genes ) {
        LIMS2::Exception->throw("Unable to find gene $gene_name in EnsEMBL" );
    }

    if ( scalar(@genes) > 1 ) {
        $self->log->debug("Found multiple EnsEMBL genes for $gene_name");
        my @stable_ids = map{ $_->stable_id } @genes;
        $type ||= 'marker symbol';

        LIMS2::Exception->throw( "Found multiple EnsEMBL genes with $type id $gene_name,"
                . " try using one of the following EnsEMBL gene ids: "
                . join( ', ', @stable_ids ) );
    }
    else {
        return shift @genes;
    }

    return;
}

=head2 build_gene_data

Build up data about targeted gene to display to user.

=cut
sub build_gene_data {
    my ( $self, $gene ) = @_;
    my %data;

    my $canonical_transcript = $gene->canonical_transcript;
    $data{ensembl_id} = $gene->stable_id;
    if ( $self->species eq 'Human' ) {
        $data{gene_link} = 'http://www.ensembl.org/Homo_sapiens/Gene/Summary?g='
            . $gene->stable_id;
        $data{transcript_link} = 'http://www.ensembl.org/Homo_sapiens/Transcript/Summary?t='
            . $canonical_transcript->stable_id;

        $data{gene_id} = $self->external_gene_id( $gene, 'HGNC' );
    }
    elsif ( $self->species eq 'Mouse' ) {
        $data{gene_link} = 'http://www.ensembl.org/Mus_musculus/Gene/Summary?g='
            . $gene->stable_id;
        $data{transcript_link} = 'http://www.ensembl.org/Mus_musculus/Transcript/Summary?t='
            . $canonical_transcript->stable_id;

        $data{gene_id} = $self->external_gene_id( $gene, 'MGI' );
    }
    $data{marker_symbol} = $gene->external_name;
    $data{canonical_transcript} = $canonical_transcript->stable_id;

    $data{strand} = $gene->strand;
    $data{chr} = $gene->seq_region_name;

    return \%data;
}

=head2 external_gene_id

Work out external gene id:
Human = HGNC
Mouse = MGI

If I have multiple ids pick the first one.
If I can not find a id go back to marker symbol.

=cut
sub external_gene_id {
    my ( $self, $gene, $type ) = @_;

    my @dbentries = @{ $gene->get_all_DBEntries( $type ) };
    my @ids = uniq map{ $_->primary_id } @dbentries;

    if ( @ids ) {
        my $id = shift @ids;
        $id = 'HGNC:' . $id if $type eq 'HGNC';
        return $id;
    }
    else {
        # return marker symbol
        return $gene->external_name;
    }

    return;
}

=head2 build_gene_exon_data

Grab genes from given exon and build up a hash of
data to display

=cut
sub build_gene_exon_data {
    my ( $self, $gene, $gene_id, $exon_types ) = @_;

    my $canonical_transcript = $gene->canonical_transcript;
    my $exons = $exon_types eq 'canonical' ? $canonical_transcript->get_all_Exons : $gene->get_all_Exons;

    my %exon_data;
    for my $exon ( @{ $exons } ) {
        my %data;
        $data{id} = $exon->stable_id;
        $data{size} = $exon->length;
        $data{chr} = $exon->seq_region_name;
        $data{start} = $exon->start;
        $data{end} = $exon->end;
        $data{start_phase} = $exon->phase;
        $data{end_phase} = $exon->end_phase;
        #TODO this may not be expected data sp12 Tue 03 Dec 2013 11:16:27 GMT
        #     not clear what constitutive means to Ensembl
        $data{constitutive} = $exon->is_constitutive ? 'yes' : 'no';

        $exon_data{ $exon->stable_id } = \%data;
    }
    $self->exon_ranks( \%exon_data, $canonical_transcript );

    if ( $gene->strand == 1 ) {
        return [ sort { $a->{start} <=> $b->{start} } values %exon_data ];
    }
    else {
        return [ sort { $b->{start} <=> $a->{start} } values %exon_data ];
    }

    return;
}

=head2 exon_ranks

Get rank of exons on canonical transcript.
If exon not on canonical transcript rank is left blank for now.

=cut
sub exon_ranks {
    my ( $self, $exons, $canonical_transcript ) = @_;

    my $rank = 1;
    for my $current_exon ( @{ $canonical_transcript->get_all_Exons } ) {
        my $current_id = $current_exon->stable_id;
        if ( exists $exons->{ $current_id } ) {
            $exons->{ $current_id }{rank} = $rank;
        }
        $rank++;
    }

    return;
}

sub pspec_parse_and_validate_gibson_params {
    return {
        gene_id         => { validate => 'non_empty_string' },
        exon_id         => { validate => 'ensembl_exon_id' },
        ensembl_gene_id => { validate => 'ensembl_gene_id' },
        # fields from the diagram
        '5F_length'    => { validate => 'integer' },
        '5F_offset'    => { validate => 'integer' },
        '5R_EF_length' => { validate => 'integer' },
        '5R_EF_offset' => { validate => 'integer' },
        'ER_3F_length' => { validate => 'integer' },
        'ER_3F_offset' => { validate => 'integer' },
        '3R_length'    => { validate => 'integer' },
        '3R_offset'    => { validate => 'integer' },
        # other options
        exon_check_flank_length => { validate => 'integer', optional => 1 },
        repeat_mask_classes     => { validate => 'repeat_mask_class', optional => 1 },
        alt_designs             => { validate => 'boolean', optional => 1 },
        #submit
        create_design => { optional => 0 }
    };
}

=head2 parse_and_validate_gibson_params

Check the parameters needed to create the gibson design are all present
and valid.

=cut
sub parse_and_validate_gibson_params {
    my ( $self ) = @_;

    my $validated_params = $self->check_params(
        $self->catalyst->request->params, $self->pspec_parse_and_validate_gibson_params );

    my $uuid = Data::UUID->new->create_str;
    $validated_params->{uuid}        = $uuid;
    $validated_params->{output_dir}  = $self->base_design_dir->subdir( $uuid );
    $validated_params->{species}     = $self->species;
    $validated_params->{build_id}    = $self->build_id;
    $validated_params->{assembly_id} = $self->assembly_id;
    $validated_params->{user}        = $self->user;

    #create dir
    $validated_params->{output_dir}->mkpath();

    $self->catalyst->stash( {
        gene_id => $validated_params->{gene_id},
        exon_id => $validated_params->{exon_id}
    } );

    return $validated_params;
}

=head2 initiate_design_attempt

create design attempt record with status pending

=cut
sub initiate_design_attempt {
    my ( $self, $params ) = @_;

    # create design attempt record
    my $design_parameters = encode_json(
        {   dir => $params->{output_dir}->stringify,
            slice_def $params,
            qw( uuid gene_id exon_id ensembl_gene_id assembly_id build_id ),
        }
    );

    my $design_attempt = $self->create_design_attempt(
        {
            gene_id           => $params->{gene_id},
            status            => 'pending',
            created_by        => $self->user,
            species           => $self->species,
            design_parameters => $design_parameters,
        }
    );
    $params->{da_id} = $design_attempt->id;

    return $design_attempt;
}

=head2 generate_gibson_design_cmd

generate the gibson design create command with all its parameters

=cut
sub generate_gibson_design_cmd {
    my ( $self, $params ) = @_;

    my @gibson_cmd_parameters = (
        'design-create',
        'gibson-design',
        '--debug',
        #required parameters
        '--created-by',  $params->{user},
        '--target-gene', $params->{gene_id},
        '--target-exon', $params->{exon_id},
        '--species',     $params->{species},
        '--dir',         $params->{output_dir}->subdir('workdir')->stringify,
        '--da-id',       $params->{da_id},
        #user specified params
        '--region-length-5f',    $params->{'5F_length'},
        '--region-offset-5f',    $params->{'5F_offset'},
        '--region-length-5r-ef', $params->{'5R_EF_length'},
        '--region-offset-5r-ef', $params->{'5R_EF_offset'},
        '--region-length-er-3f', $params->{'ER_3F_length'},
        '--region-offset-er-3f', $params->{'ER_3F_offset'},
        '--region-length-3r',    $params->{'3R_length'},
        '--region-offset-3r',    $params->{'3R_offset'},
        '--persist',
    );

    if ( $params->{repeat_mask_classes} ) {
        for my $class ( @{ $params->{repeat_mask_classes} } ){
            push @gibson_cmd_parameters, '--repeat-mask-class ' . $class;
        }
    }

    if ( $params->{alt_designs} ) {
        push @gibson_cmd_parameters, '--alt-designs';
    }

    if ( $params->{exon_check_flank_length} ) {
        push @gibson_cmd_parameters,
            '--exon-check-flank-length ' . $params->{exon_check_flank_length};
    }

    $self->log->debug('Design create command: ' . join(' ', @gibson_cmd_parameters ) );

    return \@gibson_cmd_parameters;
}

=head2 run_design_create_cmd

Bsub the design create command in farm3

=cut
sub run_design_create_cmd {
    my ( $self, $cmd, $params ) = @_;

    my $runner = LIMS2::Util::FarmJobRunner->new(
        default_memory     => 2500,
        default_processors => 2,
    );

    my $job_id = $runner->submit(
        out_file => $params->{ output_dir }->file( "design_creation.out" ),
        err_file => $params->{ output_dir }->file( "design_creation.err" ),
        cmd      => $cmd,
    );

    $self->log->info( "Successfully submitted gibson design create job $job_id with run id $params->{uuid}" );

    return $job_id;
}

=head2 get_exon_rank

Get rank of exon on canonical transcript

=cut
sub get_exon_rank {
    my ( $exon, $canonical_transcript ) = @_;

    my $rank = 1;
    for my $current_exon ( @{ $canonical_transcript->get_all_Exons } ) {
        return $rank if $current_exon->stable_id eq $exon->stable_id;
        $rank++;
    }

    return;
}

1;

__END__
