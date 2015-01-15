#!/usr/bin/env ruby

require 'yaml'
require 'rally_api'
require 'trello'
require 'slop'

CONFIG_FILE = "config.yml"
RALLY_URL = "https://rally1.rallydev.com/slm"
DEFAULT_LIST = "To Do"

def read_config

  # Read config file
  if !File.exists? CONFIG_FILE
    puts "Config file (#{CONFIG_FILE}) doesn't exist. Please create it, usin #{CONFIG_FILE}.example as a guide)."
    abort
  end
  @config = YAML.load_file(CONFIG_FILE)

  # Parse command line options
  @opts = Slop.parse help: true do
    banner "Usage: #{File.basename($0)} [options]"
    on :w, :rally_workspace=, 'Rally workspace name'
    on :p, :rally_project=, 'Rally project name'
    on :i, :rally_iteration=, 'Rally iteration name (required)'
    on :b, :trello_board=, 'Target trello board (will be created if necessary)'
    on :l, :trello_list=, 'Trello list name (will be created if necessary, default is "To Do")'
  end

  # Merge cmd-line opts with yaml config
  cmd_line = { 'rally' => {}, 'trello' => {} }
  @opts.to_hash.each do |k,v|
    if v
      (app, key) = k.to_s.split('_')
      @config[app][key] = v
    end
  end
  @config['trello']['list'] ||= "To Do"

  validate_config

  Trello.configure do |trello|
    trello.developer_public_key = @config['trello']['developer_key']
    trello.member_token = @config['trello']['user_token']
  end

end

def validate_config
  errors = []
  errors << "Rally iteration must be specified on command line (-i)" if !@config['rally']['iteration']
  errors << "Rally workspace must be specified in either #{CONFIG_FILE} or on command line" if !@config['rally']["workspace"]
  errors << "Rally project must be specified in either #{CONFIG_FILE} or on command line" if !@config['rally']["project"]
  errors << "Rally API key must be specified in #{CONFIG_FILE}" if !@config['rally']["api_key"]
  errors << "Trello API key must be specified in #{CONFIG_FILE}" if !@config['trello']['developer_key']
  errors << "Trello user token must be specified in #{CONFIG_FILE}" if !@config['trello']['user_token']
  errors << "Trello board be specified in on command line (-b)" if !@config['trello']['board']
  errors << "Trello list be specified in on command line (-l)" if !@config['trello']['list']
  if errors.length > 0
    errors.each { |e| puts e }
    puts @opts
    abort
  end

end

# Get the Rally API client
def rally
  @rally ||= begin
    headers = RallyAPI::CustomHttpHeader.new({:vendor => "Trello", :name => "Trello Import", :version => "1.0"})
    config = {:base_url => RALLY_URL}
    config[:api_key]   = @config['rally']['api_key']
    config[:workspace]  = @config['rally']['workspace']
    config[:project]    = @config['rally']['project']
    config[:headers]    = headers #from RallyAPI::CustomHttpHeader.new()
    RallyAPI::RallyRestJson.new(config)
  end
end

def rally_stories_for_iteration(iteration)
  query = RallyAPI::RallyQuery.new()
  query.type = "hierarchicalrequirement"
  query.fetch = "Name,FormattedID,Project,ObjectID"
  query.page_size = 1000
  query.limit = 1000
  query.order = "FormattedID Desc"
  query.query_string = "(Iteration.Name = #{iteration})"
  rally.find(query)
end

def rally_defects_for_iteration(iteration)
  query = RallyAPI::RallyQuery.new()
  query.type = "defect"
  query.fetch = "Name,FormattedID,Project,ObjectID"
  query.page_size = 1000
  query.limit = 1000
  query.order = "FormattedID Desc"
  query.query_string = "(Iteration.Name = #{iteration})"
  rally.find(query)
end

def trello_board(name)
  board = Trello::Board.all().find { |b| b.name == name }
  if !board && name
    puts "Creating board '#{name}'"
    board = Trello::Board.create(name: name)
  end
  board
end

def trello_list(name, board)
  list = board.lists.find { |l| l.name == name }
  if !list && name
    puts "Creating list '#{name}'"
    list = Trello::List.create(name: name, board_id: board.id)
  end
  list
end

def cards(list)
  @cards ||= list.cards
end

def import_card(card_name, attachment_name, attachment_url, list)
  if cards(list).any? {|c| c.name == card_name }
    puts "Card '#{card_name}' already exists"
  else
    puts "Creating card: #{card_name}"
    card = Trello::Card.create(name: card_name, list_id: list.id)
    card.add_attachment(attachment_url, attachment_name)
  end
end

def import_rally_entities_as_cards(rally_entities, entity_type, attachment_name, trello_list)
  projectId = rally_entities.first.Project.read.ObjectID
  rally_entities.each do |entity|
    card_name = "#{entity.FormattedID}: #{entity.name}"
    story_url = "https://rally1.rallydev.com/#/#{projectId}d/detail/#{entity_type}/#{entity.ObjectID}"
    import_card(card_name, attachment_name, story_url, trello_list)
  end
end


read_config()
iteration = @config['rally']['iteration']

stories = rally_stories_for_iteration(iteration)
if stories.length < 1
  puts "No user stories found for iteration '#{iteration}'"
end
defects = rally_defects_for_iteration(iteration)
if defects.length < 1
  puts "No defects found for iteration '#{iteration}'"
end


board = trello_board(@config['trello']['board'])
list = trello_list(@config['trello']['list'], board)
puts "Importing to board '#{board.name}'"
puts "Importing to list '#{list.name}'"
import_rally_entities_as_cards(defects, 'defect', "Rally Defect", list)
import_rally_entities_as_cards(stories, 'userstory', "Rally User Story", list)

