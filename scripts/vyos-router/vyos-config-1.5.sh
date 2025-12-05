#!/bin/vbash
# VyOS Router Configuration Script v1.5
# Reference: https://raw.githubusercontent.com/tosin2013/demo-virt/refs/heads/rhpds/demo.redhat.com/vyos-config-1.5.sh
#
# Network Layout:
# ===============
# | Network | VLAN | Subnet           | Gateway      | DHCP Range    | Description    |
# |---------|------|------------------|--------------|---------------|----------------|
# | 1924    | Lab  | 192.168.50.0/24  | 192.168.50.1 | .100-.199     | Lab network    |
# | 1925    | Disco| 192.168.52.0/24  | 192.168.52.1 | .100-.199     | Disconnected   |
# | 1926    | Proxy| 192.168.54.0/24  | 192.168.54.1 | .100-.199     | Trans-Proxy    |
# | 1927    | Metal| 192.168.56.0/24  | 192.168.56.1 | .100-.199     | Bare Metal     |
# | 1928    | Prov | 192.168.58.0/24  | 192.168.58.1 | .100-.199     | Provisioning   |
#
# Usage: Run this script on the VyOS router after initial deployment
#        vbash /path/to/vyos-config-1.5.sh

source /opt/vyatta/etc/functions/script-template
configure

# Show current interfaces
run show interfaces

# Configure eth1 - Lab Network (1924)
set interfaces ethernet eth1 address 192.168.49.1/24
set interfaces ethernet eth1 description ETH1
set interfaces ethernet eth1 vif 1924 description 'Lab'
set interfaces ethernet eth1 vif 1924 address '192.168.50.1/24'
run show interfaces

# Configure eth2 - Disco Network (1925)
set interfaces ethernet eth2 address 192.168.51.1/24
set interfaces ethernet eth2 description ETH2
set interfaces ethernet eth2 vif 1925 description 'Disco'
set interfaces ethernet eth2 vif 1925 address '192.168.52.1/24'
run show interfaces

# Configure eth3 - Trans-Proxy Network (1926) with MACVLAN
set interfaces ethernet eth3 address 192.168.53.1/24
set interfaces ethernet eth3 description ETH3
set interfaces pseudo-ethernet peth0 source-interface eth3
set interfaces pseudo-ethernet peth0 address 192.168.54.1/24
set interfaces pseudo-ethernet peth0 description 'macvlan'
run show interfaces

# Configure eth4 - Metal Network (1927)
set interfaces ethernet eth4 address 192.168.55.1/24
set interfaces ethernet eth4 description ETH4
set interfaces ethernet eth4 vif 1927 description 'Metal'
set interfaces ethernet eth4 vif 1927 address '192.168.56.1/24'
run show interfaces

# Configure eth5 - Provisioning Network (1928)
set interfaces ethernet eth5 address 192.168.57.1/24
set interfaces ethernet eth5 description ETH5
set interfaces ethernet eth5 vif 1928 description 'Provisioning'
set interfaces ethernet eth5 vif 1928 address '192.168.58.1/24'
run show interfaces

# Configure NAT masquerade for all networks
set nat source rule 10 outbound-interface name 'eth0'
set nat source rule 10 source address 192.168.122.2
set nat source rule 10 translation address masquerade
commit
run ping 1.1.1.1 count 3 interface 192.168.122.2

set nat source rule 11 outbound-interface name 'eth0'
set nat source rule 11 source address 192.168.49.0/24
set nat source rule 11 translation address masquerade
commit

set nat source rule 12 outbound-interface name 'eth0'
set nat source rule 12 source address 192.168.50.0/24
set nat source rule 12 translation address masquerade
commit

set nat source rule 13 outbound-interface name 'eth0'
set nat source rule 13 source address 192.168.52.0/24
set nat source rule 13 translation address masquerade
commit

set nat source rule 14 outbound-interface name 'eth0'
set nat source rule 14 source address 192.168.54.0/24
set nat source rule 14 translation address masquerade
commit

set nat source rule 15 outbound-interface name 'eth0'
set nat source rule 15 source address 192.168.56.0/24
set nat source rule 15 translation address masquerade
commit

set nat source rule 16 outbound-interface name 'eth0'
set nat source rule 16 source address 192.168.58.0/24
set nat source rule 16 translation address masquerade
commit

