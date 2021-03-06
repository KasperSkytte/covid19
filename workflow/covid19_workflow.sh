#!/usr/bin/env bash
VERSION=0.2.0

### Description ----------------------------------------------------------------

USAGE="$(basename "$0") [-h] [-s file -m file -a string -o dir -t int] 
-- COVID-19 pipeline for data generation and QC v. $VERSION:  

Arguments:
    -h  Show this help text.
    -i  Input directory.
    -s  Scheme, see below for which to choose.
    -o  (Develop only) Specify output directory.
    -r  (Develop only) Specify run-id.
    -x  (Develop only) Specify sample-sheet file.
    -t  (Develop only) Number of threads.

Schemes:
    aau_long_v3.1
    aau_short_v3
    v1
    v2
    v3
"
### Terminal Arguments ---------------------------------------------------------

# Import user arguments
while getopts ':hi:s:o:r:x:t:' OPTION; do
  case $OPTION in
    h) echo "$USAGE"; exit 1;;
    i) INPUT_DIR=$OPTARG;;
    s) SCHEME=$OPTARG;;
    o) OUT_DIR=$OPTARG;;
    r) RUN_ID=$OPTARG;;
    x) SAMPLE_SHEET=$OPTARG;;
    t) THREADS=$OPTARG;;
    :) printf "missing argument for -$OPTARG\n" >&2; exit 1;;
    \?) printf "invalid option for -$OPTARG\n" >&2; exit 1;;
  esac
done

# Check missing arguments
MISSING="is missing but required. Exiting."
if [ -z ${INPUT_DIR+x} ]; then echo "-i $MISSING"; exit 1; fi;
if [ -z ${SCHEME+x} ]; then echo "-s $MISSING"; exit 1; fi;
if [ -z ${OUT_DIR+x} ]; then OUT_DIR=$INPUT_DIR; fi;
if [ -z ${RUN_ID+x} ]; then RUN_ID=$INPUT_DIR; fi;
if [ -z ${SAMPLE_SHEET+x} ]; then SAMPLE_SHEET=$INPUT_DIR/sample_sheet.csv; fi;
if [ -z ${THREADS+x} ]; then THREADS=100; fi;

### Code.----------------------------------------------------------------------
# Preparation -----------------------------------------------------------------

echo ""
echo "[$(date +"%T")] Performing pre-run preparation and checks"
echo ""

