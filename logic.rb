# -*- mode: ruby -*-
# vi: set ft=ruby :

# This file contains various functions that call be called as the command line argument.
#
# Before running any command below that makes calls to Docker Compose,
# the command prepare-docker-environment should be run
# followed by sourcing scripts/prepare-docker.sh so that the correct
# apps are loaded into the Docker Compose environment variable. Just in
# case people have multiple copies of this dev-env using different configs.

require_relative 'scripts/delete_env_files'
require_relative 'scripts/utilities'
require_relative 'scripts/update_apps'
require_relative 'scripts/self_update'
require_relative 'scripts/docker_compose'
require_relative 'scripts/commodities'
require_relative 'scripts/provision_custom'
require_relative 'scripts/provision_postgres'
require_relative 'scripts/provision_postgres_9.6'
require_relative 'scripts/provision_alembic'
require_relative 'scripts/provision_alembic_9.6'
require_relative 'scripts/provision_auth'
require_relative 'scripts/provision_hosts'
require_relative 'scripts/provision_db2'
require_relative 'scripts/provision_db2_devc'
require_relative 'scripts/provision_db2_community'
require_relative 'scripts/provision_nginx'
require_relative 'scripts/provision_elasticsearch5'
require_relative 'scripts/provision_elasticsearch'

require 'fileutils'
require 'open3'
require 'rubygems'

# Ensures stdout is never buffered
STDOUT.sync = true

# Where is this file located? (From Ruby's perspective)
root_loc = __dir__

# Define the DEV_ENV_CONTEXT_FILE file name to store the users app_grouping choice
# As vagrant up can be run from any subdirectory, we must make sure it is stored alongside the Vagrantfile
DEV_ENV_CONTEXT_FILE = root_loc + '/.dev-env-context'

# Where we clone the dev env configuration repo into
DEV_ENV_CONFIG_DIR = root_loc + '/dev-env-config'

# A list of all the docker compose fragments we find, so they can be loaded into an env var and used as one big file
DOCKER_COMPOSE_FILE_LIST = root_loc + '/.docker-compose-file-list'

if ARGV.length != 1
  puts colorize_red('We need exactly one argument')
  exit 1
end

# Does a version check and self-update if required
if ['check-for-update'].include?(ARGV[0])
  this_version = '1.6.3'
  puts colorize_lightblue("This is a universal dev env (version #{this_version})")
  # Skip version check if not on master (prevents infinite loops if you're in a branch that isn't up to date with the
  # latest release code yet)
  current_branch = `git -C #{root_loc} rev-parse --abbrev-ref HEAD`.strip
  if current_branch == 'master'
    self_update(root_loc, this_version)
  else
    puts colorize_yellow('*******************************************************')
    puts colorize_yellow('**                                                   **')
    puts colorize_yellow('**                     WARNING!                      **')
    puts colorize_yellow('**                                                   **')
    puts colorize_yellow('**         YOU ARE NOT ON THE MASTER BRANCH          **')
    puts colorize_yellow('**                                                   **')
    puts colorize_yellow('**            UPDATE CHECKING IS DISABLED            **')
    puts colorize_yellow('**                                                   **')
    puts colorize_yellow('**          THERE MAY BE UNSTABLE FEATURES           **')
    puts colorize_yellow('**                                                   **')
    puts colorize_yellow("**   IF YOU DON'T KNOW WHY YOU ARE ON THIS BRANCH    **")
    puts colorize_yellow("**          THEN YOU PROBABLY SHOULDN'T BE!          **")
    puts colorize_yellow('**                                                   **')
    puts colorize_yellow('*******************************************************')
    puts ''
    puts colorize_yellow('Continuing in 5 seconds (CTRL+C to quit)...')
    sleep(5)
  end
end

if ['stop'].include? ARGV[0]
  if File.exist?(DOCKER_COMPOSE_FILE_LIST) && File.size(DOCKER_COMPOSE_FILE_LIST) != 0
    # If this file exists it must have previously got to the point of creating the containers
    # and if it has something in we know there are apps to stop and won't get an error
    puts colorize_lightblue('Stopping apps:')
    run_command('docker-compose stop')
  end
