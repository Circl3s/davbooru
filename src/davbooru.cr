require "db"
require "kemal"
require "kemal-basic-auth"
require "option_parser"
require "sqlite3"
require "uri"

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
  base_url = ""
  nsfw = false
  thumbnails = true

  class ImportantAuthHandler < Kemal::BasicAuth::Handler
    only ["/tags/edit", "/post/:id/edit"]

    def call(context)
      return call_next(context) unless only_match?(context)
      super
    end
  end

  Dir.mkdir("./backup/") unless Dir.exists?("./backup/")
  Dir.mkdir_p("./public/thumb/") unless Dir.exists?("./public/thumb/")
  File.copy("./default.db", "./davbooru.db") unless File.exists?("./davbooru.db")

  parser = OptionParser.new do |parser|
    parser.banner = "Usage: davbooru [command] [arguments]"
    parser.on("index", "Index new files over WebDAV, then quit immediately.") { only_index = true }
    parser.on("--no-indexing", "Don't index new files over WebDAV.") do
      dont_index = true
      puts "Launching without scheduled indexing. New files won't be accessible on DAVbooru."
    end
    parser.on("--no-thumbnails", "Disable thumbnail generation.") { thumbnails = false }
    parser.on("--nsfw", "Changes some things to be specifically NSFW.") { nsfw = true }
    parser.on("-u", "--username=NAME", "Set WebDADV username used to index media.") { |name| username = name }
    parser.on("--url=URL", "Base URL of the WebDAV server.") { |url| base_url = url }
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

  if (username == "" || password == "" || base_url == "")
    STDERR.puts "Provide WebDAV username, password, and URL. Exiting..."
    puts parser
    exit(1)
  end

  db = DB.open("sqlite3://./davbooru.db?journal_mode=wal&synchronous=normal&foreign_keys=true")
  indexer = Indexer.new(db, base_url, username, password)

  get "/" do
    site_title = "DAVbooru"
    media_count = indexer.get_total()
    render "src/views/index.ecr", "src/views/layout.ecr"
  end

  get "/search" do |env|
    show_favourites = false
    search_string = env.params.query["q"]
    search_param = URI.encode_www_form(search_string)
    page = env.params.query["p"].to_i64
    posts = [] of Post
    qb = QueryBuilder.new(db, search_string, page.to_i64)
    if qb.path_filter
      db.query qb.sql, "%#{qb.path_filter}%" do |rs|
        rs.each do
          posts << Post.from_row(rs, indexer)
        end
      end
    else
      db.query qb.sql do |rs|
        rs.each do
          posts << Post.from_row(rs, indexer)
        end
      end
    end
    total_posts = posts.size
    site_title = "DAVbooru | Search: #{search_string}"
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
        post = Post.from_row(rs, indexer)
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
      if thumbnails && !File.exists?("./public/thumb/#{post.id}.webp")
        indexer.generate_thumbnail(post.id, post.url)
      end
      render "src/views/post.ecr", "src/views/layout.ecr"
    end
  end

  post "/post/:id/edit" do |env|
    post_id = env.params.url["id"]
    back_url = "/post/#{post_id}"
    tag_string = env.params.body["tags"]
    tag_names = tag_string.strip.split(" ")
    tag_ids = [] of Int64
    invalid_tags = [] of String
    tag_names.each do |name|
      next if name.blank?
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

    db.transaction do |t|
      t.connection.exec "DELETE FROM post_tags WHERE post_id = ?", post_id

      tag_ids.each do |id|
        t.connection.exec "INSERT OR IGNORE INTO post_tags VALUES(?, ?)", post_id, id
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

  get "/post/:id/thumbnail" do |env|
    id = env.params.url["id"]
    url = env.params.query["url"]? || ""
    if thumbnails && !File.exists?("./public/thumb/#{id}.webp")
      begin
        indexer.generate_thumbnail(id, url)
      rescue
        halt env, status_code: 404, response: "No thumb for you. :("
      end
    end
    env.redirect "/thumb/#{id}.webp"
  end

  get "/favourites" do |env|
    show_favourites = true
    paged_posts = [] of Post
    qb = QueryBuilder.new(db, "", 0)
    total_pages = 0
    search_param = ""
    site_title = "DAVbooru | Favourites"
    render "src/views/search.ecr", "src/views/layout.ecr"
  end

  get "/random" do |env|
    begin
      search_string = env.params.query["q"]
      search_param = URI.encode_www_form(search_string)
      posts = [] of Post
      qb = QueryBuilder.new(db, search_string, 1)
      if qb.path_filter
        db.query qb.sql, "%#{qb.path_filter}%" do |rs|
          rs.each do
            posts << Post.from_row(rs, indexer)
          end
        end
      else
        db.query qb.sql do |rs|
          rs.each do
            posts << Post.from_row(rs, indexer)
          end
        end
      end
      env.redirect "/post/#{posts.sample.id}?q=#{search_param}"
    rescue e
      puts "RANDOM ERROR: #{e}"
      env.redirect "/post/#{rand(indexer.get_total())}"
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

  post "/tags/edit" do |env|
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
    indexer.run
  else
    unless dont_index
      spawn do
        loop do
          indexer.run
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
