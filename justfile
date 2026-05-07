# Manage Talos Linux VMs on remote Proxmox hosts via SSH
set unstable
set dotenv-load := true
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# -----------------------------
# Proxmox connection
# -----------------------------

pve_host        := env('PVE_HOST', '')
pve_user        := env('PVE_USER', '')
current_cluster := env('TALOS_CLUSTER', '')
sudo            := if pve_user == "root" { "" } else { "sudo" }
ssh_target      := pve_user + "@" + pve_host

# -----------------------------
# VM defaults
# -----------------------------

talos_version := env('TALOS_VERSION', '') || '1.13.0'
talos_storage := env('TALOS_STORAGE', '') || 'local-lvm'
talos_bridge  := env('TALOS_BRIDGE',  '') || 'vmbr0'
talos_image   := env('TALOS_IMAGE',   '') || '/var/lib/vz/template/qcow2/talos-' + talos_version + '.qcow2'

# Control plane defaults
cp_cores  := env('TALOS_CP_CORES',  '') || '2'
cp_memory := env('TALOS_CP_MEMORY', '') || '4096'
cp_disk   := env('TALOS_CP_DISK',   '') || '50'

# Worker defaults
worker_cores  := env('TALOS_WORKER_CORES',  '') || '4'
worker_memory := env('TALOS_WORKER_MEMORY', '') || '16384'
worker_disk   := env('TALOS_WORKER_DISK',   '') || '100'

# -----------------------------
# Preflight
# -----------------------------

# Validate required env vars and tool dependencies (used as a guard by other recipes)
check:
    #!/usr/bin/env bash
    set -euo pipefail
    errors=0
    [ -n "{{ pve_host }}" ]        || { echo "PVE_HOST is not set";       errors=$((errors+1)); }
    [ -n "{{ pve_user }}" ]        || { echo "PVE_USER is not set";       errors=$((errors+1)); }
    [ -n "{{ current_cluster }}" ] || { echo "TALOS_CLUSTER is not set";  errors=$((errors+1)); }
    command -v jq &>/dev/null      || { echo "jq not found (required for get-ip / get-ips)"; errors=$((errors+1)); }
    [ $errors -eq 0 ] || { echo "Set missing values in .env or export them — see .env.example"; exit 1; }

# -----------------------------
# SSH helper
# -----------------------------

[private]
_ssh +cmd:
    ssh {{ ssh_target }} {{ sudo }} {{ cmd }}

# -----------------------------
# VM lifecycle
# -----------------------------

# Create N control plane VMs, adding to any already in the cluster
create-cp-vms count cores=cp_cores memory=cp_memory disk=cp_disk: check
    just _create-vm-group "{{ count }}" "controlplane" "talos-{{ current_cluster }}-cp" "{{ cores }}" "{{ memory }}" "{{ disk }}"

# Create N worker VMs, adding to any already in the cluster
create-worker-vms count cores=worker_cores memory=worker_memory disk=worker_disk: check
    just _create-vm-group "{{ count }}" "worker" "talos-{{ current_cluster }}-worker" "{{ cores }}" "{{ memory }}" "{{ disk }}"

# Create all Talos VMs (control plane + workers)
create-vms count_cp count_workers: check
    just create-cp-vms "{{ count_cp }}"
    just create-worker-vms "{{ count_workers }}"

# Create a single control plane VM (vmid and name auto-assigned)
create-cp cores=cp_cores memory=cp_memory disk=cp_disk: check
    just _create-vm-group "1" "controlplane" "talos-{{ current_cluster }}-cp" "{{ cores }}" "{{ memory }}" "{{ disk }}"

# Create a single worker VM (vmid and name auto-assigned)
create-worker cores=worker_cores memory=worker_memory disk=worker_disk: check
    just _create-vm-group "1" "worker" "talos-{{ current_cluster }}-worker" "{{ cores }}" "{{ memory }}" "{{ disk }}"

[private]
_create-vm-group count role name_prefix cores memory disk:
    #!/usr/bin/env bash
    set -euo pipefail
    prefix="{{ name_prefix }}"
    prefix="${prefix//_/-}"
    base=$(just _vmids-by-role "{{ role }}" | wc -l | xargs)
    for i in $(seq 1 {{ count }}); do
        vmid=$(just next-id)
        name=$(printf "%s-%02d" "$prefix" $((base + i)))
        echo "Creating $name (VMID $vmid)..."
        just _create-vm "$vmid" "$name" "{{ cores }}" "{{ memory }}" "{{ disk }}" "{{ role }}"
    done

[private]
_create-vm vmid name cores memory disk role:
    #!/usr/bin/env bash
    set -euo pipefail
    if just _ssh "qm status {{ vmid }}" &>/dev/null; then
        echo "VM {{ vmid }} ({{ name }}) already exists, skipping"
        exit 0
    fi
    just _ssh "qm create {{ vmid }} --name {{ name }} --tags talos,{{ role }},{{ current_cluster }} --cpu host --cores {{ cores }} --memory {{ memory }} --scsihw virtio-scsi-pci --net0 virtio,bridge={{ talos_bridge }} --ostype l26 --agent enabled=1"
    just _ssh "qm importdisk {{ vmid }} {{ talos_image }} {{ talos_storage }}"
    just _ssh "qm set {{ vmid }} --scsi0 {{ talos_storage }}:vm-{{ vmid }}-disk-0"
    just _ssh "qm set {{ vmid }} --boot order=scsi0"
    just _ssh "qm resize {{ vmid }} scsi0 {{ disk }}G"
    echo "Created VM {{ name }} ({{ vmid }})"

