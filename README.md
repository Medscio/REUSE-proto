# REUSE Deployment
> NOTE: This repository is purely for architectural testing purposes (i.e, testing spawning and connectivity of multiple pods).

## Technical Overview
The `deploy.sh` script (located at `podman/deploy.sh`) performs the following technical operations:

1. **Environment Cleanup**:
   - Removes existing pods (`airflow`, `hapi-fhir`, `ehrbase`) using `podman pod rm`
   - Tears down the `medscio-network` if it exists

2. **Network Configuration**:
   - Creates an isolated `medscio-network` using `podman network create`

3. **Custom Docker Image Build**:
   - Extends `apache/airflow:2.6.3` base image
   - Creates required directory structure with appropriate permissions:
     - `/opt/airflow/project`
     - `/opt/airflow/data/openEHR_templates`
     - `/opt/airflow/data/openEHR_compositions/output`
     - `/opt/airflow/data/EPIC_output`
     - `/opt/airflow/data/hapi_fhir_profiles`
   - Copies data from host paths to container filesystem
   - Sets appropriate file permissions (644 for files, 755 for directories, 777 for output dirs)
   - Builds with `podman build` and tags as `custom-airflow`

4. **Pod Orchestration**:
   - Deploys pods using `podman play kube` with YAML configuration files:
     - `airflow-pod.yaml` → Airflow webserver, scheduler, and PostgreSQL database containers
     - `hapi-fhir-pod.yaml` → HAPI FHIR R4 server container with configurable Java settings and startup health probe
     - `ehrbase-pod.yaml` → EHRBase server container with dedicated PostgreSQL database container
   - Attaches all pods to the `medscio-network`

5. **Service Verification**:
   - Tests internal DNS resolution between containers
   - Verifies HTTP connectivity to services:
     - Airflow UI (port 8090)
     - HAPI FHIR server (port 8082)
     - EHRBase server (port 8084)
   - Validates container file permissions and environment configuration

## Deployment Instructions 

### Podman run method (under `/podman`)

1. To run, first give `deploy.sh` executable permissions by running the following command:

   ```bash
   chmod +x ./deploy.sh
   ```

2. Run the `deploy.sh` script with the repository directory path as a required argument:

   ```bash
   ./deploy.sh /path/to/your/repository
   ```

   For example:
   ```bash
   ./deploy.sh /home/username/dev/Medscio/REUSE-proto
   ```

   Note: The repository directory should contain the following structure:
   - `/data/` - Directory containing templates and other data files
   - `/.env.airflow` - Environment configuration file for Airflow

   * During deployment, if prompted to choose podman images, choose the images from the `docker.io` registry in ALL cases. For example:
   
        ```bash
        ? Please select an image: 
        registry.fedoraproject.org/postgres:14
        registry.access.redhat.com/postgres:14
        ▸ docker.io/library/postgres:14
        ```
        
3. To stop and remove all pods, run the following command:
   
   ```bash
    podman pod stop airflow && podman pod rm airflow && podman pod stop ehrbase && podman pod rm ehrbase && podman pod stop hapi-fhir && podman pod rm hapi-fhir
   ```

### podman-compose method (under `/podman-compose`)
1. To run, first give `deploy.sh` executable permissions by running the following command:

   ```bash
   chmod +x ./deploy.sh
   ```

2. Simply run the deploy script with the repository directory path as a required argument:

   ```bash
   ./deploy.sh 
   ```
   * During deployment, if prompted to choose podman images, choose the images from the `docker.io` registry in ALL cases. For example:
   
        ```bash
        ? Please select an image: 
        registry.fedoraproject.org/postgres:14
        registry.access.redhat.com/postgres:14
        ▸ docker.io/library/postgres:14
        ```

## Troubleshooting

If you encounter an error indicating that the repository directory does not exist, verify that:
1. You've provided the correct path to your repository
2. The path is absolute (starts with `/`) i.e, must be an absolute path
3. You have appropriate permissions to read from the specified directory

If the deployment fails due to missing data files or environment files, ensure that your repository directory follows the expected structure:
```
/your/repository/path/
├── .env.airflow
└── data/
    ├── openEHR_templates/
    ├── openEHR_compositions/
    ├── EPIC_output/
    └── hapi_fhir_profiles/
```
