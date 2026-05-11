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
ctl_path        := "/tmp/proxmox-ctl-" + pve_user + "@" + pve_host
ssh_opts        := "-o ControlMaster=auto -o ControlPath=" + ctl_path + " -o ControlPersist=20s"
storage_cache   := "/tmp/proxmox-storage-" + pve_user + "@" + pve_host

# -----------------------------
# VM defaults
# -----------------------------

talos_version := env('TALOS_VERSION', '') || '1.13.0'
talos_url := env('TALOS_IMAGE_URL', '') || 'https://factory.talos.dev/image/3e1b2c3ef982e30932e0b669a9922e1a65d373f65e93640cd8c444f81e47352e/v' + talos_version + '/metal-amd64.qcow2'
talos_storage := env('TALOS_STORAGE', '')
talos_bridge  := env('TALOS_BRIDGE',  '') || 'vmbr0'
talos_image   := env('TALOS_IMAGE',   '') || '/var/lib/vz/template/qcow2/talos-' + talos_version + '.qcow2'

# Control plane defaults
cp_cores  := env('TALOS_CP_CORES',  '') || '2'
cp_memory := env('TALOS_CP_MEMORY', '') || '4096'
cp_disk   := env('TALOS_CP_DISK',   '') || '50'

# Worker defaults
worker_cores  := env('TALOS_WORKER_CORES',  '') || '96'
worker_memory := env('TALOS_WORKER_MEMORY', '') || '91442'
worker_disk   := env('TALOS_WORKER_DISK',   '') || '300'

# -----------------------------
# Preflight
# -----------------------------

# Validate required env vars, local tools, and remote Proxmox prerequisites
check:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -S "{{ ctl_path }}" ] && exit 0

    errors=0
    [ -n "{{ pve_host }}" ]        || { echo "PVE_HOST is not set";       errors=$((errors+1)); }
    [ -n "{{ pve_user }}" ]        || { echo "PVE_USER is not set";       errors=$((errors+1)); }
    [ -n "{{ current_cluster }}" ] || { echo "TALOS_CLUSTER is not set";  errors=$((errors+1)); }
    command -v jq &>/dev/null      || { echo "jq not found (required for get-ip / get-ips)"; errors=$((errors+1)); }
    [ $errors -eq 0 ] || { echo "Set missing values in .env or export them — see .env.example"; exit 1; }

    if ! ssh -n {{ ssh_opts }} {{ ssh_target }} "ip link show {{ talos_bridge }}" &>/dev/null; then
        echo "Bridge '{{ talos_bridge }}' not found on {{ pve_host }}. Available bridges:"
        ssh -n {{ ssh_opts }} {{ ssh_target }} "ip link show type bridge" 2>/dev/null \
            | grep -oP '^\d+:\s*\K[^:@]+' | sed 's/ //g; s/^/  /'
        echo "Set TALOS_BRIDGE in .env to one of the above."
        exit 1
    fi
    ssh -n {{ ssh_opts }} {{ ssh_target }} "mkdir -p $(dirname '{{ talos_image }}')"

# -----------------------------
# SSH helper
# -----------------------------

[private]
_ssh +cmd:
    ssh -n {{ ssh_opts }} {{ ssh_target }} {{ sudo }} {{ cmd }}

# Resolve storage pool: TALOS_STORAGE if set, else auto-detect and cache for the session
[private]
_storage:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -s "{{ storage_cache }}" ]; then
        cat "{{ storage_cache }}"
        exit 0
    fi
    [ -S "{{ ctl_path }}" ] || { echo "error: run 'just check' first" >&2; exit 1; }
    if [ -n "{{ talos_storage }}" ]; then
        echo "{{ talos_storage }}" > "{{ storage_cache }}"
        echo "{{ talos_storage }}"
        exit 0
    fi
    active=$(ssh -n {{ ssh_opts }} {{ ssh_target }} "pvesm status | awk 'NR>1 && \$3==\"active\" {print \$1}'")
    storage=$(echo "$active" | grep -E '^(local-lvm|local-zfs)$' | head -1 || true)
    if [ -z "$storage" ]; then
        storage=$(echo "$active" | grep -v '^local$' | head -1 || true)
    fi
    storage="${storage:-local}"
    echo "$storage" > "{{ storage_cache }}"
    echo "$storage"

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
_ensure-image:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! ssh -n {{ ssh_opts }} {{ ssh_target }} "{{ sudo }} test -f {{ talos_image }}"; then
        echo "Talos image not found at {{ talos_image }}, downloading from {{ talos_url }}..."
        ssh -n {{ ssh_opts }} {{ ssh_target }} "{{ sudo }} wget -O {{ talos_image }} {{ talos_url }}"
        echo "Download complete."
    fi

