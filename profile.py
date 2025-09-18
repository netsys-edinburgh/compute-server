#!/usr/bin/env python

kube_description= \
"""
Development Cluster
"""
kube_instruction= \
"""
Author: Jon Larrea
"""


import geni.portal as portal
import geni.rspec.pg as PG
import geni.rspec.igext as IG


pc = portal.Context()
rspec = PG.Request()


# Profile parameters.
pc.defineParameter("machineNum", "Number of Machines",
                   portal.ParameterType.INTEGER, 1)
pc.defineParameter("Hardware", "Machine Hardware",
                   portal.ParameterType.STRING, "d430",
                   [("d430", "d430"), 
                    ("d710", "d710"), 
                    ("d820", "d820"), 
                    ("pc3000", "pc3000"), 
                    ("d740", "d740"), 
                    ("d840", "d840"),
                    ("c6620", "c6620")])
pc.defineParameter("OS", "Operating System",
                   portal.ParameterType.STRING,"ubuntu18",[("ubuntu18","ubuntu18"),("ubuntu20","ubuntu20"), ("ubuntu22", "ubuntu22")])

# Isolated CPU parameters
pc.defineParameter("isolcpusNumber", "Number of Isolated CPUs",
                   portal.ParameterType.INTEGER, 0,
                   advanced=True)

# Kubernetes parameters
pc.defineParameter("k8s", "Install Kubernetes",
                   portal.ParameterType.BOOLEAN, False,
                   advanced=True)

# USRP Node
usrp_b210_locations = [
    ("none",
     "No USRP"),
    ("web",
     "WEB"),
    ("bookstore",
     "Bookstore"),
    ("humanities",
     "Humanities"),
    ("law73",
     "Law 73"),
    ("ebc",
     "EBC"),
    ("madsen",
     "Madsen"),
    ("sagepoint",
     "Sage Point"),
    ("moran",
     "Moran"),
    ("cpg",
     "Central Parking Garage"),
    ("guesthouse",
     "Guest House"),
]

pc.defineParameter("usrpb210", "USRP B210 Location",
                   portal.ParameterType.STRING, "none", usrp_b210_locations, advanced=True)


params = pc.bindParameters()

#
# Give the library a chance to return nice JSON-formatted exception(s) and/or
# warnings; this might sys.exit().
#
pc.verifyParameters()



tour = IG.Tour()
tour.Description(IG.Tour.TEXT,kube_description)
tour.Instructions(IG.Tour.MARKDOWN,kube_instruction)
rspec.addTour(tour)


# Network
netmask="255.255.255.0"
network = rspec.Link("Network")
network.link_multiplexing = True
network.vlan_tagging = True
network.best_effort = True

if params.OS == 'ubuntu20':
    os = 'urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU20-64-STD'
elif params.OS == 'ubuntu22':
    os = 'urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD'
else:
    os = 'urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU18-64-STD'

# Variable that stores configuration scripts and arguments
profileConfigs = ""

# Kubernetes configuration
k8s_ip = 0 # This is to calculate the IPs when K8s is installed
if params.k8s == True:
    # Declare the master node
    master = rspec.RawPC("master")
    master.hardware_type = params.Hardware
    master.routable_control_ip = True
    master.disk_image = os
    iface = master.addInterface()
    iface.addAddress(PG.IPv4Address("192.168.1.1", netmask))
    network.addInterface(iface)
    master.addService(PG.Execute(shell="bash", command="/local/repository/scripts/master.sh"))
    k8s_ip = 1
    # Configure script for the slave nodes
    profileConfigs += "PROFILE_CONF_COMMAND_K8S='/local/repository/scripts/slave.sh' "

# IsolCPU configuration
if params.isolcpusNumber > 0:
    profileConfigs += "PROFILE_CONF_COMMAND_ISOLCPU='/local/repository/scripts/isolcpus.sh' "
    profileConfigs += "PROFILE_CONF_COMMAND_ISOLCPU_ARGS='%d' " % (params.isolcpusNumber)
else:
    profileConfigs += "PROFILE_CONF_COMMAND_NOREBOOT='touch' "
    profileConfigs += "PROFILE_CONF_COMMAND_NOREBOOT_ARGS='/local/.noreboot' "

# Machines
for i in range(0,params.machineNum):
    node = rspec.RawPC("node" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    node.hardware_type = params.Hardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("192.168.1."+str(i+1+k8s_ip), netmask))
    network.addInterface(iface)

if params.usrpb210 != 'none':
    b210_nuc_pair_node = rspec.RawPC("b210-nuc")
    agg_full_name = "urn:publicid:IDN+%s.powderwireless.net+authority+cm"%(params.usrpb210)
    b210_nuc_pair_node.component_manager_id = agg_full_name
    b210_nuc_pair_node.component_id = "nuc2"
    b210_nuc_pair_node.disk_image = os

#
# Print and go!
#
pc.printRequestRSpec(rspec)
