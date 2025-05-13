# PowerShell deployment script
# Redirect output to a log file
Start-Transcript -Path "deploy_log.txt" -Append

# Check if repository directory argument is provided
if ($args.Count -ne 1) {
    Write-Error "Error: Repository directory argument is required (must be absolute path)."
    Write-Error "Usage: .\deploy.ps1 <repository-directory>"
    Stop-Transcript
    exit 1
}

# Store repository directory path
$REPO_DIR = $args[0]

# Validate that the directory exists
if (-not (Test-Path -Path $REPO_DIR -PathType Container)) {
    Write-Error "Error: Repository directory '$REPO_DIR' does not exist."
    Stop-Transcript
    exit 1
}

# Print status messages
Write-Host "Starting deployment script..."
Write-Host "Using repository directory: $REPO_DIR"
Write-Host "----------------------------"

# Remove existing pods if they exist
Write-Host "Removing existing pods..."
try {
    podman pod rm -f airflow 2>$null
} catch {
    Write-Host "No existing airflow pod to remove."
}

try {
    podman pod rm -f hapi-fhir 2>$null
} catch {
    Write-Host "No existing hapi-fhir pod to remove."
}

try {
    podman pod rm -f ehrbase 2>$null
} catch {
    Write-Host "No existing ehrbase pod to remove."
}

# Check if network exists and remove it
Write-Host "Checking for existing network..."
try {
    podman network inspect medscio-network >$null 2>&1
    Write-Host "Removing existing medscio-network..."
    podman network rm medscio-network
} catch {
    Write-Host "No existing medscio-network to remove."
}

# Create the network
Write-Host "Creating medscio-network..."
podman network create medscio-network

# Modify the Airflow image
Write-Host "Creating a custom Airflow image"

# Create a temporary directory for our Dockerfile
$TEMP_DIR = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
New-Item -Path $TEMP_DIR -ItemType Directory -Force | Out-Null
Write-Host "Using temporary directory: $TEMP_DIR"

# Create a fixed Dockerfile that works better with Podman
@'
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
'@ | Out-File -FilePath "$TEMP_DIR\Dockerfile" -Encoding utf8

# Create data directory structure in temp dir
Write-Host "Creating data directory structure..."
New-Item -Path "$TEMP_DIR\data" -ItemType Directory -Force | Out-Null
New-Item -Path "$TEMP_DIR\data\openEHR_templates" -ItemType Directory -Force | Out-Null
New-Item -Path "$TEMP_DIR\data\openEHR_compositions\output" -ItemType Directory -Force | Out-Null
New-Item -Path "$TEMP_DIR\data\EPIC_output" -ItemType Directory -Force | Out-Null
New-Item -Path "$TEMP_DIR\data\hapi_fhir_profiles" -ItemType Directory -Force | Out-Null

# Copy data files if they exist
if (Test-Path -Path "$REPO_DIR\data" -PathType Container) {
    Write-Host "Copying data files..."
    
    # Copy only the contents of each subdirectory if they exist
    if (Test-Path -Path "$REPO_DIR\data\openEHR_templates" -PathType Container) {
        try {
            Copy-Item -Path "$REPO_DIR\data\openEHR_templates\*" -Destination "$TEMP_DIR\data\openEHR_templates\" -Recurse -ErrorAction SilentlyContinue
        } catch {
            Write-Host "No files in openEHR_templates"
        }
    }
    
    if (Test-Path -Path "$REPO_DIR\data\openEHR_compositions" -PathType Container) {
        # Don't overwrite the output directory we just created
        Get-ChildItem -Path "$REPO_DIR\data\openEHR_compositions" -Exclude "output" | ForEach-Object {
            try {
                Copy-Item -Path $_.FullName -Destination "$TEMP_DIR\data\openEHR_compositions\" -Recurse -ErrorAction SilentlyContinue
            } catch {
                Write-Host "Error copying $_"
            }
        }
    }
    
    if (Test-Path -Path "$REPO_DIR\data\EPIC_output" -PathType Container) {
        try {
            Copy-Item -Path "$REPO_DIR\data\EPIC_output\*" -Destination "$TEMP_DIR\data\EPIC_output\" -Recurse -ErrorAction SilentlyContinue
        } catch {
            Write-Host "No files in EPIC_output"
        }
    }
    
    if (Test-Path -Path "$REPO_DIR\data\hapi_fhir_profiles" -PathType Container) {
        try {
            Copy-Item -Path "$REPO_DIR\data\hapi_fhir_profiles\*" -Destination "$TEMP_DIR\data\hapi_fhir_profiles\" -Recurse -ErrorAction SilentlyContinue
        } catch {
            Write-Host "No files in hapi_fhir_profiles"
        }
    }
    
    Write-Host "Verifying data files were copied to temp directory:"
    Get-ChildItem -Path "$TEMP_DIR\data\" -Force
    Write-Host "Checking output directories:"
    Get-ChildItem -Path "$TEMP_DIR\data\openEHR_compositions\" -Force
} else {
    Write-Host "WARNING: data directory not found at $REPO_DIR\data"
}

