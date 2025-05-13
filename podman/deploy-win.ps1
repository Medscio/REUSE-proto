# PowerShell deployment script for Windows
# Equivalent to the original Bash script

param(
    [Parameter(Mandatory=$true)]
    [string]$RepoDir
)

# Set error action to stop on errors
$ErrorActionPreference = "Stop"

# Validate that the directory exists
if (-Not (Test-Path -Path $RepoDir -PathType Container)) {
    Write-Error "Error: Repository directory '$RepoDir' does not exist."
    exit 1
}

# Print status messages
Write-Host "Starting deployment script..."
Write-Host "Using repository directory: $RepoDir"
Write-Host "----------------------------"

# Remove existing pods if they exist
Write-Host "Removing existing pods..."
try {
    podman pod rm -f airflow 2>$null
} catch {
    Write-Host "No existing airflow pod found"
}

try {
    podman pod rm -f hapi-fhir 2>$null
} catch {
    Write-Host "No existing hapi-fhir pod found"
}

try {
    podman pod rm -f ehrbase 2>$null
} catch {
    Write-Host "No existing ehrbase pod found"
}

# Check if network exists and remove it
Write-Host "Checking for existing network..."
try {
    podman network inspect medscio-network >$null 2>&1
    Write-Host "Removing existing medscio-network..."
    podman network rm medscio-network
} catch {
    Write-Host "Network doesn't exist yet"
}

# Create the network
Write-Host "Creating medscio-network..."
podman network create medscio-network

# Modify the Airflow image 
Write-Host "Creating a custom Airflow image"

# Create a temporary directory for our Dockerfile
$TempDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
Write-Host "Using temporary directory: $TempDir"

# Create a fixed Dockerfile that works better with Podman
$DockerfileContent = @'
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
'@

Set-Content -Path "$TempDir\Dockerfile" -Value $DockerfileContent

# Create data directory structure in temp dir
Write-Host "Creating data directory structure..."
$DataStructure = @(
    "$TempDir\data",
    "$TempDir\data\openEHR_templates",
    "$TempDir\data\openEHR_compositions\output",
    "$TempDir\data\EPIC_output",
    "$TempDir\data\hapi_fhir_profiles"
)

foreach ($dir in $DataStructure) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# Copy data files if they exist
if (Test-Path -Path "$RepoDir\data" -PathType Container) {
    Write-Host "Copying data files..."
    
    # Copy openEHR_templates
    if (Test-Path -Path "$RepoDir\data\openEHR_templates" -PathType Container) {
        $files = Get-ChildItem -Path "$RepoDir\data\openEHR_templates" -Recurse
        if ($files.Count -gt 0) {
            Copy-Item -Path "$RepoDir\data\openEHR_templates\*" -Destination "$TempDir\data\openEHR_templates\" -Recurse -Force
        } else {
            Write-Host "No files in openEHR_templates"
        }
    }
    
    # Copy openEHR_compositions (excluding output directory)
    if (Test-Path -Path "$RepoDir\data\openEHR_compositions" -PathType Container) {
        Get-ChildItem -Path "$RepoDir\data\openEHR_compositions" | ForEach-Object {
            if ($_.Name -ne "output") {
                Copy-Item -Path $_.FullName -Destination "$TempDir\data\openEHR_compositions\" -Recurse -Force
            }
        }
    }
    
    # Copy EPIC_output
    if (Test-Path -Path "$RepoDir\data\EPIC_output" -PathType Container) {
        $files = Get-ChildItem -Path "$RepoDir\data\EPIC_output" -Recurse
        if ($files.Count -gt 0) {
            Copy-Item -Path "$RepoDir\data\EPIC_output\*" -Destination "$TempDir\data\EPIC_output\" -Recurse -Force
        } else {
            Write-Host "No files in EPIC_output"
        }
    }
    
    # Copy hapi_fhir_profiles
    if (Test-Path -Path "$RepoDir\data\hapi_fhir_profiles" -PathType Container) {
        $files = Get-ChildItem -Path "$RepoDir\data\hapi_fhir_profiles" -Recurse
        if ($files.Count -gt 0) {
            Copy-Item -Path "$RepoDir\data\hapi_fhir_profiles\*" -Destination "$TempDir\data\hapi_fhir_profiles\" -Recurse -Force
        } else {
            Write-Host "No files in hapi_fhir_profiles"
        }
    }
    
    Write-Host "Verifying data files were copied to temp directory:"
    Get-ChildItem -Path "$TempDir\data\" -Force
    Write-Host "Checking output directories:"
    Get-ChildItem -Path "$TempDir\data\openEHR_compositions\" -Force
} else {
    Write-Host "WARNING: data directory not found at $RepoDir\data"
}

