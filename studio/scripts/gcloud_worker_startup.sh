#!/bin/bash

exec > >(tee -i ~/gcloud_worker_logfile.txt)
exec 2>&1

metadata_url="http://metadata.google.internal/computeMetadata/v1/instance"
queue_name=$(curl "${metadata_url}/attributes/queue_name" -H  "Metadata-Flavor: Google")
key_name=$(curl "${metadata_url}/attributes/auth_key" -H  "Metadata-Flavor: Google")
timeout=$(curl "${metadata_url}/attributes/timeout" -H  "Metadata-Flavor: Google")

zone=$(curl "${metadata_url}/zone" -H  "Metadata-Flavor: Google")
instance_name=$(curl "${metadata_url}/name" -H  "Metadata-Flavor: Google")
group_name=$(curl "${metadata_url}/attributes/groupname" -H  "Metadata-Flavor: Google")

echo Instance name is $instance_name
echo Group name is $group_name

cd ~

mkdir -p .studioml/keys
curl "${metadata_url}/attributes/auth_data" -H  "Metadata-Flavor: Google" > .studioml/keys/${key_name}
curl "${metadata_url}/attributes/credentials" -H  "Metadata-Flavor: Google" > credentials.json
export GOOGLE_APPLICATION_CREDENTIALS=~/credentials.json


: "${GOOGLE_APPLICATION_CREDENTIALS?Need to point GOOGLE_APPLICATION_CREDENTIALS to the google credentials file}"
: "${queue_name?Queue name is not specified (pass as a script argument}"

gac_path=${GOOGLE_APPLICATION_CREDENTIALS%/*}
gac_name=${GOOGLE_APPLICATION_CREDENTIALS##*/}
#bash_cmd="git clone $repo && \
#            cd studio && \
#            git checkout $branch && \
#            sudo pip install --upgrade pip && \
#            sudo pip install -e . --upgrade && \
#            mkdir /workspace && cd /workspace && \
#            studio-rworker --queue=$queue_name"

code_url_base="https://storage.googleapis.com/studio-ed756.appspot.com/src"
#code_ver="tfstudio-64_config_location-2017-08-04_1.tgz"
repo_url="https://github.com/studioml/studio"
branch="{studioml_branch}"


if [ ! -d "studio" ]; then
    sudo apt -y update
    sudo apt install -y wget python-pip git python-dev
    sudo pip install --upgrade pip
    git clone $repo_url

    if [[ "{use_gpus}" -eq 1 ]]; then
        cudnn5="libcudnn5_5.1.10-1_cuda8.0_amd64.deb"
        cudnn6="libcudnn6_6.0.21-1_cuda8.0_amd64.deb"
        cuda_base="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1604/x86_64/"
        cuda_ver="cuda-repo-ubuntu1604_8.0.61-1_amd64.deb"

        # install cuda
        wget $cuda_base/$cuda_ver
        sudo dpkg -i $cuda_ver
        sudo apt -y update
        sudo apt install -y cuda

        # install cudnn
        wget $code_url_base/$cudnn5
        wget $code_url_base/$cudnn6
        sudo dpkg -i $cudnn5
        sudo dpkg -i $cudnn6

        sudo pip install tensorflow tensorflow-gpu --upgrade
    fi
fi

cd studio
git pull
git checkout $branch

sudo pip install -e . --upgrade
studio-remote-worker --queue=$queue_name --verbose=debug --timeout=${timeout}

if [[ -n $(who) ]]; then
    echo "Users logged in, preventing auto-shutdown"
    echo "Do not forget to turn the instance off manually"
    exit 0
fi

# shutdown the instance
not_spot=$(echo "$group_name" | grep "Error 404" | wc -l)
echo "not_spot = $not_spot"

if [[ "$not_spot" -eq "0" ]]; then
    current_size=$(gcloud compute instance-groups managed describe $group_name --zone $zone | grep "targetSize" | awk '{print $2}')
    echo Current group size is $current_size
    if [[ $current_size -gt 1 ]]; then
        echo "Deleting myself (that is, $instance_name) from $group_name"
        gcloud compute instance-groups managed delete-instances $group_name --zone $zone --instances $instance_name
    else
        template=$(gcloud compute instance-groups managed describe $group_name --zone $zone | grep "instanceTemplate" | awk '{print $2}')
        echo "Detaching myself, deleting group $group_name and the template $template"
        gcloud compute instance-groups managed abandon-instances $group_name --zone $zone --instances $instance_name
        sleep 5
        gcloud compute instance-groups managed delete $group_name --zone $zone --quiet
        sleep 5
        gcloud compute instance-templates delete $template --quiet
    fi

fi
echo "Shutting down"
gcloud compute instances delete $instance_name --zone $zone --quiet
