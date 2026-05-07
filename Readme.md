# Proxmox Ctl

Just a set of recipes created for the purpose of creating Talos Vms. 

If some nodes for a cluster exist it expects them to be labeled with their role (controleplane/worker), cluster (ex: homelab), and talos. If these conditions are met, allows you to dynamically add N nodes.

Note this does not handle actually getting the nodes to join the cluster, that's handled elsewhere. Draw the rest of the owl.