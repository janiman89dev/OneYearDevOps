#!/bin/bash

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "Timestamp: $TIMESTAMP"

LOCAL_SOURCE="$HOME/S3-backup"
BUCKET_NAME="self-learn-project-phase1-838987715391-eu-central-1-an"

if [[ ! -d $LOCAL_SOURCE ]]; then
     echo "Error: source directory $LOCAL_SOURCE does not exist."
     exit 1
fi

echo "Backing up to S3 bucket..."

aws s3 cp "$LOCAL_SOURCE" "s3://$BUCKET_NAME/backup-$TIMESTAMP/" --recursive
