#!/bin/bash

# Launch on-demand EC2 instance with auto terminate after certain time interval
# Delay termination using command <   extend-time   >

# Change AWS profile to your environment
export AWS_PROFILE=AWS-Sandbox
# Change to your region or pass the region as a parameter from CI/CD tool such as Jenkins
export AWS_DEFAULT_REGION=us-east-1
# Set the time (in hours) the EC2 instance need to be up. Can pass as a parameter from CI/CD job.
DURATION=1
# Set the EC2 instance type. Can pass as a parameter from CI/CD job.
INSTANCE_TYPE=t3.small

# Set to your environment specific values
key_pair=sandbox-key
vpc_name=sandbox

# choose owner, appropriate ami name based on AWS region
ami_id=$(aws ec2 describe-images \
    --owners "699717368611" \
    --filters "Name=name,Values=*amzn2-ami-hvm-x86_64-gp2*" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

vpc_id=$(aws ec2 describe-vpcs \
    --filter Name=tag:Name,Values=${vpc_name}-vpc \
    --query Vpcs[].VpcId \
    --output text)

subnet_id=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="${vpc_id}" "Name=tag:Name,Values=*private*a-snet" \
    --query 'Subnets[0].SubnetId' \
    --output text)

sg_id=$(
    aws ec2 describe-security-groups \
        --filters Name=vpc-id,Values="${vpc_id}" "Name=group-name,Values=*sandbox*" \
        --query 'SecurityGroups[].GroupId' \
        --output text
)

if [[ "$ami_id" == "None" || -z $vpc_id || $subnet_id == "None" || -z $sg_id ]]; then
    echo "ERROR: Exception while looking up values such as AMI, VPC, SG."
fi

cat <<EOF >ec2_user_data.txt
#!/bin/bash -e
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
shutdown -h +$((DURATION * 60))
cat <<END > /usr/local/bin/extend-time
sudo shutdown -c
sudo shutdown -h +60
END
chmod 777 /usr/local/bin/extend-time
EOF

response=$(
    aws ec2 run-instances \
        --image-id "$ami_id" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$key_pair" \
        --iam-instance-profile "Name=sandbox-ec2-profile" \
        --security-group-ids "$sg_id" \
        --subnet-id "$subnet_id" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=True}" \
        --instance-initiated-shutdown-behavior terminate \
        --user-data file://ec2_user_data.txt \
        --metadata-options "HttpEndpoint=enabled,HttpTokens=required" \
        --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=sandbox-ec2},
    {Key=createdBy,Value=launch_ec2_sandbox_with_auto_terminate},
    {Key=owner:contact,Value=your-name}
  ]"
)

rc=$?
echo $rc

if [ $rc -eq 0 ]; then
    instance_id=$(echo "$response" | jq -r '.Instances[0].InstanceId')
    ip_addr=$(echo "$response" | jq -r '.Instances[0].PrivateIpAddress')
    echo "============================================================"
    echo "Instance ID: $instance_id"
    echo "Instance IP address: $ip_addr"
    echo "Connect using ec2-user with key file $key_pair"
    echo "Instance will be terminated in $DURATION hour(s)"
    echo "Use command <   extend-time   > to delay shutdown by an hour"
    echo "============================================================"
else
    exit 1
fi
