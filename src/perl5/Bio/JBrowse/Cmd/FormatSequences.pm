package Bio::JBrowse::Cmd::FormatSequences;

=head1 NAME

Bio::JBrowse::Cmd::FormatSequences - script module to format reference
sequences (backend module for prepare-refseqs.pl)

=cut

use strict;
use warnings;

use base 'Bio::JBrowse::Cmd';
use Pod::Usage ();

use File::Spec::Functions qw/ catfile catdir /;
use File::Path 'mkpath';

use POSIX;

use Bio::JBrowse::JSON;
use JsonFileStorage;

sub option_defaults {(
    out => 'data',
    chunksize => 20_000,
    seqType => 'DNA'
)}

sub option_definitions {(
    "out=s",
    "conf=s",
    "noseq",
    "gff=s",
    "chunksize=s",
    "fasta=s@",
    "sizes=s@",
    "refs=s",
    "reftypes=s",
    "compress",
    "trackLabel=s",
    "seqType=s",
    "key=s",
    "help|h|?",
    "nohash"
)}

sub run {
    my ( $self ) = @_;

    my $compress = $self->opt('compress');

    $self->{storage} = JsonFileStorage->new( $self->opt('out'), $self->opt('compress'), { pretty => 0 } );

    Pod::Usage::pod2usage( 'must provide either a --fasta, --sizes, --gff, or --conf option' )
        unless $self->opt('gff') || $self->opt('conf') || $self->opt('fasta') || $self->opt('sizes');

    {
        my $chunkSize = $self->opt('chunksize');
        $chunkSize *= 4 if $compress;
        $self->{chunkSize} = $chunkSize;
    }

    my $refs = $self->opt('refs');

    if ( $self->opt('fasta') && @{$self->opt('fasta')} ) {
        die "--refids not implemented for FASTA files" if defined $self->opt('refids');
        $self->exportFASTA( $refs, $self->opt('fasta') );
        $self->writeTrackEntry();
    }
    elsif ( $self->opt('gff') ) {
        my $db;
        my $gff = $self->opt('gff');
        my $gzip = '';
        if( $gff =~ /\.gz$/ ) {
            $gzip = ':gzip';
        }
        open my $fh, "<$gzip", $gff or die "$! reading GFF file $gff";
        while ( <$fh> ) {
            if( /^##FASTA\s*$/i ) {
                # start of the sequence block, pass the filehandle to our fasta database
                $self->exportFASTA( $refs, [$fh] );
                last;
            }
            elsif( /^>/ ) {
                # beginning of implicit sequence block, need to seek
                # back
                seek $fh, -length($_), SEEK_CUR;
                $self->exportFASTA( $refs, [$fh] );
                last;
            }
        }
        $self->writeTrackEntry();

    } elsif ( $self->opt('conf') ) {
        my $config = Bio::JBrowse::JSON->new->decode_file( $self->opt('conf') );

        eval "require $config->{db_adaptor}; 1" or die $@;

        my $db = eval {$config->{db_adaptor}->new(%{$config->{db_args}})}
                  or warn $@;

        die "Could not open database: $@" unless $db;

        if (my $refclass = $config->{'reference class'}) {
            eval {$db->default_class($refclass)};
        }
        $db->strict_bounds_checking(1) if $db->can('strict_bounds_checking');

        $self->exportDB( $db, $refs, {} );
        $self->writeTrackEntry();
    }
    elsif( $self->opt('sizes') ) {

        my %refseqs;
        for my $sizefile ( @{$self->opt('sizes')} ) {
            open my $f, '<', $sizefile or warn "$! opening file $sizefile, skipping";
            next unless $f;
            while( my $line = <$f> ) {
                next unless $line =~ /\S/;
                chomp $line;
                my ( $name, $length ) = split /\s+/,$line,2;
                s/^\s+|\s+$//g for $name, $length;

                $refseqs{$name} = {
                    name   => $name,
                    start  => 0,
                    end    => $length,
                    length => $length
                };
            }
        }

        $self->writeRefSeqsJSON( \%refseqs );
    }
}

sub trackLabel {
    my ( $self ) = @_;

    # use --trackLabel if given
    return $self->opt('trackLabel') if $self->opt('trackLabel');

    # otherwise construct from seqType.  uppercasing in case it is
    # also used as the human-readable name
    my $st = $self->opt('seqType');
    if( $st =~ /^[dr]na$/i ) {
        return uc $st;
    }

    return lc $st;
}