end

# Ask for/update the dev-env configuration.
# Then use that config to clone/update apps, create commodities and custom provision lists
# and download supporting files
if ['prep'].include?(ARGV[0])
  # Check if a DEV_ENV_CONTEXT_FILE exists, to prevent prompting for dev-env configuration choice on each vagrant up
  if File.exist?(DEV_ENV_CONTEXT_FILE)
    puts ''
    puts colorize_green("This dev env has been provisioned to run for the repo: #{File.read(DEV_ENV_CONTEXT_FILE)}")
  else
    print colorize_yellow('Please enter the (Git) url of your dev env configuration repository: ')
    config_repo = STDIN.gets.chomp
    File.open(DEV_ENV_CONTEXT_FILE, 'w+') { |file| file.write(config_repo) }
  end

  # Check if dev-env-config exists, and if so pull the dev-env configuration. Otherwise clone it.
  puts colorize_lightblue('Retrieving custom configuration repo files:')
  if Dir.exist?(DEV_ENV_CONFIG_DIR)
    new_project = false
    command_successful = run_command("git -C #{root_loc}/dev-env-config pull")
  else
    new_project = true
    config_repo = File.read(DEV_ENV_CONTEXT_FILE)
    parsed_repo, delimiter, ref = config_repo.rpartition('#')
    # If they didn't specify a #ref, rpartition returns "", "", wholestring
    parsed_repo = ref if delimiter.empty?
    command_successful = run_command("git clone #{parsed_repo} #{root_loc}/dev-env-config")
    if command_successful.zero? && !delimiter.empty?
      puts colorize_lightblue("Checking out configuration repo ref: #{ref}")
      command_successful = run_command("git -C #{root_loc}/dev-env-config checkout #{ref}")
    end
  end

  # Error if git clone or pulling failed
  fail_and_exit(new_project) if command_successful != 0

  # Call the ruby function to pull/clone all the apps found in dev-env-config/configuration.yml
  puts colorize_lightblue('Updating apps:')
  update_apps(root_loc)

end

if ['reset'].include?(ARGV[0])
  # remove DEV_ENV_CONTEXT_FILE created on provisioning
  confirm = ''
  until confirm.upcase.start_with?('Y', 'N')
    print colorize_yellow('Would you like to KEEP your dev-env configuration files? (y/n) ')
    confirm = STDIN.gets.chomp
  end
  if confirm.upcase.start_with?('N')
    FileUtils.rm_f DEV_ENV_CONTEXT_FILE
    FileUtils.rm_rf DEV_ENV_CONFIG_DIR
  end

  # remove files created on provisioning
  delete_files(root_loc)

  # Docker
  run_command('docker-compose down --rmi all --volumes --remove-orphans')

  puts colorize_green('Environment reset')
end

# Run script to configure environment
# TODO bash autocompletion of container names
if ['prepare-compose-environment'].include?(ARGV[0])
  # Create a file called .commodities.yml with the list of commodities in it
  puts colorize_lightblue('Creating list of commodities')
  create_commodities_list(root_loc)

  # Call the ruby function to create the docker compose file containing the apps and their commodities
  puts colorize_lightblue('Creating docker-compose file list')
  prepare_compose(root_loc, DOCKER_COMPOSE_FILE_LIST)
end

