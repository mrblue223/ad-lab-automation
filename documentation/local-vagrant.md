# Local path (Vagrant + VirtualBox)

Uses the same Ansible roles and `group_vars/all.yml` as Azure.

## Prerequisites

- VirtualBox 7.x, Vagrant 2.4+, about 50 GB of free disk
- Ansible + pywinrm + collections (see the [setup guide](setup/setup-guide.md); `make deps`)

## Build

```bash
make up-local                 # vagrant up (3 VMs) + ansible-playbook -i inventory/vagrant.ini site.yml
```

Short on disk? Bring the VMs up one at a time:

```bash
cd vagrant && vagrant up hydra-dc && vagrant up thepunisher && vagrant up spiderman
cd .. && make configure INV=vagrant.ini
```

## How the connection works

- Each VM's WinRM (HTTP 5985 in the guest) is forwarded to 127.0.0.1:55985/55986/55987.
- `inventory/vagrant.ini` sets `ansible_winrm_scheme=http` and `ansible_winrm_transport=ntlm`.
  NTLM is required because Basic auth only works for *local* accounts, and once the DC is
  promoted `vagrant` becomes the domain account `MARVEL\vagrant`.
- Lab IPs (10.0.2.10–12) live on the `PEH-Lab` internal network.

## Known caveat

VirtualBox's default NAT network is also `10.0.2.0/24` (the guest's NAT address is 10.0.2.15).
The lab IPs don't collide with it, but if routing on a guest ever looks odd, this overlap is the
first thing to check.

## Tear down

```bash
make destroy-local
```