# Start all Talos VMs in the current cluster
start-vms: check
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r vmid; do
        echo "Starting VM $vmid..."
        just _ssh "qm start $vmid" || echo "VM $vmid may already be running"
    done < <(just _vmids-by-role)

# Stop all Talos VMs in the current cluster
stop-vms: check
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r vmid; do
        echo "Stopping VM $vmid..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
    done < <(just _vmids-by-role)

# Destroy all Talos VMs in the current cluster (stop + delete + purge disks)
destroy-vms: check
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r vmid; do
        echo "Destroying VM $vmid..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
        just _ssh "qm destroy $vmid --purge" 2>/dev/null || true
    done < <(just _vmids-by-role)

# Resize a VM's primary disk
resize-disk vmid additional_gb: check
    just _ssh "qm resize {{ vmid }} scsi0 +{{ additional_gb }}G"

# -----------------------------
# Querying
# -----------------------------

# Return the first unused VMID on the cluster
next-id: check
    just _ssh "pvesh get /cluster/nextid"

# List VMIDs in the current cluster; pass a role tag to filter (omit for all cluster VMs)
[private]
_vmids-by-role role="":
    #!/usr/bin/env bash
    set -euo pipefail
    ssh {{ ssh_target }} bash <<'REMOTE'
    for vmid in $({{ sudo }} qm list | tail -n+2 | awk '{print $1}'); do
        tags=$({{ sudo }} qm config "$vmid" | grep -oP '^tags:\s*\K.*' || true)
        if echo "$tags" | grep -q "{{ current_cluster }}"; then
            [[ -z "{{ role }}" ]] || echo "$tags" | grep -q "{{ role }}" || continue
            echo "$vmid"
        fi
    done
    REMOTE

# Count existing control plane nodes
count-cp: check
    just _vmids-by-role "controlplane" | wc -l | xargs

# Count existing worker nodes
count-workers: check
    just _vmids-by-role "worker" | wc -l | xargs

# List all Talos-tagged VMs on the host
list-vms: check
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Talos VMs on {{ pve_host }}:"
    ssh {{ ssh_target }} bash <<'REMOTE'
    all=$({{ sudo }} qm list)
    echo "$all" | head -1
    while IFS= read -r vmid; do
        tags=$({{ sudo }} qm config "$vmid" | grep -oP '^tags:\s*\K.*' || true)
        echo "$tags" | grep -q "talos" && echo "$all" | awk -v id="$vmid" '$1 == id'
    done < <(echo "$all" | tail -n+2 | awk '{print $1}')
    REMOTE

# Show status of all cluster VMs
status: check
    #!/usr/bin/env bash
    set -euo pipefail
    printf "%-8s %-20s %-10s\n" "VMID" "NAME" "STATUS"
    printf "%-8s %-20s %-10s\n" "----" "----" "------"
    while IFS= read -r vmid; do
        info=$(ssh {{ ssh_target }} \
            "{{ sudo }} qm status $vmid --verbose" 2>/dev/null) || { printf "%-8s %-20s %-10s\n" "$vmid" "?" "NOT FOUND"; continue; }
        name=$(echo "$info" | grep -oP '^name:\s*\K.*' || echo "?")
        status=$(echo "$info" | grep -oP '^status:\s*\K.*' || echo "?")
        printf "%-8s %-20s %-10s\n" "$vmid" "$name" "$status"
    done < <(just _vmids-by-role)

# Get the IP address of a VM via QEMU guest agent
get-ip vmid: check
    #!/usr/bin/env bash
    set -euo pipefail
    ssh {{ ssh_target }} \
        "{{ sudo }} qm guest cmd {{ vmid }} network-get-interfaces" \
        | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[] | select(."ip-address-type" == "ipv4") | ."ip-address"'

# Get IPs for all cluster VMs
get-ips: check
    just _print-role-ips "controlplane" "Control plane"
    just _print-role-ips "worker" "Workers"

[private]
_print-role-ips role label:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "{{ label }}:"
    while IFS= read -r vmid; do
        name=$(ssh {{ ssh_target }} "{{ sudo }} qm config $vmid" | grep -oP '^name:\s*\K.*' || echo "?")
        ip=$(just get-ip "$vmid" 2>/dev/null || echo "unavailable")
        echo "  $name ($vmid): $ip"
    done < <(just _vmids-by-role "{{ role }}")

# -----------------------------
# Snapshots
# -----------------------------

# Snapshot all VMs — disk-consistent only; VMs remain running (no --vmstate)
snapshot-all name="pre-change": check
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r vmid; do
        echo "Snapshotting VM $vmid as {{ name }}..."
        just _ssh "qm snapshot $vmid {{ name }} --description 'automated snapshot'"
    done < <(just _vmids-by-role)

# Rollback all VMs to a snapshot
rollback-all name="pre-change": check
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r vmid; do
        echo "Rolling back VM $vmid to {{ name }}..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
        just _ssh "qm rollback $vmid {{ name }}"
        just _ssh "qm start $vmid"
    done < <(just _vmids-by-role)
