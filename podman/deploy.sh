#!/bin/bash
set -e

# Print status messages
echo "Starting deployment script..."
echo "----------------------------"

# Remove existing pods if they exist
echo "Removing existing pods..."
podman pod rm -f airflow 2>/dev/null || true
podman pod rm -f hapi-fhir 2>/dev/null || true
podman pod rm -f ehrbase 2>/dev/null || true

# Check if network exists and remove it
echo "Checking for existing network..."
if podman network inspect medscio-network &>/dev/null; then
    echo "Removing existing medscio-network..."
    podman network rm medscio-network
fi

# Create the network
echo "Creating medscio-network..."
podman network create medscio-network

# Modify the Airflow image 
echo "Creating a custom Airflow image"

# Create a temporary directory for our Dockerfile
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Create a fixed Dockerfile that works better with Podman
cat > $TEMP_DIR/Dockerfile << 'EOF'
FROM apache/airflow:2.6.3
USER root

# Create directory structure
RUN mkdir -p /opt/airflow/project \
    /opt/airflow/data \
    /opt/airflow/data/openEHR_templates \
    /opt/airflow/data/openEHR_compositions/output \
    /opt/airflow/data/EPIC_output \
    /opt/airflow/data/hapi_fhir_profiles \
    && chown -R airflow:root /opt/airflow/project /opt/airflow/data

# Set appropriate permissions
RUN chmod -R 755 /opt/airflow/project /opt/airflow/data && \
    # Create output directories if they don't exist
    mkdir -p /opt/airflow/data/openEHR_compositions/output && \
    mkdir -p /opt/airflow/data/EPIC_output && \
    # Ensure airflow user owns all data directories and files
    chown -R airflow:root /opt/airflow/data && \
    # Make sure output directories are writable
    chmod -R 777 /opt/airflow/data/openEHR_compositions/output \
    /opt/airflow/data/EPIC_output

# Switch back to airflow user for installing python packages and for copying files 
USER airflow

EOF


# Create data directory structure in temp dir
echo "Creating data directory structure..."
mkdir -p $TEMP_DIR/data
mkdir -p $TEMP_DIR/data/openEHR_templates
mkdir -p $TEMP_DIR/data/openEHR_compositions/output
mkdir -p $TEMP_DIR/data/EPIC_output
mkdir -p $TEMP_DIR/data/hapi_fhir_profiles

