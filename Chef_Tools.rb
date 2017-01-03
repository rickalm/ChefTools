class Chef_Tools
  
  # Create instance, needs Chef Node and user defined 'AppName'
  #
  def initialize(node = {}, cookbook = 'unknown', recipe = 'unknown')
    @node = node
    @appname = cookbook
    @cookbook_name = cookbook
    @recipe_name = recipe
    @environment = ! @node.chef_environment.nil? ? @node.chef_environment : 'prod';
    @region = @node.key?(cookbook) && @node[cookbook].key?('region') ? @node[cookbook]['region'] : 'us-east-1';
    @thisName = "#{cookbook}-#{recipe}"
  end

  # Return Environment based on chef settings or user override
  #
  def environment(e = nil)
    @environment = e unless e.nil?
    return @environment
  end

  # Return Datacenter based on chef settings or user override
  #
  def region(d = nil)
    @region = d unless d.nil?
    return @region
  end

  def dns()
    return 'prod.com' if @environment == "prod"
    return 'unknown.com'
  end

  # Return hostname
  # just to be feature complete
  #
  def hostname
    return @node.name if @node.name.is_a? String
    return @node.hostname if @node.key?('hostname')
    'unknown'
  end

  # Return @appname
  # incase user forgot his appname declaration
  #
  attr_reader :appname
  attr_reader :thisName

  # method to grab just one ip address from list
  #
  def ip(item)
    iplist[item]
  end

  # Find 'Public', 'Private', 'VirtualBox' and 'Docker' ipaddresses
  # will use Chef 'ec2' data and local machine data to compile list
  # TODO: ec2
  #
  def iplist
    my_ip_list = {}

    @node.automatic.network.interfaces.each do |_if_name, if_details|
      next if if_details.encapsulation != 'Ethernet' || if_details.type != 'eth' || if_details.state != 'up'

      if_details.addresses.each do |address, options|
        next if options.family != 'inet'

        if address =~ /10\.0\.2\..*/
          my_ip_list['virtualbox'] = address

        elsif address =~ /^10\..*/
          my_ip_list['private'] = address

        elsif address =~ /^172\.(1[6789]|2[0-9]|3[012])\..*/
          my_ip_list['private'] = address

        else
          my_ip_list['public'] = address

        end
      end
    end

    # If we found one (Public/Private) but not the other then backfill
    #
    if !my_ip_list.key?('private') && my_ip_list.key?('public')
      my_ip_list['private'] = my_ip_list['public']
    end

    if !my_ip_list.key?('public') && my_ip_list.key?('private')
      my_ip_list['public'] = my_ip_list['private']
    end

    # If we didn't find any public or private IP's but we found a VirtualBox adapter then use that for both
    #
    if !my_ip_list.key?('public') && !my_ip_list.key?('private') && my_ip_list.key?('virtualbox')
      my_ip_list['public'] = my_ip_list['virtualbox']
      my_ip_list['private'] = my_ip_list['virtualbox']
    end

    my_ip_list
  end

  def split_image_string(image)
    if image.split(":")[2].nil?
      image_name = image.split(":")[0]
      image_tag = image.split(":")[1]
    else
      image_name = image.split(":")[0..1].join(":")
      image_tag = image.split(":")[2]
    end

    return [image_name,image_tag]
  end

  def image_name(image)
    return split_image_string(image)[0]
  end

  def image_tag(image)
    return split_image_string(image)[1]
  end

  # Load configs from a YAML file
  # Supports inheritance from various working_datas in the file
  #
  # _default/'_global':
  # _default/region:
  # environment/'_global':
  # environment/region:
  # hostname
  #
  def load_config(filename, config_hash = {})
    ### Setup default vars for machine specific params
    #
    default_vars = {
      'dns_name' => "#{dns()}",
      'node_name' => hostname(),
      'node_ip' => ip('private'),
      'repo' => "docker.#{dns()}",
      'region' => @region,
      'cookbook' => @cookbook_name,
      'recipe' => @recipe_name
    }

    # add any *_dir node variable to list of variables
    #
    @node[@cookbook_name].each do |key, value|
      default_vars[key] = value if key =~ /.*_dir$/ && value =~ %r{^/}
    end

    # Append the default_vars to the config_hash[vars] structure
    #
    config_hash = Chef::Mixin::DeepMerge.deep_merge!( config_hash, { 'vars' => default_vars } )
    #
    ### Default Vars

    ### import filename (allowing for filename to be an array of files to read)
    #
    if filename.is_a?(String) then filename = [filename] end
    working_data = {}

    filename.each do | file |
      # if filename starts with pathing "e.g. ./ or ../ or / ", then use directly
      # otherwise assume we are in a recipe and get from the files/config directory
      #
      filedir = File.join(Chef::Config[:file_cache_path], '/cookbooks/', @cookbook_name, '/files/config/')
      #filedir = File.join(File.dirname(__FILE__), '../../',@cookbook_name,'/files/config/')

      if file =~ %r{^\.{0,2}/}
        filepath = File.join(File.dirname(__FILE__), file)
      else
        filepath = File.join(filedir, file)
      end

      puts "Loading data for #{@cookbook_name}/#{@recipe_name} in #{environment}/#{region}\n   from #{filepath}"
      yaml_hash = YAML.load_file(filepath)

      # If Yaml_Hash has a top level named by cookbook then use that working_data, otherwise whole file
      #
      yaml_hash = yaml_hash.key?(@cookbook_name) ? yaml_hash[@cookbook_name] : yaml_hash
      working_data = Chef::Mixin::DeepMerge.deep_merge!(working_data, yaml_hash)
    end
    #
    # Finished reading files

    ### Merge Site Configs
    #
    # _default/'_global':
    # _default/region:
    # environment/'_global':
    # environment/region:
    #
    ['_default',environment].each do | toplevel |
      if working_data.key?(toplevel)
        ['_global', region].each do | secondlevel |
          if working_data[toplevel].key?(secondlevel) 
            #puts "Loading #{toplevel}/#{secondlevel}, #{working_data[toplevel][secondlevel]}"
            config_hash = Chef::Mixin::DeepMerge.deep_merge!(config_hash, working_data[toplevel][secondlevel])
          end
        end
      end
    end
    #
    ###

    ### lastly merge hostname specific config
    #
    if working_data[hostname]
      config_hash = Chef::Mixin::DeepMerge.deep_merge!(config_hash, working_data[hostname]) 
    end

    # Perform variable substitution accross config array
    #
    vars = config_hash.delete('vars')
    #puts Psych.dump({'vars' => vars})
    puts Psych.dump(config_hash)

    vars.each do | key, val |
      #puts "Replacing #{key} with #{val}"
      search_replace_hash(config_hash,/\%#{key}\%/, val)
    end

    puts Psych.dump(config_hash)

    # return config_hash
    #
    config_hash
  end

  def search_replace_hash(target, search, replace)
    #puts "Replacing #{search} with #{replace}: #{target}"

    case
      when target.is_a?(Hash)
        #puts "Target is a Hash"
        target.keys.each do |old|
          new = old.gsub(search,replace)
          target[new] = target.delete(old) unless new == old
        end
        target.each_value { |v| search_replace_hash(v, search, replace) }

      when target.is_a?(Array)
        #puts "Target is an Array"
        target.each { |v| search_replace_hash(v, search, replace) }

      when target.is_a?(String)
        #puts "Target is a String"
        target.gsub!(search,replace)

      #else
        #puts "Dont know what Target is"
    end
  end

  # Scan through node[@cookbook_name] hash for any items named *_dir who's value begins with a slash
  # (e.g. directory), return that list as an array
  #
  # Useful for creating directories as part of a recipe
  #

  def dirlist(app = @cookbook_name)
    app_dirs = []

    @node[app].each do |key, value|
      app_dirs << value if key =~ /.*_dir$/ && value =~ %r{^/}
    end

    app_dirs
  end

  def autodeploy(target_instances = nil, zone_placement = nil)
    # if target_instances isn't defined, simply return
    #
    return zone_placement unless target_instances.is_a? Numeric

    # Autoprovision accross placement zones if instances is defined
    #
    #puts 'Checking Zone Placement'

    current_instances = 0
    autodeploy_zones = []

    # Gather current deployment data, and autodeployment zonelist
    #
    zone_placement.each do |zone, value|
      if value.is_a? Numeric
        current_instances += value

      elsif (value.is_a? String) && (value == 'autodeploy')
        autodeploy_zones << zone
        zone_placement[zone] = 0

      end
    end

    # If defined instances greater than number of discovered instances then add instances
    #
    unless current_instances < target_instances
      unless autodeploy_zones.length > 0
        fail "Number of instances is defined as #{target_instances} but there are no autodeploy zones defined"
      end

      puts "Found #{current_instances}, planning #{target_instances - current_instances} additional instances"

      # could use .sample, but want a round-robin vs a "random" layout
      #
      while current_instances < target_instances
        target_zone = autodeploy_zones[current_instances % autodeploy_zones.length]
        zone_placement[target_zone] += 1
        current_instances += 1
      end
    end

    puts 'New zone_placement plan is: ' << Chef::JSONCompat.to_json_pretty(zone_placement)

    zone_placement
  end

  # Based on an array of "Compose" stanza's derived from the config yaml (with variable substitution)
  #
  # 1. Fetch the images
  # 2. Pre-Build the docker-compose file so we can establish triggers
  # 3. Launch the containers (and their dependancies)
  #
  # !!! This does not work at this point !!!

  def DockerCompose( composeData = {} )

    # Pre-Fetch images from repo
    # forces local docker repo to check upstream incase label got new image
    # docker_compose DSL doesn't do this
    #
    composeData.each do |container, container_config|
      unless container_config['image'].nil?
        puts "Pre-Fetch Image: #{container_config['image']}"

        # Need to split image into image_name and image_tag for chef DSL
        # but some images specify host:port/image:tag and some dont have :port
        # so check if there are three parts to the image and handle it
        #
        if container_config['image'].split(":")[2].nil?
          image_name = container_config['image'].split(":")[0]
          image_tag = container_config['image'].split(":")[1]
        else
          image_name = container_config['image'].split(":")[0..1].join(":")
          image_tag = container_config['image'].split(":")[2]
        end

        docker_image "#{container}" do
          ignore_failure true

          repo "#{image_name}"
          tag "#{image_tag}"
          action :pull

          # If image changed, force container rebuild
          #
          notifies :destroy, "docker_compose[#{container}]", :immediate
        end
      end
    end

    # Used to trigger stop-kill/create jobs when config changes
    # Write the config hash to a tmp file, and if it changes 
    # chef::template will notify on change
    #
    # docker_compose DSL doesn't do this properly
    #
    composeData.each do |container, container_config|
      file "/tmp/aa-#{thisName}-#{container}.yml" do
        content Psych.dump({ "#{container}" => container_config })

        # If template changed, force container rebuild
        #
        notifies :destroy, "docker_compose[#{container}]", :immediate
      end

    end

    # Create & Launch container
    #
    composeData.each do |container,container_config|
      # Define name as docker-compose section name if not defined
      #
      container_config['container_name'] ||= container

      docker_compose "#{container}" do
        ignore_failure true

        source 'yaml.erb'

        variables ({
          yaml_data: { "#{container}" => container_config }
        })

        action :up

        # Setup chef to subscribe to container changes of containers this container depends on
        # derive the dependent containers based on the external_links array
        #
        if container_config.key?('external_links') && container_config['external_links'].is_a?(Array)
          container_config['external_links'].each do |v|
            subscribes :destroy, "docker_compose[#{v.split(":")[0]}]", :immediate
          end
        end
      end
    end

  end

end