if ['start'].include?(ARGV[0])
  if File.size(DOCKER_COMPOSE_FILE_LIST).zero?
    puts colorize_red('Nothing to start!')
    exit
  end

  puts colorize_lightblue('Building images...')
  if run_command('docker-compose build --parallel --pull') != 0
    puts colorize_yellow('Build command failed. Trying without --parallel')
    # Might not be running a version of compose that supports --parallel, try one more time
    if run_command('docker-compose build --pull') != 0
      puts colorize_red('Something went wrong when building your app images. Check the output above.')
      exit
    end
  end

  # Before creating any containers, let's see what already exists (in case we need to override provision status)
  existing_containers = []
  run_command('docker-compose ps --services --filter "status=stopped" && '\
              'docker-compose ps --services --filter "status=running"',
              existing_containers)

  # Let's force a recreation of the containers here so we know they're using up-to-date images
  puts colorize_lightblue('Creating containers...')
  if run_command('docker-compose up --remove-orphans --force-recreate --no-start') != 0
    puts colorize_red('Something went wrong when creating your app containers. Check the output above.')
    exit
  end

  # Now we identify exactly which containers we've created in the above command
  existing_containers2 = []
  run_command('docker-compose ps --services --filter "status=stopped" && '\
              'docker-compose ps --services --filter "status=running"',
              existing_containers2)
  new_containers = existing_containers2 - existing_containers

  # Check the apps for a postgres SQL snippet to add to the SQL that then gets run.
  # If you later modify .commodities to allow this to run again (e.g. if you've added new apps to your group),
  # you'll need to delete the postgres container and it's volume else you'll get errors.
  # Do a fullreset, or docker-compose rm -v -f postgres (or postgres-9.6 etc)
  provision_postgres(root_loc, new_containers)
  provision_postgres96(root_loc, new_containers)
  # Alembic
  provision_alembic(root_loc)
  provision_alembic96(root_loc)
  # Hosts File
  provision_hosts(root_loc)
  # Run app DB2 SQL statements
  provision_db2(root_loc)
  provision_db2_devc(root_loc, new_containers)
  provision_db2_community(root_loc, new_containers)
  # Nginx
  provision_nginx(root_loc)
  # Elasticsearch
  provision_elasticsearch(root_loc)
  # Elasticsearch5
  provision_elasticsearch5(root_loc)
  # Auth
  provision_auth(root_loc, new_containers)

  # Now that commodities are all provisioned, we can start the containers

  # Load configuration.yml into a Hash
  config = YAML.load_file("#{root_loc}/dev-env-config/configuration.yml")

  # The list of all Compose services to start (which may be trimmed down in the following sections)
  services_to_start = []
  run_command('docker-compose config --services', services_to_start)

  # The list of expensive services we have yet to start
  expensive_todo = []
  # The list of expensive services currently starting
  expensive_inprogress = []

  config['applications'].each do |appname, appconfig|
    # First, special options check (in the dev-env-config)
    # for any settings that should override what the app wants to do
    options = appconfig.fetch('options', [])
    options.each do |option|
      service_name = option['compose-service-name']
      auto_start = option.fetch('auto-start', true)
      next if auto_start

      # We will not start this at all (unless depended upon by another service we are
      # starting - Compose will enforce that!)
      puts colorize_pink("Dev-env-config option found - service #{service_name} autostart is FALSE")
      services_to_start.delete(service_name)
    end

    # Check if any services have declared themselves as having a resource-intensive startup procedure
    # and move them to the separate todo list if so.
    next unless File.exist?("#{root_loc}/apps/#{appname}/configuration.yml")

    dependencies = YAML.load_file("#{root_loc}/apps/#{appname}/configuration.yml")
    next if dependencies.nil?
    next unless dependencies.key?('expensive_startup')

    dependencies['expensive_startup'].each do |service|
      service_name = service['compose_service']
      # If we have already decided not to start it, don't bother going further
      next unless services_to_start.include?(service_name)

      puts colorize_pink("Found expensive to start service #{service_name}")
      # We will start it apart from our main list
      expensive_todo << service
      services_to_start.delete(service_name)
    end
  end

  # Now we can start inexpensive apps, which should be quick and easy
  if services_to_start.any?
    puts colorize_lightblue('Starting inexpensive services...')
    up_exit_code = run_command('docker-compose up --no-deps --remove-orphans -d ' + services_to_start.join(' '))
    if up_exit_code != 0
      puts colorize_red('Something went wrong when creating your app images or containers. Check the output above.')
      exit
    end
  end

  # Until we have no more left to start AND we have no more in progress...
  puts colorize_lightblue('Starting expensive services...') if expensive_todo.length.positive?
  expensive_failed = []
  while expensive_todo.length.positive? || expensive_inprogress.length.positive?
    # Wait for a bit before the next round of checks
    if expensive_inprogress.length.positive?
      puts ''
      sleep(5)
    end

    # Remove any from the in progress list that are now healthy as per their declared cmd
    expensive_inprogress.delete_if do |service|
      service_healthy = false
      service['check_count'] += 1
      if service['healthcheck_cmd'] == 'docker'
        puts colorize_lightblue("Checking if #{service['compose_service']} is healthy (using Docker healthcheck)" \
                                " - Attempt #{service['check_count']}")
        output_lines = []
        outcode = run_command("docker inspect --format=\"{{json .State.Health.Status}}\" #{service['compose_service']}",
                              output_lines)
        service_healthy = outcode.zero? && output_lines.any? && output_lines[0].start_with?('"healthy"')
      else
        puts colorize_lightblue("Checking if #{service['compose_service']} is healthy (using configuration.yml CMD)" \
                                " - Attempt #{service['check_count']}")
        service_healthy = run_command("docker exec #{service['compose_service']} #{service['healthcheck_cmd']}",
                                      []).zero?
      end

      if service_healthy
        puts colorize_green('It is!')
      else
        puts colorize_yellow('Not yet')
        # Check if the container has crashed and restarted
        output_lines = []
        run_command("docker inspect --format=\"{{json .RestartCount}}\" #{service['compose_service']}",
                    output_lines)
        restart_count = output_lines[0].to_i
        if restart_count.positive?
          puts colorize_pink("The container has exited (crashed?) and been restarted #{restart_count} times " \
                             '(max 10 allowed)')
        end
        if restart_count > 9
          puts colorize_red('The failure threshold has been reached. Skipping this container')
          expensive_failed << service
          run_command("docker-compose stop #{service['compose_service']}")
          service_healthy = true
        end
      end
      service_healthy
    end

    # Move as many as we can into in-progress
    # todo list and start them up.
    expensive_todo.delete_if do |service|
      # Have we reached the limit?
      break false if expensive_inprogress.length >= 3

      dependency_healthy = true
      # Would this service like others to be healthy prior to starting?
      wait_until_healthy_list = service.fetch('wait_until_healthy', {})
      if wait_until_healthy_list.length.positive?
        puts colorize_lightblue("#{service['compose_service']} has dependencies it would like to be healthy "\
                                'before starting:')
      end
      wait_until_healthy_list.each do |dep|
        if dep['healthcheck_cmd'] == 'docker'
          puts colorize_lightblue("Checking if #{dep['compose_service']} is healthy (using Docker healthcheck)")
          output_lines = []
          outcode = run_command("docker inspect --format=\"{{json .State.Health.Status}}\" #{dep['compose_service']}",
                                output_lines)
          dependency_healthy = outcode.zero? && output_lines.any? && output_lines[0].start_with?('"healthy"')
        else
          puts colorize_lightblue("Checking if #{dep['compose_service']} is healthy (using cmd in configuration.yml)")
          dependency_healthy = run_command("docker exec #{dep['compose_service']} #{dep['healthcheck_cmd']}",
                                           []).zero?
        end
        if dependency_healthy
          puts colorize_green('It is!')
        else
          puts colorize_yellow("#{dep['compose_service']} is not healthy, so #{service['compose_service']}"\
                               ' will not be started yet')
          sleep(3)
          break
        end
      end

      if dependency_healthy
        run_command("docker-compose up --no-deps --remove-orphans -d #{service['compose_service']}")
        service['check_count'] = 0
        expensive_inprogress << service
      end
      dependency_healthy
    end
  end

  # Any custom scripts to run?
  provision_custom(root_loc)

  if expensive_failed.length.positive?
    puts colorize_yellow('All done, but the following containers failed to start - check logs/log.txt for any ' \
                         'useful error messages:')
    expensive_failed.each do |service|
      puts colorize_yellow("  #{service['compose_service']}")
    end
  else
    puts colorize_green('All done, environment is ready for use')
  end

  post_up_message = config.fetch('post-up-message', nil)
  if post_up_message
    puts ''
    puts colorize_yellow('Special message from your dev-env-config:')
    puts colorize_pink(post_up_message)
  end
end