# Copy data files if they exist
# if [ -d /home/howitzer/dev/Medscio/REUSE/data ]; then
if [ -d /home/maverick/dev/Medscio/REUSE/data ]; then
    echo "Copying data files..."
    
    # Copy only the contents of each subdirectory if they exist
    if [ -d /home/maverick/dev/Medscio/REUSE/data/openEHR_templates ]; then
        cp -r /home/maverick/dev/Medscio/REUSE/data/openEHR_templates/* $TEMP_DIR/data/openEHR_templates/ 2>/dev/null || echo "No files in openEHR_templates"
    fi
    
    if [ -d /home/maverick/dev/Medscio/REUSE/data/openEHR_compositions ]; then
        # Don't overwrite the output directory we just created
        for item in /home/maverick/dev/Medscio/REUSE/data/openEHR_compositions/*; do
            if [ "$(basename "$item")" != "output" ]; then
                cp -r "$item" $TEMP_DIR/data/openEHR_compositions/ 2>/dev/null
            fi
        done
    fi
    
    if [ -d /home/maverick/dev/Medscio/REUSE/data/EPIC_output ]; then
        cp -r /home/maverick/dev/Medscio/REUSE/data/EPIC_output/* $TEMP_DIR/data/EPIC_output/ 2>/dev/null || echo "No files in EPIC_output"
    fi
    
    if [ -d /home/maverick/dev/Medscio/REUSE/data/hapi_fhir_profiles ]; then
        cp -r /home/maverick/dev/Medscio/REUSE/data/hapi_fhir_profiles/* $TEMP_DIR/data/hapi_fhir_profiles/ 2>/dev/null || echo "No files in hapi_fhir_profiles"
    fi
    
    echo "Verifying data files were copied to temp directory:"
    ls -la $TEMP_DIR/data/
    echo "Checking output directories:"
    ls -la $TEMP_DIR/data/openEHR_compositions/
else
    echo "WARNING: data directory not found at /home/maverick/dev/Medscio/REUSE/data"
fi

# Ensure the output directory exists and has the right permissions in the temp directory
chmod -R 777 $TEMP_DIR/data/openEHR_compositions/output $TEMP_DIR/data/EPIC_output

# Copy .env.airflow file if it exists
if [ -f /home/maverick/dev/Medscio/REUSE/.env.airflow ]; then
    echo "Copying .env.airflow file..."
    mkdir -p $TEMP_DIR/project
    cp /home/maverick/dev/Medscio/REUSE/.env.airflow $TEMP_DIR/project/
    echo "Verifying .env.airflow file was copied to temp directory:"
    ls -la $TEMP_DIR/project/
else
    echo "WARNING: .env.airflow file not found at /home/maverick/dev/Medscio/REUSE/.env.airflow"
fi

# Continue appending to the Dockerfile now that we know if project files exist
cat >> $TEMP_DIR/Dockerfile << 'EOF'
# Copy data files
COPY data/ /opt/airflow/data/

# Copy environment file to a location not affected by mounts
COPY project/.env.airflow /opt/airflow/.env.airflow
EOF

# Always copy project files if the directory exists
if [ -d "$TEMP_DIR/project" ]; then
    echo "Adding project files to Dockerfile..."
    cat >> $TEMP_DIR/Dockerfile << 'EOF'
# Copy project files
COPY --chown=airflow:root project/ /opt/airflow/project/
EOF
    
    # Verify what files will be copied
    echo "Files that will be copied from project directory:"
    ls -la $TEMP_DIR/project/
else
    echo "WARNING: project directory does not exist in temporary directory"
fi

# Finish the Dockerfile
cat >> $TEMP_DIR/Dockerfile << 'EOF'
# Set proper permissions
USER root
RUN [ -d "/opt/airflow/project" ] && [ "$(ls -A /opt/airflow/project)" ] && chmod -R 644 /opt/airflow/project/* || true && \
    chmod 755 /opt/airflow/project /opt/airflow/data && \
    # Ensure all directories under data are accessible
    find /opt/airflow/data -type d -exec chmod 755 {} \; && \
    # Set appropriate permissions for files
    find /opt/airflow/data -type f -exec chmod 644 {} \; && \
    # Make sure output directories are writable
    chmod -R 777 /opt/airflow/data/openEHR_compositions/output \
    /opt/airflow/data/EPIC_output

# Switch back to airflow user
USER airflow

# Verify environment file exists
RUN if [ -f /opt/airflow/project/.env.airflow ]; then echo "Environment file exists in final image"; else echo "WARNING: Environment file not found in final image"; fi
EOF

# Build the custom image
echo "Building custom airflow image..."
podman build -t custom-airflow $TEMP_DIR

# Clean up temporary directory
echo "Cleaning up temporary directory..."
rm -rf $TEMP_DIR

# Deploy the pods
echo "Deploying Airflow pod with custom image..."
podman play kube airflow-pod.yaml --network medscio-network

echo "Deploying HAPI FHIR pod..."
podman play kube hapi-fhir-pod.yaml --network medscio-network

echo "Deploying EHRBase pod..."
podman play kube ehrbase-pod.yaml --network medscio-network

# List running pods
echo ""
echo "Pods running:"
echo "-------------"
podman pod ps

# List all containers
echo ""
echo "Containers running:"
echo "------------------"
podman ps

# Wait for services to initialize with progress bar
echo ""
echo "Waiting for services to initialize (60 seconds)..."
WAIT_TIME=60
for (( i=WAIT_TIME; i>=0; i-- )); do
    # Calculate progress percentage and bar length
    percent=$((100*(WAIT_TIME-i)/WAIT_TIME))
    completed=$((percent/2))
    remaining=$((50-completed))
    
    # Create the progress bar
    bar="["
    for (( j=0; j<completed; j++ )); do
        bar+="="
    done
    if [ $i -ne 0 ]; then
        bar+=">"
        remaining=$((remaining-1))
    fi
    for (( j=0; j<remaining; j++ )); do
        bar+=" "
    done
    bar+="] $percent%"
    
    # Print the progress bar and countdown
    printf "\r%-60s %3ds remaining" "$bar" "$i"
    sleep 1
done
printf "\n\nServices should be ready now!\n"

# Check if the environment file is in the container
echo ""
echo "Checking if environment file exists in container..."
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/.env.airflow || echo 'Environment file not found!'"

# Verify data directory contents in the container
echo ""
echo "Checking data directory in container..."
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/data/ || echo 'Data directory not found or empty!'"

# Verify permissions on output directories
echo ""
echo "Checking permissions on output directories..."
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/data/openEHR_compositions/ || echo 'openEHR_compositions directory not found!'"
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/data/EPIC_output/ || echo 'EPIC_output directory not found!'"

# Verify network connectivity using curl 
echo ""
echo "Testing pod network connectivity..."
echo "----------------------------------"
echo "Testing basic network connectivity between services:"

# Test connectivity to Airflow
echo "Testing Airflow webserver connectivity:"
if podman container inspect airflow-airflow-webserver &>/dev/null && \
   [ "$(podman container inspect -f '{{.State.Running}}' airflow-airflow-webserver)" = "true" ]; then
    podman exec -t airflow-airflow-webserver curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080 || echo "  → Could not connect to Airflow webserver"
else
    echo "  → Airflow webserver container is not running, skipping connectivity test"
fi

# Test connectivity to HAPI FHIR
echo "Testing HAPI FHIR connectivity:"
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8082/fhir/metadata || echo "  → Could not connect to HAPI FHIR"

# Test connectivity to EHRBase
echo "Testing EHRBase connectivity:"
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8084/ehrbase || echo "  → Could not connect to EHRBase"

# DNS resolution test
echo ""
echo "Testing DNS resolution between pods:"
podman exec -t airflow-airflow-webserver getent hosts hapi-fhir 2>/dev/null || echo "  → Failed to resolve hapi-fhir from Airflow"
podman exec -t airflow-airflow-webserver getent hosts ehrbase 2>/dev/null || echo "  → Failed to resolve ehrbase from Airflow"

# Check service availability with more information
echo ""
echo "Testing service availability..."
echo "-----------------------------"

echo "Checking HAPI FHIR service:"
HAPI_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/fhir/metadata)
if [ "$HAPI_STATUS" -eq 200 ]; then
    echo "  ✓ HAPI FHIR is running (Status: $HAPI_STATUS)"
else
    echo "  ✗ HAPI FHIR service check failed (Status: $HAPI_STATUS)"
fi

echo "Checking Airflow service:"
AIRFLOW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8090)
if [ "$AIRFLOW_STATUS" -eq 200 ] || [ "$AIRFLOW_STATUS" -eq 302 ]; then
    echo "  ✓ Airflow is running (Status: $AIRFLOW_STATUS)"
else
    echo "  ✗ Airflow service check failed (Status: $AIRFLOW_STATUS)"
fi

echo "Checking EHRBase service:"
EHRBASE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8084/ehrbase)
if [ "$EHRBASE_STATUS" -eq 200 ] || [ "$EHRBASE_STATUS" -eq 302 ]; then
    echo "  ✓ EHRBase is running (Status: $EHRBASE_STATUS)"
else
    echo "  ✗ EHRBase service check failed (Status: $EHRBASE_STATUS)"
fi

echo ""
echo "Deployment complete!"
echo "-------------------"
echo "Access Airflow at: http://localhost:8090"
echo "Access HAPI FHIR at: http://localhost:8082/fhir/metadata"
echo "Access EHRBase at: http://localhost:8084/ehrbase"
echo ""