sub exportFASTA {
    my ( $self, $refs, $files ) = @_;
    my $accept_ref = sub {1};

    if( $refs ) {
		my $refhash = ();

		foreach my $cle (split /\s*,\s*/, $refs){
	        $refhash->{$cle} = 1;
		}

		$refs = $refhash;		
        $accept_ref = sub { $refs->{$_[0]} };
    }

    my %refSeqs;
    for my $fasta ( @$files ) {
        my $gzip = $fasta =~ /\.gz(ip)?$/i ? ':gzip' : '';

        my $fasta_fh;
        if( ref $fasta ) {
            $fasta_fh = $fasta;
        } else {
            open $fasta_fh, "<$gzip", $fasta or die "$! reading $fasta";
        }

        my $curr_seq;
        my $curr_chunk = '';
        my $chunk_num;

        my $noseq = $self->opt('noseq');

        my $writechunks = sub {
            my $flush = shift;
            return if $noseq;

            while( $flush && $curr_chunk || length $curr_chunk >= $self->{chunkSize} ) {
                $self->openChunkFile( $curr_seq, $chunk_num )
                     ->print(
                         substr( $curr_chunk, 0, $self->{chunkSize}, '' ) #< shifts off the first part of the string
                         );
                $chunk_num++;
            }
        };

        local $_;
        while ( <$fasta_fh> ) {
            if ( /^\s*>\s*(\S+)\s*(.*)/ ) {
                $writechunks->('flush') if $curr_seq;

                if ( $accept_ref->($1) ) {
                    $chunk_num = 0;
                    $curr_chunk = '';
                    $curr_seq = $refSeqs{$1} = {
                        name => $1,
                        start => 0,
                        end => 0,
                        seqChunkSize => $self->{chunkSize},
                        $2 ? ( description => $2 ) : ()
                        };
                } else {
                    undef $curr_seq;
                }
            } elsif ( $curr_seq && /\S/ ) {
                s/[\s\r\n]//g;
                $curr_seq->{end} += length;

                unless( $noseq ) {
                    $curr_chunk .= $_;
                    $writechunks->();
                }
            }
        }
        $writechunks->('flush');
    }
	
    $self->writeRefSeqsJSON( \%refSeqs );
}

sub exportDB {
    my ( $self, $db, $refs, $refseqs ) = @_;

    my $compress = $self->opt('compress');
    my %refSeqs = %$refseqs;
    my %exportedRefSeqs;

    my @queries;

    if( my $reftypes = $self->opt('reftypes') ) {
        if( $db->isa( 'Bio::DB::Das::Chado' ) ) {
            die "--reftypes argument not supported when using the Bio::DB::Das::Chado adaptor\n";
        }
        push @queries, [ -type => [ split /[\s,]+/, $reftypes ] ];
    }

    if( ! @queries && ! defined $refs && $db->can('seq_ids') ) {
        $refs = join ',', $db->seq_ids;
    }
    if ( defined $refs ) {
        for my $ref (split ",", $refs) {
            push @queries, [ -name => $ref ];
        }
    }

    my $refCount = 0;
    for my $query ( @queries ) {
        my @segments = $db->isa('Bio::DB::Das::Chado') ? $db->segment( @$query ) : $db->features( @$query );

        unless( @segments ) {
            warn "WARNING: Reference sequence with @$query not found in input.\n";
            next;
        }

        for my $seg ( @segments ) {

            my $refInfo = {
                name => $self->refName($seg),
                start => $seg->start - 1,
                end => $seg->end,
                length => $seg->length
                };

            if ( $refSeqs{ $refInfo->{name} } ) {
                warn "WARNING: multiple reference sequences found named '$refInfo->{name}', using only the first one.\n";
            } else {
                $refSeqs{ $refInfo->{name} } = $refInfo;
            }

            unless( $self->opt('noseq') || $exportedRefSeqs{ $refInfo->{name} }++ ) {
                $self->exportSeqChunksFromDB( $refInfo, $self->{chunkSize}, $db,
                                              [ -name => $refInfo->{name} ],
                                              $seg->start, $seg->end);
                $refSeqs{ $refInfo->{name}}{seqChunkSize} = $self->{chunkSize};
            }
        }
    }

    unless( %refSeqs ) {
        warn "No reference sequences found, exiting.\n";
        exit;
    }

    $self->writeRefSeqsJSON( \%refSeqs );
}

sub writeRefSeqsJSON {
    my ( $self, $refseqs ) = @_;

    mkpath( File::Spec->catdir($self->{storage}{outDir},'seq') );

    $self->{storage}->modify( 'seq/refSeqs.json',
                                   sub {
                                       #add new ref seqs while keeping the order
                                       #of the existing ref seqs
                                       my $old = shift || [];
                                       my %refs = %$refseqs;
                                       for (my $i = 0; $i < @$old; $i++) {
                                           if( $refs{$old->[$i]->{name}} ) {
                                               $old->[$i] = delete $refs{$old->[$i]->{name}};
                                           }
                                       }
                                       foreach my $name (sort keys %refs) {
                                           if( not exists $refs{$name}{length} ) {
                                               $refs{$name}{length} = $refs{$name}{end} - $refs{$name}{start};
                                           }
                                           push @{$old}, $refs{$name};
                                       }
                                       return $old;
                                   });

    if ( $self->opt('compress') ) {
        # if we are compressing the sequence files, drop a .htaccess file
        # in the seq/ dir that will automatically configure users with
        # Apache (and AllowOverride on) to serve the .txt.gz files
        # correctly
        require GenomeDB;
        my $hta = catfile( $self->opt('out'), 'seq', '.htaccess' );
        open my $hta_fh, '>', $hta or die "$! writing $hta";
        $hta_fh->print( GenomeDB->precompression_htaccess('.txtz','.jsonz') );
    }
}

