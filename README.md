# VMRoles
This repo contains a couple of Windows Azure Pack VM Roles

## RDSGW
Remote Desktop Services - Remote Gateway
Workgroup version and Domain Version

## RDSSH
Remote Desktop Service - Session Host Environment
Full RDS Environment

## SQL2016
SQL Server 2016
Workgroup version and Domain Version

## SQL2016AO
SQL Server 2016 Always On Cluster
As a cluster has dependancies on the underlaying network, this VM Role exists in 3 version which reflect the possible network technologies in use with Azure Pack.
* NVGRE for Network virtualization
* VLAN Static for VLAN with Static IP Pool
* VLAN DHCP for VLAN with DHCP service