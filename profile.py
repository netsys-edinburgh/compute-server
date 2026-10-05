#!/usr/bin/env python

kube_description= \
    """
    Chronos: large-scale UE/gNB emulation testbed for 5G RAN research.
    Provisions a k8s cluster (1 controller + N workers, custom time-dilation
    kernel) plus proxy and Global-SC nodes, then deploys the Chronos control
    plane. Kernel build makes first boot slow.
    """
kube_instruction= \
    """
    ## Once ready

    **controlPlane = phobos-console (default):** nothing to run. When `ins0vm:~/PHOBOS_READY`
    appears the console is up on ins0vm port 8090 (`ssh -L 8090:localhost:8090` via node0) with
    numGNB x numUE deployed. Progress: `ins0vm:~/.phobos/setup.log`.

    **controlPlane = chronos-auto-deploy:**

    1. SSH to node0 (k8s controller, ins0vm).
    2. Run `chronos-auto-deploy/run-experiment.sh` to deploy the five
       Chronos components (globalsc, core, proxy, gnb, ue).
    3. Run `chronos-auto-deploy/teardown-experiment.sh` when done.
    """


import geni.portal as portal
import geni.rspec.pg as PG
import geni.rspec.igext as IG
import geni.rspec.emulab.spectrum as spectrum
import geni.rspec.emulab.pnext as pn
import math


pc = portal.Context()
rspec = PG.Request()

COMP_MANAGER_ID = "urn:publicid:IDN+emulab.net+authority+cm"

# Profile parameters.
pc.defineParameter(
    "machineNum", "Number of gNB / UE Worker Nodes",
    portal.ParameterType.INTEGER, 1,
    longDescription="Worker node count, separate from the k8s controller (node0). "
        "Each worker holds up to 200 gNB/UE pods combined, so numGNB + numUE "
        "must not exceed 200 x this value.")

pc.defineParameter(
    "machinePNum", "Number of Proxy Nodes",
    portal.ParameterType.INTEGER, 1,
    longDescription="Runs the Chronos proxy component. Separate from the worker "
        "nodes above and from the single Global-SC node.")

pc.defineParameter(
    "numGNB", "Number of gNB",
    portal.ParameterType.INTEGER, 1,
    longDescription="Emulated gNB pods, spread across worker nodes. Must be >= 1. "
        "numGNB + numUE <= 200 x machineNum.")

pc.defineParameter(
    "numUE", "Number of UE",
    portal.ParameterType.INTEGER, 1,
    longDescription="Emulated UE pods, split evenly across gNBs. "
        "numGNB + numUE <= 200 x machineNum.")

pc.defineParameter(
    "Hardware", "Worker Node Hardware Type",
    portal.ParameterType.NODETYPE, "pc",
    longDescription="Hosts gNB/UE pods and the custom kernel build.")

pc.defineParameter(
    "ProxyHardware", "Proxy Node Hardware Type",
    portal.ParameterType.NODETYPE, "pc",
    longDescription="Hosts the Chronos proxy component.")

pc.defineParameter(
    "GlobalSCHardware", "Global-SC Node Hardware Type",
    portal.ParameterType.NODETYPE, "pc",
    longDescription="Runs the single Global-SC node.")

pc.defineParameter(
    "ManagerHardware", "k8s Controller Hardware Type",
    portal.ParameterType.NODETYPE, "pc",
    longDescription="Runs node0 / ins0vm, the k8s controller every other node joins.")

pc.defineParameter(
    "OS", "Operating System", portal.ParameterType.STRING, "ubuntu22",
    [("ubuntu18", "ubuntu18"), ("ubuntu20", "ubuntu20"), ("ubuntu22", "ubuntu22")],
    longDescription="Base image for every node. ubuntu22 is the tested default.")

pc.defineParameter(
    "controlPlane", "Control plane", portal.ParameterType.STRING, "phobos-console",
    [("phobos-console", "phobos-console (one click: console up, emulation deployed)"),
     ("chronos-auto-deploy", "chronos-auto-deploy (manual run-experiment.sh)")],
    longDescription="phobos-console: once every node has joined, the controller VM prepares hypervisors and VMs, "
        "builds and stages the phobos UE and proxy, deploys Open5GS, starts phobos-console on port 8090 and "
        "deploys numGNB x numUE. Progress in ins0vm:~/.phobos/setup.log, result in ins0vm:~/PHOBOS_READY.")
