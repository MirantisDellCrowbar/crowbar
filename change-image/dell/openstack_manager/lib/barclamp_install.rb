# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: RobHirschfeld
#

namespace :barclamp do

  MODEL_SOURCE = File.join 'lib', 'barclamp_model'
  MODEL_SUBSTRING_BASE = '==BC-MODEL=='
  MODEL_SUBSTRING_CAMEL = '==^BC-MODEL=='
  MODEL_TARGET = File.join '..', 'barclamps'
  BASE_PATH = File.join '/opt', 'dell'
  BARCLAMP_PATH = File.join BASE_PATH, 'chef'
  CROWBAR_PATH = File.join BASE_PATH, 'openstack_manager'
  BIN_PATH = File.join BASE_PATH, 'bin'
  
  def bc_cloner(item, bc, entity, source, target, replace)
    files = []
    puts "cloner #{item}, #{bc}, #{entity}, #{source}, #{target}, #{replace}."
    new_item = (replace ? bc_replacer(item, bc, entity) : item)
    new_file = File.join target, new_item
    new_source = File.join(source, item)
    if File.directory? new_source
      puts "\tcreating directory #{new_file}."
      FileUtils.mkdir new_file
      clone = Dir.entries(new_source).find_all { |e| !e.start_with? '.'}
      clone.each do |recurse|
        files += bc_cloner(recurse, bc, entity, new_source, new_file, replace)
      end
    else
      #need to inject into the file
      unless replace
        puts "\t\tcopying file #{new_file}."
        FileUtils.cp new_source, new_file
      else
        puts "\t\tcreating file #{new_file}."
        t = File.open(new_file, 'w')
        File.open(new_source, 'r') do |f|
          s = f.read
          t.write(bc_replacer(s, bc, entity))
        end
        t.close
        files << new_file
      end
    end
    return files
  end
  
  def bc_replacer(item, bc, entity)
    item = item.gsub(MODEL_SUBSTRING_BASE, bc)
    item = item.gsub(MODEL_SUBSTRING_CAMEL, bc.capitalize)
    item = item.gsub('Copyright 2011, Dell', "Copyright #{Time.now.year}, #{entity}")
    return item
  end
  
  # this is used by the install-chef installer script becaues rake is not ready yet
  def shell_install(path, parts)
    version = File.join path, 'crowbar.yml'
    barclamp = YAML.load_file(version)
    bc_install_layout_0 bc, path, barclamp, parts
  end

  #merges localizations from config into the matching translation files
  def merge_i18n(barclamp)
    locales = barclamp['locale_additions']
    locales.each do |key, value|
      #translation file (can be multiple)
      f = File.join CROWBAR_PATH, 'config', 'locales', "#{key}.yml"
      if File.exist? f
        puts "merging tranlation for #{f}"
        master = YAML.load_file f
        master = merge_tree(key, value, master)
        File.open( f, 'w' ) do |out|
          YAML.dump( master, out )
        end
      else
        puts "WARNING: Did not attempt tranlation merge for #{f} because file was not found."
      end
    end
  end
  
  def merge_nav(barclamp, installing)
    unless barclamp['nav'].nil?
      # get raw file
      nav_file = File.join 'config', 'navigation.rb'  #assume that we're in the app dir
      nav = []
      File.open(nav_file, 'r') do |f|
        nav << f.eachline { |line| nav.push line }
      end
      add = barclamp['nav']['add']
      # we only write the updated file if we are adding to it
      unless add.nil?
        File.open( nav_file, 'w') do |out|
          nav.each do |line|
            # remove the old menu item (works for install or uninstall)
            out.puts line unless line.lstrip.starts_with? "secondary.item :#{key}"
            # if you are installing, add the item under the barclamp menu.
            if installing and line.lstrip.starts_with? "primary.item :barclamps"
              add.each do |key, value|
                out.puts "secondary.item :#{key}, t('nav.#{key}'), #{value}" unless value.nil?
              end
            end
          end
        end
      end
    end
  end
  
  def merge_tree(key, value, target)
    if target.key? key
      if target[key].class == Hash
        value.each do |k, v|
          #puts "recursing into tree at #{key} for #{k}"
          target[key] = merge_tree(k, v, target[key])
        end
      else
        #puts "replaced key #{key} value #{value}"
        target[key] = value      
      end
    else
      #puts "added key #{key} value #{value}"
      target[key] = value
    end
    return target
  end
  
  def bc_remove_layout_1(bc, path, barclamp)
    filelist = File.join path, 'filelist.yml'
  end

  def bc_install_layout_1_app(bc, path, barclamp)
    
    #TODO - add a roll back so there are NOT partial results if a step fails
    files = []
    
    puts "Installing barclamp #{bc} from #{path}"

    #merge i18n information (least invasive operations first)
    merge_i18n barclamp
    merge_nav barclamp    

    #copy the rails parts (required for render BEFORE import into chef)
    dirs = Dir.entries(path)
    files += bc_cloner('app', bc, nil, path, CROWBAR_PATH, false) if dirs.include? 'app'
    files += bc_cloner('public', bc, nil, path, CROWBAR_PATH, false) if dirs.include? 'public'
    files += bc_cloner('command_line', bc, nil, path, BIN_PATH, false) if dirs.include? 'command_line'
    puts "\tcopied app & command line files"

    # copy all the files to the target
    files += bc_cloner('chef', bc, nil, path, BASE_PATH, false)
    puts "\tcopied over chef parts from #{path} to #{BARCLAMP_PATH}"
  
    filelist = File.join path, 'filelist.yml'
    File.open( filelist, 'w' ) do |out|
      YAML.dump( {"files" => files }, out )
    end

    if File.directory?(File.join('/etc', 'redhat-release'))
      system "service httpd reload"
    else
      system "service apache2 reload"
    end
    puts "\trestarted the web server"

    puts "Barclamp #{bc} (format v1) added to Crowbar Framework.  Review #{filelist} for files created."
    
  def bc_install_layout_1_chef(bc, path, barclamp)

    #upload the cookbooks
    FileUtils.cd File.join BARCLAMP_PATH, 'cookbooks'
    knife_cookbook = "knife cookbook upload -o . #{bc}"
    system knife_cookbook
    puts "\texecuted: #{knife_cookbook}"
    
    #upload the databags
    FileUtils.cd File.join BARCLAMP_PATH, 'data_bags', 'crowbar'
    knife_databag  = "knife data bag from file crowbar bc-template-#{bc}.json"
    system knife_databag
    puts "\texecuted: #{knife_databag}"

    #upload the roles
    roles = Dir.entries(File.join(path, 'chef', 'roles')).find_all { |r| r.end_with?(".rb") }
    FileUtils.cd File.join BARCLAMP_PATH, 'roles'
    roles.each do |role|
      knife_role = "knife role from file #{role}"
      system knife_role
      puts "\texecuted: #{knife_role}"
    end

    puts "Barclamp #{bc} (format v1) Chef Components Uploaded."

  end
  
end
