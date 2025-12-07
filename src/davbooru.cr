require "db"
require "html"
require "kemal"
require "kemal-basic-auth"
require "kemal-session"
require "kemal-flash"
require "option_parser"
require "sqlite3"
require "uri"

require "./query_builder"
require "./indexer"

require "./models/post"
require "./models/tag"
require "./models/album"
require "./models/wiki"

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
  testing = false

  class ImportantAuthHandler < Kemal::BasicAuth::Handler
    only ["/tag/:id"]
    only(["/tag/edit", "/post/:id/edit", "/post/:id/delete", "/tag/:id/mass_tag", "/tag/:id/mass_remove", "/albums/create", "/album/:id/delete", "/album/:id/add", "/album/:id/remove", "/album/:id/edit", "/album/:id/reorder"], method: "POST")

    def call(context)
      return call_next(context) unless only_match?(context)
      super
    end
  end

  Dir.mkdir("./backup/") unless Dir.exists?("./backup/")
  Dir.mkdir_p("./public/thumb/") unless Dir.exists?("./public/thumb/")
  File.copy("./default.db", "./davbooru.db") unless File.exists?("./davbooru.db")

  unless Dir.exists?("./public/articles/default")
    Dir.mkdir_p("./public/articles/") unless Dir.exists?("./public/articles/")
    git = Process.find_executable("git")
    if git
      Process.run(git, ["clone", "https://github.com/Circl3s/davbooru.wiki.git", "./public/articles/default"])
    else
      STDERR.puts "Git not found. Default wiki articles will not be available."
    end
  end

  parser = OptionParser.new do |parser|
    parser.banner = "Usage: davbooru [command] [arguments]"
    parser.on("index", "Index new files over WebDAV, then quit immediately.") { only_index = true }
    parser.on("--no-indexing", "Don't index new files over WebDAV.") do
      dont_index = true
      puts "Launching without scheduled indexing. New files won't be accessible on DAVbooru."
    end
    parser.on("--no-thumbnails", "Disable thumbnail generation.") { thumbnails = false }
    parser.on("--testing", "Use a test database instead of the real one.") do
      testing = true
      File.copy("./davbooru.db", "./test.db")
    end
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

  db = DB.open("sqlite3://./#{testing ? "test" : "davbooru"}.db?journal_mode=wal&synchronous=normal&foreign_keys=true")
  
  # Migration: Add etag column if it doesn't exist
  begin
    db.exec "ALTER TABLE posts ADD COLUMN etag TEXT"
  rescue
    # Column likely already exists
  end

  # Migration: Create albums table
  begin
    db.exec "CREATE TABLE IF NOT EXISTS albums (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, description TEXT)"
  rescue e
    puts "Error creating albums table: #{e}"
  end

  # Migration: Create album_posts table
  begin
    db.exec "CREATE TABLE IF NOT EXISTS album_posts (album_id INTEGER NOT NULL, post_id INTEGER NOT NULL, \"order\" INTEGER NOT NULL, PRIMARY KEY (album_id, post_id), FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE, FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE)"
  rescue e
    puts "Error creating album_posts table: #{e}"
  end

  indexer = Indexer.new(db, base_url, username, password)

  Kemal::Session.config.secret = ":)"

  get "/" do |env|
    site_title = "DAVbooru"
    media_count = indexer.get_total
    tagged = indexer.get_tagged
    tagging_progress = (tagged / media_count * 100).round(1)
    render "src/views/index.ecr", "src/views/layout.ecr"
  end

  get "/search" do |env|
    search_string = env.params.query["q"]
    search_param = URI.encode_www_form(search_string)
    page = env.params.query["p"].to_i64
    posts = [] of Post
    qb = QueryBuilder.new(db, search_string)
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
    site_title = "Search: #{search_string} | DAVbooru"
    if total_posts == 0
      message = "No posts found matching current criteria. :("
      back_url = "/search?q=&p=0"

      render "src/views/error.ecr", "src/views/layout.ecr"
    else
      total_pages = (total_posts / QueryBuilder::DEFAULT_PAGE_SIZE).ceil
      paged_posts = posts[(page * QueryBuilder::DEFAULT_PAGE_SIZE)..((page+1) * QueryBuilder::DEFAULT_PAGE_SIZE) - 1]

      unless qb.unknown_tags.empty?
        env.flash["toast-enabled"] = "true"
        env.flash["toast-title"] = "Ignoring unknown tags"
        env.flash["toast-body"] = qb.unknown_tags.join(", ")
        env.flash["toast-type"] = "warning"
      end

      render "src/views/search.ecr", "src/views/layout.ecr"
    end
  end

  get "/post/:id" do |env|
    search_param = URI.encode_www_form(env.params.query["q"]? || "")
    post = nil
    tags = [] of Tag
    relevant_tags = [] of String
    album_id = env.params.query["album"]?
    album = nil
    album_posts = [] of Post

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
          tag = Tag.from_row(rs)
          relevant_tags << tag.name if [2, 3, 4, 5].includes?(tag.category_id)
          tags << tag
        end
      end

      duplicates = [] of Post
      if post.etag
        db.query "SELECT * FROM posts WHERE etag = ? AND id != ?", post.etag, post.id do |rs|
          rs.each do
            duplicates << Post.from_row(rs, indexer)
          end
        end
      end

      all_albums = [] of Album
      db.query "SELECT albums.* FROM albums JOIN album_posts ON albums.id = album_posts.album_id WHERE album_posts.post_id = ?", post.id do |rs|
        rs.each do
          all_albums << Album.from_row(rs)
        end
      end

      if album_id
        db.query "SELECT * FROM albums WHERE id = ? LIMIT 1", album_id.to_i64 do |rs|
          rs.each do
            album = Album.from_row(rs)
            album_posts = album.posts(db, indexer)
          end
        end
        current_post_index = album_posts.map { |p| p.id }.index(post.id)
      end

      env.set "thumb", post.thumbnail
      env.set "desc", relevant_tags.join(", ")
      site_title = "Post ##{post.id} | DAVbooru"
      render "src/views/post.ecr", "src/views/layout.ecr"
    end
  end

  post "/post/:id/edit" do |env|
    search_param = URI.encode_www_form(env.params.query["q"]? || "")
    post_id = env.params.url["id"]
    back_url = "/post/#{post_id}?q=#{search_param}"
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

    unless invalid_tags.empty?
      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Ignored unknown tags"
      env.flash["toast-body"] = invalid_tags.join(", ")
      env.flash["toast-type"] = "danger"
    end

    env.redirect back_url
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

  post "/post/:id/kudos" do |env|
    search_param = URI.encode_www_form(env.params.query["q"]? || "")
    post_id = env.params.url["id"]
    cookie = env.request.cookies["kudos"]?
    env.flash["toast-enabled"] = "true"
    if cookie
      env.flash["toast-title"] = "Error"
      env.flash["toast-body"] = "You can't #{nsfw ? "cum" : "send kudos"} to the same post more than once a day."
      env.flash["toast-type"] = "danger"
    else
      db.exec "UPDATE posts SET kudos = kudos + 1 WHERE id = ?", post_id
      
      env.flash["toast-title"] = "Success"
      env.flash["toast-body"] = "Successfully #{nsfw ? "came" : "sent kudos"} to ##{post_id}!"
      env.flash["toast-type"] = "success"
      env.response.cookies << HTTP::Cookie.new(name: "kudos", value: "true", path: "/post/#{post_id}/kudos", expires: (Time.utc() + 1.day).at_beginning_of_day)
    end

    env.redirect "/post/#{post_id}?q=#{search_param}"
  end

  post "/post/:id/delete" do |env|
    search_param = URI.encode_www_form(env.params.query["q"]? || "")
    post_id = env.params.url["id"]
    blacklist = env.params.body["blacklist"]?

    begin
      db.transaction do |t|
        t.connection.exec "DELETE FROM post_tags WHERE post_id = ?", post_id
        t.connection.exec "DELETE FROM posts WHERE id = ?", post_id
        t.commit
      end

      File.delete?("./public/thumb/#{post_id}.webp")
      File.write("./blacklist.davbooru", "\n" + blacklist, mode: "a") if blacklist
      indexer.update_lists if blacklist

      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Success"
      env.flash["toast-body"] = "Successfully deleted ##{post_id}."
      env.flash["toast-type"] = "success"

      env.redirect "/search?q=#{search_param}&p=0"
    rescue e
      message = e
      site_title = "Error | DAVbooru"
      back_url = "/post/#{post_id}?q=#{search_param}"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  get "/favourites" do |env|
    env.set "show_favourites", "true"
    paged_posts = [] of Post
    qb = QueryBuilder.new(db, "")
    total_pages = 0
    search_param = ""
    site_title = "Favourites | DAVbooru"
    render "src/views/search.ecr", "src/views/layout.ecr"
  end

  get "/random" do |env|
    begin
      search_string = env.params.query["q"]
      search_param = URI.encode_www_form(search_string)
      posts = [] of Post
      qb = QueryBuilder.new(db, search_string)
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

  get "/tag" do |env|
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

    site_title = "Tag List | DAVbooru"
    render "src/views/tags.ecr", "src/views/layout.ecr"
  end

  post "/tag/edit" do |env|
    back_url = "/tag"
    begin
      tag_id = env.params.body["id"]
      tag_parent = env.params.body["parent-id"]
      tag_name = env.params.body["name"]
      tag_category = env.params.body["category"]
      tag_description = env.params.body["description"]

      tag_id = tag_id.blank? ? nil : tag_id.to_i64
      tag_parent = tag_parent.blank? ? nil : tag_parent.to_i64

      raise "You can't have children with yourself. I tried." if tag_id == tag_parent && (tag_id || tag_parent != nil)

      args = [] of DB::Any
      args << tag_id
      args << tag_name
      args << (tag_category.blank? ? 1 : tag_category.to_i64)
      args << tag_parent
      args << tag_description

      result = db.exec "INSERT OR IGNORE INTO tags VALUES (?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET name=excluded.name, category_id=excluded.category_id, parent_id=excluded.parent_id, description=excluded.description", args: args

      env.redirect back_url + "#tag-#{result.last_insert_id}"
    rescue e
      site_title = "Error | DAVbooru"
      message = "DAVbooru encountered an error:<br />#{e}"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  get "/tag/:id/" do |env|
    tag_id = env.params.url["id"]
    tag = nil
    db.query "SELECT tags.*, categories.name FROM tags JOIN categories ON tags.category_id = categories.id WHERE tags.id = ? LIMIT 1", tag_id do |rs|
      rs.each do
        tag = Tag.from_row(rs)
      end
    end
    if tag.nil?
      env.response.status_code = 404
      raise Kemal::Exceptions::CustomException.new env
    else
      site_title = "Tagger: #{tag.name} | DAVbooru"
      render "src/views/tagger.ecr", "src/views/layout.ecr"
    end
  end

  post "/tag/:id/mass_tag" do |env|
    tag_id = env.params.url["id"].to_i64
    predicate = URI.encode_path(env.params.body["predicate"])
    respect_tagme = (env.params.body["respect_tagme"]? || false) == "true"
    posts = [] of Post
    affected = 0_i64

    begin
      db.query "SELECT posts.* FROM posts JOIN post_tags ON post_id = posts.id WHERE posts.url LIKE ? #{respect_tagme ? "AND tag_id = 1 " : ""}GROUP BY posts.id", "%#{predicate}%" do |rs|
        rs.each do
          posts << Post.from_row(rs, indexer)
        end
      end

      db.transaction do |t|
        posts.each do |post|
          result = t.connection.exec "INSERT OR IGNORE INTO post_tags VALUES(?, ?)", post.id, tag_id
          affected += result.rows_affected
        end
        t.commit
      end

      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Success"
      env.flash["toast-body"] = "Posts affected: #{affected}"
      env.flash["toast-type"] = "info"
      env.redirect "/search?q=path:\"#{predicate}\"&p=0"
    rescue e
      back_url = "/tag/#{tag_id}"
      site_title = "Error | DAVbooru"
      message = "DAVbooru encountered an error:<br />#{e}"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  post "/tag/:id/mass_remove" do |env|
    tag_id = env.params.url["id"].to_i64
    predicate = URI.encode_path(env.params.body["predicate"])
    respect_tagme = (env.params.body["respect_tagme"]? || false) == "true"
    posts = [] of Post
    affected = 0

    begin
      db.query "SELECT posts.* FROM posts JOIN post_tags ON post_id = posts.id WHERE posts.url LIKE ? #{respect_tagme ? "AND tag_id = 1 " : ""}GROUP BY posts.id", "%#{predicate}%" do |rs|
        rs.each do
          posts << Post.from_row(rs, indexer)
        end
      end

      db.transaction do |t|
        posts.each do |post|
          result = t.connection.exec "DELETE FROM post_tags WHERE post_id = ? AND tag_id = ?", post.id, tag_id
          affected += result.rows_affected
        end
        t.commit
      end

      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Success"
      env.flash["toast-body"] = "Posts affected: #{affected}"
      env.flash["toast-type"] = "info"
      env.redirect "/search?q=path:\"#{predicate}\"&p=0"
    rescue e
      back_url = "/tag/#{tag_id}"
      site_title = "Error | DAVbooru"
      message = "DAVbooru encountered an error:<br />#{e}"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  # Albums

  get "/albums" do |env|
    search_string = env.params.query["q"]? || ""
    page = (env.params.query["p"]? || "0").to_i64

    albums = [] of Album
    matching_posts = [] of Post
    first_posts = [] of Post?

    qb = QueryBuilder.new(db, search_string)
    sql = qb.sql

    unless qb.valid_tags.empty?
      db.query sql do |rs|
        rs.each do
          matching_posts << Post.from_row(rs, indexer)
        end
      end
    end

    db.query "SELECT * FROM albums ORDER BY id DESC" do |rs|
      rs.each do
        album = Album.from_row(rs)
        all_posts = album.posts(db, indexer)
        unless qb.valid_tags.empty?
          should_include = all_posts.any? { |post| matching_posts.map(&.id).includes?(post.id) }
          albums << album if should_include
          first_posts << all_posts.first? if should_include
        else
          albums << album
          first_posts << all_posts.first?
        end
      end
    end
    
    total_albums = albums.size
    
    total_pages = (total_albums / 12).ceil
    paged_albums = albums[(page * 12)..((page+1) * 12) - 1]
    paged_first_posts = first_posts[(page * 12)..((page+1) * 12) - 1]

    unless qb.unknown_tags.empty?
      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Ignoring unknown tags"
      env.flash["toast-body"] = qb.unknown_tags.join(", ")
      env.flash["toast-type"] = "warning"
    end

    site_title = "Albums | DAVbooru"
    render "src/views/albums.ecr", "src/views/layout.ecr"
  end

  post "/albums/create" do |env|
    name = env.params.body["name"]
    description = env.params.body["description"]
    
    begin
      db.exec "INSERT INTO albums (name, description) VALUES (?, ?)", name, description
      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Success"
      env.flash["toast-body"] = "Album created successfully"
      env.flash["toast-type"] = "success"
      env.redirect "/albums"
    rescue e
      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Error"
      env.flash["toast-body"] = "Error creating album: #{e.message}"
      env.flash["toast-type"] = "danger"
      env.redirect "/albums"
    end
  end

  get "/album/:id" do |env|
    id = env.params.url["id"].to_i64
    album = nil
    db.query "SELECT * FROM albums WHERE id = ?", id do |rs|
      rs.each do
        album = Album.from_row(rs)
      end
    end

    if album
      posts = album.posts(db, indexer)
      thumbnail = posts.first?.nil? ? "/thumb/placeholder.webp" : posts.first.thumbnail

      env.set "thumb", thumbnail
      env.set "desc", album.description
      site_title = "#{album.name} | DAVbooru"
      render "src/views/album.ecr", "src/views/layout.ecr"
    else
      back_url = "/albums"
      site_title = "Error | DAVbooru"
      message = "Album not found"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  post "/album/:id/edit" do |env|
    id = env.params.url["id"].to_i64
    name = env.params.body["name"]
    description = env.params.body["description"]
    
    begin
      db.exec "UPDATE albums SET name = ?, description = ? WHERE id = ?", name, description, id
      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Success"
      env.flash["toast-body"] = "Album edited successfully"
      env.flash["toast-type"] = "success"
      env.redirect "/album/#{id}"
    rescue e
      back_url = "/album/#{id}"
      site_title = "Error | DAVbooru"
      message = "Error editing album: #{e.message}"
      render "src/views/error.ecr", "src/views/layout.ecr"
    end
  end

  post "/album/:id/add" do |env|
    album_id = env.params.url["id"].to_i64
    post_id = env.params.body["post_id"].to_i64

    valid_album = begin db.scalar("SELECT 1 FROM albums WHERE id = ?", album_id).as(Int64?) rescue nil end
    valid_post = begin db.scalar("SELECT 1 FROM posts WHERE id = ?", post_id).as(Int64?) rescue nil end
    
    if valid_album.nil?
      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Error"
      env.flash["toast-body"] = "Album not found"
      env.flash["toast-type"] = "danger"
      env.redirect "/post/#{post_id}"
    elsif valid_post.nil?
      env.flash["toast-enabled"] = "true"
      env.flash["toast-title"] = "Error"
      env.flash["toast-body"] = "Post not found"
      env.flash["toast-type"] = "danger"
      env.redirect "/album/#{album_id}"
    else
      # Get max order
      max_order = 0
      max_order = db.scalar("SELECT MAX(\"order\") FROM album_posts WHERE album_id = ?", album_id).as(Int64?) || 0
      
      begin
        db.exec "INSERT OR IGNORE INTO album_posts (album_id, post_id, \"order\") VALUES (?, ?, ?)", album_id, post_id, max_order + 1
        env.flash["toast-enabled"] = "true"
        env.flash["toast-title"] = "Success"
        env.flash["toast-body"] = "Post ##{post_id} added to album successfully"
        env.flash["toast-type"] = "success"
        env.redirect "/album/#{album_id}"
      rescue e
        back_url = "/album/#{album_id}"
        site_title = "Error | DAVbooru"
        message = "Error adding post to album: #{e.message}"
        render "src/views/error.ecr", "src/views/layout.ecr"
      end
    end
  end

  post "/album/:id/remove" do |env|
    album_id = env.params.url["id"].to_i64
    post_id = env.params.body["post_id"].to_i64
    
    db.exec "DELETE FROM album_posts WHERE album_id = ? AND post_id = ?", album_id, post_id
    env.redirect "/album/#{album_id}"
  end

  post "/album/:id/delete" do |env|
    album_id = env.params.url["id"].to_i64
    db.exec "DELETE FROM albums WHERE id = ?", album_id
    env.redirect "/albums"
  end

  post "/album/:id/reorder" do |env|
    album_id = env.params.url["id"].to_i64
    post_ids_str = env.params.body["post_ids"]?
    if post_ids_str
      post_ids = post_ids_str.split(",").map(&.to_i64)
      db.transaction do |t|
        post_ids.each_with_index do |pid, index|
          t.connection.exec "UPDATE album_posts SET \"order\" = ? WHERE album_id = ? AND post_id = ?", index + 1, album_id, pid
        end
        t.commit
      end
    end
    env.redirect "/album/#{album_id}"
  end

  get "/wiki" do |env|
    all_articles = Wiki.all_articles
    article = Wiki.new("", "# Welcome to the wiki!")
    mentioned_tags = [] of Tag

    site_title = "Wiki | DAVbooru"
    render "src/views/wiki.ecr", "src/views/layout.ecr"
  end

  get "/wiki/*page" do |env|
    page = env.params.url["page"]
    page = page + ".md" unless page.ends_with?(".md")
    
    all_articles = Wiki.all_articles
    article = Wiki.from_path(page)
    if article.nil?
      env.redirect "/wiki"
    else
      mentioned_tags = article.mentioned_tags(db)
      
      site_title = "#{article.title} | DAVbooru"
      render "src/views/wiki.ecr", "src/views/layout.ecr"
    end
  end

  #*
  #* API
  #*

  get "/api/suggest" do |env|
    query = env.params.query["q"]? || ""
    nopseudo = (env.params.query["nopseudo"]? || "") === "1"
    tags = [] of Tag

    if (query.includes?("sort:") && !nopseudo)
      filter = query.lchop "sort:"
      possible_matches = [] of String
      QueryBuilder::SORTING_TYPES.keys.each do |key|
        possible_matches << key unless (key.includes?("cum") && !nsfw)
      end
      if query.matches? /sort:.*:/
        possible_matches.each do |key|
          if key.matches? /^#{filter}/
            tags << Tag.pseudo("sort:#{key}")
          end
        end
      else
        possible_matches.each do |key|
          if (key.matches?(/^#{filter}/) && !key.includes?(":"))
            tags << Tag.pseudo("sort:#{key}")
          end
        end
      end
      tags.to_json
    end

    abbr_query = query.each_char.map_with_index do |c, i|
      if i == query.size - 1
        "#{c}%"
      else
        "#{c}%\\_"
      end
    end.join

    db.query "SELECT tags.*, categories.name FROM tags JOIN categories ON tags.category_id = categories.id WHERE tags.name LIKE ? ESCAPE '\\' \
      UNION \
      SELECT tags.*, categories.name FROM tags JOIN categories ON tags.category_id = categories.id WHERE tags.name LIKE ? \
      ORDER BY tags.name ASC LIMIT 5", "#{abbr_query}", "#{query}%" do |rs|
      rs.each do
        tags << Tag.from_row(rs)
      end
    end

    env.response.content_type = "application/json"
    tags.to_json
  end

  if only_index
    indexer.run
  else
    spawn do
      loop do
        indexer.backup unless testing
        indexer.run unless dont_index
        sleep 60.minutes
      end
    end

    Kemal.config.auth_handler = ImportantAuthHandler
    basic_auth username, password

    Kemal.run
    db.close
    puts("Everything closed gracefully!")
  end
end
