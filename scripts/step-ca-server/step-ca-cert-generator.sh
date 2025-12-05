#!/bin/bash

# Check if a URL was passed as an argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <URL>"
    exit 1
fi

URL=$1

# Define the directory to store the certificates
CERT_DIR="./certs"
mkdir -p $CERT_DIR

TOKEN=$(step ca token ${URL})
# Generate the certificate and key for the given URL
step ca certificate "$URL" "$CERT_DIR/$URL.crt" "$CERT_DIR/$URL.key"

# Check if the certificate generation was successful
if [ $? -eq 0 ]; then
    echo "Certificate and key generated successfully."
    echo "Certificate location: $CERT_DIR/$URL.crt"
    echo "Key location: $CERT_DIR/$URL.key"
else
    echo "Failed to generate the certificate and key."
fi
