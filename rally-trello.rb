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
  story_query = RallyAPI::RallyQuery.new()
  story_query.type = "hierarchicalrequirement"
  story_query.fetch = "Name,FormattedID,Project,ObjectID"
  story_query.page_size = 1000
  story_query.limit = 1000
  story_query.order = "FormattedID Asc"
  story_query.query_string = "(Iteration.Name = #{iteration})"
  rally.find(story_query)
end

def import_stories_as_cards(rally_stories, trello_board_name, trello_list_name)
  projectId = rally_stories.first.Project.read.ObjectID

  board = Trello::Board.all().find { |b| b.name == trello_board_name }
  if board
    puts "Importing to board '#{trello_board_name}'"
  else
    puts "Creating board '#{trello_board_name}'"
    board = Trello::Board.create(name: trello_board_name)
  end

  list = board.lists.find { |l| l.name == trello_list_name }
  if list
    puts "Importing to list '#{trello_list_name}'"
  else
    puts "Creating list '#{trello_list_name}'"
    list = Trello::List.create(name: trello_list_name, board_id: board.id)
  end

  cards = list.cards

  rally_stories.each do |story|
    card_name = "#{story.FormattedID}: #{story.name}"
    if cards.any? {|c| c.name == card_name }
      puts "Card '#{card_name}' already exists"
    else
      puts "Creating card: #{card_name}"
      card = Trello::Card.create(name: card_name, list_id: list.id)
      story_url = "https://rally1.rallydev.com/#/#{projectId}d/detail/userstory/#{story.ObjectID}"
      card.add_attachment(story_url, "Rally User Story")
    end
  end
end

read_config()
iteration = @config['rally']['iteration']
stories = rally_stories_for_iteration(iteration)
if stories.length < 1
  puts "No user stories found for iteration '#{iteration}'"
  abort
end
import_stories_as_cards(stories, @config['trello']['board'], @config['trello']['list'])