# Ensure the output directory exists and has the right permissions in the temp directory
# Note: We can't directly set 777 permissions in PowerShell, but on Windows this is less of an issue

# Copy .env.airflow file if it exists
if (Test-Path -Path "$REPO_DIR\.env.airflow" -PathType Leaf) {
    Write-Host "Copying .env.airflow file..."
    New-Item -Path "$TEMP_DIR\project" -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$REPO_DIR\.env.airflow" -Destination "$TEMP_DIR\project\"
    Write-Host "Verifying .env.airflow file was copied to temp directory:"
    Get-ChildItem -Path "$TEMP_DIR\project\" -Force
} else {
    Write-Host "WARNING: .env.airflow file not found at $REPO_DIR\.env.airflow"
}

# Continue appending to the Dockerfile now that we know if project files exist
@'
# Copy data files
COPY data/ /opt/airflow/data/

# Copy environment file to a location not affected by mounts
COPY project/.env.airflow /opt/airflow/.env.airflow
'@ | Add-Content -Path "$TEMP_DIR\Dockerfile"

# Always copy project files if the directory exists
if (Test-Path -Path "$TEMP_DIR\project" -PathType Container) {
    Write-Host "Adding project files to Dockerfile..."
    @'
# Copy project files
COPY --chown=airflow:root project/ /opt/airflow/project/
'@ | Add-Content -Path "$TEMP_DIR\Dockerfile"
    
    # Verify what files will be copied
    Write-Host "Files that will be copied from project directory:"
    Get-ChildItem -Path "$TEMP_DIR\project\" -Force
} else {
    Write-Host "WARNING: project directory does not exist in temporary directory"
}

# Finish the Dockerfile
@'
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
'@ | Add-Content -Path "$TEMP_DIR\Dockerfile"

# Build the custom image
Write-Host "Building custom airflow image..."
podman build -t custom-airflow $TEMP_DIR

# Clean up temporary directory
Write-Host "Cleaning up temporary directory..."
Remove-Item -Path $TEMP_DIR -Recurse -Force

# Deploy the pods
Write-Host "Deploying Airflow pod with custom image..."
podman play kube airflow-pod.yaml --network medscio-network

Write-Host "Deploying HAPI FHIR pod..."
podman play kube hapi-fhir-pod.yaml --network medscio-network

Write-Host "Deploying EHRBase pod..."
podman play kube ehrbase-pod.yaml --network medscio-network

# List running pods
Write-Host ""
Write-Host "Pods running:"
Write-Host "-------------"
podman pod ps

# List all containers
Write-Host ""
Write-Host "Containers running:"
Write-Host "------------------"
podman ps

# Wait for services to initialize with progress bar
Write-Host ""
Write-Host "Waiting for services to initialize (60 seconds)..."
$WAIT_TIME = 60
for ($i = $WAIT_TIME; $i -ge 0; $i--) {
    # Calculate progress percentage and bar length
    $percent = [int](100 * ($WAIT_TIME - $i) / $WAIT_TIME)
    $completed = [int]($percent / 2)
    $remaining = 50 - $completed
    
    # Create the progress bar
    $bar = "["
    for ($j = 0; $j -lt $completed; $j++) {
        $bar += "="
    }
    if ($i -ne 0) {
        $bar += ">"
        $remaining = $remaining - 1
    }
    for ($j = 0; $j -lt $remaining; $j++) {
        $bar += " "
    }
    $bar += "] $percent%"
    
    # Print the progress bar and countdown
    Write-Host -NoNewline "`r{0,-60} {1,3}s remaining" -f $bar, $i
    Start-Sleep -Seconds 1
}
Write-Host "`n`nServices should be ready now!"

# Check if the environment file is in the container
Write-Host ""
Write-Host "Checking if environment file exists in container..."
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/.env.airflow || echo 'Environment file not found!'"

# Verify data directory contents in the container
Write-Host ""
Write-Host "Checking data directory in container..."
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/data/ || echo 'Data directory not found or empty!'"