# Script paths
WORKFLOW_PATH="$(dirname "$(readlink -f "$0")")"
COVID19_PATH=${WORKFLOW_PATH%/*}
SINGIMG="/srv/rbd/thecontainer/covid19_latest.sif"
RUNTIME_DIR="/tmp/sing.${UID}"
if [ -d ${RUNTIME_DIR} ]; then
    rm -rf ${RUNTIME_DIR}
fi
HUMREF=${WORKFLOW_PATH}/dependencies/ref/human_g1k_v37.fasta

mkdir -m 0700 -p ${RUNTIME_DIR}

# Determine absolute path to input/output
INPUT_DIR=$(readlink -f "$INPUT_DIR")
OUT_DIR=$(readlink -f "$OUT_DIR")

# Create output folder
mkdir -p $OUT_DIR

# Copy sample_sheet.csv to output folder
if [ ! -f "${OUT_DIR}/sample_sheet.csv" ]; then
  cp $SAMPLE_SHEET ${OUT_DIR}/sample_sheet.csv
fi

# Check references 
#if [ ! -f "$HUMREF" ]; then
#  echo ""
#  echo "Downloading human reference genome to ${WORKFLOW_PATH}/dependencies/ref/human_g1k_v37.fasta"
#  echo ""
#  
#  wget \
#    -O- \
#    'ftp://ftp.ncbi.nlm.nih.gov/1000genomes/ftp/technical/reference/human_g1k_v37.fasta.gz' |\
#  gunzip > "${WORKFLOW_PATH}/dependencies/ref/human_g1k_v37.fasta"
#fi


# This is the full workflow script.

###############################################################################
# Demultiplexing
###############################################################################

echo ""
echo "[$(date +"%T")] Demultiplexing and trimming of fastq data"
echo ""

if [ -d $OUT_DIR/demultiplexed ]; then 
  echo "$OUT_DIR/demultiplexed directory exists. Demultiplexing is skipped..."
else 
  # Check if default folder structure is present
  if [ -d "${INPUT_DIR}/fastq" ]; then
    echo ""
    echo "Processing fastq files from ${INPUT_DIR}/fastq directory..."
    FASTQ_DIR="${INPUT_DIR}/fastq"
    echo ""
  elif [ -d "$INPUT_DIR" ]; then
    echo ""
    echo "Processing fastq files from ${INPUT_DIR} directory..."
    FASTQ_DIR="${INPUT_DIR}"
    echo ""
  else
    echo ""
    echo "$INPUT_DIR or ${INPUT_DIR}/fastq does not exist"
    echo "Aborting covid19_workflow..."
    echo ""
    return
  fi
  
  # compute the ammount of .fastq data used for demultiplexing.
  rm -f $OUT_DIR/data_used.txt 
  echo $(($(find $FASTQ_DIR -name *.fastq | wc -l) * 4000 * 1050)) > $OUT_DIR/data_used.txt
  chmod 777 $OUT_DIR/data_used.txt

  # Demultiplexing
  singularity \
    --silent \
    exec \
    -B $WORKFLOW_PATH:$WORKFLOW_PATH \
    -B $FASTQ_DIR:$FASTQ_DIR \
    -B $OUT_DIR:$OUT_DIR \
    -B $INPUT_DIR:$INPUT_DIR \
    -B $RUNTIME_DIR:/run/user/$UID \
    $SINGIMG \
    bash -c "
      $WORKFLOW_PATH/demultiplex.sh \
        $FASTQ_DIR \
        $RUN_ID \
        $SAMPLE_SHEET \
        $OUT_DIR/demultiplexed \
        $THREADS \
        $SCHEME;
      retn_code=$?;
      if [ \$retn_code == 123 ]; then echo 'missing barcodes, exit.'; exit 123; fi
      "
fi

if [ -s $OUT_DIR/demultiplexed/missing.txt ]; then 
  echo "The following barcodes were in $SAMPLE_SHEET but not in barcodes.csv:"
  echo $(awk '{print}' ORS=' ' $OUT_DIR/demultiplexed/missing.txt)  
  rm -r $OUT_DIR/demultiplexed
  exit
fi

###############################################################################
# Remove human reads
###############################################################################

#echo ""
#echo "[$(date +"%T")] Removing human reads from demultiplexed data"
#echo ""

#if [ -d $OUT_DIR/filtered ]; then 
#  echo "$OUT_DIR/filtered directory exists. Human read filtering is skipped..."
#else 

#  singularity \
#    --silent \
#    exec \
#    -B $WORKFLOW_PATH:$WORKFLOW_PATH \
#    -B $OUT_DIR:$OUT_DIR \
#    -B $INPUT_DIR:$INPUT_DIR \
#    -B $RUNTIME_DIR:/run/user/$UID \
#    $SINGIMG \
#    bash -c "INdir=$INPUT_DIR/demultiplexed; OUTdir=$OUT_DIR/filtered; THREADS=$THREADS; HUMREF=$HUMREF; . $WORKFLOW_PATH/human-filtering-reads.sh"
#fi

###############################################################################
# Generate genomes
###############################################################################

mkdir -p $OUT_DIR/final_output

echo ""
echo "[$(date +"%T")] Generating genomes with ARTIC medaka pipeline"
echo ""

if [ -d $OUT_DIR/processing ]; then 
  echo "$OUT_DIR/processing directory exists. ARTIC pipeline is skipped..."
else 

  singularity \
    --silent \
    exec \
    -B $WORKFLOW_PATH:$WORKFLOW_PATH \
    -B $INPUT_DIR:$INPUT_DIR \
    -B $OUT_DIR:$OUT_DIR \
    -B $RUNTIME_DIR:/run/user/$UID \
    $SINGIMG \
    bash -c "
      source activate artic-ncov2019;

      # Medaka cannot control mem, need to scale down to 66%.
      THREADS_MEDAKA=$((($THREADS * 2)/3));

      $WORKFLOW_PATH/processing.sh \
        -i $OUT_DIR/demultiplexed \
        -s nCoV-2019/$SCHEME \
        -o $OUT_DIR/processing \
        -t \$THREADS_MEDAKA;
      "
fi

###############################################################################
# Run QC
###############################################################################

echo ""
echo "[$(date +"%T")] Quality control of genomes"
echo ""

singularity \
  --silent \
  exec \
  -B $WORKFLOW_PATH:$WORKFLOW_PATH \
  -B $INPUT_DIR:$INPUT_DIR \
  -B $OUT_DIR:$OUT_DIR \
  -B $RUNTIME_DIR:/run/user/$UID \
  --no-home \
  $SINGIMG \
  bash -c "
    $WORKFLOW_PATH/QC.sh \
      -i $OUT_DIR \
      -s $SCHEME \
      -r $WORKFLOW_PATH/QC.rmd \
      -t $THREADS
    "

echo ""
echo "[$(date +"%T")] Workflow done, cleaning up..."
echo ""

################################################################################
# Sweep important data and put in "output"
################################################################################

cp $OUT_DIR/QC/*.html $OUT_DIR/final_output/*.html
cp $OUT_DIR/processing/results/consensus.fasta $OUT_DIR/final_output/consensus.fasta

################################################################################
# Set group permissions for output folders.
################################################################################

chgrp -R cli_a1024-gc1-e-03-srv-aau-dk_hostaccess@srv.aau.dk $OUT_DIR/demultiplexed
#chgrp -R cli_a1024-gc1-e-03-srv-aau-dk_hostaccess@srv.aau.dk $OUT_DIR/filtered
chgrp -R cli_a1024-gc1-e-03-srv-aau-dk_hostaccess@srv.aau.dk $OUT_DIR/processing
chgrp -R cli_a1024-gc1-e-03-srv-aau-dk_hostaccess@srv.aau.dk $OUT_DIR/QC
chgrp -R cli_a1024-gc1-e-03-srv-aau-dk_hostaccess@srv.aau.dk $OUT_DIR/final_output

chmod -R g+rwx $OUT_DIR/demultiplexed
#chmod -R g+rwx $OUT_DIR/filtered
chmod -R g+rwx $OUT_DIR/processing
chmod -R g+rwx $OUT_DIR/QC
chmod -R g+rwx $OUT_DIR/final_output