pc.defineParameter("phobosConsoleBranch", "phobos-console branch", portal.ParameterType.STRING, "main", groupId="phobos")
pc.defineParameter("phobos5gBranch", "phobos-5g branch", portal.ParameterType.STRING, "new-oai-port", groupId="phobos")
pc.defineParameter("phobosOaiBranch", "openairinterface5g branch (UE build)", portal.ParameterType.STRING,
                   "phobos-ue", groupId="phobos")
pc.defineParameterGroup("phobos", "phobos sources (one-click)")

#GitHub parameters
pc.defineParameter("githubUser","GitHub Username",
                   portal.ParameterType.STRING,"",groupId="github")
pc.defineParameter("token", "GitHub Token",
                   portal.ParameterType.STRING, "",groupId="github")
pc.defineParameterGroup("github", "GitHub Access (optional)")



params = pc.bindParameters()

if params.numGNB < 1:
    pc.reportError(portal.ParameterError(
        "Number of gNB must be at least 1.", ["numGNB"]))

if params.numGNB + params.numUE > 200 * params.machineNum:
    pc.reportError(portal.ParameterError(
        "Number of gNB + Number of UE ({}) exceeds the per-node pod budget "
        "of 200 x Number of Worker Nodes ({}).".format(
            params.numGNB + params.numUE, 200 * params.machineNum),
        ["numGNB", "numUE", "machineNum"]))

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
netmask="255.0.0.0"
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

# NOTE on repository-clone resilience: CloudLab clones this profile's git repo
# into /local/repository as startup "execution 0", guarded by an abort-on-failure
# check, BEFORE any service below runs. A transient failure of that clone (the
# GitHub HTTP/2 framing bug) therefore aborts the whole node before any profile
# service executes -- so it cannot be repaired by a service added here. Hardening
# that clone has to happen at the image/CloudLab level, not in these services.
# What IS handled here: in-script clones use git_clone_retry (HTTP/1.1 + retry),
# and verify_node.sh below turns a node that came up incomplete into a loud
# failure instead of a silent one.

# Machines
for i in range(0,params.machineNum+1):
    node = rspec.RawPC("node" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command = "/local/repository/scripts/build_kernel.sh {} {} {} {} {} {} {} {} {} {} {}".format(
    params.token,           # $1 = token
    params.githubUser,      # $2 = GitHub username
    params.machineNum+1,    # $3 = machine number
    i,                      # $4 = instance index
    params.machinePNum,     # $5 = proxy node count
    params.numGNB,          # $6 = number of gNB
    params.numUE,           # $7 = number of UE
    params.controlPlane,    # $8 = control plane (phobos-console = one-click phobos)
    params.phobosConsoleBranch, params.phobos5gBranch, params.phobosOaiBranch)  # $9..$11
    node.addService(PG.Execute(shell="bash", command=command))
    # Fail-loud verification that this node's inner VM was created and joined k0s.
    node.addService(PG.Execute(shell="bash", command="/local/repository/scripts/verify_node.sh {}".format(i)))
    node.hardware_type = params.ManagerHardware if i == 0 else params.Hardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.1."+str(i+1)+".1", netmask))
    network.addInterface(iface)

node = rspec.RawPC("Global-SC")
node.disk_image = os
node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
command="/local/repository/scripts/build_globalsc.sh {}".format(params.machineNum+1)
node.addService(PG.Execute(shell="bash", command=command))
node.hardware_type = params.GlobalSCHardware
iface = node.addInterface()
iface.addAddress(PG.IPv4Address("10.4.1.1", netmask))
network.addInterface(iface)

for i in range(0,params.machinePNum):
    node = rspec.RawPC("Proxy" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command="/local/repository/scripts/build_proxy.sh {} {}".format(params.machineNum+1, i)
    node.addService(PG.Execute(shell="bash", command=command))
    node.hardware_type = params.ProxyHardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.3."+str(i+1)+".1", netmask))
    network.addInterface(iface)


pc.printRequestRSpec(rspec)