sub writeTrackEntry {
    my ( $self ) = @_;

    my $compress = $self->opt('compress');

    my $seqTrackName = $self->trackLabel;
    unless( $self->opt('noseq') ) {
        $self->{storage}->touch( 'tracks.conf' );

        $self->{storage}->modify( 'trackList.json',
                                       sub {
                                           my $trackList = shift;
                                           unless (defined($trackList)) {
                                               $trackList =
                                           {
                                               'formatVersion' => 1,
                                               'tracks' => []
                                               };
                                           }
                                           my $tracks = $trackList->{'tracks'};
                                           my $i;
                                           for ($i = 0; $i <= $#{$tracks}; $i++) {
                                               last if ($tracks->[$i]->{'label'}
                                                    eq
                                                $seqTrackName);
                                           }
                                           $tracks->[$i] =
                                       {
                                           'label' => $seqTrackName,
                                           'key' => $self->opt('key') || 'Reference sequence',
                                           'type' => "SequenceTrack",
                                           'category' => "Reference sequence",
                                           'storeClass' => 'JBrowse/Store/Sequence/StaticChunked',
                                           'chunkSize' => $self->{chunkSize},
                                           'urlTemplate' => $self->seqUrlTemplate,
                                           ( $compress ? ( 'compress' => 1 ): () ),
                                           ( 'dna' eq lc $self->opt('seqType') ? () : ('showReverseStrand' => 0 ) )
                                       };
                                           return $trackList;
                                       });
    }

    return;
}

###########################

sub refName {
    my ( $self, $seg ) = @_;
    my $segName = $seg->name;
    $segName = $seg->{'uniquename'} if $seg->{'uniquename'};
    $segName =~ s/:.*$//; #get rid of coords if any
    return $segName;
}

sub openChunkFile {
    my ( $self, $refInfo, $chunkNum ) = @_;

    my $compress = $self->opt('compress');

    my ( $dir, $file ) = $self->opt('nohash')
        # old style
        ? ( catdir( $self->opt('out'), 'seq',
                    $refInfo->{name}
                    ),
            "$chunkNum.txt"
          )
        # new hashed structure
        : ( catdir( $self->opt('out'), 'seq',
                    $self->_crc32_path( $refInfo->{name} )
                  ),
            "$refInfo->{name}-$chunkNum.txt"
          );

    $file .= 'z' if $compress;

    mkpath( $dir );
    open my $fh, '>'.($compress ? ':gzip' : ''), catfile( $dir, $file )
        or die "$! writing $file";
    return $fh;
}

sub _crc32_path {
    my ( $self, $str ) = @_;
    my $crc = ( $self->{crc} ||= do { require Digest::Crc32; Digest::Crc32->new } )
                ->strcrc32( $str );
    my $hex = lc sprintf( '%08x', $crc );
    return catdir( $hex =~ /(.{1,3})/g );
}

sub seqUrlTemplate {
    my ( $self ) = @_;
    return $self->opt('nohash')
        ? "seq/{refseq}/"                   # old style
        : "seq/{refseq_dirpath}/{refseq}-"; # new hashed structure
}


sub exportSeqChunksFromDB {
    my ( $self, $refInfo, $chunkSize, $db, $segDef, $start, $end ) = @_;

    $start = 1 if $start < 1;
    $db->absolute( 1 ) if $db->can('absolute');

    my $chunkStart = $start;
    while( $chunkStart <= $end ) {
        my $chunkEnd = $chunkStart + $chunkSize - 1;
        $chunkEnd = $end if $chunkEnd > $end;
        my $chunkNum = floor( ($chunkStart - 1) / $chunkSize );
        my ($seg) = $db->segment( @$segDef,
                                  -start    => $chunkStart,
                                  -end      => $chunkEnd,
                                  -absolute => 1,
                                );
        unless( $seg ) {
            die "Seq export query failed, please inform the developers of this error"
        }

        $seg->start == $chunkStart
          or die "requested $chunkStart .. $chunkEnd; got " . $seg->start . " .. " . $seg->end;

        $chunkStart = $chunkEnd + 1;
        next unless $seg && $seg->seq && $seg->seq->seq;

        $self->openChunkFile( $refInfo, $chunkNum )
             ->print( $seg->seq->seq );
    }
}

1;
