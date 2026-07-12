	#!/bin/bash

list_instances() {
    echo "Listing instances..."
    aws ec2 describe-instances \
    --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' \
    --output table
}

start_instance() {
local instance_name=$1
local matches=$(aws ec2 describe-instances \
     --filters "Name=tag:Name,Values=$instance_name" \
     --query 'Reservations[*].Instances[*].InstanceId' \
     --output text)

    local count=$(echo "$matches" | wc -w)

    if [[ $count -eq 0 ]]; then
    echo "No instance found with name: $instance_name"
    return 1
    elif [[ $count -gt 1 ]]; then
    echo "Multiple instances found with name '$instance_name':"
    echo "$matches"
    echo "Refusing to act — please target a specific instance ID instead."
    return 1
    fi
echo "Starting $instance_name ($matches)..."
aws ec2 start-instances --instance-ids "$matches"
}

stop_instance() {
local instance_name=$1
local matches=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$instance_name" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

    local count=$(echo "$matches" | wc -w)

    if [[ $count -eq 0 ]]; then
    echo "No instance found with name: $instance_name"
    return 1
    elif [[ $count -gt 1 ]]; then
    echo "Multiple instances found with name '$instance_name':"
    echo "$matches"
    echo "Refusing to act — please target a specific instance ID instead."
    return 1
    fi

 echo "Stopping $instance_name ($matches)..."
 aws ec2 stop-instances --instance-ids "$matches"
}

case "$1" in
  list)
    list_instances
    ;;
  stop)
    stop_instance "$2"
    ;;
  start)
    start_instance "$2"
    ;;
  *)
    echo "Usage: $0 {list|start|stop} [instance-name]"
    ;;
esac