# Verify permissions on output directories
Write-Host ""
Write-Host "Checking permissions on output directories..."
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/data/openEHR_compositions/ || echo 'openEHR_compositions directory not found!'"
podman exec -it airflow-airflow-webserver bash -c "ls -la /opt/airflow/data/EPIC_output/ || echo 'EPIC_output directory not found!'"

# Verify network connectivity using curl 
Write-Host ""
Write-Host "Testing pod network connectivity..."
Write-Host "----------------------------------"
Write-Host "Testing basic network connectivity between services:"

# Test connectivity to Airflow
Write-Host "Testing Airflow webserver connectivity:"
try {
    $containerInfo = podman container inspect airflow-airflow-webserver 2>$null
    $isRunning = podman container inspect -f '{{.State.Running}}' airflow-airflow-webserver
    if ($isRunning -eq "true") {
        podman exec -t airflow-airflow-webserver curl -s -o /dev/null -w "%{http_code}`n" http://localhost:8080
    } else {
        Write-Host "  → Airflow webserver container is not running, skipping connectivity test"
    }
} catch {
    Write-Host "  → Could not connect to Airflow webserver"
}

# Test connectivity to HAPI FHIR
Write-Host "Testing HAPI FHIR connectivity:"
try {
    $response = Invoke-WebRequest -Uri "http://localhost:8082/fhir/metadata" -Method Get -ErrorAction SilentlyContinue
    Write-Host $response.StatusCode
} catch {
    Write-Host "  → Could not connect to HAPI FHIR"
}

# Test connectivity to EHRBase
Write-Host "Testing EHRBase connectivity:"
try {
    $response = Invoke-WebRequest -Uri "http://localhost:8084/ehrbase" -Method Get -ErrorAction SilentlyContinue
    Write-Host $response.StatusCode
} catch {
    Write-Host "  → Could not connect to EHRBase"
}

# DNS resolution test
Write-Host ""
Write-Host "Testing DNS resolution between pods:"
try {
    podman exec -t airflow-airflow-webserver getent hosts hapi-fhir 2>$null
} catch {
    Write-Host "  → Failed to resolve hapi-fhir from Airflow"
}

try {
    podman exec -t airflow-airflow-webserver getent hosts ehrbase 2>$null
} catch {
    Write-Host "  → Failed to resolve ehrbase from Airflow"
}

# Check service availability with more information
Write-Host ""
Write-Host "Testing service availability..."
Write-Host "-----------------------------"

Write-Host "Checking HAPI FHIR service:"
try {
    $response = Invoke-WebRequest -Uri "http://localhost:8082/fhir/metadata" -Method Get -ErrorAction SilentlyContinue
    $HAPI_STATUS = $response.StatusCode
    if ($HAPI_STATUS -eq 200) {
        Write-Host "  ✓ HAPI FHIR is running (Status: $HAPI_STATUS)"
    } else {
        Write-Host "  ✗ HAPI FHIR service check failed (Status: $HAPI_STATUS)"
    }
} catch {
    Write-Host "  ✗ HAPI FHIR service check failed (Status: Failed to connect)"
}

Write-Host "Checking Airflow service:"
try {
    $response = Invoke-WebRequest -Uri "http://localhost:8090" -Method Get -ErrorAction SilentlyContinue
    $AIRFLOW_STATUS = $response.StatusCode
    if ($AIRFLOW_STATUS -eq 200 -or $AIRFLOW_STATUS -eq 302) {
        Write-Host "  ✓ Airflow is running (Status: $AIRFLOW_STATUS)"
    } else {
        Write-Host "  ✗ Airflow service check failed (Status: $AIRFLOW_STATUS)"
    }
} catch {
    Write-Host "  ✗ Airflow service check failed (Status: Failed to connect)"
}

Write-Host "Checking EHRBase service:"
try {
    $response = Invoke-WebRequest -Uri "http://localhost:8084/ehrbase" -Method Get -ErrorAction SilentlyContinue
    $EHRBASE_STATUS = $response.StatusCode
    if ($EHRBASE_STATUS -eq 200 -or $EHRBASE_STATUS -eq 302) {
        Write-Host "  ✓ EHRBase is running (Status: $EHRBASE_STATUS)"
    } else {
        Write-Host "  ✗ EHRBase service check failed (Status: $EHRBASE_STATUS)"
    }
} catch {
    Write-Host "  ✗ EHRBase service check failed (Status: Failed to connect)"
}

Write-Host ""
Write-Host "Deployment complete!"
Write-Host "-------------------"
Write-Host "Access Airflow at: http://localhost:8090"
Write-Host "Access HAPI FHIR at: http://localhost:8082/fhir/metadata"
Write-Host "Access EHRBase at: http://localhost:8084/ehrbase"
Write-Host ""

Stop-Transcript