#!/bin/sh
set -eu

# TODO:
# include bin/setup scripting
# repository name for app.json?
# consolidate docker files
# stop using database.yml, use DATABASE_URL instead
# create rails app in one directory, then change to real one
# use .bootstrap_step to record progress

if ! command -v docker-compose &> /dev/null
then
  echo "the docker-compose command is required to run this script"
  exit 1
fi

echo "Enter the name of the application (lowercase, snakecase, not an existing directory)"
echo "The application will be built in a directory with the corresponding name"
read -p "application name: " application_name
if [ -z "$application_name" ]
then
  echo "application name is not optional"
  exit 1
fi
if [ -d "$application_name" ]
then
  echo "directory already exists"
  exit 1
fi

echo "Enter the ABSOLUTE url of the github repository which will house this application"
echo "You must have full access for this to work nicely"
read -p "github url: " github_url
if [ -z "$github_url" ]
then
  echo "github url is not optional"
  exit 1
fi

echo "Press return to generate a strong password for Postgres, or enter one if desired:"
read -p "password: " postgres_password
if [ -z $postgres_password ]
then
  echo "generating a password..."
  postgres_password="$(cat /dev/urandom | base64 | tr -cd "[:upper:][:lower:][:digit:]" | head -c 32)"
fi

# Set up workspace
mkdir $application_name
cd $application_name

# Bootstrap docker environment
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/docker-compose.bootstrap.yml
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/Dockerfile
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/.dockerignore
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" docker-compose.bootstrap.yml
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" Dockerfile
docker-compose -f docker-compose.bootstrap.yml build --no-cache

# Bootstrap Rails application
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/Gemfile
docker-compose -f docker-compose.bootstrap.yml run web bundle install --jobs 10 --retry 5
docker-compose -f docker-compose.bootstrap.yml run web bundle exec rails new . --database=postgresql --force

# Swap bootstrapping docker files for application docker files
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/docker-compose.yml
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/docker-compose.override.yml
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" docker-compose.yml
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" docker-compose.override.yml
touch ./sample.docker.bashrc ./sample.docker.bash_history ./sample.docker.pry_history
touch ./docker.bashrc ./docker.bash_history ./docker.pry_history

# append to .gitignore
curl -L https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/additions.gitignore >> .gitignore

# create, populate .env
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/.env
cp .env sample.env
sed -i.bkp "s/<POSTGRES_PASSWORD>/$postgres_password/g" .env

# set up default gems
echo "
# TODO: move automatically-installed gems to the appropriate blocks:" >> Gemfile
docker-compose run web bundle add pry-rails
docker-compose run web bundle add --group development,test pry-byebug \
                                                           rspec-rails \
                                                           factory_bot_rails \
                                                           rubocop-rails \
                                                           rubocop-rails_config rubocop-performance rubocop-rspec \
                                                           brakeman
docker-compose run web bundle exec rails generate rspec:install
mkdir -p spec/support
curl -Lo spec/support/factory_bot.rb https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/factory_bot.rb
curl -Lo spec/support/capybara.rb https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/capybara.rb
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/.rubocop.yml
curl -Lo lib/tasks/rubocop.rake https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/rubocop.rake
# this uncomments the corresponding line in spec/rails_helper.rb to load our spec support files
sed -i.bkp "s/# \(Dir\[Rails.root.join('spec', 'support'\)/\1/g" spec/rails_helper.rb

# migrate the database and run setup
# TODO: use DATABASE_URL instead of overriding database.yml
# - postgres://postgres:${POSTGRES_PASSWORD}@db:5432/<app_name>_<env> ???
curl -Lo config/database.yml https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/database.yml
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" config/database.yml
docker-compose run web bundle exec rails db:prepare

# set up GH Action-based CI and do automatic corrections
mkdir -p .github/workflows
curl -Lo .github/workflows/ci.yml https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/ci.yml
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/docker-compose.ci.yml
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" docker-compose.ci.yml
docker-compose run web bundle exec rails rubocop:auto_correct
# this uncomments the corresponding line in config/environments/production.rb to appease brakeman
sed -i.bkp "s/ # \(config.force_ssl = true\)/\1/g" config/environments/production.rb

# set up review apps on Heroku
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/heroku.yml
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/app.json
curl -LJO https://raw.githubusercontent.com/mhs/docker-rails-bootstrapper/main/support/heroku.Dockerfile
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" heroku.Dockerfile
sed -i.bkp "s/<APPLICATION_NAME>/$application_name/g" app.json
# wonkiness replaces e.g. "http://"" with "http:\/\/"" to escape it for use by sed
sed -i.bkp "s/<GITHUB_URL>/"${github_url//\//\\\/}"/g" app.json

# cleanup
rm -rf **/.*.bkp **/*.bkp docker-compose.bootstrap.yml test lib/tasks/.keep

# push to GitHub
git checkout -b main 2> /dev/null
git branch -D master 2> /dev/null
git add .
git commit -m "Bootstrapped application"
git remote add origin $github_url
git push -u origin main
