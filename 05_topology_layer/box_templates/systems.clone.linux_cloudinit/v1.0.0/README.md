# systems.clone.linux_cloudinit

Portable Linux guest for attaching catalog roles, files, scripts and supported Compose workloads.

## Requirements and placement

- Existing cloud-init template running Linux with cloud-init and Python 3.
- 2 CPU cores, 2048 MiB RAM and a disk of at least 20 GiB.
- Choose the registered Proxmox host and local template VMID for your installation.
- Review clone storage in Scenario: blank inherits template storage; an explicit pool receives new full clones after backend capacity and permission checks. This does not move existing disks.
- SDN is the default: review zone, VNet, subnet, gateway, outgoing NAT and an unused static guest address in Scenario before deployment.
- The network link is a placeholder until those addresses are assigned.
- Configure the guest SSH user to match the selected template.

Use Create project or Add to project in the catalog. Each addition gets fresh node names; allocation assigns runtime VMIDs and addresses. Review the generated Ansible files, save to the project branch, then deploy its exact commit. This blueprint does not build a template.
