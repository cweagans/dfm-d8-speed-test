#!/usr/bin/env bash

# Update and start Docker in the Linux build environment.
function linux_updateStartDocker {
  if [[ "$TRAVIS_OS_NAME" == "linux" ]]
  then
    echo "--> Updating Docker."
    sudo sh -c 'echo "deb https://apt.dockerproject.org/repo ubuntu-precise main" > /etc/apt/sources.list.d/docker.list'
    sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
    sudo apt-get -qq update
    sudo apt-key -qq update
    sudo apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install docker-engine=1.11.1-0~precise
    sudo rm /usr/local/bin/docker-compose
    curl -L https://github.com/docker/compose/releases/download/1.7.1/docker-compose-`uname -s`-`uname -m` > docker-compose
    chmod +x docker-compose
    sudo mv docker-compose /usr/local/bin
    sudo service docker start
  fi
}

function osx_prepEnvironment {
  if [[ "$TRAVIS_OS_NAME" == "osx" ]]
  then
    echo "--> Tapping caskroom/cask and homebrew/php."
    brew tap caskroom/cask
    brew tap homebrew/php
    echo "--> Updating Homebrew."
    brew update
    echo "--> Updating Homebrew Cask."
    brew cask update
    echo "--> Installing PHP 7 and Composer."
    brew install php70 composer
  fi
}

# Note: normally, using sudo for brew cask install is not needed, but doing it
# here to avoid the pw prompts for the .pkg installs.
echo "--> Preparing environment..."
case "$BENCHMARK" in
  "linux")
    linux_updateStartDocker
    ;;

  "toolbox")
    osx_prepEnvironment
    echo "--> Installing Docker Toolbox."
    sudo brew cask install dockertoolbox
    echo "--> Creating Docker machine for test."
    docker-machine create dev --driver=virtualbox
    eval $(docker-machine env dev)
    ;;

  "toolbox_nfs")
    osx_prepEnvironment
    echo "--> Installing Docker Toolbox."
    sudo brew cask install dockertoolbox
    echo "--> Installing docker-machine-nfs"
    brew install docker-machine-nfs
    echo "--> Creating Docker machine for test."
    docker-machine create dev --driver=virtualbox
    sudo docker-machine-nfs dev
    eval $(docker-machine env dev)
    ;;

  "xhyve")
    echo "Error: Not implemented yet."
    exit 1
    ;;

  "xhyve_nfs")
    echo "Error: Not implemented yet."
    exit 1
    ;;

  "dfm")
    osx_prepEnvironment
    echo "--> Installing Docker for Mac."
    sudo brew cask install ./docker-for-mac.rb
    sudo /opt/homebrew-cask/Caskroom/docker-for-mac/latest/Docker.app/Contents/MacOS/Docker --token="$DFM_BETA_KEY"
    ;;
esac

# At this point, we should have a connection to the Docker daemon. If not, bail out.
echo "--> Checking connectivity to Docker daemon."
docker ps > /dev/null 2>&1
if [[ "$?" != "0" ]]; then
  echo "No docker daemon found!"
  exit 1
fi

echo ""
echo "Environment looks good. Starting test."
echo ""

# Output some version information to refer to later.
echo "Docker version:"
echo "$(docker -v)"
echo "Docker Compose version:"
echo "$(docker-compose -v)"

# Install Composer dependencies.
echo "--> Installing Composer dependencies."
composer install --optimize-autoloader --quiet

# The db service needs a little extra time to come up after the docker-compose
# command returns, so starting it separately so that it has time to finish starting
# while the web container downloads.
echo "--> Starting database container."
docker-compose up -d db
echo "--> Starting web container."
docker-compose up -d web

# Test 0: How long does it take to grep for a string in all files?
time docker-compose exec web bash -c "cd /var/www/benchmark; grep -r some-string *"

# Test 1: How long does it take to install Drupal?
time docker-compose exec web bash -c "cd /var/www/benchmark; ./vendor/bin/drush -y --root=./docroot si standard --db-url=mysql://root:root@db/benchmark --db-su=root --db-su-pw=root --account-pass=admin"

# Test 2: How long does it take to load the front page?
time docker-compose exec web bash -c "cd /var/www/benchmark; curl http://localhost"

# Test 3: How long does it take to run Drupal's unit tests?
# Note: The Composer group is excluded here because it fails in this setup.
time docker-compose exec web bash -c "cd /var/www/benchmark; ./vendor/bin/phpunit -c ./docroot/core/phpunit.xml.dist --testsuite=unit --exclude-group=Composer"