# Configure DHCP Server for Lab Network (1924)
set service dhcp-server shared-network-name Lab subnet 192.168.50.0/24 option default-router '192.168.50.1'
set service dhcp-server shared-network-name Lab subnet 192.168.50.0/24 option name-server '1.1.1.1'
set service dhcp-server shared-network-name Lab subnet 192.168.50.0/24 option domain-name 'example.com'
set service dhcp-server shared-network-name Lab subnet 192.168.50.0/24 lease '86400'
set service dhcp-server shared-network-name Lab subnet 192.168.50.0/24 range 0 start 192.168.50.100
set service dhcp-server shared-network-name Lab subnet 192.168.50.0/24 range 0 stop '192.168.50.199'
set service dhcp-server shared-network-name Lab subnet 192.168.50.0/24 subnet-id '1'
commit

# Configure DHCP Server for Disco Network (1925)
set service dhcp-server shared-network-name Disco subnet 192.168.52.0/24 option default-router '192.168.52.1'
set service dhcp-server shared-network-name Disco subnet 192.168.52.0/24 option name-server '1.1.1.1'
set service dhcp-server shared-network-name Disco subnet 192.168.52.0/24 option domain-name 'example.com'
set service dhcp-server shared-network-name Disco subnet 192.168.52.0/24 lease '86400'
set service dhcp-server shared-network-name Disco subnet 192.168.52.0/24 range 0 start 192.168.52.100
set service dhcp-server shared-network-name Disco subnet 192.168.52.0/24 range 0 stop '192.168.52.199'
set service dhcp-server shared-network-name Disco subnet 192.168.52.0/24 subnet-id '2'
commit

# Configure DHCP Server for Trans-Proxy Network (1926)
set service dhcp-server shared-network-name Trans-Proxy subnet 192.168.54.0/24 option default-router '192.168.54.1'
set service dhcp-server shared-network-name Trans-Proxy subnet 192.168.54.0/24 option name-server '1.1.1.1'
set service dhcp-server shared-network-name Trans-Proxy subnet 192.168.54.0/24 option domain-name 'example.com'
set service dhcp-server shared-network-name Trans-Proxy subnet 192.168.54.0/24 lease '86400'
set service dhcp-server shared-network-name Trans-Proxy subnet 192.168.54.0/24 range 0 start 192.168.54.100
set service dhcp-server shared-network-name Trans-Proxy subnet 192.168.54.0/24 range 0 stop '192.168.54.199'
set service dhcp-server shared-network-name Trans-Proxy subnet 192.168.54.0/24 subnet-id '3'
commit

# Configure DHCP Server for Metal Network (1927)
set service dhcp-server shared-network-name Metal subnet 192.168.56.0/24 option default-router '192.168.56.1'
set service dhcp-server shared-network-name Metal subnet 192.168.56.0/24 option name-server '1.1.1.1'
set service dhcp-server shared-network-name Metal subnet 192.168.56.0/24 option domain-name 'example.com'
set service dhcp-server shared-network-name Metal subnet 192.168.56.0/24 lease '86400'
set service dhcp-server shared-network-name Metal subnet 192.168.56.0/24 range 0 start 192.168.56.100
set service dhcp-server shared-network-name Metal subnet 192.168.56.0/24 range 0 stop '192.168.56.199'
set service dhcp-server shared-network-name Metal subnet 192.168.56.0/24 subnet-id '4'
commit

# Configure DHCP Server for Provisioning Network (1928)
set service dhcp-server shared-network-name Provisioning subnet 192.168.58.0/24 option default-router '192.168.58.1'
set service dhcp-server shared-network-name Provisioning subnet 192.168.58.0/24 option name-server '1.1.1.1'
set service dhcp-server shared-network-name Provisioning subnet 192.168.58.0/24 option domain-name 'example.com'
set service dhcp-server shared-network-name Provisioning subnet 192.168.58.0/24 lease '86400'
set service dhcp-server shared-network-name Provisioning subnet 192.168.58.0/24 range 0 start 192.168.58.100
set service dhcp-server shared-network-name Provisioning subnet 192.168.58.0/24 range 0 stop '192.168.58.199'
set service dhcp-server shared-network-name Provisioning subnet 192.168.58.0/24 subnet-id '5'
commit

# Save configuration
save
exit

echo "VyOS configuration complete!"
echo ""
echo "Network Summary:"
echo "  1924 (Lab):          192.168.50.0/24, GW: 192.168.50.1, DHCP: .100-.199"
echo "  1925 (Disco):        192.168.52.0/24, GW: 192.168.52.1, DHCP: .100-.199"
echo "  1926 (Trans-Proxy):  192.168.54.0/24, GW: 192.168.54.1, DHCP: .100-.199"
echo "  1927 (Metal):        192.168.56.0/24, GW: 192.168.56.1, DHCP: .100-.199"
echo "  1928 (Provisioning): 192.168.58.0/24, GW: 192.168.58.1, DHCP: .100-.199"