# Set permissions for Windows - this is just for compatibility
# In Windows, we don't need to explicitly set these permissions like in Linux
New-Item -ItemType Directory -Force -Path "$TempDir\data\openEHR_compositions\output" | Out-Null
New-Item -ItemType Directory -Force -Path "$TempDir\data\EPIC_output" | Out-Null

# Copy .env.airflow file if it exists
if (Test-Path -Path "$RepoDir\.env.airflow" -PathType Leaf) {
    Write-Host "Copying .env.airflow file..."
    New-Item -ItemType Directory -Force -Path "$TempDir\project" | Out-Null
    Copy-Item -Path "$RepoDir\.env.airflow" -Destination "$TempDir\project\.env.airflow"
    Write-Host "Verifying .env.airflow file was copied to temp directory:"
    Get-ChildItem -Path "$TempDir\project\" -Force
} else {
    Write-Host "WARNING: .env.airflow file not found at $RepoDir\.env.airflow"
}

# Continue appending to the Dockerfile
$DockerfileAddition1 = @'
# Copy data files
COPY data/ /opt/airflow/data/

# Copy environment file to a location not affected by mounts
COPY project/.env.airflow /opt/airflow/.env.airflow
'@

Add-Content -Path "$TempDir\Dockerfile" -Value $DockerfileAddition1

# Always copy project files if the directory exists
if (Test-Path -Path "$TempDir\project" -PathType Container) {
    Write-Host "Adding project files to Dockerfile..."
    $DockerfileAddition2 = @'
# Copy project files
COPY --chown=airflow:root project/ /opt/airflow/project/
'@
    Add-Content -Path "$TempDir\Dockerfile" -Value $DockerfileAddition2
    
    # Verify what files will be copied
    Write-Host "Files that will be copied from project directory:"
    Get-ChildItem -Path "$TempDir\project\" -Force
} else {
    Write-Host "WARNING: project directory does not exist in temporary directory"
}

# Finish the Dockerfile
$DockerfileAddition3 = @'
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
'@

Add-Content -Path "$TempDir\Dockerfile" -Value $DockerfileAddition3

# Build the custom image
Write-Host "Building custom airflow image..."
# Convert Windows path to Unix-style for Podman
$TempDirUnix = $TempDir -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
podman build -t custom-airflow $TempDir

