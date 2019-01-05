#!/bin/bash
function start_instances
{
    # $1: number of instances to start
    echo "Launching $1 AWS EC2 instances"
    aws ec2 run-instances --launch-template LaunchTemplateId=lt-0065a09a461515b3e --count $1 > aws_start.log
    local instances=`jq -r '.Instances[].InstanceId ' aws_start.log`
    echo "Waiting for network interfaces to attach"
    sleep 3
    rm instances.txt
    rm ~/.ssh/config.d/spider
    echo "Querying public IPs and writing to SSH config"
    for instance in $instances ;
    do
        local ip=`aws ec2 describe-instances --instance-ids $instance | jq -r '.Reservations[0].Instances[0].PublicIpAddress'`
        echo "$instance,$ip" >> instances.txt
        echo "Host $instance" >> ~/.ssh/config.d/spider
        echo "    Hostname $ip" >> ~/.ssh/config.d/spider
        echo "    User ubuntu" >> ~/.ssh/config.d/spider
        echo "    IdentityFile ~/.ssh/leiy-aws.pem" >> ~/.ssh/config.d/spider
        echo "    StrictHostKeyChecking no" >> ~/.ssh/config.d/spider
        echo "    UserKnownHostsFile=/dev/null" >> ~/.ssh/config.d/spider
        echo "" >> ~/.ssh/config.d/spider
    done
}

function stop_instances
{
   local instances=`cat instances.txt`
   local instance_ids=""
   for instance in $instances ;
   do
       local id
       local ip
       IFS=',' read -r id ip <<< "$instance"
       instance_ids="$instance_ids $id"
   done
   echo "Terminating instances $instance_ids"
   aws ec2 terminate-instances --instance-ids $instance_ids > aws_stop.log
}

function build_container
{
    # $1: instance id
    scp setup_image.sh $1:
    ssh $1 -- bash setup_image.sh
}

function init_swarm
{
    local instances=`cat instances.txt`
    local instance_ids=""
    for instance in $instances ;
    do
        local id
        local ip
        IFS=',' read -r id ip <<< "$instance"
        instance_ids="$instance_ids $id"
    done
    local first_id
    local rest_ids
    read first_id rest_ids <<< "$instance_ids"
    local cmd_to_use=`ssh $first_id -- 'docker swarm init | sed -n 5p'`
    for instance in $rest_ids ;
    do
        ssh $instance -- "$cmd_to_use"
    done
    ssh $first_id -- 'docker network create -d overlay --subnet 10.0.0.0/16 --attachable spider'
}

function destroy_swarm
{
    local instances=`cat instances.txt`
    local instance_ids=""
    for instance in $instances ;
    do
        local id
        local ip
        IFS=',' read -r id ip <<< "$instance"
        instance_ids="$instance_ids $id"
    done
    local first_id
    read first_id _ <<< "$instance_ids"
    ssh $first_id -- 'docker network rm spider'
    for instance in $instance_ids ;
    do
        ssh $instance -- 'docker swarm leave --force'
    done
}

function build_all
{
    local instances=`cat instances.txt`
    local pids=""
    for instance in $instances ;
    do
        local id
        local ip
        IFS=',' read -r id ip <<< "$instance"
        echo "Job launched for $id"
        build_container $id &>"build_$id.log" &
        pids="$pids $!"
    done
    echo "Waiting for all jobs to finish"
    for pid in $pids ;
    do
        wait $pid
    done
}

function start_container
{
	# $1: node name, $2: ip, $3: host
	ssh $3 -- docker run -itd --name "spider$1" -e NODENAME=$1 -e NODEIP=$2 -e SPIDER_EXP_NAME="$EXP_NAME" -e TOPO_FILE="$TOPO_FILE" -e EXP_TIME="$EXP_TIME" --network spider --ip $2 spider
}

function destroy_container
{
	# $1: node name, $2: host
	ssh $2 -- docker kill "spider$1"
	ssh $2 -- docker rm "spider$1"
}

function next_index()
{
	# $1: current index
	local len=${#hosts[@]}
	local next=`expr $1 + 1`
	if [ "$next" -ge "$len" ]
	then
		next=0
	fi
	echo $next
}


function start_experiment
{
    local instances=`cat instances.txt`
    hosts=()
    for instance in $instances ;
    do
        local id
        local ip
        IFS=',' read -r id ip <<< "$instance"
        hosts+=("$id")
    done
    local host_idx=0
    local pids=""
	for node in `cat $TOPO_FILE | jq -rc '.nodes | .[]'`
	do
		name=`echo $node | jq -r '.name'`
		ip=`echo $node | jq -r '.ip'`
        echo "Starting $name"
		start_container $name $ip ${hosts[$host_idx]} &> /dev/null &
        pids="$pids $!"
		host_idx=`next_index $host_idx`
	done
    echo "Waiting for all jobs to finish"
    for pid in $pids ;
    do
        wait $pid
    done
}

function stop_experiment
{
    local instances=`cat instances.txt`
    hosts=()
    for instance in $instances ;
    do
        local id
        local ip
        IFS=',' read -r id ip <<< "$instance"
        hosts+=("$id")
    done
    local host_idx=0
    local pids=""
	for node in `cat $TOPO_FILE | jq -rc '.nodes | .[]'`
	do
		name=`echo $node | jq -r '.name'`
        echo "Stopping $name"
		destroy_container $name ${hosts[$host_idx]} &> /dev/null &
        pids="$pids $!"
		host_idx=`next_index $host_idx`
	done
    echo "Waiting for all jobs to finish"
    for pid in $pids ;
    do
        wait $pid
    done
}

case "$1" in
    help)
        echo "Helper script to run Spider distributed tests"
        echo ""
        echo "start-instances n"
        echo "    Start n EC2 instances"
        echo "stop-instances"
        echo "    Terminate EC2 instances"
        echo "init-docker"
        echo "    Initialize docker swarm"
        echo "uninit-docker"
        echo "    Destroy docker swarm"
        echo "build-images"
        echo "    Build docker images" 
        echo "start-exp topofile expname exptime"
        echo "    Start an experiment"
        echo "stop-exp topofile"
        echo "    Stop an experiment" ;;
    start-instances)
        start_instances $2 ;;
    stop-instances)
        stop_instances ;;
    init-docker)
        init_swarm ;;
    uninit-docker)
        destroy_swarm ;;
    build-images)
        build_all ;;
    start-exp)
        TOPO_FILE=$2
        EXP_NAME=$3
        EXP_TIME=$4
        start_experiment;;
    stop-exp)
        TOPO_FILE=$2
        stop_experiment;;
esac