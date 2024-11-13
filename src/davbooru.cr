require "db"
require "kemal"
require "kemal-basic-auth"
require "option_parser"
require "sqlite3"

require "./query_builder"
require "./indexer"

require "./models/post"
require "./models/tag"

module Davbooru
  extend self
  VERSION = "0.1.0"

  only_index = false
  dont_index = false
  tag_mode = false
  username = ""
  password = ""
  nsfw = false
  tag_mode = false

  @@total_media = nil

  def get_total(db : DB::Database, force_update : Bool = false) : Int64
    if @@total_media == nil
      @@total_media = (db.scalar "SELECT COUNT(id) FROM posts").as(Int64) || -1_i64
    end
  
    return @@total_media.not_nil!
  end

  class ImportantAuthHandler < Kemal::BasicAuth::Handler
    only ["/tags"]

    def call(context)
      return call_next(context) unless only_match?(context)
      super
    end
  end

  Dir.mkdir("./backup/") unless Dir.exists?("./backup/")
  File.copy("./default.db", "./davbooru.db") unless File.exists?("./davbooru.db")
  
  
  parser = OptionParser.new do |parser|
    parser.banner = "Usage: davbooru [command] [arguments]"
    parser.on("index", "Index new files over WebDAV, then quit immediately.") { only_index = true }
    parser.on("tag", "Subcommand to manage tags.") do
      tag_mode = true;
      parser.banner = "Usage: davbooru tag [command] [arguments]"
      parser.on("add", "Add a new tag.") do

      end
      parser.on("modify", "Modify and existing tag.") do

      end
      parser.on("delete", "Delete and existing tag.") do

      end
    end
    parser.on("--no-indexing", "Don't index new files over WebDAV.") do
      dont_index = true
      puts "Launching without scheduled indexing. New files won't be accessible on DAVbooru."
    end
    parser.on("--nsfw", "Changes some things to be specifically NSFW.") { nsfw = true }
    parser.on("-u", "--username=NAME", "Set WebDADV username used to index media.") { |name| username = name }
    parser.on("-p", "--password=PASS", "Set WebDADV password used to index media.") { |pass| password = pass }
    parser.on("-h", "--help", "Show this help.") do
      puts parser
      exit
    end
  end

  parser.parse

  if (only_index && dont_index)
    STDERR.puts "You can't index without indexing. Exiting..."
    puts parser
    exit(1)
  end

  if (username == "" || password == "")
    STDERR.puts "Provide WebDAV username and password. Exiting..."
    puts parser
    exit(1)
  end

  db = DB.open("sqlite3://./davbooru.db")
  indexer = Indexer.new(db, "https://seafile.nil.services/seafdav/", username, password)

  get "/" do
    site_title = "DAVbooru"
    media_count = get_total(db)
    render "src/views/index.ecr", "src/views/layout.ecr"
  end

  get "/search" do |env|
    search_string = env.params.query["q"]
    page = env.params.query["p"].to_i64
    posts = [] of Post
    qb = QueryBuilder.new(db, search_string, page.to_i64)
    puts qb.sql
    puts qb.path_filter
    if qb.path_filter
      db.query qb.sql, "%#{qb.path_filter}%" do |rs|
        rs.each do
          posts << Post.from_row(rs)
        end
      end
    else
      db.query qb.sql do |rs|
        rs.each do
          posts << Post.from_row(rs)
        end
      end
    end
    search_text = qb.text
    total_posts = posts.size
    site_title = "DAVbooru | Search: #{search_text}"
    if total_posts == 0
      message = "No posts found matching current criteria. :("
      back_url = "/search?q=&p=0"

      render "src/views/error.ecr", "src/views/layout.ecr"
    else
      total_pages = (total_posts / QueryBuilder::DEFAULT_PAGE_SIZE).ceil
      paged_posts = posts[(page * QueryBuilder::DEFAULT_PAGE_SIZE)..((page+1) * QueryBuilder::DEFAULT_PAGE_SIZE) - 1]
      
      render "src/views/search.ecr", "src/views/layout.ecr"
    end
  end

  get "/post/:id" do |env|
    post = nil
    tags = [] of Tag
    db.query "SELECT * FROM posts WHERE id = ? LIMIT 1", env.params.url["id"].to_i64 do |rs|
      rs.each do
        post = Post.from_row(rs)
      end
    end
    if post.nil?
      env.response.status_code = 404
      raise Kemal::Exceptions::CustomException.new env
    else
      db.query "SELECT tags.*, categories.name FROM tags JOIN post_tags ON post_tags.tag_id = tags.id JOIN categories ON categories.id = tags.category_id WHERE post_tags.post_id = ? ORDER BY categories.id ASC, tags.name ASC", post.id do |rs|
        rs.each do
          tags << Tag.from_row(rs)
        end
      end
      site_title = "DAVbooru | Post ##{post.id}"
      render "src/views/post.ecr", "src/views/layout.ecr"
    end
  end

  post "/post/:id" do |env|
    post_id = env.params.url["id"]
    back_url = "/post/#{post_id}"
    tag_string = env.params.body["tags"]
    tag_names = tag_string.split(" ")
    tag_ids = [] of Int64
    invalid_tags = [] of String
    tag_names.each do |name|
      tag = Tag.cache.values.find {|t| t.name == name}
      unless tag
        db.query "SELECT tags.*, categories.name FROM tags JOIN categories ON tags.category_id = categories.id WHERE tags.name = ? LIMIT 1", name.strip do |rs|
          rs.each do
            tag = Tag.from_row(rs)
          end
        end
      end

      if tag.nil?
        invalid_tags << name
      else
        tag_ids << tag.id
      end
    end

    db.exec "DELETE FROM post_tags WHERE post_id = #{post_id}"

    db.transaction do |t|
      tag_ids.each do |id|
        t.connection.exec "INSERT INTO post_tags VALUES(#{post_id}, #{id})"
      end
      t.commit
    end

    if invalid_tags.empty?
      env.redirect back_url
    else
      env.response.status_code = 400
      message = "Ignored unknown tags: #{invalid_tags.join(", ")}"
      site_title = "DAVbooru | Warning"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  get "/random" do |env|
    begin
      search_string = env.params.query["q"]
      posts = [] of Post
      qb = QueryBuilder.new(db, search_string, 1)
      db.query qb.sql do |rs|
        rs.each do
          posts << Post.from_row(rs)
        end
      end
      env.redirect "/post/#{posts.sample.id}?q=#{search_string}"
    rescue
      env.redirect "/post/#{rand(get_total(db))}"
    end
  end

  get "/tags" do |env|
    tags = [] of Tag
    categories = [] of String
    db.query "SELECT tags.*, categories.name FROM tags JOIN categories ON tags.category_id = categories.id ORDER BY category_id ASC, tags.id ASC" do |rs|
      rs.each do
        tags << Tag.from_row(rs)
      end
    end
    
    db.query "SELECT name FROM categories ORDER BY id ASC" do |rs|
      rs.each do
        categories << rs.read(String)
      end
    end

    site_title = "DAVbooru | Tag List"
    render "src/views/tags.ecr", "src/views/layout.ecr"
  end

  post "/tags" do |env|
    back_url = "/tags"
    begin
      tag_id = env.params.body["id"]
      tag_parent = env.params.body["parent-id"]
      tag_name = env.params.body["name"]
      tag_category = env.params.body["category"]
      tag_description = env.params.body["description"]

      args = [] of DB::Any
      args << (tag_id.blank? ? nil : tag_id.to_i64)
      args << tag_name
      args << (tag_category.blank? ? 1 : tag_category.to_i64)
      args << (tag_parent.blank? ? nil : tag_parent.to_i64)
      args << tag_description

      result = db.exec "INSERT OR IGNORE INTO tags VALUES (?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET name=excluded.name, category_id=excluded.category_id, parent_id=excluded.parent_id, description=excluded.description", args: args

      env.redirect back_url + "#tag-#{result.last_insert_id}"
    rescue e
      site_title = "DAVbooru | Error"
      message = "DAVbooru encountered an error: #{e}"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  if only_index
    puts "Starting indexing..."
    indexer.run
    puts "Indexing finished!"
    puts "#{get_total(db, true)} in database."
  else
    unless dont_index
      spawn do
        loop do
          puts "Starting indexing..."
          indexer.run
          puts "Indexing finished!"
          puts "#{get_total(db, true)} in database."
          sleep 60.minutes
        end
      end
    end

    Kemal.config.auth_handler = ImportantAuthHandler
    basic_auth username, password

    Kemal.run
    db.close
    puts("Everything closed gracefully!")
  end
end