# Clean up temporary directory
Write-Host "Cleaning up temporary directory..."
Remove-Item -Path $TempDir -Recurse -Force

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
$WaitTime = 60
for ($i = $WaitTime; $i -ge 0; $i--) {
    # Calculate progress percentage and bar length
    $percent = [math]::Floor(100 * ($WaitTime - $i) / $WaitTime)
    $completed = [math]::Floor($percent / 2)
    $remaining = 50 - $completed
    
    # Create the progress bar
    $bar = "["
    for ($j = 0; $j -lt $completed; $j++) {
        $bar += "="
    }
    if ($i -ne 0) {
        $bar += ">"
        $remaining--
    }
    for ($j = 0; $j -lt $remaining; $j++) {
        $bar += " "
    }
    $bar += "] $percent%"
    
    # Print the progress bar and countdown
    Write-Host "`r$bar $i`s remaining" -NoNewline
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
$containerExists = $false
$containerRunning = $false

try {
    $containerInfo = podman container inspect airflow-airflow-webserver
    $containerExists = $true
    $containerRunning = ($containerInfo | ConvertFrom-Json).State.Running
} catch {
    $containerExists = $false
}

if ($containerExists -and $containerRunning) {
    podman exec -t airflow-airflow-webserver curl -s -o /dev/null -w "%{http_code}`n" http://localhost:8080
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  → Could not connect to Airflow webserver"
    }
} else {
    Write-Host "  → Airflow webserver container is not running, skipping connectivity test"
}

# Function to test connectivity
function Test-Connectivity {
    param (
        [string]$Url
    )
    
    try {
        $result = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction SilentlyContinue
        return $result.StatusCode
    } catch [System.Net.WebException] {
        if ($_.Exception.Response -ne $null) {
            return $_.Exception.Response.StatusCode.value__
        } else {
            return 0
        }
    } catch {
        return 0
    }
}

# Test connectivity to HAPI FHIR
Write-Host "Testing HAPI FHIR connectivity:"
$hapiStatus = Test-Connectivity -Url "http://localhost:8082/fhir/metadata"
if ($hapiStatus -eq 0) {
    Write-Host "  → Could not connect to HAPI FHIR"
} else {
    Write-Host $hapiStatus
}

# Test connectivity to EHRBase
Write-Host "Testing EHRBase connectivity:"
$ehrStatus = Test-Connectivity -Url "http://localhost:8084/ehrbase"
if ($ehrStatus -eq 0) {
    Write-Host "  → Could not connect to EHRBase"
} else {
    Write-Host $ehrStatus
}

# DNS resolution test
Write-Host ""
Write-Host "Testing DNS resolution between pods:"
podman exec -t airflow-airflow-webserver getent hosts hapi-fhir 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  → Failed to resolve hapi-fhir from Airflow"
}

podman exec -t airflow-airflow-webserver getent hosts ehrbase 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  → Failed to resolve ehrbase from Airflow"
}

# Check service availability with more information
Write-Host ""
Write-Host "Testing service availability..."
Write-Host "-----------------------------"

Write-Host "Checking HAPI FHIR service:"
$hapiStatus = Test-Connectivity -Url "http://localhost:8082/fhir/metadata"
if ($hapiStatus -eq 200) {
    Write-Host "  ✓ HAPI FHIR is running (Status: $hapiStatus)"
} else {
    Write-Host "  ✗ HAPI FHIR service check failed (Status: $hapiStatus)"
}

Write-Host "Checking Airflow service:"
$airflowStatus = Test-Connectivity -Url "http://localhost:8090"
if ($airflowStatus -eq 200 -or $airflowStatus -eq 302) {
    Write-Host "  ✓ Airflow is running (Status: $airflowStatus)"
} else {
    Write-Host "  ✗ Airflow service check failed (Status: $airflowStatus)"
}

Write-Host "Checking EHRBase service:"
$ehrbaseStatus = Test-Connectivity -Url "http://localhost:8084/ehrbase"
if ($ehrbaseStatus -eq 200 -or $ehrbaseStatus -eq 302) {
    Write-Host "  ✓ EHRBase is running (Status: $ehrbaseStatus)"
} else {
    Write-Host "  ✗ EHRBase service check failed (Status: $ehrbaseStatus)"
}

Write-Host ""
Write-Host "Deployment complete!"
Write-Host "-------------------"
Write-Host "Access Airflow at: http://localhost:8090"
Write-Host "Access HAPI FHIR at: http://localhost:8082/fhir/metadata"
Write-Host "Access EHRBase at: http://localhost:8084/ehrbase""
Write-Host ""