[private]
_create-vm-group count role name_prefix cores memory disk: _ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    prefix="{{ name_prefix }}"
    prefix="${prefix//_/-}"
    base=$(just _vmids-by-tag "{{ role }}" "{{ current_cluster }}" | wc -l | xargs)
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
    storage=$(just _storage)
    if just _ssh "qm status {{ vmid }}" &>/dev/null; then
        echo "VM {{ vmid }} ({{ name }}) already exists, skipping"
        exit 0
    fi
    just _ssh "qm create {{ vmid }} --name {{ name }} --tags talos,{{ role }},{{ current_cluster }} --cpu host --cores {{ cores }} --memory {{ memory }} --machine q35 --bios ovmf --scsihw virtio-scsi-pci --net0 virtio,bridge={{ talos_bridge }} --ostype l26 --agent enabled=1"
    just _ssh "qm set {{ vmid }} --efidisk0 $storage:0,efitype=4m,pre-enrolled-keys=0"
    just _ssh "qm importdisk {{ vmid }} {{ talos_image }} $storage"
    imported_disk=$(ssh {{ ssh_opts }} {{ ssh_target }} "{{ sudo }} qm config {{ vmid }}" | grep -oP '^unused\d+:\s*\K\S+')
    just _ssh "qm set {{ vmid }} --scsi0 $imported_disk"
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
    done < <(just _vmids-by-tag {{ current_cluster }})

# Stop all Talos VMs in the current cluster
stop-vms: check
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r vmid; do
        echo "Stopping VM $vmid..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
    done < <(just _vmids-by-tag "talos")

# Destroy all Talos VMs in cluster TALOS_CLUSTER (stop + delete + purge disks)
destroy-vms: check
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Destroying all VMs tagged {{ current_cluster }}..."
    while IFS= read -r vmid; do
        echo "  destroying $vmid..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
        just _ssh "qm destroy $vmid --purge" 2>/dev/null || true
    done < <(just _vmids-by-tag {{ current_cluster }})

# Resize a VM's primary disk
resize-disk vmid additional_gb: check
    just _ssh "qm resize {{ vmid }} scsi0 +{{ additional_gb }}G"

# -----------------------------
# Querying
# -----------------------------

# Return the first unused VMID on the cluster
next-id: check
    just _ssh "pvesh get /cluster/nextid"

# List VMIDs whose tags include current_cluster AND all given tags (at least one required)
[private]
_vmids-by-tag +tags:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -n "{{ tags }}" ]] || { echo "error: _vmids-by-tag requires at least one tag"; exit 1; }
    ssh {{ ssh_target }} bash <<'REMOTE'
    for vmid in $({{ sudo }} qm list | tail -n+2 | awk '{print $1}'); do
        vm_tags=$({{ sudo }} qm config "$vmid" | grep -oP '^tags:\s*\K.*' || true)
        for tag in {{ tags }}; do
            echo "$vm_tags" | grep -q "$tag" || continue 2
        done
        echo "$vmid"
    done
    REMOTE

# Count existing control plane nodes
count-cp: check
    just _vmids-by-tag "controlplane" {{ current_cluster }} | wc -l | xargs

# Count existing worker nodes
count-workers: check
    just _vmids-by-tag "worker" {{ current_cluster }} | wc -l | xargs

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
    done < <(just _vmids-by-tag "talos")

# Get the IP address of a VM via QEMU guest agent
get-ip vmid: check
    #!/usr/bin/env bash
    set -euo pipefail
    ssh {{ ssh_target }} \
        "{{ sudo }} qm guest cmd {{ vmid }} network-get-interfaces" \
        | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"'

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
        name=$(ssh -n {{ ssh_opts }} {{ ssh_target }} "{{ sudo }} qm config $vmid" | grep -oP '^name:\s*\K.*' || echo "?")
        ip=$(ssh -n {{ ssh_opts }} {{ ssh_target }} "{{ sudo }} qm guest cmd $vmid network-get-interfaces" \
            | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null || echo "unavailable")
        echo "  $name ($vmid): $ip"
    done < <(just _vmids-by-tag "{{ role }}" "{{ current_cluster }}")

# Return comma-separated IPs for all control plane VMs (e.g. for talosctl --nodes)
get-cp-ips: check
    just _role-ip-list "controlplane"

# Return comma-separated IPs for all worker VMs (e.g. for talosctl --nodes)
get-worker-ips: check
    just _role-ip-list "worker"

[private]
_role-ip-list role:
    #!/usr/bin/env bash
    set -euo pipefail
    ips=()
    while IFS= read -r vmid; do
        ip=$(ssh -n {{ ssh_opts }} {{ ssh_target }} \
            "{{ sudo }} qm guest cmd $vmid network-get-interfaces" 2>/dev/null \
            | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' \
            || true)
        if [[ -n "$ip" ]]; then
            ips+=("$ip")
        fi
    done < <(just _vmids-by-tag "{{ role }}" "{{ current_cluster }}")
    (IFS=,; printf '%s\n' "${ips[*]}")

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
    done < <(just _vmids-by-tag "talos")

# Rollback all VMs to a snapshot
rollback-all name="pre-change": check
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r vmid; do
        echo "Rolling back VM $vmid to {{ name }}..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
        just _ssh "qm rollback $vmid {{ name }}"
        just _ssh "qm start $vmid"
    done < <(just _vmids-by-tag "talos")
