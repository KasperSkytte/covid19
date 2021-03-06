#!/usr/bin/env bash
VERSION=0.1.0

### Description ----------------------------------------------------------------

USAGE="$(basename "$0") [-h] [-m file -s file -o dir -t int]
-- COVID-19 pipeline for nextstrain visualization and basic genomic analysis v. $VERSION:  

Arguments:
    -h  Show this help text.
    -m  Metadata file.
    -s  Sequence file.
    -b  Choose custom build among 'light' (default), 'full' or 'global'. Multiple builds also possible: light,full (no space around ',')
    -i  (Develop only) Specify a specific singularity image to use.
    -o  (Develop only) Specify output directory.
    -t  (Develop only) Number of threads.
    -f  (Develop only) Force override existing output directory. 
    -p  (Develop only) Pull ncov from github
    -k  (Develop only) Additional snakemake arguments given in quotes

"
### Terminal Arguments ---------------------------------------------------------

# Import user arguments
while getopts ':hfpm:b:s:o:t:k:i:' OPTION; do
  case $OPTION in
    h) echo "$USAGE"; exit 1;;
    m) META=$OPTARG;;
    s) SEQS=$OPTARG;;
    o) OUTDIR=$OPTARG;;
    t) THREADS=$OPTARG;;
    i) SINGIMG=$OPTARG;;
    f) FORCE=1;;
    p) PULL_GITHUB=1;;
    b) CUSTOM_BUILD=$OPTARG;;
    k) SNAKE_ADD=$OPTARG;;
    :) printf "missing argument for -$OPTARG\n" >&2; exit 1;;
    \?) printf "invalid option for -$OPTARG\n" >&2; exit 1;;
  esac
done

# Setup directories.
THISDIR=$(dirname $(readlink -f $0))
DISTDIR="/srv/rbd/covid19"
NEXTSTRAINOUT="${DISTDIR}/nextstrain"

# Check missing arguments
MISSING="is missing but required. Exiting."
if [ -z ${THREADS+x} ]; then THREADS=64; fi;

### Code.----------------------------------------------------------------------
# Source utility functions
source ${THISDIR}/utils.sh

IMGDIR="/srv/rbd/thecontainer"
if [ -z "$SINGIMG" ]; then
    SINGIMG=$(findTheLatest "${IMGDIR}/*sif")
fi
echo Using Singularity image: $SINGIMG
# DISTDIR="/srv/rbd/covid19/current"

if [ -z ${META+x} ]; then
    META=$(findTheLatest "${DISTDIR}/metadata/*nextstrain.tsv")
    echo "WARNING: -m not provided, will use the latest one for nextstrain:"
    echo $META
fi
if [ -z ${SEQS+x} ]; then
    SEQS=$(findTheLatest "${DISTDIR}/genomes/*export")/sequences.fasta
    echo "WARNING: -s not provided, will use the latest sequences in :"
    echo $SEQS
fi

if [ -z ${OUTDIR+x} ]; then 
    OUTDIR=${NEXTSTRAINOUT}/$(basename -s _export $(findTheLatest "${DISTDIR}/genomes/*export"))_nextstrain
fi

if [ -z ${CUSTOM_BUILD+x} ]; then 
    CUSTOM_BUILD="light"
fi

GENOMEDIR=$(dirname $SEQS)
METADIR=$(dirname $META)

# setup output folders.
#if [ -d $OUTDIR -a  x$FORCE == x  ]; then
#    echo "$OUTDIR already exists!"
#    echo "Please choose a different output directory or use -f to force delete $OUTDIR"
#    exit 1
#fi

#if [ -d $OUTDIR -a x${FORCE} != x  ]; then
#    echo "Deleting $OUTDIR ..."
#    rm -rf $OUTDIR
#fi

mkdir -p $OUTDIR
OUTDIR=$(readlink -f $OUTDIR) # Convert to absolute path
mkdir -p $OUTDIR/data

GISAID_META=$(findTheLatest "${DISTDIR}/global_data/*tsv")
GISAID_FASTA=$(findTheLatest "${DISTDIR}/global_data/*fasta")
NCOV_ROOT="/opt/nextstrain/ncov-aau"
BPROFILE="my_profiles/denmark"
RUNLOGFILE=${OUTDIR}/run.log

