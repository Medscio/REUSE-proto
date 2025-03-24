#!/bin/bash
set -e

echo "Starting simple deployment script..."
echo "----------------------------------"

# Check if podman-compose.yaml exists
if [ ! -f "podman-compose.yaml" ]; then
    echo "Error: podman-compose.yaml file not found in current directory."
    exit 1
fi

# Stop any running services
echo "Stopping any existing services..."
podman-compose down

# Create the network if it doesn't exist
if ! podman network inspect medscio-network &>/dev/null; then
    echo "Creating medscio-network..."
    podman network create medscio-network
else
    echo "Network medscio-network already exists."
fi

# Deploy using podman-compose
echo "Starting services with podman-compose..."
podman-compose -f podman-compose.yaml up -d

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

# Test connectivity between services
echo ""
echo "Testing connectivity between services..."
echo "-------------------------------------"

# Get container names
AIRFLOW_CONTAINER=$(podman ps --filter name=_airflow-webserver_ --format "{{.Names}}" | head -1)

if [ -n "$AIRFLOW_CONTAINER" ]; then
    echo "Testing DNS resolution from Airflow container ($AIRFLOW_CONTAINER):"
    podman exec -it $AIRFLOW_CONTAINER getent hosts hapi-fhir 2>/dev/null && echo "  ✓ Can resolve hapi-fhir" || echo "  ✗ Failed to resolve hapi-fhir"
    podman exec -it $AIRFLOW_CONTAINER getent hosts ehrbase 2>/dev/null && echo "  ✓ Can resolve ehrbase" || echo "  ✗ Failed to resolve ehrbase"
else
    echo "  ✗ Airflow container not found, skipping connectivity tests"
fi

echo ""
echo "Deployment complete!"
echo "-------------------"
echo "Access Airflow at: http://localhost:8090"
echo "Access HAPI FHIR at: http://localhost:8082/fhir/metadata"
echo "Access EHRBase at: http://localhost:8084/ehrbase"
echo ""