if [ -n "$CUSTOM_BUILD" ]; then
    SNAKE_ADD="custom_build=$CUSTOM_BUILD $SNAKE_ADD"
fi


gisaid_date=$(basename $GISAID_META|sed -e 's/metadata_//;s/.tsv//')
data_date=$(basename -s "_export" $(dirname $SEQS))


# Make sure when re-running on the same $OUTDIR use the same input data
SNAKE_OUT=${OUTDIR}/results
if [ -s "${RUNLOGFILE}" ]; then
    data_date=$(grep snakemake ${RUNLOGFILE} |tail -n 1|sed 's/ /\n/g'| grep 'data_date=' | awk -F '=' '{print $2}'|tr -d \'\")
    gisaid_date=$(grep snakemake ${RUNLOGFILE} |tail -n 1|sed 's/ /\n/g'| grep 'gisaid_date=' | awk -F '=' '{print $2}'|tr -d \'\")

    META=$(grep snakemake ${RUNLOGFILE} |tail -n 1|sed 's/ /\n/g'| grep 'denmark_meta=' | awk -F '=' '{print $2}')
    SEQS=$(grep snakemake ${RUNLOGFILE} |tail -n 1|sed 's/ /\n/g'| grep 'denmark_fasta=' | awk -F '=' '{print $2}')
    GISAID_META=$(grep snakemake ${RUNLOGFILE} |tail -n 1|sed 's/ /\n/g'| grep 'gisaid_meta=' | awk -F '=' '{print $2}')
    GISAID_FASTA=$(grep snakemake ${RUNLOGFILE} |tail -n 1|sed 's/ /\n/g'| grep 'gisaid_fasta=' | awk -F '=' '{print $2}')
    echo Existing run output detected at $OUTDIR.
    echo Now rerunning with data_date: $data_date, gisaid_date: $gisaid_date ...
fi


ARGSTR="--cores $THREADS --profile $BPROFILE --config gisaid_date='\"$gisaid_date\"' data_date='\"$data_date\"' "
ARGSTR="$ARGSTR denmark_meta=${META} denmark_fasta=${SEQS} gisaid_meta=${GISAID_META} gisaid_fasta=${GISAID_FASTA}"
ARGSTR="$ARGSTR outdir=${SNAKE_OUT} out_auspice=${OUTDIR}/auspice ${SNAKE_ADD}"

# Run nextstrain 
###############################################################################

if [ -d $OUTDIR -a x${PULL_GITHUB} != x ]; then
    cd $OUTDIR
    wget https://github.com/biocyberman/ncov/archive/aau.zip
    unzip -o aau.zip && rm aau.zip
    cd -
fi

CONDA_RUN=0 # preserve conda-based setup for convenience. 

if [ $CONDA_RUN -eq 1 ]; then

    NCOV_ROOT="/srv/rbd/bin/ncov.1308"
    if [ -d ${OUTDIR}/ncov-aau ]; then
        NCOV_ROOT="${OUTDIR}/ncov-aau"
    fi
    AUGUR_ENV="/srv/rbd/bin/conda/envs/augur"

    cd $NCOV_ROOT
    source activate  $AUGUR_ENV
    snakemake ${ARGSTR}

else

    TimeStamp=$(date +%y%m%d_%H%M)

    echo ${TimeStamp}: ${USER}, PWD: ${PWD} >>${RUNLOGFILE}
    echo ${TimeStamp}: "$0 $@" >>${RUNLOGFILE}
    echo ${TimeStamp}: Singularity Image Used: $SINGIMG >> ${RUNLOGFILE}
    echo ${TimeStamp}: snakemake ${ARGSTR} >> ${RUNLOGFILE}

    singularity exec  -B /srv/rbd:/srv/rbd \
                -B $HOME:$HOME \
                $SINGIMG bash <<HEREDOC
source activate nextstrain

###############################################################################
# Run nextstrain 
###############################################################################
if [ ! -d $OUTDIR/ncov-aau ]; then
   cp -r $NCOV_ROOT $OUTDIR
   chmod -R g+w ${OUTDIR}/ncov-aau
fi
cd $OUTDIR/ncov-aau
snakemake ${ARGSTR}
HEREDOC

fi
